param(
    [string]$ExePath = "",
    [string]$OutputRoot = "",
    [string]$PackageName = "",
    [string]$AppRuntimeRoot = "",
    [string]$FfmpegRuntimeRoot = "",
    [switch]$Build,
    [switch]$BuildAppRuntime,
    [switch]$BuildFfmpegRuntime,
    [switch]$InstallerPayload,
    [switch]$Force,
    [switch]$NoZip,
    [switch]$LaunchCheck,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Copy-RequiredDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required directory not found: $Source"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required file not found: $Source"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Assert-PathInsideDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside output root: $fullPath"
    }
    if ($fullPath -eq $fullDirectory) {
        throw "Refusing to operate on output root itself: $fullPath"
    }
}

function Remove-GeneratedPackageFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    Assert-PathInsideDirectory -Path $PackageRoot -Directory (Split-Path -Parent $PackageRoot)

    $cacheDirs = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force |
            Where-Object {
                $_.PSIsContainer -and
                (($_.Name -in @("__pycache__", ".pytest_cache")) -or ($_.Name -like "*.egg-info"))
            }
    )
    foreach ($cacheDir in $cacheDirs) {
        Assert-PathInsideDirectory -Path $cacheDir.FullName -Directory $PackageRoot
        Remove-Item -LiteralPath $cacheDir.FullName -Recurse -Force
    }

    $compiledFiles = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File |
            Where-Object { $_.Extension -in @(".pyc", ".pyo") }
    )
    foreach ($compiledFile in $compiledFiles) {
        Assert-PathInsideDirectory -Path $compiledFile.FullName -Directory $PackageRoot
        Remove-Item -LiteralPath $compiledFile.FullName -Force
    }

    $rootGeneratedPaths = @("artifacts", "output", "tmp", "DemoTest")
    foreach ($rootName in $rootGeneratedPaths) {
        $rootGeneratedPath = Join-Path $PackageRoot $rootName
        if (Test-Path -LiteralPath $rootGeneratedPath) {
            Assert-PathInsideDirectory -Path $rootGeneratedPath -Directory $PackageRoot
            Remove-Item -LiteralPath $rootGeneratedPath -Recurse -Force
        }
    }
}

function Assert-PortablePackageNoSecrets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $forbiddenNames = @(
        ".env",
        ".imagegen.env",
        ".env.imagegen",
        "providers.local.yaml",
        "auth.json"
    )
    $matches = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File |
            Where-Object { $forbiddenNames -contains $_.Name } |
            ForEach-Object { $_.FullName }
    )
    if ($matches.Count -gt 0) {
        throw "Portable package contains forbidden local/secret files: $($matches -join ', ')"
    }

    $forbiddenRootPaths = @(
        ".venv", "artifacts", "output", "tmp", "DemoTest",
        "Components", "Models", "Downloads", "src", "pyproject.toml"
    )
    $rootMatches = @(
        $forbiddenRootPaths |
            ForEach-Object { Join-Path $PackageRoot $_ } |
            Where-Object { Test-Path -LiteralPath $_ } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    )
    if ($rootMatches.Count -gt 0) {
        throw "Portable package contains forbidden repo-local root paths: $($rootMatches -join ', ')"
    }

    $forbiddenAsrRuntimeFiles = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File |
            Where-Object {
                $_.Name -eq "model.bin" -or
                $_.Name -like "cublas*.dll" -or
                $_.Name -like "cudnn*.dll" -or
                $_.Name -like "ctranslate2*.pyd" -or
                $_.Name -like "torch*.dll"
            } |
            ForEach-Object { $_.FullName }
    )
    $forbiddenAsrRuntimeDirectories = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -Directory |
            Where-Object { $_.Name -in @("faster_whisper", "ctranslate2", "nvidia", "torch") } |
            ForEach-Object { $_.FullName }
    )
    $forbiddenAsrPayloads = @($forbiddenAsrRuntimeFiles) + @($forbiddenAsrRuntimeDirectories)
    if ($forbiddenAsrPayloads.Count -gt 0) {
        throw "Portable package contains managed ASR runtime/model payloads: $($forbiddenAsrPayloads -join ', ')"
    }
}

function Test-PackagedProviderSeed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $pythonPath = Join-Path $PackageRoot "runtime\python\python.exe"
    $providersPath = Join-Path $PackageRoot "providers.yaml"
    if (-not (Test-Path -LiteralPath $pythonPath)) {
        throw "Packaged Python not found for provider seed validation: $pythonPath"
    }
    if (-not (Test-Path -LiteralPath $providersPath)) {
        throw "Packaged provider seed not found: $providersPath"
    }
    $parser = @'
