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
                $relativePath = [System.IO.Path]::GetRelativePath($sourceFullPath, $file.FullName).Replace('\', '/')
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
$pin = Get-Content -LiteralPath $pinPath -Encoding utf8 -Raw | ConvertFrom-Json
if ([int]$pin.schema_version -ne 1 -or [string]$pin.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg runtime pin: $pinPath"
}

$version = [string]$pin.version
$ffmpegCommit = [string]$pin.ffmpeg_commit
$variant = [string]$pin.variant
$licenseSpdx = [string]$pin.license
$binary = $pin.binary
$source = $pin.corresponding_source
$ffmpegSource = $source.ffmpeg_archive
$buildScriptsSource = $source.build_scripts_archive

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
    -Url ([string]$binary.upstream_url) `
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

$assetName = [string]$source.asset_name
$assetPath = Join-Path $outputFullPath $assetName
$buildManifestPath = Join-Path $outputFullPath "ffmpeg_distribution_build.json"
foreach ($generatedPath in @($assetPath, $buildManifestPath)) {
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
    Write-Utf8NoBom -Path (Join-Path $bundleRoot "SOURCE_NOTICE.txt") -Content $sourceNotice

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
        -Content ($bundleManifest | ConvertTo-Json -Depth 10)

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
$buildManifest = [ordered]@{
    schema_version = 1
    component = "transvortex-ffmpeg-distribution"
    version = $version
    platform = "windows-x64"
    repository = [string]$source.repository
    release_tag = [string]$source.release_tag
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
    public_distribution_source_ready = [bool]$source.public_distribution_ready
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}
Write-Utf8NoBom -Path $buildManifestPath -Content ($buildManifest | ConvertTo-Json -Depth 10)

$report = [ordered]@{
    ok = $true
    version = $version
    release_tag = [string]$source.release_tag
    source_asset = $sourceAsset.FullName
    source_asset_size = [int64]$sourceAsset.Length
    source_asset_sha256 = $sourceAssetSha256
    build_manifest = $buildManifestPath
    binary_archive = $resolvedBinaryArchive
    binary_sha256 = [string]$binary.sha256
}
if ($Json) { $report | ConvertTo-Json -Depth 6 } else { [pscustomobject]$report }
