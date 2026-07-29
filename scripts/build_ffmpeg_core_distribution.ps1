param(
    [string]$PinFile = "",
    [string]$PrototypeRoot = "",
    [string]$OutputRoot = "",
    [string]$CacheRoot = "",
    [string]$FfmpegSourceArchivePath = "",
    [string]$BuildScriptsArchivePath = "",
    [switch]$BootstrapPin,
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "FFmpeg core distribution generation requires the pinned PowerShell 7 build environment."
}

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Assert-PathInsideDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $fullPath = Get-FullPath -Path $Path
    $fullDirectory = Get-FullPath -Path $Directory
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $fullPath"
    }
}

function Get-RelativeArchivePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $fullPath = Get-FullPath -Path $Path
    $fullDirectory = Get-FullPath -Path $Directory
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $fullPath"
    }
    return $fullPath.Substring($prefix.Length).Replace('\', '/')
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [ValidateSet("Preserve", "Lf", "CrLf")]
        [string]$LineEndings = "Preserve"
    )

    $normalizedContent = $Content
    if ($LineEndings -ne "Preserve") {
        $normalizedContent = $normalizedContent.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($LineEndings -eq "CrLf") {
            $normalizedContent = $normalizedContent.Replace("`n", "`r`n")
        }
    }
    [System.IO.File]::WriteAllText(
        $Path,
        $normalizedContent,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [int64]$ExpectedSize,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $parent = Split-Path -Parent $Path
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $downloadPath = "$Path.download"
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force
        }
        try {
            $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
            if ($null -ne $bits) {
                Start-BitsTransfer -Source $Url -Destination $downloadPath
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $downloadPath
            }
            Move-Item -LiteralPath $downloadPath -Destination $Path
        } finally {
            if (Test-Path -LiteralPath $downloadPath) {
                Remove-Item -LiteralPath $downloadPath -Force
            }
        }
    }

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -ne $ExpectedSize) {
        throw "Pinned input size mismatch. Expected=$ExpectedSize Actual=$($file.Length) Path=$Path"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256) {
        throw "Pinned input SHA-256 mismatch. Expected=$ExpectedSha256 Actual=$actualSha256 Path=$Path"
    }
    return $file.FullName
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    $sourceFullPath = Get-FullPath -Path $SourceRoot
    $destinationFullPath = Get-FullPath -Path $DestinationPath
    $destinationParent = Split-Path -Parent $destinationFullPath
    Assert-PathInsideDirectory -Path $destinationFullPath -Directory $destinationParent
    if (Test-Path -LiteralPath $destinationFullPath) {
        Remove-Item -LiteralPath $destinationFullPath -Force
    }

    $fileStream = [System.IO.File]::Open(
        $destinationFullPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            [System.Text.Encoding]::UTF8
        )
        try {
            $fixedTimestamp = [System.DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
            $files = @(Get-ChildItem -LiteralPath $sourceFullPath -Recurse -File | Sort-Object FullName)
            foreach ($file in $files) {
                $relativePath = Get-RelativeArchivePath -Path $file.FullName -Directory $sourceFullPath
                $entry = $archive.CreateEntry(
                    $relativePath,
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = $fixedTimestamp
                $inputStream = [System.IO.File]::OpenRead($file.FullName)
                $outputStream = $entry.Open()
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
}

function Copy-DirectoryFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $sourceFullPath = Get-FullPath -Path $Source
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceFullPath -Recurse -File)) {
        $relativePath = Get-RelativeArchivePath -Path $file.FullName -Directory $sourceFullPath
        $targetPath = Join-Path $Destination $relativePath.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $targetPath
    }
}

function Get-FileEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        size = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($PinFile)) {
    $PinFile = Join-Path $repoRoot "requirements\ffmpeg-core-runtime.json"
}
$pinPath = (Resolve-Path -LiteralPath $PinFile).Path
$pin = Get-Content -LiteralPath $pinPath -Encoding utf8 -Raw | ConvertFrom-Json -DateKind String
if ([int]$pin.schema_version -ne 1 -or [string]$pin.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg core runtime pin: $pinPath"
}
if ([string]$pin.status -ne "candidate" -or [bool]$pin.adopted) {
    throw "The core distribution builder only accepts an unadopted candidate pin."
}

