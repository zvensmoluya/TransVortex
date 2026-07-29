param(
    [string]$PinFile = "",
    [string]$OutputRoot = "",
    [string]$CacheRoot = "",
    [string]$BinaryArchivePath = "",
    [string]$FfmpegSourceArchivePath = "",
    [string]$BuildScriptsArchivePath = "",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "FFmpeg source archive generation requires the pinned PowerShell 7 build environment."
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
        throw "Source input size mismatch. Expected=$ExpectedSize Actual=$($file.Length) Path=$Path"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256) {
        throw "Source input SHA-256 mismatch. Expected=$ExpectedSha256 Actual=$actualSha256 Path=$Path"
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($PinFile)) {
    $PinFile = Join-Path $repoRoot "requirements\ffmpeg-runtime.json"
}
$pinPath = (Resolve-Path -LiteralPath $PinFile).Path
$pin = Get-Content -LiteralPath $pinPath -Encoding utf8 -Raw | ConvertFrom-Json -DateKind String
if ([int]$pin.schema_version -ne 1 -or [string]$pin.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg runtime pin: $pinPath"
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
$sourceAssetName = [string]$source.asset_name
$expectedSourceAssetSize = [int64]$source.size
$expectedSourceAssetSha256 = [string]$source.sha256
$sourceScope = [string]$source.scope
$externalLibrarySourcesIncluded = [bool]$source.external_library_sources_included
$publicDistributionReady = [bool]$source.public_distribution_ready

$requiredPinStrings = [ordered]@{
    version = $version
    ffmpeg_commit = $ffmpegCommit
    variant = $variant
    license = $licenseSpdx
    binary_asset_name = [string]$binary.asset_name
    binary_url = [string]$binary.url
    binary_upstream_url = [string]$binary.upstream_url
    binary_sha256 = [string]$binary.sha256
    source_scope = $sourceScope
    source_repository = $repository
    source_release_tag = $releaseTag
    source_asset_name = $sourceAssetName
    source_url = [string]$source.url
    source_sha256 = $expectedSourceAssetSha256
    archive_builder_powershell_version = [string]$archiveBuilder.powershell_version
    archive_builder_source_notice_line_endings = [string]$archiveBuilder.source_notice_line_endings
    archive_builder_manifest_line_endings = [string]$archiveBuilder.manifest_line_endings
    archive_builder_zip_compression = [string]$archiveBuilder.zip_compression
    archive_builder_entry_timestamp = [string]$archiveBuilder.entry_timestamp
    ffmpeg_source_asset_name = [string]$ffmpegSource.asset_name
    ffmpeg_source_url = [string]$ffmpegSource.url
    ffmpeg_source_sha256 = [string]$ffmpegSource.sha256
    build_scripts_asset_name = [string]$buildScriptsSource.asset_name
    build_scripts_url = [string]$buildScriptsSource.url
    build_scripts_sha256 = [string]$buildScriptsSource.sha256
}
foreach ($entry in $requiredPinStrings.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "FFmpeg runtime pin is missing $($entry.Key): $pinPath"
    }
}
foreach ($commit in @($ffmpegCommit, [string]$binary.build_commit)) {
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "FFmpeg runtime pin contains an invalid commit: $commit"
    }
}
foreach ($sha256 in @(
    [string]$binary.sha256,
    $expectedSourceAssetSha256,
    [string]$ffmpegSource.sha256,
    [string]$buildScriptsSource.sha256
)) {
    if ($sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "FFmpeg runtime pin contains an invalid SHA-256 value: $sha256"
    }
}
foreach ($size in @(
    [int64]$binary.size,
    $expectedSourceAssetSize,
    [int64]$ffmpegSource.size,
    [int64]$buildScriptsSource.size
)) {
    if ($size -le 0) {
        throw "FFmpeg runtime pin contains a non-positive asset size: $size"
    }
}
foreach ($assetName in @(
    [string]$binary.asset_name,
    $sourceAssetName,
    [string]$ffmpegSource.asset_name,
    [string]$buildScriptsSource.asset_name
)) {
    if ([System.IO.Path]::GetFileName($assetName) -ne $assetName) {
        throw "FFmpeg runtime pin contains an invalid asset name: $assetName"
    }
}
$releaseBaseUrl = "https://github.com/$repository/releases/download/$releaseTag"
if ([string]$binary.url -ne "$releaseBaseUrl/$([string]$binary.asset_name)") {
    throw "Pinned FFmpeg binary URL does not match its repository, release tag, and asset name."
}
if ([string]$source.url -ne "$releaseBaseUrl/$sourceAssetName") {
    throw "Pinned FFmpeg source URL does not match its repository, release tag, and asset name."
}
if ($publicDistributionReady -and -not $externalLibrarySourcesIncluded) {
    throw "FFmpeg source cannot be public-distribution ready without external library sources."
}
if ($publicDistributionReady -and $sourceScope -eq "ffmpeg-core-and-build-scripts") {
    throw "FFmpeg source scope is still traceability-only but is marked public-distribution ready."
}
$requiredPowerShellVersion = [string]$archiveBuilder.powershell_version
if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion.ToString() -ne $requiredPowerShellVersion) {
    throw "FFmpeg source archive generation requires PowerShell $requiredPowerShellVersion exactly. Current=$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
}
if ([string]$archiveBuilder.source_notice_line_endings -ne "lf" -or
    [string]$archiveBuilder.manifest_line_endings -ne "crlf" -or
    [string]$archiveBuilder.zip_compression -ne "optimal" -or
    [string]$archiveBuilder.entry_timestamp -ne "1980-01-01T00:00:00Z") {
    throw "Unsupported FFmpeg source archive-builder pin."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\ffmpeg-source\$version"
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = Join-Path $repoRoot "dist\build-cache\ffmpeg-source"
}
$outputFullPath = Get-FullPath -Path $OutputRoot
$outputParent = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Force -Path $outputFullPath | Out-Null
Assert-PathInsideDirectory -Path $outputFullPath -Directory $outputParent

