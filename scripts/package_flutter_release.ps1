param(
    [string]$ExePath = "",
    [string]$OutputRoot = "",
    [string]$PackageName = "",
    [switch]$Build,
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

    $forbiddenRootPaths = @(".venv", "artifacts", "output", "tmp", "DemoTest")
    $rootMatches = @(
        $forbiddenRootPaths |
            ForEach-Object { Join-Path $PackageRoot $_ } |
            Where-Object { Test-Path -LiteralPath $_ } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    )
    if ($rootMatches.Count -gt 0) {
        throw "Portable package contains forbidden repo-local root paths: $($rootMatches -join ', ')"
    }
}

function Invoke-PortableServiceCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,
        [int]$TimeoutSeconds = 15
    )

    $pythonPath = Join-Path $PackageRoot "src"
    if (-not (Test-Path -LiteralPath (Join-Path $pythonPath "transvortex\app_service.py"))) {
        throw "Portable package service source not found under $pythonPath"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "python"
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
    $existingPythonPath = if ($psi.Environment.ContainsKey("PYTHONPATH")) { $psi.Environment["PYTHONPATH"] } else { "" }
    $psi.Environment["PYTHONPATH"] = if ([string]::IsNullOrWhiteSpace($existingPythonPath)) {
        $pythonPath
    } else {
        "$pythonPath;$PackageRoot;$existingPythonPath"
    }
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
        $requests = @(
            [ordered]@{ jsonrpc = "2.0"; id = 1; method = "service.info"; params = @{} },
            [ordered]@{ jsonrpc = "2.0"; id = 2; method = "service.health"; params = @{} },
            [ordered]@{ jsonrpc = "2.0"; id = 3; method = "service.shutdown"; params = @{} }
        )
        foreach ($request in $requests) {
            $process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 5))
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
    $shutdown = $responses | Where-Object { $_.id -eq 3 } | Select-Object -First 1
    $errors = @(
        $responses |
            Where-Object { ($_.PSObject.Properties.Name -contains "error") -and $null -ne $_.error } |
            ForEach-Object { $_.error }
    )
    if ($responses.Count -ne 3 -or $errors.Count -gt 0) {
        throw "Portable Local Service RPC check failed. Responses=$($responses.Count) Errors=$($errors.Count) Stdout=$stdoutText Stderr=$stderrText"
    }
    if ($info.result.service -ne "transvortex.app_service") {
        throw "Unexpected service.info service: $($info.result.service)"
    }
    if ($health.result.service -ne "transvortex.app_service") {
        throw "Unexpected service.health service: $($health.result.service)"
    }
    if (-not [bool]$shutdown.result.ok) {
        throw "service.shutdown did not return ok=true."
    }

    return [ordered]@{
        ok = $true
        started_at = $startedAt.ToString("o")
        ended_at = (Get-Date).ToString("o")
        working_directory = $PackageRoot
        pythonpath_prefix = $pythonPath
        response_count = $responses.Count
        service = [string]$info.result.service
        protocol_version = $info.result.protocol_version
        health_status = [string]$health.result.status
        pump_enabled = [bool]$health.result.pump.enabled
        shutdown_ok = [bool]$shutdown.result.ok
        exit_code = $process.ExitCode
        stderr = $stderrText.Trim()
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

This portable package includes the Flutter release bundle and the Python source
tree required by the current Local Service launcher. It does not include a
Python runtime, FFmpeg, model files, API keys, auth.json, .env files, or local
provider configuration.

Credentials are resolved from the user-level TransVortex credential store
(~\.transvortex\auth.json) or environment variables. The bundled providers.yaml
is copied from providers.example.yaml so that no local provider secrets are
packaged.

This is not an MSIX/MSI/NSIS/Inno installer. It is a portable distribution
artifact used to validate package layout and release startup before the formal
installer path is built. The package manifest records the package-root Local
Service RPC check performed by the packaging script. The optional install script
copies the package to a user-level directory and creates a Start menu shortcut,
but it is still not a formal Windows installer.
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
    $PackageName = "TransVortex-portable-" + (Get-Date -Format "yyyyMMdd-HHmmss")
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
Copy-RequiredDirectory -Source (Join-Path $repoRoot "src") -Destination (Join-Path $packageRoot "src")
Copy-RequiredDirectory -Source (Join-Path $repoRoot "prompts") -Destination (Join-Path $packageRoot "prompts")
if (Test-Path -LiteralPath (Join-Path $repoRoot "memory\presets")) {
    Copy-RequiredDirectory -Source (Join-Path $repoRoot "memory\presets") -Destination (Join-Path $packageRoot "memory\presets")
}
Copy-RequiredFile -Source (Join-Path $repoRoot "pyproject.toml") -Destination (Join-Path $packageRoot "pyproject.toml")
Copy-RequiredFile -Source (Join-Path $repoRoot "pipeline.yaml") -Destination (Join-Path $packageRoot "pipeline.yaml")
Copy-RequiredFile -Source (Join-Path $repoRoot "providers.example.yaml") -Destination (Join-Path $packageRoot "providers.example.yaml")
Copy-RequiredFile -Source (Join-Path $repoRoot "providers.example.yaml") -Destination (Join-Path $packageRoot "providers.yaml")
Copy-RequiredFile -Source (Join-Path $repoRoot "README.md") -Destination (Join-Path $packageRoot "README.md")
Copy-RequiredFile -Source (Join-Path $repoRoot "LICENSE") -Destination (Join-Path $packageRoot "LICENSE")
Copy-RequiredFile -Source (Join-Path $PSScriptRoot "install_flutter_desktop_shortcut.ps1") -Destination (Join-Path $packageRoot "scripts\install_flutter_desktop_shortcut.ps1")
Copy-RequiredFile -Source (Join-Path $PSScriptRoot "install_flutter_portable_release.ps1") -Destination (Join-Path $packageRoot "scripts\install_flutter_portable_release.ps1")
New-PortableShortcutInstaller -Path (Join-Path $packageRoot "Install-StartMenuShortcut.ps1")
New-PortableUserInstaller -Path (Join-Path $packageRoot "Install-TransVortex.ps1")
New-PortableReadme -Path (Join-Path $packageRoot "README_PORTABLE.txt")
Remove-GeneratedPackageFiles -PackageRoot $packageRoot

$requiredPaths = @(
    "TransVortex.exe",
    "flutter_windows.dll",
    "flutter_local_notifications_windows.dll",
    "data\flutter_assets\FontManifest.json",
    "src\transvortex\app_service.py",
    "src\transvortex\app\desktop_api.py",
    "prompts\translation\system.v1.md",
    "pipeline.yaml",
    "providers.yaml",
    "pyproject.toml",
    "Install-TransVortex.ps1",
    "Install-StartMenuShortcut.ps1"
)
$missing = @(
    $requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $packageRoot $_)) }
)
if ($missing.Count -gt 0) {
    throw "Portable package missing required paths: $($missing -join ', ')"
}
Assert-PortablePackageNoSecrets -PackageRoot $packageRoot