import json
import pathlib
import sys

import yaml

path = pathlib.Path(sys.argv[1])
payload = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
if not isinstance(payload, dict):
    raise TypeError("providers.yaml root must be an object")
providers = payload.get("providers")
if not isinstance(providers, list):
    raise TypeError("providers.yaml must contain a providers list")
print(json.dumps({"provider_connection_count": len(providers)}))
'@
    $parserPath = Join-Path $PackageRoot ".provider_seed_check.py"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        [System.IO.File]::WriteAllText($parserPath, $parser, [System.Text.UTF8Encoding]::new($false))
        $ErrorActionPreference = "Continue"
        $json = & $pythonPath $parserPath $providersPath 2>&1
        $parserExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if (Test-Path -LiteralPath $parserPath) {
            Remove-Item -LiteralPath $parserPath -Force
        }
    }
    if ($parserExitCode -ne 0) {
        throw "Packaged provider seed could not be parsed: $($json | Out-String)"
    }
    $result = (($json | Out-String).Trim() | ConvertFrom-Json)
    if ([int]$result.provider_connection_count -ne 0) {
        throw "Portable product seed must contain zero provider connections, got: $($result.provider_connection_count)"
    }
    return [ordered]@{
        ok = $true
        providers_path = $providersPath
        provider_connection_count = [int]$result.provider_connection_count
    }
}