$version = [string]$pin.version
$ffmpegCommit = [string]$pin.ffmpeg_commit
$variant = [string]$pin.variant
$licenseSpdx = [string]$pin.license
$binary = $pin.binary
$source = $pin.corresponding_source
$archiveBuilder = $source.archive_builder
$ffmpegSource = $source.ffmpeg_archive
$buildScriptsSource = $source.build_scripts_archive
$repository = [string]$source.repository
$releaseTag = [string]$source.release_tag
$releaseBaseUrl = "https://github.com/$repository/releases/download/$releaseTag"
$binaryAssetName = [string]$binary.asset_name
$sourceAssetName = [string]$source.asset_name
$archiveRootName = [string]$binary.archive_root

$requiredStrings = [ordered]@{
    version = $version
    ffmpeg_commit = $ffmpegCommit
    variant = $variant
    license = $licenseSpdx
    binary_build_provider = [string]$binary.build_provider
    binary_build_tag = [string]$binary.build_tag
    binary_build_commit = [string]$binary.build_commit
    binary_btbn_build_commit = [string]$binary.btbn_build_commit
    binary_builder_image = [string]$binary.builder_image
    binary_archive_root = $archiveRootName
    binary_asset_name = $binaryAssetName
    binary_url = [string]$binary.url
    binary_sha256 = [string]$binary.sha256
    source_scope = [string]$source.scope
    source_repository = $repository
    source_release_tag = $releaseTag
    source_asset_name = $sourceAssetName
    source_url = [string]$source.url
    source_sha256 = [string]$source.sha256
    ffmpeg_source_asset_name = [string]$ffmpegSource.asset_name
    ffmpeg_source_url = [string]$ffmpegSource.url
    ffmpeg_source_sha256 = [string]$ffmpegSource.sha256
    build_scripts_asset_name = [string]$buildScriptsSource.asset_name
    build_scripts_url = [string]$buildScriptsSource.url
    build_scripts_sha256 = [string]$buildScriptsSource.sha256
}
foreach ($entry in $requiredStrings.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "FFmpeg core runtime pin is missing $($entry.Key): $pinPath"
    }
}
foreach ($commit in @(
    $ffmpegCommit,
    [string]$binary.build_commit,
    [string]$binary.btbn_build_commit
)) {
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "FFmpeg core runtime pin contains an invalid commit: $commit"
    }
}
foreach ($sha256 in @(
    [string]$binary.sha256,
    [string]$source.sha256,
    [string]$ffmpegSource.sha256,
    [string]$buildScriptsSource.sha256
)) {
    if ($sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "FFmpeg core runtime pin contains an invalid SHA-256 value: $sha256"
    }
}
foreach ($size in @(
    [int64]$binary.size,
    [int64]$source.size,
    [int64]$ffmpegSource.size,
    [int64]$buildScriptsSource.size
)) {
    if ($size -le 0) {
        throw "FFmpeg core runtime pin contains a non-positive size: $size"
    }
}
foreach ($assetName in @(
    $binaryAssetName,
    $sourceAssetName,
    [string]$ffmpegSource.asset_name,
    [string]$buildScriptsSource.asset_name,
    $archiveRootName
)) {
    if ([System.IO.Path]::GetFileName($assetName) -ne $assetName) {
        throw "FFmpeg core runtime pin contains an invalid asset or archive-root name: $assetName"
    }
}
if ([string]$binary.url -ne "$releaseBaseUrl/$binaryAssetName") {
    throw "Pinned FFmpeg core binary URL does not match its release coordinates."
}
if ([string]$source.url -ne "$releaseBaseUrl/$sourceAssetName") {
    throw "Pinned FFmpeg core source URL does not match its release coordinates."
}
if ([string]$archiveBuilder.powershell_version -ne $PSVersionTable.PSVersion.ToString() -or
    [string]$archiveBuilder.powershell_version -ne "7.6.4") {
    throw "FFmpeg core archive generation requires PowerShell 7.6.4 exactly. Current=$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
}
if ([string]$archiveBuilder.source_notice_line_endings -ne "lf" -or
    [string]$archiveBuilder.manifest_line_endings -ne "crlf" -or
    [string]$archiveBuilder.zip_compression -ne "optimal" -or
    [string]$archiveBuilder.entry_timestamp -ne "1980-01-01T00:00:00Z") {
    throw "Unsupported FFmpeg core archive-builder pin."
}
if (-not [bool]$source.build_input_scope_complete -or
    -not [bool]$source.external_library_sources_included -or
    -not [bool]$source.optional_external_media_source_scope_complete -or
    @($source.external_library_sources_required).Count -ne 0) {
    throw "The core source pin must describe a complete build-input set with no optional external libraries."
}
if ([bool]$source.public_distribution_ready -or [bool]$source.license_review_complete) {
    throw "The local core candidate must remain blocked until publication, integration, acceptance, and license review are complete."
}
if ([bool]$pin.integration.replaces_current_release -or
    [bool]$pin.integration.portable_enabled -or
    [bool]$pin.integration.installer_enabled) {
    throw "The core candidate pin cannot claim current release integration."
}