$serviceReport = Invoke-PortableServiceCheck -PackageRoot $packageRoot
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
$report = [ordered]@{
    ok = $true
    package_type = "portable"
    installer = $false
    formal_installer = $false
    user_level_install_script = "Install-TransVortex.ps1"
    user_level_install_supported = $true
    frontend_design_mvp_complete = $false
    completion_claim = "Portable release package created; this validates package layout and package-root Local Service RPC, but is not a formal MSIX/MSI/NSIS/Inno installer."
    package_dir = $packageRoot
    zip_path = $zipPath
    exe_path = Join-Path $packageRoot "TransVortex.exe"
    source_release_dir = $releaseRoot
    file_count = $files.Count
    total_bytes = [int64]$totalBytes
    providers_yaml_source = "providers.example.yaml"
    python_runtime_included = $false
    ffmpeg_included = $false
    excluded_local_secret_files = @(".env", ".imagegen.env", ".env.imagegen", "providers.local.yaml", "auth.json")
    required_paths = $requiredPaths
    local_service_check = $serviceReport
    launch_check = if ($launchReport -ne $null) { $launchReport } else { $null }
    manual_acceptance_required = @(
        "real visible release window end-to-end run; record with scripts/accept_flutter_release_manual.ps1",
        "formal MSIX/MSI/NSIS/Inno installer acceptance"
    )
}
$manifestPath = Join-Path $packageRoot "portable_manifest.json"
$report["manifest_path"] = $manifestPath
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
