param(
    [string]$OutputRoot = "",
    [string]$CacheRoot = "",
    [string]$ArchivePath = "",
    [string]$PinFile = "",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($PinFile)) {
    $PinFile = Join-Path $repoRoot "requirements\ffmpeg-runtime.json"
}
$pinPath = (Resolve-Path -LiteralPath $PinFile).Path
$pin = Get-Content -LiteralPath $pinPath -Encoding utf8 -Raw | ConvertFrom-Json
if ([int]$pin.schema_version -ne 1 -or [string]$pin.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg runtime pin: $pinPath"
}

$ffmpegVersion = [string]$pin.version
$ffmpegCommit = [string]$pin.ffmpeg_commit
$variant = [string]$pin.variant
$licenseSpdx = [string]$pin.license
$buildProvider = [string]$pin.binary.build_provider
$buildTag = [string]$pin.binary.build_tag
$buildCommit = [string]$pin.binary.build_commit
$btbnBuildCommit = [string]$pin.binary.btbn_build_commit
$builderImage = [string]$pin.binary.builder_image
$archiveLayout = [string]$pin.binary.archive_layout
if ([string]::IsNullOrWhiteSpace($archiveLayout)) {
    $archiveLayout = "btbn-lgpl-shared-v1"
}
$archiveRootName = [string]$pin.binary.archive_root
$archiveName = [string]$pin.binary.asset_name
$archiveUrl = [string]$pin.binary.url
$upstreamArchiveUrl = [string]$pin.binary.upstream_url
$archiveSize = [int64]$pin.binary.size
$archiveSha256 = [string]$pin.binary.sha256
$correspondingSourceUrl = [string]$pin.corresponding_source.url
$correspondingSourceAsset = [string]$pin.corresponding_source.asset_name
$correspondingSourceSize = [int64]$pin.corresponding_source.size
$correspondingSourceSha256 = [string]$pin.corresponding_source.sha256
$correspondingSourceScope = [string]$pin.corresponding_source.scope
$correspondingSourceReady = [bool]$pin.corresponding_source.public_distribution_ready
$correspondingSourceExternalLibrariesIncluded = [bool]$pin.corresponding_source.external_library_sources_included
$correspondingSourceRepository = [string]$pin.corresponding_source.repository
$correspondingSourceReleaseTag = [string]$pin.corresponding_source.release_tag
$externalLibrarySourcesRequired = @($pin.corresponding_source.external_library_sources_required)
$buildInputScopeComplete = [bool]$pin.corresponding_source.build_input_scope_complete
$licenseReviewComplete = [bool]$pin.corresponding_source.license_review_complete