if ([string]::IsNullOrWhiteSpace($PrototypeRoot)) {
    $PrototypeRoot = Join-Path $repoRoot "dist\ffmpeg-core-prototype\windows-x64"
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\ffmpeg-core-distribution\$version"
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = Join-Path $repoRoot "dist\build-cache\ffmpeg-source"
}
$prototypeFullPath = (Resolve-Path -LiteralPath $PrototypeRoot).Path
$outputFullPath = Get-FullPath -Path $OutputRoot
$outputParent = Split-Path -Parent $outputFullPath
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "OutputRoot must have a parent directory: $outputFullPath"
}
New-Item -ItemType Directory -Force -Path $outputFullPath | Out-Null
Assert-PathInsideDirectory -Path $outputFullPath -Directory $outputParent

if ([string]::IsNullOrWhiteSpace($FfmpegSourceArchivePath)) {
    $FfmpegSourceArchivePath = Join-Path (Get-FullPath -Path $CacheRoot) ([string]$ffmpegSource.asset_name)
}
if ([string]::IsNullOrWhiteSpace($BuildScriptsArchivePath)) {
    $BuildScriptsArchivePath = Join-Path (Get-FullPath -Path $CacheRoot) ([string]$buildScriptsSource.asset_name)
}
$resolvedFfmpegSource = Get-VerifiedFile `
    -Path (Get-FullPath -Path $FfmpegSourceArchivePath) `
    -Url ([string]$ffmpegSource.url) `
    -ExpectedSize ([int64]$ffmpegSource.size) `
    -ExpectedSha256 ([string]$ffmpegSource.sha256)
$resolvedBuildScripts = Get-VerifiedFile `
    -Path (Get-FullPath -Path $BuildScriptsArchivePath) `
    -Url ([string]$buildScriptsSource.url) `
    -ExpectedSize ([int64]$buildScriptsSource.size) `
    -ExpectedSha256 ([string]$buildScriptsSource.sha256)