if ([string]::IsNullOrWhiteSpace($BinaryArchivePath)) {
    $binaryCache = Join-Path $repoRoot "dist\build-cache\ffmpeg"
    $BinaryArchivePath = Join-Path $binaryCache ([string]$binary.asset_name)
}
if ([string]::IsNullOrWhiteSpace($FfmpegSourceArchivePath)) {
    $FfmpegSourceArchivePath = Join-Path (Get-FullPath -Path $CacheRoot) ([string]$ffmpegSource.asset_name)
}
if ([string]::IsNullOrWhiteSpace($BuildScriptsArchivePath)) {
    $BuildScriptsArchivePath = Join-Path (Get-FullPath -Path $CacheRoot) ([string]$buildScriptsSource.asset_name)
}

$resolvedBinaryArchive = Get-VerifiedFile `
    -Path (Get-FullPath -Path $BinaryArchivePath) `
    -Url ([string]$binary.url) `
    -ExpectedSize ([int64]$binary.size) `
    -ExpectedSha256 ([string]$binary.sha256)
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

$assetName = $sourceAssetName
$assetPath = Join-Path $outputFullPath $assetName
$unpinnedAssetPath = "$assetPath.unpinned"
$buildManifestPath = Join-Path $outputFullPath "ffmpeg_distribution_build.json"
foreach ($generatedPath in @($assetPath, $unpinnedAssetPath, $buildManifestPath)) {
    Assert-PathInsideDirectory -Path $generatedPath -Directory $outputFullPath
    if (Test-Path -LiteralPath $generatedPath) {
        if (-not $Force) {
            throw "FFmpeg source output already exists: $generatedPath. Pass -Force to replace it."
        }
        Remove-Item -LiteralPath $generatedPath -Force
    }
}

$stagingRoot = Join-Path $outputParent (".ffmpeg-source-staging-" + [guid]::NewGuid().ToString("N"))
Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
$bundleRoot = Join-Path $stagingRoot "bundle"
$stagedAsset = Join-Path $stagingRoot $assetName
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $bundleRoot "sources") | Out-Null
    Copy-Item -LiteralPath $resolvedFfmpegSource -Destination (Join-Path $bundleRoot "sources\$([string]$ffmpegSource.asset_name)")
    Copy-Item -LiteralPath $resolvedBuildScripts -Destination (Join-Path $bundleRoot "sources\$([string]$buildScriptsSource.asset_name)")

    $sourceNotice = @"
TransVortex FFmpeg source traceability bundle
==============================================

This bundle accompanies the unmodified BtbN Windows x64 LGPL shared FFmpeg
binary identified below. TransVortex invokes FFmpeg as a separate process.

Binary distribution:
  Version: $version
  Variant: $variant
  Asset: $([string]$binary.asset_name)
  SHA-256: $([string]$binary.sha256)
  Original upstream: $([string]$binary.upstream_url)

Source contents:
  FFmpeg commit: $ffmpegCommit
  FFmpeg source archive: sources/$([string]$ffmpegSource.asset_name)
  FFmpeg source SHA-256: $([string]$ffmpegSource.sha256)
  BtbN build scripts commit: $([string]$binary.build_commit)
  Build scripts archive: sources/$([string]$buildScriptsSource.asset_name)
  Build scripts SHA-256: $([string]$buildScriptsSource.sha256)

The BtbN scripts include the dependency definitions, patches, container files,
and build controls used for this build family. The relevant commands are:
  ./makeimage.sh win64 lgpl-shared 8.1
  ./build.sh win64 lgpl-shared 8.1

