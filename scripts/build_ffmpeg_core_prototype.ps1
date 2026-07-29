param(
    [string]$OutputRoot = "",
    [string]$CacheRoot = "",
    [string]$SourceArchivePath = "",
    [string]$FixtureGeneratorRoot = "",
    [string]$SpecFile = "",
    [string]$PinFile = "",
    [int]$BuildJobs = 0,
    [switch]$SkipCompatibilityCheck,
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($SpecFile)) {
    $SpecFile = Join-Path $repoRoot "requirements\ffmpeg-core-prototype.json"
}
if ([string]::IsNullOrWhiteSpace($PinFile)) {
    $PinFile = Join-Path $repoRoot "requirements\ffmpeg-runtime.json"
}

$specPath = (Resolve-Path -LiteralPath $SpecFile).Path
$pinPath = (Resolve-Path -LiteralPath $PinFile).Path
$spec = Get-Content -LiteralPath $specPath -Encoding utf8 -Raw | ConvertFrom-Json
$pin = Get-Content -LiteralPath $pinPath -Encoding utf8 -Raw | ConvertFrom-Json

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

function Get-VerifiedDownload {
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
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $downloadPath
            Move-Item -LiteralPath $downloadPath -Destination $Path
        } finally {
            if (Test-Path -LiteralPath $downloadPath) {
                Remove-Item -LiteralPath $downloadPath -Force
            }
        }
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $actualSize = (Get-Item -LiteralPath $resolved).Length
    $actualSha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSize -ne $ExpectedSize) {
        throw "Archive size mismatch. Expected=$ExpectedSize Actual=$actualSize Path=$resolved"
    }
    if ($actualSha256 -ne $ExpectedSha256) {
        throw "Archive SHA-256 mismatch. Expected=$ExpectedSha256 Actual=$actualSha256 Path=$resolved"
    }
    return $resolved
}

function Test-PinnedFixtureGenerator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommit
    )

    $ffmpegPath = Join-Path $RuntimeRoot "bin\ffmpeg.exe"
    $manifestPath = Join-Path $RuntimeRoot "ffmpeg_runtime.json"
    if (-not (Test-Path -LiteralPath $ffmpegPath) -or -not (Test-Path -LiteralPath $manifestPath)) {
        return $false
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Encoding utf8 -Raw | ConvertFrom-Json
        return (
            [string]$manifest.version -eq $ExpectedVersion -and
            [string]$manifest.ffmpeg_commit -eq $ExpectedCommit
        )
    } catch {
        return $false
    }
}

if ([int]$spec.schema_version -ne 1 -or [string]$spec.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg core prototype spec: $specPath"
}
if ([int]$pin.schema_version -ne 1 -or [string]$pin.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg runtime pin: $pinPath"
}

$ffmpegVersion = [string]$pin.version
$ffmpegCommit = [string]$pin.ffmpeg_commit
$buildCommit = [string]$pin.binary.build_commit
$sourceArchive = $pin.corresponding_source.ffmpeg_archive
$sourceArchiveName = [string]$sourceArchive.asset_name
$sourceArchiveUrl = [string]$sourceArchive.url
$sourceArchiveSize = [int64]$sourceArchive.size
$sourceArchiveSha256 = [string]$sourceArchive.sha256
$builderImage = [string]$spec.builder_image
$sourceDateEpoch = [int64]$spec.source_date_epoch
$licenseSpdx = [string]$spec.license
$configureFlags = @($spec.configure_flags | ForEach-Object { [string]$_ })

if ($ffmpegCommit -notmatch '^[0-9a-f]{40}$' -or $buildCommit -notmatch '^[0-9a-f]{40}$') {
    throw "The runtime pin contains an invalid source or build commit."
}
if ($sourceArchiveSha256 -notmatch '^[0-9a-f]{64}$' -or $sourceArchiveSize -le 0) {
    throw "The runtime pin contains invalid FFmpeg source archive metadata."
}
if ([string]$spec.ffmpeg_commit -ne $ffmpegCommit) {
    throw "Prototype FFmpeg commit does not match the current runtime pin."
}
if ([string]$spec.btbn_build_commit -ne $buildCommit) {
    throw "Prototype BtbN build commit does not match the current runtime pin."
}
if ($builderImage -notmatch '^ghcr\.io/btbn/ffmpeg-builds/base-win64@sha256:[0-9a-f]{64}$') {
    throw "Prototype builder image must use an immutable base-win64 digest."
}
if ($licenseSpdx -ne "LGPL-3.0-or-later") {
    throw "Prototype license must remain LGPL-3.0-or-later."
}
if (-not [bool]$spec.policy.preserve_ffmpeg_builtin_components) {
    throw "Prototype policy must preserve FFmpeg built-in components."
}
if ([bool]$spec.policy.extreme_component_pruning) {
    throw "Extreme component pruning is intentionally unsupported by this prototype."
}
if ([bool]$spec.policy.replace_current_release) {
    throw "An evaluation prototype cannot replace the current release pin."
}
if (@($spec.policy.external_library_allowlist).Count -ne 0) {
    throw "The prototype external library allowlist must be empty."
}

