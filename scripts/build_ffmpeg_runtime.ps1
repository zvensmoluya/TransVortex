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

$requiredPinStrings = [ordered]@{
    version = $ffmpegVersion
    ffmpeg_commit = $ffmpegCommit
    variant = $variant
    license = $licenseSpdx
    build_provider = $buildProvider
    build_tag = $buildTag
    build_commit = $buildCommit
    archive_name = $archiveName
    archive_url = $archiveUrl
    upstream_archive_url = $upstreamArchiveUrl
    archive_sha256 = $archiveSha256
    corresponding_source_url = $correspondingSourceUrl
    corresponding_source_asset = $correspondingSourceAsset
    corresponding_source_sha256 = $correspondingSourceSha256
}
foreach ($entry in $requiredPinStrings.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "FFmpeg runtime pin is missing $($entry.Key): $pinPath"
    }
}
foreach ($hash in @($ffmpegCommit, $buildCommit, $archiveSha256, $correspondingSourceSha256)) {
    if ($hash -notmatch '^[0-9a-f]{40}$' -and $hash -notmatch '^[0-9a-f]{64}$') {
        throw "FFmpeg runtime pin contains an invalid commit or SHA-256 value: $hash"
    }
}
if ($archiveSize -le 0 -or $correspondingSourceSize -le 0) {
    throw "FFmpeg runtime pin must contain positive binary and corresponding-source sizes."
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

    $versionOutput = @(& $sourceFfmpeg -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg -version failed with exit code $LASTEXITCODE"
    }
    $probeVersionOutput = @(& $sourceFfprobe -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe -version failed with exit code $LASTEXITCODE"
    }
    $versionText = $versionOutput -join "`n"
    if ($versionText -notmatch [regex]::Escape("ffmpeg version n$ffmpegVersion")) {
        throw "Unexpected FFmpeg version in pinned archive: $($versionOutput[0])"
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

    $sourceNotice = @"
TransVortex FFmpeg distribution notice
======================================

This directory contains unmodified FFmpeg command-line executables and their
shared libraries from the BtbN FFmpeg Builds win64 LGPL-shared variant.
TransVortex invokes these executables as separate processes and is not linked
to FFmpeg libraries.

Binary release:
  $archiveUrl
  SHA-256: $archiveSha256

Original upstream binary:
  $upstreamArchiveUrl

Source traceability bundle:
  $correspondingSourceUrl
  SHA-256: $correspondingSourceSha256
  Scope: $correspondingSourceScope

Exact source commits:
  FFmpeg: $ffmpegCommit
  Build scripts: $buildCommit

FFmpeg is licensed under $licenseSpdx in this build. The copied
FFmpeg-LICENSE.txt file is part of this distribution.

This bundle does not yet include the exact sources of every external LGPL
library compiled into the BtbN binary. It does not complete the public-release
source obligation until public_distribution_source_ready becomes true.
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
        archive_name = $archiveName
        archive_url = $archiveUrl
        upstream_archive_url = $upstreamArchiveUrl
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