function Invoke-PortableServiceCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,
        [int]$TimeoutSeconds = 30
    )

    $runtimeRoot = Join-Path $PackageRoot "runtime"
    $runtimeManifestPath = Join-Path $runtimeRoot "app_runtime.json"
    $pythonPath = Join-Path $runtimeRoot "python\python.exe"
    if (-not (Test-Path -LiteralPath $runtimeManifestPath)) {
        throw "Portable package app runtime manifest not found: $runtimeManifestPath"
    }
    if (-not (Test-Path -LiteralPath $pythonPath)) {
        throw "Portable package app runtime Python not found: $pythonPath"
    }
    $runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Encoding utf8 -Raw | ConvertFrom-Json

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pythonPath
    $psi.WorkingDirectory = $PackageRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    } catch {
    }
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Environment["PYTHONIOENCODING"] = "utf-8"
    $psi.Environment["PYTHONUTF8"] = "1"
    $psi.Environment["PYTHONPATH"] = ""
    $psi.Environment["PYTHONNOUSERSITE"] = "1"
    $psi.Environment["TRANSVORTEX_MEDIA_TOOLS_DIR"] = Join-Path $PackageRoot "tools\ffmpeg\bin"
    $escapedPackageRoot = $PackageRoot.Replace('"', '\"')
    $psi.Arguments = "-m transvortex.app_service --root `"$escapedPackageRoot`" --no-pump"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $startedAt = (Get-Date)
    $responses = @()
    $stdoutText = ""
    $stderrText = ""
    try {
        if (-not $process.Start()) {
            throw "Could not start python Local Service process."
        }
        foreach ($line in @(
            '{"jsonrpc":"2.0","id":1,"method":"service.info","params":{}}',
            '{"jsonrpc":"2.0","id":2,"method":"service.health","params":{}}',
            '{"jsonrpc":"2.0","id":3,"method":"asr.status","params":{}}',
            '{"jsonrpc":"2.0","id":4,"method":"service.shutdown","params":{}}'
        )) {
            $process.StandardInput.WriteLine($line)
        }
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Portable Local Service did not exit after service.shutdown within $TimeoutSeconds seconds."
        }
        $stdoutText = $process.StandardOutput.ReadToEnd()
        $stderrText = $process.StandardError.ReadToEnd()
        $responses = @(
            $stdoutText -split "`r?`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json }
        )
    } finally {
        if ($process -ne $null -and -not $process.HasExited) {
            try {
                $process.Kill()
            } catch {
            }
        }
    }

    $info = $responses | Where-Object { $_.id -eq 1 } | Select-Object -First 1
    $health = $responses | Where-Object { $_.id -eq 2 } | Select-Object -First 1
    $asrStatus = $responses | Where-Object { $_.id -eq 3 } | Select-Object -First 1
    $shutdown = $responses | Where-Object { $_.id -eq 4 } | Select-Object -First 1
    $errors = @(
        $responses |
            Where-Object { ($_.PSObject.Properties.Name -contains "error") -and $null -ne $_.error } |
            ForEach-Object { $_.error }
    )
    if ($responses.Count -ne 4 -or $errors.Count -gt 0) {
        throw "Portable Local Service RPC check failed. Responses=$($responses.Count) Errors=$($errors.Count) Stdout=$stdoutText Stderr=$stderrText"
    }
    if ($info.result.service -ne "transvortex.app_service") {
        throw "Unexpected service.info service: $($info.result.service)"
    }
    if ($health.result.service -ne "transvortex.app_service") {
        throw "Unexpected service.health service: $($health.result.service)"
    }
    if ([string]$info.result.app_version -ne [string]$runtimeManifest.version) {
        throw "App runtime version mismatch. Manifest=$($runtimeManifest.version) Service=$($info.result.app_version)"
    }
    if ([int]$info.result.protocol_version -ne [int]$runtimeManifest.protocol_version) {
        throw "App runtime protocol mismatch. Manifest=$($runtimeManifest.protocol_version) Service=$($info.result.protocol_version)"
    }
    if (-not [bool]$shutdown.result.ok) {
        throw "service.shutdown did not return ok=true."
    }
    $selectedAsr = [string]$asrStatus.result.provider
    if ($asrStatus.result.kind -ne "local_worker") {
        throw "Portable default ASR must use local_worker, got: $($asrStatus.result.kind)"
    }
    if ([bool]$asrStatus.result.readiness.can_run) {
        throw "Portable package reported local Whisper ready without a managed component."
    }

    return [ordered]@{
        ok = $true
        started_at = $startedAt.ToString("o")
        ended_at = (Get-Date).ToString("o")
        working_directory = $PackageRoot
        python_executable = $pythonPath
        pythonpath_empty = $true
        runtime_version = [string]$runtimeManifest.version
        runtime_python_version = [string]$runtimeManifest.python_version
        response_count = $responses.Count
        service = [string]$info.result.service
        protocol_version = $info.result.protocol_version
        health_status = [string]$health.result.status
        pump_enabled = [bool]$health.result.pump.enabled
        shutdown_ok = [bool]$shutdown.result.ok
        asr_provider = $selectedAsr
        asr_kind = [string]$asrStatus.result.kind
        asr_readiness = [string]$asrStatus.result.readiness.code
        exit_code = $process.ExitCode
        stderr = $stderrText.Trim()
    }
}

function Test-PackagedFfmpegRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $ffmpegRoot = Join-Path $PackageRoot "tools\ffmpeg"
    $manifestPath = Join-Path $ffmpegRoot "ffmpeg_runtime.json"
    $ffmpegPath = Join-Path $ffmpegRoot "bin\ffmpeg.exe"
    $ffprobePath = Join-Path $ffmpegRoot "bin\ffprobe.exe"
    foreach ($required in @($manifestPath, $ffmpegPath, $ffprobePath, (Join-Path $ffmpegRoot "SOURCE_NOTICE.txt"))) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Packaged FFmpeg runtime is incomplete: $required"
        }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Encoding utf8 -Raw | ConvertFrom-Json
    $ffmpegOutput = @(& $ffmpegPath -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged ffmpeg -version failed with exit code $LASTEXITCODE"
    }
    $ffprobeOutput = @(& $ffprobePath -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged ffprobe -version failed with exit code $LASTEXITCODE"
    }
    $ffmpegHash = (Get-FileHash -LiteralPath $ffmpegPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ffprobeHash = (Get-FileHash -LiteralPath $ffprobePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ffmpegHash -ne [string]$manifest.ffmpeg_sha256 -or $ffprobeHash -ne [string]$manifest.ffprobe_sha256) {
        throw "Packaged FFmpeg executable hash does not match ffmpeg_runtime.json."
    }
    $libraryProperties = @($manifest.shared_library_sha256.PSObject.Properties)
    if ($libraryProperties.Count -ne [int]$manifest.shared_library_count) {
        throw "Packaged FFmpeg shared library count does not match ffmpeg_runtime.json."
    }
    foreach ($property in $libraryProperties) {
        $libraryPath = Join-Path $ffmpegRoot ("bin\" + $property.Name)
        if (-not (Test-Path -LiteralPath $libraryPath)) {
            throw "Packaged FFmpeg shared library is missing: $libraryPath"
        }
        $libraryHash = (Get-FileHash -LiteralPath $libraryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($libraryHash -ne [string]$property.Value) {
            throw "Packaged FFmpeg shared library hash mismatch: $($property.Name)"
        }
    }

    $correspondingSourceUrl = [string]$manifest.corresponding_source.url
    $correspondingSourceSha256 = [string]$manifest.corresponding_source.sha256
    $correspondingSourceSize = [int64]$manifest.corresponding_source.size
    $correspondingSourceScope = [string]$manifest.corresponding_source.scope
    $correspondingSourceAssetsPublished = [bool]$manifest.corresponding_source.assets_published
    $externalLibrarySourcesIncluded = [bool]$manifest.corresponding_source.external_library_sources_included
    $externalLibrarySourcesRequired = @($manifest.corresponding_source.external_library_sources_required)
    $buildInputScopeComplete = [bool]$manifest.corresponding_source.build_input_scope_complete
    $licenseReviewComplete = [bool]$manifest.corresponding_source.license_review_complete
    $publicDistributionSourceReady = [bool]$manifest.public_distribution_source_ready
    if ([string]::IsNullOrWhiteSpace($correspondingSourceUrl) -or
        $correspondingSourceSha256 -notmatch '^[0-9a-f]{64}$' -or
        $correspondingSourceSize -le 0 -or
        [string]::IsNullOrWhiteSpace($correspondingSourceScope)) {
        throw "Packaged FFmpeg runtime has an incomplete corresponding-source record."
    }
    if ($publicDistributionSourceReady -and -not $externalLibrarySourcesIncluded) {
        throw "Packaged FFmpeg runtime claims public source readiness without external library sources."
    }
    if ($publicDistributionSourceReady -and $correspondingSourceScope -eq "ffmpeg-core-and-build-scripts") {
        throw "Packaged FFmpeg runtime still has a traceability-only source scope but claims public readiness."
    }

    return [ordered]@{
        ok = $true
        version = [string]$manifest.version
        variant = [string]$manifest.variant
        license = [string]$manifest.license
        ffmpeg_path = $ffmpegPath
        ffprobe_path = $ffprobePath
        ffmpeg_version_line = [string]$ffmpegOutput[0]
        ffprobe_version_line = [string]$ffprobeOutput[0]
        shared_library_count = $libraryProperties.Count
        public_distribution_requires_corresponding_source = [bool]$manifest.public_distribution_requires_corresponding_source
        public_distribution_source_ready = $publicDistributionSourceReady
        corresponding_source_assets_published = $correspondingSourceAssetsPublished
        external_library_sources_included = $externalLibrarySourcesIncluded
        external_library_sources_required = $externalLibrarySourcesRequired
        build_input_scope_complete = $buildInputScopeComplete
        license_review_complete = $licenseReviewComplete
        corresponding_source_scope = $correspondingSourceScope
        corresponding_source_url = $correspondingSourceUrl
        corresponding_source_size = $correspondingSourceSize
        corresponding_source_sha256 = $correspondingSourceSha256
    }
}

function New-PortableReadme {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $content = @"
TransVortex portable release
============================

Run:
  .\TransVortex.exe

Optional start-menu identity shortcut:
  powershell -ExecutionPolicy Bypass -File .\Install-StartMenuShortcut.ps1

Optional user-level install:
  powershell -ExecutionPolicy Bypass -File .\Install-TransVortex.ps1

This portable package includes the Flutter release bundle, a fixed embedded
Python runtime for the TransVortex Local Service, and pinned FFmpeg command-line
tools. It does not depend on a system Python or FFmpeg installation. It does not
include model files, API keys, auth.json, .env files, or local provider
configuration.

The agent\ directory contains a short Agent/CLI entry, AGENT_USAGE.md, an
Agent-native adaptation guide, and on-demand workflows and references. The
portable package does not register a global Agent entry or modify any Agent's
skill/plugin directories. These files do not contain models or credentials.

Local Whisper is represented as an optional managed component. Runtime,
model, and NVIDIA packages are downloaded only after an explicit user action
and are stored under the user-level TransVortex data directory.

Credentials are resolved from the user-level TransVortex credential store
(~\.transvortex\auth.json) or environment variables. The bundled providers.yaml
is copied from providers.desktop.yaml and starts with no configured connections.
The separate providers.example.yaml uses a non-routable example domain and does
not contain local provider secrets.

This is not an MSIX/MSI/NSIS/Inno installer. It is a portable distribution
artifact used to validate package layout and release startup before the formal
installer path is built. The package manifest records the package-root Local
Service RPC check performed by the packaging script. The optional install script
copies the package to a user-level directory and creates a Start menu shortcut,
but it is still not a formal Windows installer.
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding utf8
}

function New-InstallerPayloadReadme {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $content = @"
TransVortex Windows installer payload
=====================================

This directory is an intermediate input for the TransVortex Windows installer.
It contains the Flutter release bundle, the fixed Local Service Python runtime,
and pinned FFmpeg command-line tools. It does not depend on a system Python,
FFmpeg, or PowerShell installation at runtime.

This payload does not include model files, API keys, auth.json, .env files, or
local provider configuration. Local Whisper components are installed only after
an explicit user action and remain under the user-level TransVortex data root.

The agent\ directory contains the versioned Agent/CLI entry, usage contract,
adaptation guide, and on-demand ASR workflow. The NSIS installer registers the
stable per-user locator under %LOCALAPPDATA%\TransVortex\Agent without modifying
any Agent's own skill/plugin directories.

FFmpeg notices and source traceability are under tools\ffmpeg. Public release of
an installer must be accompanied by the complete corresponding FFmpeg source
and a legal review of the distribution notices.

Do not distribute this directory as a native installer. The NSIS build step
embeds it into the signed-or-explicitly-unsigned installer artifact.
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding utf8
}

function New-PortableShortcutInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $content = @'
param(
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$helper = Join-Path $root "scripts\install_flutter_desktop_shortcut.ps1"
$exe = Join-Path $root "TransVortex.exe"
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Shortcut helper not found: $helper"
}
if (-not (Test-Path -LiteralPath $exe)) {
    throw "TransVortex.exe not found: $exe"
}
$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $helper, "-ExePath", $exe)
if ($Json) {
    $argsList += "-Json"
}
& powershell @argsList
exit $LASTEXITCODE
'@
    Set-Content -LiteralPath $Path -Value $content -Encoding utf8
}

function New-PortableUserInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $content = @'
param(
    [string]$InstallRoot = "",
    [string]$ShortcutPath = "",
    [switch]$Force,
    [switch]$VerifyOnly,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$helper = Join-Path $root "scripts\install_flutter_portable_release.ps1"
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Portable install helper not found: $helper"
}
$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $helper, "-SourceRoot", $root)
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    $argsList += @("-InstallRoot", $InstallRoot)
}
if (-not [string]::IsNullOrWhiteSpace($ShortcutPath)) {
    $argsList += @("-ShortcutPath", $ShortcutPath)
}
if ($Force) {
    $argsList += "-Force"
}
if ($VerifyOnly) {
    $argsList += "-VerifyOnly"
}
if ($Json) {
    $argsList += "-Json"
}
& powershell @argsList
exit $LASTEXITCODE
'@
    Set-Content -LiteralPath $Path -Value $content -Encoding utf8
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$desktopFlutterRoot = Join-Path $repoRoot "desktop_flutter"
$appRuntimeBuildScript = Join-Path $PSScriptRoot "build_app_runtime.ps1"
$ffmpegRuntimeBuildScript = Join-Path $PSScriptRoot "build_ffmpeg_runtime.ps1"
if ([string]::IsNullOrWhiteSpace($AppRuntimeRoot)) {
    $AppRuntimeRoot = Join-Path $repoRoot "dist\app-runtime\windows-x64"
}
if ($BuildAppRuntime -or $Build) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $appRuntimeBuildScript -OutputRoot $AppRuntimeRoot -Force
    if ($LASTEXITCODE -ne 0) {
        throw "App runtime build failed with exit code $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $AppRuntimeRoot)) {
    throw "App runtime not found: $AppRuntimeRoot. Build it with scripts\build_app_runtime.ps1."
}
$resolvedAppRuntimeRoot = (Resolve-Path -LiteralPath $AppRuntimeRoot).Path
$requiredRuntimePaths = @(
    "app_runtime.json",
    "python\python.exe",
    "python\pythonw.exe",
    "python\Lib\site-packages\transvortex\app_service.py",
    "python\Lib\site-packages\transvortex\app\agent_client.py",
    "python\Lib\site-packages\transvortex\app\asr_storage.py",
    "python\Lib\site-packages\transvortex\protocol\agent_setup.py",
    "python\Lib\site-packages\transvortex\resources\asr_components.json"
)
$missingRuntimePaths = @(
    $requiredRuntimePaths |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $resolvedAppRuntimeRoot $_)) }
)
if ($missingRuntimePaths.Count -gt 0) {
    throw "App runtime is incomplete under $resolvedAppRuntimeRoot. Missing: $($missingRuntimePaths -join ', '). Build it with scripts\build_app_runtime.ps1."
}
if ([string]::IsNullOrWhiteSpace($FfmpegRuntimeRoot)) {
    $FfmpegRuntimeRoot = Join-Path $repoRoot "dist\ffmpeg-runtime\windows-x64"
}
if ($BuildFfmpegRuntime -or $Build) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ffmpegRuntimeBuildScript -OutputRoot $FfmpegRuntimeRoot -Force
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg runtime build failed with exit code $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $FfmpegRuntimeRoot)) {
    throw "FFmpeg runtime not found: $FfmpegRuntimeRoot. Build it with scripts\build_ffmpeg_runtime.ps1."
}
$resolvedFfmpegRuntimeRoot = (Resolve-Path -LiteralPath $FfmpegRuntimeRoot).Path
$requiredFfmpegRuntimePaths = @(
    "ffmpeg_runtime.json",
    "bin\ffmpeg.exe",
    "bin\ffprobe.exe",
    "licenses\FFmpeg-LICENSE.txt",
    "SOURCE_NOTICE.txt"
)
$missingFfmpegRuntimePaths = @(
    $requiredFfmpegRuntimePaths |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $resolvedFfmpegRuntimeRoot $_)) }
)
if ($missingFfmpegRuntimePaths.Count -gt 0) {
    throw "FFmpeg runtime is incomplete under $resolvedFfmpegRuntimeRoot. Missing: $($missingFfmpegRuntimePaths -join ', ')."
}
if ($Build) {
    Push-Location $desktopFlutterRoot
    try {
        & flutter build windows
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build windows failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $releaseDir = Join-Path $repoRoot "desktop_flutter\build\windows\x64\runner\Release"
    $newExePath = Join-Path $releaseDir "TransVortex.exe"
    $legacyExePath = Join-Path $releaseDir "transvortex_desktop_flutter.exe"
    $ExePath = if (Test-Path -LiteralPath $newExePath) { $newExePath } else { $legacyExePath }
}
$resolvedExe = Resolve-Path -LiteralPath $ExePath
$releaseRoot = Split-Path -Parent $resolvedExe.Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist"
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$resolvedOutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $packageKind = if ($InstallerPayload) { "installer-payload" } else { "portable" }
    $PackageName = "TransVortex-$packageKind-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}
$packageRoot = Join-Path $resolvedOutputRoot $PackageName
Assert-PathInsideDirectory -Path $packageRoot -Directory $resolvedOutputRoot
if (Test-Path -LiteralPath $packageRoot) {
    if (-not $Force) {
        throw "Package directory already exists: $packageRoot. Pass -Force to replace it."
    }
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

Get-ChildItem -LiteralPath $releaseRoot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $packageRoot -Recurse -Force
}
Copy-RequiredDirectory -Source $resolvedAppRuntimeRoot -Destination (Join-Path $packageRoot "runtime")
Copy-RequiredDirectory -Source $resolvedFfmpegRuntimeRoot -Destination (Join-Path $packageRoot "tools\ffmpeg")
Copy-RequiredDirectory -Source (Join-Path $repoRoot "prompts") -Destination (Join-Path $packageRoot "prompts")
Copy-RequiredDirectory -Source (Join-Path $repoRoot "agent") -Destination (Join-Path $packageRoot "agent")
if (Test-Path -LiteralPath (Join-Path $repoRoot "memory\presets")) {
    Copy-RequiredDirectory -Source (Join-Path $repoRoot "memory\presets") -Destination (Join-Path $packageRoot "memory\presets")
}
Copy-RequiredFile -Source (Join-Path $repoRoot "pipeline.desktop.yaml") -Destination (Join-Path $packageRoot "pipeline.yaml")
Copy-RequiredFile -Source (Join-Path $repoRoot "providers.example.yaml") -Destination (Join-Path $packageRoot "providers.example.yaml")
Copy-RequiredFile -Source (Join-Path $repoRoot "providers.desktop.yaml") -Destination (Join-Path $packageRoot "providers.yaml")
Copy-RequiredFile -Source (Join-Path $repoRoot "README.md") -Destination (Join-Path $packageRoot "README.md")
Copy-RequiredFile -Source (Join-Path $repoRoot "LICENSE") -Destination (Join-Path $packageRoot "LICENSE")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "desktop_flutter\assets\fonts\NotoSansSC-OFL.txt") `
    -Destination (Join-Path $packageRoot "licenses\fonts\NotoSansSC-OFL.txt")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "desktop_flutter\assets\fonts\LXGWWenKaiLite-OFL.txt") `
    -Destination (Join-Path $packageRoot "licenses\fonts\LXGWWenKaiLite-OFL.txt")
if ($InstallerPayload) {
    New-InstallerPayloadReadme -Path (Join-Path $packageRoot "README_INSTALLER_PAYLOAD.txt")
} else {
    Copy-RequiredFile -Source (Join-Path $PSScriptRoot "install_flutter_desktop_shortcut.ps1") -Destination (Join-Path $packageRoot "scripts\install_flutter_desktop_shortcut.ps1")
    Copy-RequiredFile -Source (Join-Path $PSScriptRoot "install_flutter_portable_release.ps1") -Destination (Join-Path $packageRoot "scripts\install_flutter_portable_release.ps1")
    New-PortableShortcutInstaller -Path (Join-Path $packageRoot "Install-StartMenuShortcut.ps1")
    New-PortableUserInstaller -Path (Join-Path $packageRoot "Install-TransVortex.ps1")
    New-PortableReadme -Path (Join-Path $packageRoot "README_PORTABLE.txt")
}
Remove-GeneratedPackageFiles -PackageRoot $packageRoot

$requiredPaths = @(
    "TransVortex.exe",
    "flutter_windows.dll",
    "flutter_local_notifications_windows.dll",
    "data\flutter_assets\FontManifest.json",
    "LICENSE",
    "licenses\fonts\NotoSansSC-OFL.txt",
    "licenses\fonts\LXGWWenKaiLite-OFL.txt",
    "runtime\app_runtime.json",
    "runtime\python\python.exe",
    "runtime\python\pythonw.exe",
    "runtime\python\Lib\site-packages\transvortex\app_service.py",
    "runtime\python\Lib\site-packages\transvortex\app\agent_client.py",
    "runtime\python\Lib\site-packages\transvortex\app\agent_entry.py",
    "runtime\python\Lib\site-packages\transvortex\protocol\agent_protocol.py",
    "runtime\python\Lib\site-packages\transvortex\protocol\agent_setup.py",
    "runtime\python\Lib\site-packages\transvortex\app\desktop_api.py",
    "runtime\python\Lib\site-packages\transvortex\app\asr_storage.py",
    "runtime\python\Lib\site-packages\transvortex\app\asr_operations.py",
    "runtime\python\Lib\site-packages\transvortex\core\whisper_host.py",
    "runtime\python\Lib\site-packages\transvortex\resources\asr_components.json",
    "tools\ffmpeg\ffmpeg_runtime.json",
    "tools\ffmpeg\bin\ffmpeg.exe",
    "tools\ffmpeg\bin\ffprobe.exe",
    "tools\ffmpeg\SOURCE_NOTICE.txt",
    "prompts\translation\system.v1.md",
    "agent\README.md",
    "agent\AGENT_USAGE.md",
    "agent\ADAPTATION_GUIDE.md",
    "agent\workflows\ASR_ENVIRONMENT_SETUP.md",
    "agent\references\provider-modes.md",
    "agent\references\setup_contract.schema.json",
    "pipeline.yaml",
    "providers.example.yaml",
    "providers.yaml"
)
if ($InstallerPayload) {
    $requiredPaths += "README_INSTALLER_PAYLOAD.txt"
} else {
    $requiredPaths += @("Install-TransVortex.ps1", "Install-StartMenuShortcut.ps1", "README_PORTABLE.txt")
}
$missing = @(
    $requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $packageRoot $_)) }
)
if ($missing.Count -gt 0) {
    throw "Portable package missing required paths: $($missing -join ', ')"
}
Assert-PortablePackageNoSecrets -PackageRoot $packageRoot

$providerSeedReport = Test-PackagedProviderSeed -PackageRoot $packageRoot
$ffmpegReport = Test-PackagedFfmpegRuntime -PackageRoot $packageRoot
$serviceReport = Invoke-PortableServiceCheck -PackageRoot $packageRoot
if ($InstallerPayload) {
    $ffmpegReport["ffmpeg_path"] = "tools\ffmpeg\bin\ffmpeg.exe"
    $ffmpegReport["ffprobe_path"] = "tools\ffmpeg\bin\ffprobe.exe"
    $providerSeedReport["providers_path"] = "providers.yaml"
    $serviceReport["working_directory"] = "."
    $serviceReport["python_executable"] = "runtime\python\python.exe"
}
Remove-GeneratedPackageFiles -PackageRoot $packageRoot
Assert-PortablePackageNoSecrets -PackageRoot $packageRoot

$launchReport = $null
if ($LaunchCheck) {
    $manualScript = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "accept_flutter_release_manual.ps1")
    $launchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $manualScript -ExePath (Join-Path $packageRoot "TransVortex.exe") -LaunchCheck -LaunchCheckSeconds 1 -Json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Portable package launch check failed: $($launchJson | Out-String)"
    }
    $launchReport = (($launchJson | Out-String).Trim() | ConvertFrom-Json)
    Remove-GeneratedPackageFiles -PackageRoot $packageRoot
    Assert-PortablePackageNoSecrets -PackageRoot $packageRoot
}

$zipPath = ""
if (-not $NoZip) {
    $zipPath = Join-Path $resolvedOutputRoot "$PackageName.zip"
    if (Test-Path -LiteralPath $zipPath) {
        if (-not $Force) {
            throw "Zip already exists: $zipPath. Pass -Force to replace it."
        }
        Assert-PathInsideDirectory -Path $zipPath -Directory $resolvedOutputRoot
        Remove-Item -LiteralPath $zipPath -Force
    }
}

$files = Get-ChildItem -LiteralPath $packageRoot -Recurse -File
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$ffmpegPublicationRequirement = $null
if (-not [bool]$ffmpegReport.corresponding_source_assets_published) {
    $ffmpegPublicationRequirement = "publish the pinned FFmpeg corresponding source alongside any public installer"
} elseif (-not [bool]$ffmpegReport.build_input_scope_complete -or
    -not [bool]$ffmpegReport.external_library_sources_included) {
    $ffmpegPublicationRequirement = "publish complete corresponding FFmpeg source, including required external LGPL library sources, alongside any public installer"
} elseif (-not [bool]$ffmpegReport.license_review_complete) {
    $ffmpegPublicationRequirement = "complete the recorded FFmpeg license review before any public installer"
}
$manualAcceptanceRequired = @(
    "real visible release window end-to-end run; record with scripts/accept_flutter_release_manual.ps1",
    "native NSIS installer install, upgrade, running-process protection, and uninstall acceptance"
)
if (-not [string]::IsNullOrWhiteSpace($ffmpegPublicationRequirement)) {
    $manualAcceptanceRequired += $ffmpegPublicationRequirement
}
$report = [ordered]@{
    ok = $true
    package_type = if ($InstallerPayload) { "installer_payload" } else { "portable" }
    installer = $false
    native_installer = $false
    installer_format_complete = $false
    user_level_install_script = if ($InstallerPayload) { $null } else { "Install-TransVortex.ps1" }
    user_level_install_supported = -not [bool]$InstallerPayload
    frontend_design_mvp_complete = $false
    completion_claim = if ($InstallerPayload) { "Installer payload created and validated; the payload itself is not a native Windows installer." } else { "Portable release package created; this validates package layout and package-root Local Service RPC, but is not a native Windows installer." }
    package_dir = if ($InstallerPayload) { "." } else { $packageRoot }
    zip_path = $zipPath
    exe_path = if ($InstallerPayload) { "TransVortex.exe" } else { Join-Path $packageRoot "TransVortex.exe" }
    source_release_dir = if ($InstallerPayload) { $null } else { $releaseRoot }
    file_count = $files.Count
    total_bytes = [int64]$totalBytes
    providers_yaml_source = "providers.desktop.yaml"
    provider_connection_count = $providerSeedReport.provider_connection_count
    provider_seed_check = $providerSeedReport
    python_runtime_included = $true
    python_runtime_root = "runtime"
    python_runtime_manifest = "runtime\app_runtime.json"
    python_runtime_source = if ($InstallerPayload) { $null } else { $resolvedAppRuntimeRoot }
    ffmpeg_included = $true
    ffmpeg_runtime_root = "tools\ffmpeg"
    ffmpeg_runtime_source = if ($InstallerPayload) { $null } else { $resolvedFfmpegRuntimeRoot }
    agent_assets_included = $true
    agent_asset_root = "agent"
    agent_entry_registration = if ($InstallerPayload) { "nsis_installer" } else { "none" }
    agent_entry_stable_root = if ($InstallerPayload) { "%LOCALAPPDATA%\TransVortex\Agent" } else { $null }
    agent_native_extensions_modified = $false
    ffmpeg_check = $ffmpegReport
    local_asr_runtime_included = $false
    local_asr_models_included = $false
    local_asr_accelerator_included = $false
    local_asr_catalog = "runtime\python\Lib\site-packages\transvortex\resources\asr_components.json"
    excluded_local_secret_files = @(".env", ".imagegen.env", ".env.imagegen", "providers.local.yaml", "auth.json")
    required_paths = $requiredPaths
    local_service_check = $serviceReport
    launch_check = if ($launchReport -ne $null) { $launchReport } else { $null }
    manual_acceptance_required = $manualAcceptanceRequired
}
$manifestName = if ($InstallerPayload) { "installer_payload_manifest.json" } else { "portable_manifest.json" }
$manifestPath = Join-Path $packageRoot $manifestName
$report["manifest_path"] = if ($InstallerPayload) { $manifestName } else { $manifestPath }
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$files = Get-ChildItem -LiteralPath $packageRoot -Recurse -File
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$report["file_count"] = $files.Count
$report["total_bytes"] = [int64]$totalBytes
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

if (-not $NoZip) {
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -Force
}

if ($Json) {
    $report | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$report
}