$requiredFlags = @(
    "--enable-version3",
    "--enable-shared",
    "--disable-static",
    "--disable-autodetect",
    "--disable-gpl",
    "--disable-nonfree"
)
foreach ($requiredFlag in $requiredFlags) {
    if ($configureFlags -notcontains $requiredFlag) {
        throw "Prototype configure flags are missing: $requiredFlag"
    }
}
$forbiddenPruning = @(
    "--disable-all",
    "--disable-everything",
    "--disable-decoders",
    "--disable-demuxers",
    "--disable-encoders",
    "--disable-filters",
    "--disable-muxers",
    "--disable-parsers",
    "--disable-protocols"
)
foreach ($flag in $configureFlags) {
    if ($flag.StartsWith("--enable-lib", [System.StringComparison]::Ordinal) -or $forbiddenPruning -contains $flag) {
        throw "Prototype configure flag violates the balanced core policy: $flag"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\ffmpeg-core-prototype\windows-x64"
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = Join-Path $repoRoot "dist\build-cache\ffmpeg-source"
}
if ($BuildJobs -le 0) {
    $BuildJobs = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount))
}

$outputFullPath = Get-FullPath -Path $OutputRoot
$outputParent = Split-Path -Parent $outputFullPath
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "OutputRoot must have a parent directory: $outputFullPath"
}
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
Assert-PathInsideDirectory -Path $outputFullPath -Directory $outputParent
if ((Test-Path -LiteralPath $outputFullPath) -and -not $Force) {
    throw "FFmpeg core prototype already exists: $outputFullPath. Pass -Force to replace it."
}

if ([string]::IsNullOrWhiteSpace($SourceArchivePath)) {
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    $SourceArchivePath = Join-Path (Get-FullPath -Path $CacheRoot) $sourceArchiveName
}
$resolvedSourceArchive = Get-VerifiedDownload `
    -Path (Get-FullPath -Path $SourceArchivePath) `
    -Url $sourceArchiveUrl `
    -ExpectedSize $sourceArchiveSize `
    -ExpectedSha256 $sourceArchiveSha256

if ([string]::IsNullOrWhiteSpace($FixtureGeneratorRoot)) {
    $fixtureCandidates = @(
        (Join-Path $repoRoot "dist\ffmpeg-runtime\windows-x64-pin-review"),
        (Join-Path $repoRoot "dist\ffmpeg-runtime\windows-x64")
    )
    foreach ($candidate in $fixtureCandidates) {
        if (Test-PinnedFixtureGenerator `
            -RuntimeRoot $candidate `
            -ExpectedVersion $ffmpegVersion `
            -ExpectedCommit $ffmpegCommit) {
            $FixtureGeneratorRoot = $candidate
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($FixtureGeneratorRoot)) {
        $FixtureGeneratorRoot = Join-Path $repoRoot (
            "dist\ffmpeg-runtime\prototype-fixture-generator-" + $ffmpegCommit.Substring(0, 12)
        )
        $runtimeBuilder = Join-Path $PSScriptRoot "build_ffmpeg_runtime.ps1"
        $runtimeArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $runtimeBuilder,
            "-OutputRoot", $FixtureGeneratorRoot,
            "-PinFile", $pinPath,
            "-Json"
        )
        if (Test-Path -LiteralPath $FixtureGeneratorRoot) {
            $runtimeArgs += "-Force"
        }
        & powershell.exe @runtimeArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to prepare the pinned full FFmpeg fixture generator."
        }
    }
}
$fixtureGeneratorFullPath = Get-FullPath -Path $FixtureGeneratorRoot
if (-not (Test-PinnedFixtureGenerator `
    -RuntimeRoot $fixtureGeneratorFullPath `
    -ExpectedVersion $ffmpegVersion `
    -ExpectedCommit $ffmpegCommit)) {
    throw "FixtureGeneratorRoot is not the current immutable FFmpeg runtime pin: $fixtureGeneratorFullPath"
}

$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $dockerCommand) {
    throw "Docker CLI is required to build the FFmpeg core prototype."
}
$dockerServer = @(& $dockerCommand.Source version --format '{{.Server.Version}}' 2>&1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($dockerServer -join ""))) {
    throw "Docker Desktop is not running. Start it and rerun this script."
}

