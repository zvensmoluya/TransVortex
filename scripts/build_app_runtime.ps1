param(
    [string]$OutputRoot = "",
    [string]$PythonCommand = "py",
    [string]$PythonVersion = "3.13",
    [string]$PythonEmbedUrl = "https://www.python.org/ftp/python/3.13.14/python-3.13.14-embed-amd64.zip",
    [string]$PythonEmbedSha256 = "90b4e5b9898b72d744650524bff92377c367f44bd5fbd09e3148656c080ad907",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$requirementsPath = Join-Path $repoRoot "requirements\app-runtime.txt"
if (-not (Test-Path -LiteralPath $requirementsPath)) {
    throw "App runtime requirements not found: $requirementsPath"
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\app-runtime\windows-x64"
}
$outputRootFull = [System.IO.Path]::GetFullPath($OutputRoot)
$outputRootTrimmed = $outputRootFull.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$volumeRoot = [System.IO.Path]::GetPathRoot($outputRootFull).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$repoRootTrimmed = $repoRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$outputPrefix = $outputRootTrimmed + [System.IO.Path]::DirectorySeparatorChar
if (
    [string]::IsNullOrWhiteSpace($outputRootTrimmed) -or
    $outputRootTrimmed.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $repoRootTrimmed.Equals($outputRootTrimmed, [System.StringComparison]::OrdinalIgnoreCase) -or
    $repoRootTrimmed.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw "Unsafe app runtime output directory: $outputRootFull"
}
if (Test-Path -LiteralPath $outputRootFull) {
    if (-not $Force) {
        throw "Output directory already exists: $outputRootFull. Pass -Force to replace it."
    }
    Remove-Item -LiteralPath $outputRootFull -Recurse -Force
}
$workRoot = Join-Path $outputRootFull "work"
$runtimeStage = Join-Path $workRoot "python"
$wheelRoot = Join-Path $workRoot "wheels"
New-Item -ItemType Directory -Force -Path $runtimeStage, $wheelRoot | Out-Null

function Invoke-Checked {
    param([string]$FileName, [string[]]$Arguments)
    if ($Json) {
        & $FileName @Arguments | Out-Null
    } else {
        & $FileName @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FileName $($Arguments -join ' ')"
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$pythonEmbedZip = Join-Path $workRoot "python-embed.zip"
Invoke-WebRequest -Uri $PythonEmbedUrl -OutFile $pythonEmbedZip -UseBasicParsing
$actualPythonEmbedHash = (Get-FileHash -LiteralPath $pythonEmbedZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualPythonEmbedHash -ne $PythonEmbedSha256.ToLowerInvariant()) {
    throw "Embedded Python SHA-256 mismatch. Expected $PythonEmbedSha256, got $actualPythonEmbedHash."
}
Expand-Archive -LiteralPath $pythonEmbedZip -DestinationPath $runtimeStage -Force

$pthFile = Get-ChildItem -LiteralPath $runtimeStage -Filter "python*._pth" | Select-Object -First 1
if ($null -eq $pthFile) {
    throw "Embedded Python _pth file not found."
}
$pthLines = @(Get-Content -LiteralPath $pthFile.FullName -Encoding utf8)
$nextPthLines = @()
$hasSitePackages = $false
$hasImportSite = $false
foreach ($line in $pthLines) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "Lib\site-packages") {
        $hasSitePackages = $true
    }
    if ($trimmed -eq "import site" -or $trimmed -eq "#import site") {
        if (-not $hasSitePackages) {
            $nextPthLines += "Lib\site-packages"
            $hasSitePackages = $true
        }
        $nextPthLines += "import site"
        $hasImportSite = $true
    } else {
        $nextPthLines += $line
    }
}
if (-not $hasSitePackages) {
    $nextPthLines += "Lib\site-packages"
}
if (-not $hasImportSite) {
    $nextPthLines += "import site"
}
Write-Utf8NoBom -Path $pthFile.FullName -Text (($nextPthLines -join "`r`n") + "`r`n")

$sitePackages = Join-Path $runtimeStage "Lib\site-packages"
New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
Invoke-Checked -FileName $PythonCommand -Arguments @(
    "-$PythonVersion", "-m", "pip", "wheel",
    "--disable-pip-version-check", "--no-deps",
    "--wheel-dir", $wheelRoot,
    $repoRoot
)
$appWheels = @(Get-ChildItem -LiteralPath $wheelRoot -Filter "transvortex-*.whl" -File)
if ($appWheels.Count -ne 1) {
    throw "Expected one TransVortex wheel, found $($appWheels.Count)."
}
$appWheel = $appWheels[0]
Invoke-Checked -FileName $PythonCommand -Arguments @(
    "-$PythonVersion", "-m", "pip", "install",
    "--disable-pip-version-check", "--only-binary=:all:", "--no-compile",
    "--target", $sitePackages,
    "-r", $requirementsPath,
    $appWheel.FullName
)

$runtimePython = Join-Path $runtimeStage "python.exe"
Invoke-Checked -FileName $runtimePython -Arguments @(
    "-B", "-I", "-c",
    "import httpx, yaml, transvortex; from transvortex.app.desktop_api import PROTOCOL_VERSION; print(transvortex.__version__); print(PROTOCOL_VERSION)"
)
$metadataProbePath = Join-Path $workRoot "probe_app_runtime.py"
$metadataProbe = @'
import importlib.metadata as metadata
import json
import platform
import transvortex
from transvortex.app.desktop_api import PROTOCOL_VERSION

packages = sorted(
    (
        {"name": str(item.metadata.get("Name") or ""), "version": item.version}
        for item in metadata.distributions()
        if item.metadata.get("Name")
    ),
    key=lambda item: item["name"].lower(),
)
print(json.dumps({
    "app_version": transvortex.__version__,
    "protocol_version": PROTOCOL_VERSION,
    "python_version": platform.python_version(),
    "python_implementation": platform.python_implementation(),
    "python_architecture": platform.machine(),
    "packages": packages,
}))
'@
Write-Utf8NoBom -Path $metadataProbePath -Text $metadataProbe
$metadataJson = & $runtimePython -B -I $metadataProbePath
if ($LASTEXITCODE -ne 0) {
    throw "Embedded app runtime metadata probe failed with exit code $LASTEXITCODE."
}
$metadata = ($metadataJson | Out-String).Trim() | ConvertFrom-Json

$runtimeRoot = Join-Path $outputRootFull "python"
Move-Item -LiteralPath $runtimeStage -Destination $runtimeRoot
$manifest = [ordered]@{
    schema_version = 1
    id = "transvortex-app-runtime"
    version = [string]$metadata.app_version
    platform = "windows-x64"
    protocol_version = [int]$metadata.protocol_version
    python = "python\python.exe"
    python_version = [string]$metadata.python_version
    python_implementation = [string]$metadata.python_implementation
    python_architecture = [string]$metadata.python_architecture
    python_embed_url = $PythonEmbedUrl
    python_embed_sha256 = $actualPythonEmbedHash
    app_wheel = [ordered]@{
        name = $appWheel.Name
        sha256 = (Get-FileHash -LiteralPath $appWheel.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    requirements = @(
        Get-Content -LiteralPath $requirementsPath -Encoding utf8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
    requirements_sha256 = (Get-FileHash -LiteralPath $requirementsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    packages = @($metadata.packages)
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}
$manifestPath = Join-Path $outputRootFull "app_runtime.json"
Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 10)
Remove-Item -LiteralPath $workRoot -Recurse -Force

$report = [ordered]@{
    ok = $true
    runtime_root = $outputRootFull
    python_executable = Join-Path $runtimeRoot "python.exe"
    manifest_path = $manifestPath
    app_version = [string]$metadata.app_version
    protocol_version = [int]$metadata.protocol_version
    python_version = [string]$metadata.python_version
    package_count = @($metadata.packages).Count
}
if ($Json) {
    $report | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$report
}