$requiredPinStrings = [ordered]@{
    version = $ffmpegVersion
    ffmpeg_commit = $ffmpegCommit
    variant = $variant
    license = $licenseSpdx
    build_provider = $buildProvider
    build_tag = $buildTag
    build_commit = $buildCommit
    archive_layout = $archiveLayout
    archive_name = $archiveName
    archive_url = $archiveUrl
    archive_sha256 = $archiveSha256
    corresponding_source_url = $correspondingSourceUrl
    corresponding_source_asset = $correspondingSourceAsset
    corresponding_source_sha256 = $correspondingSourceSha256
    corresponding_source_scope = $correspondingSourceScope
    corresponding_source_repository = $correspondingSourceRepository
    corresponding_source_release_tag = $correspondingSourceReleaseTag
}
foreach ($entry in $requiredPinStrings.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "FFmpeg runtime pin is missing $($entry.Key): $pinPath"
    }
}
$supportedArchiveLayouts = @("btbn-lgpl-shared-v1", "transvortex-core-v1")
if ($supportedArchiveLayouts -notcontains $archiveLayout) {
    throw "FFmpeg runtime pin contains an unsupported archive layout: $archiveLayout"
}
if ($archiveLayout -eq "btbn-lgpl-shared-v1" -and [string]::IsNullOrWhiteSpace($upstreamArchiveUrl)) {
    throw "BtbN FFmpeg runtime pin is missing upstream_archive_url: $pinPath"
}
if ($archiveLayout -eq "transvortex-core-v1") {
    if ([string]::IsNullOrWhiteSpace($archiveRootName) -or
        [System.IO.Path]::GetFileName($archiveRootName) -ne $archiveRootName) {
        throw "TransVortex core runtime pin contains an invalid archive_root: $archiveRootName"
    }
    if ($btbnBuildCommit -notmatch '^[0-9a-f]{40}$') {
        throw "TransVortex core runtime pin contains an invalid BtbN build commit: $btbnBuildCommit"
    }
    if ($builderImage -notmatch '^ghcr\.io/btbn/ffmpeg-builds/base-win64@sha256:[0-9a-f]{64}$') {
        throw "TransVortex core runtime pin must use an immutable BtbN base-win64 image digest."
    }
}
foreach ($commit in @($ffmpegCommit, $buildCommit)) {
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "FFmpeg runtime pin contains an invalid commit: $commit"
    }
}
foreach ($sha256 in @($archiveSha256, $correspondingSourceSha256)) {
    if ($sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "FFmpeg runtime pin contains an invalid SHA-256 value: $sha256"
    }
}
if ($archiveSize -le 0 -or $correspondingSourceSize -le 0) {
    throw "FFmpeg runtime pin must contain positive binary and corresponding-source sizes."
}
$releaseBaseUrl = "https://github.com/$correspondingSourceRepository/releases/download/$correspondingSourceReleaseTag"
if ($archiveUrl -ne "$releaseBaseUrl/$archiveName") {
    throw "Pinned FFmpeg binary URL does not match its repository, release tag, and asset name."
}
if ($correspondingSourceUrl -ne "$releaseBaseUrl/$correspondingSourceAsset") {
    throw "Pinned FFmpeg source URL does not match its repository, release tag, and asset name."
}
if ($correspondingSourceReady -and -not $correspondingSourceExternalLibrariesIncluded) {
    throw "FFmpeg source cannot be public-distribution ready without external library sources."
}
if ($correspondingSourceReady -and $correspondingSourceScope -eq "ffmpeg-core-and-build-scripts") {
    throw "FFmpeg source scope is still traceability-only but is marked public-distribution ready."
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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-VerifiedArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
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
                Start-BitsTransfer -Source $archiveUrl -Destination $downloadPath
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $downloadPath
            }
            Move-Item -LiteralPath $downloadPath -Destination $Path
        } finally {
            if (Test-Path -LiteralPath $downloadPath) {
                Remove-Item -LiteralPath $downloadPath -Force
            }
        }
    }

    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $archiveSha256) {
        throw "FFmpeg archive SHA-256 mismatch. Expected=$archiveSha256 Actual=$actualSha256 Path=$Path"
    }
    $actualSize = (Get-Item -LiteralPath $Path).Length
    if ($actualSize -ne $archiveSize) {
        throw "FFmpeg archive size mismatch. Expected=$archiveSize Actual=$actualSize Path=$Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\ffmpeg-runtime\windows-x64"
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = Join-Path $repoRoot "dist\build-cache\ffmpeg"
}

$outputFullPath = Get-FullPath -Path $OutputRoot
$outputParent = Split-Path -Parent $outputFullPath
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "OutputRoot must have a parent directory: $outputFullPath"
}
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
Assert-PathInsideDirectory -Path $outputFullPath -Directory $outputParent

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    $ArchivePath = Join-Path (Get-FullPath -Path $CacheRoot) $archiveName
} else {
    $ArchivePath = Get-FullPath -Path $ArchivePath
}
$resolvedArchive = Get-VerifiedArchive -Path $ArchivePath