$dockerfile = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "ffmpeg_core_prototype.Dockerfile")).Path
$validator = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "verify_ffmpeg_core_runtime.py")).Path
$stagingRoot = Join-Path $outputParent (".ffmpeg-core-staging-" + [guid]::NewGuid().ToString("N"))
Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
$contextRoot = Join-Path $stagingRoot "context"
$exportRoot = Join-Path $stagingRoot "export"

try {
    New-Item -ItemType Directory -Force -Path $contextRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $exportRoot | Out-Null
    Copy-Item -LiteralPath $resolvedSourceArchive -Destination (Join-Path $contextRoot "ffmpeg-source.tar.gz")
    Copy-Item -LiteralPath $dockerfile -Destination (Join-Path $contextRoot "Dockerfile")

    $dockerArgs = @(
        "buildx", "build",
        "--progress=plain",
        "--file", (Join-Path $contextRoot "Dockerfile"),
        "--build-arg", "BUILDER_IMAGE=$builderImage",
        "--build-arg", "BUILD_JOBS=$BuildJobs",
        "--build-arg", "FFMPEG_COMMIT=$ffmpegCommit",
        "--build-arg", "FFMPEG_VERSION=$ffmpegVersion",
        "--build-arg", "SOURCE_DATE_EPOCH=$sourceDateEpoch",
        "--build-arg", ("FFMPEG_CONFIGURE_FLAGS=" + ($configureFlags -join " ")),
        "--output", "type=local,dest=$exportRoot",
        $contextRoot
    )
    & $dockerCommand.Source @dockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker failed to build the FFmpeg core prototype."
    }

    $targetFfmpeg = Join-Path $exportRoot "bin\ffmpeg.exe"
    $targetFfprobe = Join-Path $exportRoot "bin\ffprobe.exe"
    $targetLicense = Join-Path $exportRoot "licenses\FFmpeg-LICENSE.txt"
    foreach ($requiredFile in @($targetFfmpeg, $targetFfprobe, $targetLicense)) {
        if (-not (Test-Path -LiteralPath $requiredFile)) {
            throw "FFmpeg core build is missing a required output: $requiredFile"
        }
    }

    $versionOutput = @(& $targetFfmpeg -hide_banner -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg core prototype cannot execute on Windows."
    }
    $versionText = $versionOutput -join "`n"
    foreach ($requiredFlag in $requiredFlags) {
        if ($versionText -notmatch [regex]::Escape($requiredFlag)) {
            throw "Built FFmpeg configuration is missing: $requiredFlag"
        }
    }
    if ($versionText -match '--enable-lib' -or $versionText -match '--disable-everything') {
        throw "Built FFmpeg configuration violates the balanced core policy."
    }

    $sourceNotice = @"
TransVortex FFmpeg core prototype notice
========================================

This evaluation build preserves FFmpeg's built-in demuxers, decoders, encoders,
muxers, parsers, protocols, and filters. It disables optional dependency
autodetection and does not compile any optional external media library.

It is intentionally not the current TransVortex release runtime. Adoption must
remain gated on the compatibility report and release packaging integration.

Exact FFmpeg source:
  Commit: $ffmpegCommit
  Archive: $sourceArchiveUrl
  Size: $sourceArchiveSize
  SHA-256: $sourceArchiveSha256

Reproducible build inputs:
  Builder image: $builderImage
  BtbN build definition commit: $buildCommit
  SOURCE_DATE_EPOCH: $sourceDateEpoch
  Configure flags: $($configureFlags -join " ")