This FFmpeg build reports $licenseSpdx. License texts and source-level notices
remain inside the source archives; the binary distribution also carries the
original BtbN LICENSE.txt.

Scope limitation:
  This bundle contains FFmpeg source and exact BtbN build-control scripts. It
  does not yet contain the exact source snapshots for every external LGPL
  library compiled into the binary, so it is not marked ready for public
  installer distribution.
"@
    Write-Utf8NoBom `
        -Path (Join-Path $bundleRoot "SOURCE_NOTICE.txt") `
        -Content $sourceNotice `
        -LineEndings Lf

    $bundleManifest = [ordered]@{
        schema_version = 1
        component = "ffmpeg-source-traceability-bundle"
        public_distribution_ready = [bool]$source.public_distribution_ready
        external_library_sources_included = [bool]$source.external_library_sources_included
        platform = "windows-x64"
        version = $version
        ffmpeg_commit = $ffmpegCommit
        variant = $variant
        license = $licenseSpdx
        binary = [ordered]@{
            asset_name = [string]$binary.asset_name
            distribution_url = [string]$binary.url
            upstream_url = [string]$binary.upstream_url
            size = [int64]$binary.size
            sha256 = [string]$binary.sha256
        }
        build = [ordered]@{
            provider = [string]$binary.build_provider
            tag = [string]$binary.build_tag
            commit = [string]$binary.build_commit
            commands = @(
                "./makeimage.sh win64 lgpl-shared 8.1",
                "./build.sh win64 lgpl-shared 8.1"
            )
        }
        source_archives = @(
            [ordered]@{
                kind = "ffmpeg"
                asset_name = [string]$ffmpegSource.asset_name
                upstream_url = [string]$ffmpegSource.url
                size = [int64]$ffmpegSource.size
                sha256 = [string]$ffmpegSource.sha256
            },
            [ordered]@{
                kind = "build_scripts"
                asset_name = [string]$buildScriptsSource.asset_name
                upstream_url = [string]$buildScriptsSource.url
                size = [int64]$buildScriptsSource.size
                sha256 = [string]$buildScriptsSource.sha256
            }
        )
    }
    Write-Utf8NoBom `
        -Path (Join-Path $bundleRoot "ffmpeg_corresponding_source.json") `
        -Content ($bundleManifest | ConvertTo-Json -Depth 10) `
        -LineEndings CrLf

    New-DeterministicZip -SourceRoot $bundleRoot -DestinationPath $stagedAsset
    Move-Item -LiteralPath $stagedAsset -Destination $assetPath
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$sourceAsset = Get-Item -LiteralPath $assetPath
$sourceAssetSha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceAsset.Length -ne $expectedSourceAssetSize -or $sourceAssetSha256 -ne $expectedSourceAssetSha256) {
    $actualSourceAssetSize = [int64]$sourceAsset.Length
    Move-Item -LiteralPath $assetPath -Destination $unpinnedAssetPath
    throw (
        "Generated corresponding-source asset does not match the immutable pin. " +
        "ExpectedSize=$expectedSourceAssetSize ActualSize=$actualSourceAssetSize " +
        "ExpectedSha256=$expectedSourceAssetSha256 ActualSha256=$sourceAssetSha256 " +
        "QuarantinedPath=$unpinnedAssetPath"
    )
}
$buildManifest = [ordered]@{
    schema_version = 1
    component = "transvortex-ffmpeg-distribution"
    version = $version
    platform = "windows-x64"
    repository = $repository
    release_tag = $releaseTag
    assets = @(
        [ordered]@{
            kind = "binary"
            asset_name = [string]$binary.asset_name
            path = $resolvedBinaryArchive
            size = [int64]$binary.size
            sha256 = [string]$binary.sha256
        },
        [ordered]@{
            kind = "corresponding_source"
            asset_name = $assetName
            path = $sourceAsset.FullName
            size = [int64]$sourceAsset.Length
            sha256 = $sourceAssetSha256
        }
    )
    corresponding_source_url = [string]$source.url
    public_distribution_source_ready = $publicDistributionReady
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}
Write-Utf8NoBom -Path $buildManifestPath -Content ($buildManifest | ConvertTo-Json -Depth 10)

$report = [ordered]@{
    ok = $true
    version = $version
    release_tag = $releaseTag
    source_asset = $sourceAsset.FullName
    source_asset_size = [int64]$sourceAsset.Length
    source_asset_sha256 = $sourceAssetSha256
    source_asset_pin_verified = $true
    build_manifest = $buildManifestPath
    binary_archive = $resolvedBinaryArchive
    binary_sha256 = [string]$binary.sha256
}
if ($Json) { $report | ConvertTo-Json -Depth 6 } else { [pscustomobject]$report }