$stagingRoot = Join-Path $outputParent (".ffmpeg-runtime-staging-" + [guid]::NewGuid().ToString("N"))
Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
$extractRoot = Join-Path $stagingRoot "extract"
$payloadRoot = Join-Path $stagingRoot "payload"
try {
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $payloadRoot "bin") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $payloadRoot "licenses") | Out-Null
    Expand-Archive -LiteralPath $resolvedArchive -DestinationPath $extractRoot -Force

    $ffmpegMatches = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "ffmpeg.exe")
    if ($ffmpegMatches.Count -ne 1) {
        throw "Expected one ffmpeg.exe in the archive, found $($ffmpegMatches.Count)."
    }
    $sourceBin = $ffmpegMatches[0].Directory.FullName
    $sourceRoot = Split-Path -Parent $sourceBin
    $sourceFfmpeg = Join-Path $sourceBin "ffmpeg.exe"
    $sourceFfprobe = Join-Path $sourceBin "ffprobe.exe"
    $sourceLicense = Join-Path $sourceRoot "LICENSE.txt"
    foreach ($required in @($sourceFfmpeg, $sourceFfprobe, $sourceLicense)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "FFmpeg archive is missing a required file: $required"
        }
    }
    $sourceLibraries = @(Get-ChildItem -LiteralPath $sourceBin -File -Filter "*.dll")
    if ($sourceLibraries.Count -eq 0) {
        throw "Pinned shared FFmpeg archive does not contain its required DLLs."
    }

    $coreArchiveManifest = $null
    if ($archiveLayout -eq "transvortex-core-v1") {
        if ((Split-Path -Leaf $sourceRoot) -ne $archiveRootName) {
            throw "TransVortex core archive root does not match its pin. Expected=$archiveRootName Actual=$(Split-Path -Leaf $sourceRoot)"
        }
        $coreArchiveManifestPath = Join-Path $sourceRoot "ffmpeg_runtime.json"
        if (-not (Test-Path -LiteralPath $coreArchiveManifestPath -PathType Leaf)) {
            throw "TransVortex core archive is missing ffmpeg_runtime.json."
        }
        $coreArchiveManifest = Get-Content -LiteralPath $coreArchiveManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
        if ([string]$coreArchiveManifest.component -ne "ffmpeg-core-candidate" -or
            [string]$coreArchiveManifest.archive_layout -ne $archiveLayout -or
            [string]$coreArchiveManifest.version -ne $ffmpegVersion -or
            [string]$coreArchiveManifest.ffmpeg_commit -ne $ffmpegCommit -or
            [string]$coreArchiveManifest.variant -ne $variant -or
            [string]$coreArchiveManifest.license -ne $licenseSpdx -or
            [string]$coreArchiveManifest.build_commit -ne $buildCommit -or
            [string]$coreArchiveManifest.btbn_build_commit -ne $btbnBuildCommit -or
            [string]$coreArchiveManifest.builder_image -ne $builderImage) {
            throw "TransVortex core archive manifest does not match its immutable pin."
        }
        if (@($coreArchiveManifest.optional_external_libraries).Count -ne 0) {
            throw "TransVortex core archive unexpectedly contains optional external libraries."
        }
        foreach ($fileProperty in @($coreArchiveManifest.files.PSObject.Properties)) {
            $relativePath = [string]$fileProperty.Name
            if ([string]::IsNullOrWhiteSpace($relativePath) -or [System.IO.Path]::IsPathRooted($relativePath)) {
                throw "TransVortex core archive manifest contains an invalid file path: $relativePath"
            }
            $pinnedFilePath = Get-FullPath -Path (Join-Path $sourceRoot $relativePath.Replace('/', '\'))
            Assert-PathInsideDirectory -Path $pinnedFilePath -Directory $sourceRoot
            if (-not (Test-Path -LiteralPath $pinnedFilePath -PathType Leaf)) {
                throw "TransVortex core archive is missing a pinned file: $relativePath"
            }
            $pinnedFile = Get-Item -LiteralPath $pinnedFilePath
            $pinnedFileSha256 = (Get-FileHash -LiteralPath $pinnedFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($pinnedFile.Length -ne [int64]$fileProperty.Value.size -or
                $pinnedFileSha256 -ne [string]$fileProperty.Value.sha256) {
                throw "TransVortex core archive file does not match its manifest: $relativePath"
            }
        }
    }

    $versionOutput = @(& $sourceFfmpeg -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg -version failed with exit code $LASTEXITCODE"
    }
    $probeVersionOutput = @(& $sourceFfprobe -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe -version failed with exit code $LASTEXITCODE"
    }
    $versionText = $versionOutput -join "`n"
    if ($archiveLayout -eq "transvortex-core-v1") {
        if ([string]$versionOutput[0] -ne [string]$coreArchiveManifest.ffmpeg_version_line -or
            [string]$probeVersionOutput[0] -ne [string]$coreArchiveManifest.ffprobe_version_line) {
            throw "TransVortex core executable version lines do not match the archive manifest."
        }
    } elseif ($versionText -notmatch [regex]::Escape("ffmpeg version n$ffmpegVersion")) {
        throw "Unexpected FFmpeg version in pinned BtbN archive: $($versionOutput[0])"
    }
    if ($versionText -match "--enable-gpl" -or $versionText -match "--enable-nonfree") {
        throw "Pinned FFmpeg archive unexpectedly enables GPL or nonfree components."
    }
    if ($licenseSpdx -eq "LGPL-3.0-or-later" -and $versionText -notmatch "--enable-version3") {
        throw "Pinned FFmpeg archive does not report the expected LGPLv3 build configuration."
    }

    $targetFfmpeg = Join-Path $payloadRoot "bin\ffmpeg.exe"
    $targetFfprobe = Join-Path $payloadRoot "bin\ffprobe.exe"
    Copy-Item -LiteralPath $sourceFfmpeg -Destination $targetFfmpeg
    Copy-Item -LiteralPath $sourceFfprobe -Destination $targetFfprobe
    foreach ($library in $sourceLibraries) {
        Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $payloadRoot "bin")
    }
    Copy-Item -LiteralPath $sourceLicense -Destination (Join-Path $payloadRoot "licenses\FFmpeg-LICENSE.txt")
    if ($archiveLayout -eq "transvortex-core-v1") {
        $coreBuildInfo = Join-Path $sourceRoot "build-info"
        $coreCompatibility = Join-Path $sourceRoot "ffmpeg_compatibility.json"
        $coreLicenseSummary = Join-Path $sourceRoot "LICENSE.md"
        foreach ($coreEvidencePath in @($coreBuildInfo, $coreCompatibility, $coreLicenseSummary)) {
            if (-not (Test-Path -LiteralPath $coreEvidencePath)) {
                throw "TransVortex core archive is missing packaged evidence: $coreEvidencePath"
            }
        }
        Copy-Item -LiteralPath $coreBuildInfo -Destination (Join-Path $payloadRoot "build-info") -Recurse
        Copy-Item -LiteralPath $coreCompatibility -Destination (Join-Path $payloadRoot "ffmpeg_compatibility.json")
        Copy-Item -LiteralPath $coreLicenseSummary -Destination (Join-Path $payloadRoot "licenses\FFmpeg-LICENSE-SUMMARY.md")
    }

    $sourceReadinessNotice = if ($correspondingSourceReady) {
        "The pinned source bundle is marked complete for public distribution and includes the required external library sources."
    } elseif ($archiveLayout -eq "transvortex-core-v1" -and
        $correspondingSourceExternalLibrariesIncluded -and
        $externalLibrarySourcesRequired.Count -eq 0 -and
        $buildInputScopeComplete) {
        "The pinned source bundle contains the complete technical build-input set and no optional external media library is compiled in. Public distribution remains blocked until the recorded release and license-review gates are complete."
    } else {
        "This bundle does not yet include the exact sources of every external LGPL library compiled into the BtbN binary. It does not complete the public-release source obligation."
    }
    $binaryDescription = if ($archiveLayout -eq "transvortex-core-v1") {
        "the reproducible TransVortex FFmpeg core build and its shared libraries"
    } else {
        "unmodified FFmpeg command-line executables and their shared libraries from the BtbN FFmpeg Builds win64 LGPL-shared variant"
    }
    $upstreamBinaryNotice = if ([string]::IsNullOrWhiteSpace($upstreamArchiveUrl)) {
        ""
    } else {
        @"
Original upstream binary:
  $upstreamArchiveUrl

"@
    }
    $buildProvenanceNotice = if ($archiveLayout -eq "transvortex-core-v1") {
        @"
  TransVortex build: $buildCommit
  BtbN base build: $btbnBuildCommit
  Builder image: $builderImage
"@
    } else {
        "  BtbN build scripts: $buildCommit"
    }
    $sourceNotice = @"
TransVortex FFmpeg distribution notice
======================================

This directory contains $binaryDescription.
TransVortex invokes these executables as separate processes and is not linked
to FFmpeg libraries.

Binary release:
  $archiveUrl
  SHA-256: $archiveSha256

$upstreamBinaryNotice
Source traceability bundle:
  $correspondingSourceUrl
  SHA-256: $correspondingSourceSha256
  Scope: $correspondingSourceScope

Exact source commits:
  FFmpeg: $ffmpegCommit
$buildProvenanceNotice

FFmpeg is licensed under $licenseSpdx in this build. The copied
FFmpeg-LICENSE.txt file is part of this distribution.

$sourceReadinessNotice
"@
    Write-Utf8NoBom -Path (Join-Path $payloadRoot "SOURCE_NOTICE.txt") -Content $sourceNotice

    $sharedLibraryHashes = [ordered]@{}
    Get-ChildItem -LiteralPath (Join-Path $payloadRoot "bin") -File -Filter "*.dll" |
        Sort-Object Name |
        ForEach-Object {
            $sharedLibraryHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    $manifest = [ordered]@{
        schema_version = 1
        component = "ffmpeg"
        platform = "windows-x64"
        version = $ffmpegVersion
        ffmpeg_commit = $ffmpegCommit
        variant = $variant
        license = $licenseSpdx
        build_provider = $buildProvider
        build_tag = $buildTag
        build_commit = $buildCommit
        btbn_build_commit = if ([string]::IsNullOrWhiteSpace($btbnBuildCommit)) { $null } else { $btbnBuildCommit }
        builder_image = if ([string]::IsNullOrWhiteSpace($builderImage)) { $null } else { $builderImage }
        archive_layout = $archiveLayout
        archive_name = $archiveName
        archive_url = $archiveUrl
        upstream_archive_url = if ([string]::IsNullOrWhiteSpace($upstreamArchiveUrl)) { $null } else { $upstreamArchiveUrl }
        archive_size = $archiveSize
        archive_sha256 = $archiveSha256
        ffmpeg_sha256 = (Get-FileHash -LiteralPath $targetFfmpeg -Algorithm SHA256).Hash.ToLowerInvariant()
        ffprobe_sha256 = (Get-FileHash -LiteralPath $targetFfprobe -Algorithm SHA256).Hash.ToLowerInvariant()
        shared_library_count = $sourceLibraries.Count
        shared_library_sha256 = $sharedLibraryHashes
        ffmpeg_version_line = [string]$versionOutput[0]
        ffprobe_version_line = [string]$probeVersionOutput[0]
        source_notice = "SOURCE_NOTICE.txt"
        corresponding_source = [ordered]@{
            asset_name = $correspondingSourceAsset
            url = $correspondingSourceUrl
            size = $correspondingSourceSize
            sha256 = $correspondingSourceSha256
            scope = $correspondingSourceScope
            external_library_sources_included = $correspondingSourceExternalLibrariesIncluded
            external_library_sources_required = $externalLibrarySourcesRequired
            build_input_scope_complete = $buildInputScopeComplete
            license_review_complete = $licenseReviewComplete
        }
        public_distribution_requires_corresponding_source = $true
        public_distribution_source_ready = $correspondingSourceReady
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Utf8NoBom -Path (Join-Path $payloadRoot "ffmpeg_runtime.json") -Content ($manifest | ConvertTo-Json -Depth 6)

    if (Test-Path -LiteralPath $outputFullPath) {
        if (-not $Force) {
            throw "FFmpeg runtime already exists: $outputFullPath. Pass -Force to replace it."
        }
        Remove-Item -LiteralPath $outputFullPath -Recurse -Force
    }
    Move-Item -LiteralPath $payloadRoot -Destination $outputFullPath
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$report = [ordered]@{
    ok = $true
    output_root = $outputFullPath
    manifest_path = Join-Path $outputFullPath "ffmpeg_runtime.json"
    archive_path = $resolvedArchive
    archive_sha256 = $archiveSha256
    version = $ffmpegVersion
    variant = $variant
    archive_layout = $archiveLayout
    license = $licenseSpdx
    ffmpeg_path = Join-Path $outputFullPath "bin\ffmpeg.exe"
    ffprobe_path = Join-Path $outputFullPath "bin\ffprobe.exe"
    corresponding_source_url = $correspondingSourceUrl
    corresponding_source_sha256 = $correspondingSourceSha256
    public_distribution_requires_corresponding_source = $true
    public_distribution_source_ready = $correspondingSourceReady
}

if ($Json) {
    $report | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$report
}