FFmpeg is licensed under $licenseSpdx in this build. See the files in licenses/.
Because no optional external media library is compiled in, there is no external
library corresponding-source list for this prototype.
"@
    Write-Utf8NoBom -Path (Join-Path $exportRoot "SOURCE_NOTICE.txt") -Content $sourceNotice

    $runtimeFiles = @(Get-ChildItem -LiteralPath $exportRoot -Recurse -File)
    $fileHashes = [ordered]@{}
    foreach ($file in ($runtimeFiles | Sort-Object FullName)) {
        $relativePath = $file.FullName.Substring($exportRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $fileHashes[$relativePath] = [ordered]@{
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $referenceFiles = @(Get-ChildItem -LiteralPath $fixtureGeneratorFullPath -Recurse -File)
    $referenceBytes = [int64](($referenceFiles | Measure-Object -Property Length -Sum).Sum)
    $prototypeBytes = [int64](($runtimeFiles | Measure-Object -Property Length -Sum).Sum)
    $sizeReductionPercent = if ($referenceBytes -gt 0) {
        [Math]::Round((1.0 - ($prototypeBytes / [double]$referenceBytes)) * 100.0, 2)
    } else {
        0.0
    }

    $manifest = [ordered]@{
        schema_version = 1
        component = "ffmpeg-core-prototype"
        status = "evaluation"
        platform = "windows-x64"
        version = $ffmpegVersion
        ffmpeg_commit = $ffmpegCommit
        variant = [string]$spec.variant
        license = $licenseSpdx
        builder_image = $builderImage
        btbn_build_commit = $buildCommit
        source_date_epoch = $sourceDateEpoch
        configure_flags = $configureFlags
        preserves_ffmpeg_builtin_components = $true
        extreme_component_pruning = $false
        optional_external_libraries = @()
        ffmpeg_version_line = [string]$versionOutput[0]
        files = $fileHashes
        runtime_bytes_before_manifest = $prototypeBytes
        reference_runtime_bytes = $referenceBytes
        size_reduction_percent_before_manifest = $sizeReductionPercent
        source = [ordered]@{
            url = $sourceArchiveUrl
            size = $sourceArchiveSize
            sha256 = $sourceArchiveSha256
        }
        external_library_corresponding_sources_required = @()
        optional_external_media_source_scope_complete = $true
        public_distribution_ready = $false
        public_distribution_blocker = "prototype_not_adopted_packaged_or_license_reviewed"
        replaces_current_release = $false
        compatibility_report = if ($SkipCompatibilityCheck) { $null } else { "ffmpeg_core_compatibility.json" }
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Utf8NoBom `
        -Path (Join-Path $exportRoot "ffmpeg_core_runtime.json") `
        -Content ($manifest | ConvertTo-Json -Depth 8)

    if (-not $SkipCompatibilityCheck) {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            throw "Python is required to run the FFmpeg core compatibility verifier."
        }
        & $pythonCommand.Source $validator `
            --runtime-root $exportRoot `
            --fixture-generator-root $fixtureGeneratorFullPath `
            --spec $specPath `
            --output (Join-Path $exportRoot "ffmpeg_core_compatibility.json")
        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg core compatibility verification failed."
        }
    }

    if (Test-Path -LiteralPath $outputFullPath) {
        Assert-PathInsideDirectory -Path $outputFullPath -Directory $outputParent
        Remove-Item -LiteralPath $outputFullPath -Recurse -Force
    }
    Move-Item -LiteralPath $exportRoot -Destination $outputFullPath
    if (-not $SkipCompatibilityCheck) {
        $compatibilityPath = Join-Path $outputFullPath "ffmpeg_core_compatibility.json"
        $compatibility = Get-Content -LiteralPath $compatibilityPath -Encoding utf8 -Raw | ConvertFrom-Json
        $compatibility.runtime_root = $outputFullPath
        Write-Utf8NoBom `
            -Path $compatibilityPath `
            -Content ($compatibility | ConvertTo-Json -Depth 8)
    }
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-PathInsideDirectory -Path $stagingRoot -Directory $outputParent
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$finalFiles = @(Get-ChildItem -LiteralPath $outputFullPath -Recurse -File)
$finalBytes = [int64](($finalFiles | Measure-Object -Property Length -Sum).Sum)
$report = [ordered]@{
    ok = $true
    status = "evaluation"
    output_root = $outputFullPath
    manifest_path = Join-Path $outputFullPath "ffmpeg_core_runtime.json"
    compatibility_report = if ($SkipCompatibilityCheck) { $null } else {
        Join-Path $outputFullPath "ffmpeg_core_compatibility.json"
    }
    ffmpeg_path = Join-Path $outputFullPath "bin\ffmpeg.exe"
    ffprobe_path = Join-Path $outputFullPath "bin\ffprobe.exe"
    source_archive_path = $resolvedSourceArchive
    fixture_generator_root = $fixtureGeneratorFullPath
    runtime_bytes = $finalBytes
    reference_runtime_bytes = $referenceBytes
    size_reduction_percent = if ($referenceBytes -gt 0) {
        [Math]::Round((1.0 - ($finalBytes / [double]$referenceBytes)) * 100.0, 2)
    } else {
        0.0
    }
    optional_external_media_source_scope_complete = $true
    public_distribution_ready = $false
    replaces_current_release = $false
}

if ($Json) {
    $report | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$report
}