$resolvedBuildControls = @()
foreach ($control in @($source.build_control_files)) {
    $controlPath = [string]$control.path
    if ([string]::IsNullOrWhiteSpace($controlPath) -or [System.IO.Path]::IsPathRooted($controlPath)) {
        throw "Invalid FFmpeg core build-control path: $controlPath"
    }
    $resolvedPath = Get-FullPath -Path (Join-Path $repoRoot $controlPath.Replace('/', '\'))
    Assert-PathInsideDirectory -Path $resolvedPath -Directory $repoRoot
    $evidence = Get-FileEvidence -Path $resolvedPath
    if ($evidence.size -ne [int64]$control.size -or $evidence.sha256 -ne [string]$control.sha256) {
        throw "FFmpeg core build-control file does not match its pin: $controlPath"
    }
    $resolvedBuildControls += [pscustomobject]@{
        relative_path = $controlPath.Replace('\', '/')
        resolved_path = $resolvedPath
        size = $evidence.size
        sha256 = $evidence.sha256
    }
}
if ($resolvedBuildControls.Count -eq 0) {
    throw "FFmpeg core pin does not list any build-control files."
}

$prototypeManifestPath = Join-Path $prototypeFullPath "ffmpeg_core_runtime.json"
$prototypeCompatibilityPath = Join-Path $prototypeFullPath "ffmpeg_core_compatibility.json"
foreach ($requiredPath in @(
    $prototypeManifestPath,
    $prototypeCompatibilityPath,
    (Join-Path $prototypeFullPath "bin\ffmpeg.exe"),
    (Join-Path $prototypeFullPath "bin\ffprobe.exe"),
    (Join-Path $prototypeFullPath "licenses\FFmpeg-LICENSE.txt"),
    (Join-Path $prototypeFullPath "licenses\FFmpeg-LICENSE-SUMMARY.md")
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "FFmpeg core prototype is missing a required file: $requiredPath"
    }
}
$prototypeManifest = Get-Content -LiteralPath $prototypeManifestPath -Encoding utf8 -Raw | ConvertFrom-Json -DateKind String
$compatibility = Get-Content -LiteralPath $prototypeCompatibilityPath -Encoding utf8 -Raw | ConvertFrom-Json -DateKind String
if ([string]$prototypeManifest.status -ne "evaluation" -or
    [string]$prototypeManifest.version -ne $version -or
    [string]$prototypeManifest.ffmpeg_commit -ne $ffmpegCommit -or
    [string]$prototypeManifest.variant -ne $variant -or
    [string]$prototypeManifest.license -ne $licenseSpdx) {
    throw "FFmpeg core prototype manifest does not match the candidate pin."
}
if ([string]$prototypeManifest.builder_image -ne [string]$binary.builder_image -or
    [string]$prototypeManifest.btbn_build_commit -ne [string]$binary.btbn_build_commit -or
    [int64]$prototypeManifest.source_date_epoch -ne [int64]$binary.source_date_epoch) {
    throw "FFmpeg core prototype build provenance does not match the candidate pin."
}
if (@($prototypeManifest.optional_external_libraries).Count -ne 0 -or
    -not [bool]$prototypeManifest.optional_external_media_source_scope_complete) {
    throw "FFmpeg core prototype unexpectedly contains optional external media libraries."
}
if (-not [bool]$compatibility.ok -or @($compatibility.pe_imports.unexpected_external).Count -ne 0) {
    throw "FFmpeg core prototype compatibility evidence is incomplete or has unexpected PE imports."
}
foreach ($fileProperty in @($prototypeManifest.files.PSObject.Properties)) {
    $relativePath = [string]$fileProperty.Name
    $resolvedPath = Get-FullPath -Path (Join-Path $prototypeFullPath $relativePath.Replace('/', '\'))
    Assert-PathInsideDirectory -Path $resolvedPath -Directory $prototypeFullPath
    $evidence = Get-FileEvidence -Path $resolvedPath
    if ($evidence.size -ne [int64]$fileProperty.Value.size -or
        $evidence.sha256 -ne [string]$fileProperty.Value.sha256) {
        throw "FFmpeg core prototype file does not match its manifest: $relativePath"
    }
}

$ffmpegPath = Join-Path $prototypeFullPath "bin\ffmpeg.exe"
$ffprobePath = Join-Path $prototypeFullPath "bin\ffprobe.exe"
$versionOutput = @(& $ffmpegPath -hide_banner -version 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg core candidate cannot execute on Windows."
}
$probeVersionOutput = @(& $ffprobePath -hide_banner -version 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "FFprobe core candidate cannot execute on Windows."
}
$versionText = $versionOutput -join "`n"
if ($versionText -match '--enable-gpl' -or
    $versionText -match '--enable-nonfree' -or
    $versionText -match '--enable-lib') {
    throw "FFmpeg core candidate violates the LGPL no-optional-external-library policy."
}

$binaryAssetPath = Join-Path $outputFullPath $binaryAssetName
$sourceAssetPath = Join-Path $outputFullPath $sourceAssetName
$buildManifestPath = Join-Path $outputFullPath "ffmpeg_core_distribution_build.json"
$generatedPaths = @(
    $binaryAssetPath,
    $sourceAssetPath,
    "$binaryAssetPath.unpinned",
    "$sourceAssetPath.unpinned",
    $buildManifestPath
)
foreach ($generatedPath in $generatedPaths) {
    Assert-PathInsideDirectory -Path $generatedPath -Directory $outputFullPath
    if (Test-Path -LiteralPath $generatedPath) {
        if (-not $Force) {
            throw "FFmpeg core distribution output already exists: $generatedPath. Pass -Force to replace it."
        }
        Remove-Item -LiteralPath $generatedPath -Force
    }
}

$stagingRoot = Join-Path $outputParent (".ffmpeg-core-distribution-staging-" + [guid]::NewGuid().ToString("N"))
Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
$binaryZipRoot = Join-Path $stagingRoot "binary-zip"
$binaryBundleRoot = Join-Path $binaryZipRoot $archiveRootName
$sourceBundleRoot = Join-Path $stagingRoot "source-bundle"
$stagedBinaryAsset = Join-Path $stagingRoot $binaryAssetName
$stagedSourceAsset = Join-Path $stagingRoot $sourceAssetName

try {
    New-Item -ItemType Directory -Force -Path $binaryBundleRoot | Out-Null
    foreach ($directoryName in @("bin", "build-info", "licenses")) {
        Copy-DirectoryFiles `
            -Source (Join-Path $prototypeFullPath $directoryName) `
            -Destination (Join-Path $binaryBundleRoot $directoryName)
    }
    Copy-Item `
        -LiteralPath (Join-Path $prototypeFullPath "licenses\FFmpeg-LICENSE.txt") `
        -Destination (Join-Path $binaryBundleRoot "LICENSE.txt")
    Copy-Item `
        -LiteralPath (Join-Path $prototypeFullPath "licenses\FFmpeg-LICENSE-SUMMARY.md") `
        -Destination (Join-Path $binaryBundleRoot "LICENSE.md")

    $binaryNotice = @"
TransVortex FFmpeg core candidate notice
========================================

This Windows x64 candidate preserves FFmpeg's built-in media components while
disabling optional dependency autodetection. It contains no optional external
media library and reports an LGPL-3.0-or-later configuration.

Binary candidate:
  Version: $version
  FFmpeg commit: $ffmpegCommit
  Variant: $variant
  Asset: $binaryAssetName

Corresponding source candidate:
  $([string]$source.url)

Build provenance:
  TransVortex build commit: $([string]$binary.build_commit)
  BtbN base build commit: $([string]$binary.btbn_build_commit)
  Builder image: $([string]$binary.builder_image)
  SOURCE_DATE_EPOCH: $([int64]$binary.source_date_epoch)

This candidate has not replaced the current TransVortex release runtime. Public
distribution remains blocked until publication, packaging integration, clean
Windows acceptance, and license review are complete.
"@
    Write-Utf8NoBom `
        -Path (Join-Path $binaryBundleRoot "SOURCE_NOTICE.txt") `
        -Content $binaryNotice `
        -LineEndings Lf

    $compatibilitySummary = [ordered]@{
        schema_version = 1
        component = "ffmpeg-core-compatibility-evidence"
        ok = [bool]$compatibility.ok
        platform = "windows-x64"
        version = $version
        ffmpeg_commit = $ffmpegCommit
        policy = $compatibility.policy
        capabilities = $compatibility.capabilities
        pe_imports = $compatibility.pe_imports
        audio_fixtures = $compatibility.audio_fixtures
        container_fixtures = $compatibility.container_fixtures
        direct_subtitle_fixtures = $compatibility.direct_subtitle_fixtures
        required_operations = @($compatibility.required_operations)
    }
    Write-Utf8NoBom `
        -Path (Join-Path $binaryBundleRoot "ffmpeg_compatibility.json") `
        -Content ($compatibilitySummary | ConvertTo-Json -Depth 12) `
        -LineEndings CrLf

    $runtimeFiles = @(Get-ChildItem -LiteralPath $binaryBundleRoot -Recurse -File | Sort-Object FullName)
    $runtimeFileEvidence = [ordered]@{}
    foreach ($file in $runtimeFiles) {
        $relativePath = Get-RelativeArchivePath -Path $file.FullName -Directory $binaryBundleRoot
        $runtimeFileEvidence[$relativePath] = Get-FileEvidence -Path $file.FullName
    }
    $runtimeBytesBeforeManifest = [int64](($runtimeFiles | Measure-Object -Property Length -Sum).Sum)
    $runtimeManifest = [ordered]@{
        schema_version = 1
        component = "ffmpeg-core-candidate"
        status = "candidate"
        adopted = $false
        platform = "windows-x64"
        version = $version
        ffmpeg_commit = $ffmpegCommit
        variant = $variant
        license = $licenseSpdx
        build_provider = [string]$binary.build_provider
        build_tag = [string]$binary.build_tag
        build_commit = [string]$binary.build_commit
        btbn_build_commit = [string]$binary.btbn_build_commit
        builder_image = [string]$binary.builder_image
        source_date_epoch = [int64]$binary.source_date_epoch
        ffmpeg_version_line = [string]$versionOutput[0]
        ffprobe_version_line = [string]$probeVersionOutput[0]
        preserves_ffmpeg_builtin_components = $true
        optional_external_libraries = @()
        files = $runtimeFileEvidence
        runtime_bytes_before_manifest = $runtimeBytesBeforeManifest
        corresponding_source = [ordered]@{
            asset_name = $sourceAssetName
            url = [string]$source.url
            scope = [string]$source.scope
        }
        public_distribution_ready = $false
        public_distribution_blockers = @($source.public_distribution_blockers)
        replaces_current_release = $false
    }
    Write-Utf8NoBom `
        -Path (Join-Path $binaryBundleRoot "ffmpeg_runtime.json") `
        -Content ($runtimeManifest | ConvertTo-Json -Depth 12) `
        -LineEndings CrLf

    New-DeterministicZip -SourceRoot $binaryZipRoot -DestinationPath $stagedBinaryAsset
    $binaryEvidence = Get-FileEvidence -Path $stagedBinaryAsset

    New-Item -ItemType Directory -Force -Path (Join-Path $sourceBundleRoot "sources") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceBundleRoot "licenses") | Out-Null
    Copy-Item -LiteralPath $resolvedFfmpegSource -Destination (Join-Path $sourceBundleRoot "sources\$([string]$ffmpegSource.asset_name)")
    Copy-Item -LiteralPath $resolvedBuildScripts -Destination (Join-Path $sourceBundleRoot "sources\$([string]$buildScriptsSource.asset_name)")
    Copy-Item -LiteralPath (Join-Path $prototypeFullPath "licenses\FFmpeg-LICENSE.txt") -Destination (Join-Path $sourceBundleRoot "licenses\FFmpeg-LICENSE.txt")
    Copy-Item -LiteralPath (Join-Path $prototypeFullPath "licenses\FFmpeg-LICENSE-SUMMARY.md") -Destination (Join-Path $sourceBundleRoot "licenses\FFmpeg-LICENSE-SUMMARY.md")

    $bundledBuildControls = @()
    foreach ($control in $resolvedBuildControls) {
        $targetRelativePath = "build-control/$($control.relative_path)"
        $targetPath = Join-Path $sourceBundleRoot $targetRelativePath.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Copy-Item -LiteralPath $control.resolved_path -Destination $targetPath
        $bundledBuildControls += [ordered]@{
            path = $control.relative_path
            bundled_path = $targetRelativePath
            size = [int64]$control.size
            sha256 = [string]$control.sha256
        }
    }
    $distributionBuilderPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $distributionBuilderTarget = Join-Path $sourceBundleRoot "distribution-control\scripts\build_ffmpeg_core_distribution.ps1"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $distributionBuilderTarget) | Out-Null
    Copy-Item -LiteralPath $distributionBuilderPath -Destination $distributionBuilderTarget
    $distributionBuilderEvidence = Get-FileEvidence -Path $distributionBuilderTarget

    $buildInstructions = @"
# Rebuilding the TransVortex FFmpeg core

The exact FFmpeg source, BtbN build definitions, TransVortex build controls,
license texts, immutable builder image digest, and SOURCE_DATE_EPOCH are bundled
here. From this extracted source bundle on Windows, the core build can be run
from the build-control directory with the pinned PowerShell and Docker environment:

    pwsh -NoProfile -File scripts/build_ffmpeg_core_prototype.ps1 -Force -Json

The default compatibility pass may download the separately pinned full FFmpeg
runtime to generate fixtures. Pass an already verified fixture runtime through
-FixtureGeneratorRoot when operating offline. The binary archive itself is
assembled by distribution-control/scripts/build_ffmpeg_core_distribution.ps1.

FFmpeg source commit: $ffmpegCommit
Builder image: $([string]$binary.builder_image)
SOURCE_DATE_EPOCH: $([int64]$binary.source_date_epoch)
"@
    Write-Utf8NoBom -Path (Join-Path $sourceBundleRoot "BUILD.md") -Content $buildInstructions -LineEndings Lf

    $sourceNotice = @"
TransVortex FFmpeg core corresponding source candidate
======================================================

This archive accompanies $binaryAssetName (SHA-256 $($binaryEvidence.sha256)).
It contains the exact FFmpeg source archive, the pinned BtbN build definitions,
the TransVortex Docker and orchestration controls used for the candidate, and
the relevant FFmpeg license texts.

No optional external media library is compiled into this core build, so the
external-library corresponding-source requirement list is empty. The technical
build-input set is complete, but public distribution remains blocked pending
asset publication, portable/installer integration, clean Windows real-media
acceptance, and license review.
"@
    Write-Utf8NoBom -Path (Join-Path $sourceBundleRoot "SOURCE_NOTICE.txt") -Content $sourceNotice -LineEndings Lf

    $sourceManifest = [ordered]@{
        schema_version = 1
        component = "ffmpeg-core-corresponding-source"
        status = "candidate"
        platform = "windows-x64"
        version = $version
        ffmpeg_commit = $ffmpegCommit
        variant = $variant
        license = $licenseSpdx
        scope = [string]$source.scope
        build_input_scope_complete = $true
        external_library_sources_required = @()
        external_library_sources_included = $true
        optional_external_media_source_scope_complete = $true
        license_review_complete = $false
        public_distribution_ready = $false
        public_distribution_blockers = @($source.public_distribution_blockers)
        binary = [ordered]@{
            asset_name = $binaryAssetName
            url = [string]$binary.url
            size = [int64]$binaryEvidence.size
            sha256 = [string]$binaryEvidence.sha256
        }
        build = [ordered]@{
            provider = [string]$binary.build_provider
            tag = [string]$binary.build_tag
            commit = [string]$binary.build_commit
            btbn_build_commit = [string]$binary.btbn_build_commit
            builder_image = [string]$binary.builder_image
            source_date_epoch = [int64]$binary.source_date_epoch
            build_control_files = $bundledBuildControls
            distribution_control_file = [ordered]@{
                bundled_path = "distribution-control/scripts/build_ffmpeg_core_distribution.ps1"
                size = [int64]$distributionBuilderEvidence.size
                sha256 = [string]$distributionBuilderEvidence.sha256
            }
        }
        source_archives = @(
            [ordered]@{
                kind = "ffmpeg"
                asset_name = [string]$ffmpegSource.asset_name
                bundled_path = "sources/$([string]$ffmpegSource.asset_name)"
                upstream_url = [string]$ffmpegSource.url
                size = [int64]$ffmpegSource.size
                sha256 = [string]$ffmpegSource.sha256
            },
            [ordered]@{
                kind = "btbn_build_scripts"
                asset_name = [string]$buildScriptsSource.asset_name
                bundled_path = "sources/$([string]$buildScriptsSource.asset_name)"
                upstream_url = [string]$buildScriptsSource.url
                size = [int64]$buildScriptsSource.size
                sha256 = [string]$buildScriptsSource.sha256
            }
        )
    }
    Write-Utf8NoBom `
        -Path (Join-Path $sourceBundleRoot "ffmpeg_corresponding_source.json") `
        -Content ($sourceManifest | ConvertTo-Json -Depth 12) `
        -LineEndings CrLf

    New-DeterministicZip -SourceRoot $sourceBundleRoot -DestinationPath $stagedSourceAsset
    $sourceEvidence = Get-FileEvidence -Path $stagedSourceAsset
    Move-Item -LiteralPath $stagedBinaryAsset -Destination $binaryAssetPath
    Move-Item -LiteralPath $stagedSourceAsset -Destination $sourceAssetPath
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$binaryEvidence = Get-FileEvidence -Path $binaryAssetPath
$sourceEvidence = Get-FileEvidence -Path $sourceAssetPath
$pinVerified = (
    $binaryEvidence.size -eq [int64]$binary.size -and
    $binaryEvidence.sha256 -eq [string]$binary.sha256 -and
    $sourceEvidence.size -eq [int64]$source.size -and
    $sourceEvidence.sha256 -eq [string]$source.sha256
)
if (-not $BootstrapPin -and -not $pinVerified) {
    $binaryQuarantinePath = "$binaryAssetPath.unpinned"
    $sourceQuarantinePath = "$sourceAssetPath.unpinned"
    Move-Item -LiteralPath $binaryAssetPath -Destination $binaryQuarantinePath
    Move-Item -LiteralPath $sourceAssetPath -Destination $sourceQuarantinePath
    throw (
        "Generated FFmpeg core assets do not match the immutable candidate pin. " +
        "BinaryExpectedSize=$([int64]$binary.size) BinaryActualSize=$($binaryEvidence.size) " +
        "BinaryExpectedSha256=$([string]$binary.sha256) BinaryActualSha256=$($binaryEvidence.sha256) " +
        "SourceExpectedSize=$([int64]$source.size) SourceActualSize=$($sourceEvidence.size) " +
        "SourceExpectedSha256=$([string]$source.sha256) SourceActualSha256=$($sourceEvidence.sha256)"
    )
}

$buildManifest = [ordered]@{
    schema_version = 1
    component = "transvortex-ffmpeg-core-distribution"
    status = "candidate"
    version = $version
    platform = "windows-x64"
    repository = $repository
    release_tag = $releaseTag
    pin_file = $pinPath
    pin_verified = $pinVerified
    bootstrap_mode = [bool]$BootstrapPin
    public_distribution_ready = $false
    replaces_current_release = $false
    assets = @(
        [ordered]@{
            kind = "binary"
            asset_name = $binaryAssetName
            path = $binaryAssetPath
            size = [int64]$binaryEvidence.size
            sha256 = [string]$binaryEvidence.sha256
        },
        [ordered]@{
            kind = "corresponding_source"
            asset_name = $sourceAssetName
            path = $sourceAssetPath
            size = [int64]$sourceEvidence.size
            sha256 = [string]$sourceEvidence.sha256
        }
    )
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}
Write-Utf8NoBom -Path $buildManifestPath -Content ($buildManifest | ConvertTo-Json -Depth 10) -LineEndings CrLf

$report = [ordered]@{
    ok = $true
    status = "candidate"
    output_root = $outputFullPath
    build_manifest = $buildManifestPath
    binary_asset = $binaryAssetPath
    binary_size = [int64]$binaryEvidence.size
    binary_sha256 = [string]$binaryEvidence.sha256
    source_asset = $sourceAssetPath
    source_size = [int64]$sourceEvidence.size
    source_sha256 = [string]$sourceEvidence.sha256
    pin_verified = $pinVerified
    bootstrap_mode = [bool]$BootstrapPin
    public_distribution_ready = $false
    replaces_current_release = $false
}
if ($Json) { $report | ConvertTo-Json -Depth 6 } else { [pscustomobject]$report }
