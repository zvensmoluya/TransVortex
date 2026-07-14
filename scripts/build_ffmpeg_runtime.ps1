param(
    [string]$OutputRoot = "",
    [string]$CacheRoot = "",
    [string]$ArchivePath = "",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$ffmpegVersion = "8.1.2-21-gce3c09c101"
$ffmpegCommit = "ce3c09c101c83add623774d414a9f9498caf5c25"
$buildTag = "autobuild-2026-06-30-13-34"
$buildCommit = "7a83528ea3431e9eca982a712bc3a7cd0789d5d0"
$archiveName = "ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip"
$archiveSha256 = "27bcaf58b5140171dfe838a0b365d12c60607d71fc168424456410bad6a834da"
$archiveUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$buildTag/$archiveName"

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
    return (Resolve-Path -LiteralPath $Path).Path
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

Exact source references:
  FFmpeg: https://github.com/FFmpeg/FFmpeg/archive/$ffmpegCommit.tar.gz
  Build scripts: https://github.com/BtbN/FFmpeg-Builds/archive/$buildCommit.tar.gz

FFmpeg is licensed under LGPL-2.1-or-later in this build. The copied
FFmpeg-LICENSE.txt file is part of this distribution.

Before publishing an installer, the distributor must make the complete
corresponding source for this exact binary build available alongside the
download. The URLs above provide traceability; they do not replace the
distributor's source-hosting and legal review responsibilities.
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
        variant = "win64-lgpl-shared-8.1"
        license = "LGPL-2.1-or-later"
        build_provider = "BtbN/FFmpeg-Builds"
        build_tag = $buildTag
        build_commit = $buildCommit
        archive_name = $archiveName
        archive_url = $archiveUrl
        archive_sha256 = $archiveSha256
        ffmpeg_sha256 = (Get-FileHash -LiteralPath $targetFfmpeg -Algorithm SHA256).Hash.ToLowerInvariant()
        ffprobe_sha256 = (Get-FileHash -LiteralPath $targetFfprobe -Algorithm SHA256).Hash.ToLowerInvariant()
        shared_library_count = $sourceLibraries.Count
        shared_library_sha256 = $sharedLibraryHashes
        ffmpeg_version_line = [string]$versionOutput[0]
        ffprobe_version_line = [string]$probeVersionOutput[0]
        source_notice = "SOURCE_NOTICE.txt"
        public_distribution_requires_corresponding_source = $true
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
    variant = "win64-lgpl-shared-8.1"
    ffmpeg_path = Join-Path $outputFullPath "bin\ffmpeg.exe"
    ffprobe_path = Join-Path $outputFullPath "bin\ffprobe.exe"
    public_distribution_requires_corresponding_source = $true
}

if ($Json) {
    $report | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$report
}
