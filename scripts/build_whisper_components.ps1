param(
    [string]$OutputRoot = "",
    [string]$PythonCommand = "py",
    [string]$PythonVersion = "3.13",
    [string]$PythonEmbedUrl = "https://www.python.org/ftp/python/3.13.14/python-3.13.14-embed-amd64.zip",
    [string]$PythonEmbedSha256 = "90b4e5b9898b72d744650524bff92377c367f44bd5fbd09e3148656c080ad907",
    [switch]$RuntimeOnly,
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$catalogPath = Join-Path $repoRoot "src\transvortex\resources\asr_components.json"
$catalog = Get-Content -LiteralPath $catalogPath -Encoding utf8 -Raw | ConvertFrom-Json

function Assert-SafeLeafName {
    param([string]$Value, [string]$Description)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9._-]+$' -or $Value -in @('.', '..')) {
        throw "$Description is not a safe file-system name: $Value"
    }
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return (
        $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

$runtimeVersion = [string]$catalog.runtime.version
Assert-SafeLeafName -Value $runtimeVersion -Description "Runtime version"
Assert-SafeLeafName -Value ([string]$catalog.runtime.artifact.asset_name) -Description "Runtime asset_name"
foreach ($accelerator in @($catalog.accelerators)) {
    Assert-SafeLeafName -Value ([string]$accelerator.version) -Description "Accelerator version"
    Assert-SafeLeafName -Value ([string]$accelerator.artifact.asset_name) -Description "Accelerator asset_name"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\asr-components\$($catalog.runtime.version)"
}
$outputRootFull = [System.IO.Path]::GetFullPath($OutputRoot)
$volumeRoot = [System.IO.Path]::GetPathRoot($outputRootFull)
if ([string]::IsNullOrWhiteSpace($volumeRoot) -or $outputRootFull.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) {
    throw "OutputRoot must not be a file-system volume root: $outputRootFull"
}
if ($outputRootFull.TrimEnd('\', '/') -eq $repoRoot.TrimEnd('\', '/')) {
    throw "OutputRoot must not be the repository root: $outputRootFull"
}
$workRoot = Join-Path $outputRootFull "work"
if (Test-Path -LiteralPath $outputRootFull) {
    if (-not $Force) {
        throw "Output directory already exists: $outputRootFull. Pass -Force to replace it."
    }
    $existingOutput = Get-Item -LiteralPath $outputRootFull -Force -ErrorAction Stop
    if (-not $existingOutput.PSIsContainer -or ($existingOutput.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "OutputRoot must be a non-reparse directory: $outputRootFull"
    }
    $existingManifestPath = Join-Path $outputRootFull "asr_components_build.json"
    $ownedOutput = $false
    if (Test-Path -LiteralPath $existingManifestPath -PathType Leaf) {
        try {
            $existingManifest = Get-Content -LiteralPath $existingManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
            $ownedOutput = ([string]$existingManifest.schema_version -eq "1" -and [string]$existingManifest.release_tag -eq [string]$catalog.runtime.artifact.release_tag)
            $existingAssets = @($existingManifest.assets)
            if ($existingAssets.Count -lt 1) {
                $ownedOutput = $false
            }
            foreach ($asset in $existingAssets) {
                $assetPathValue = [string]$asset.path
                $assetPath = if ([System.IO.Path]::IsPathRooted($assetPathValue)) {
                    [System.IO.Path]::GetFullPath($assetPathValue)
                } else {
                    [System.IO.Path]::GetFullPath((Join-Path $outputRootFull $assetPathValue))
                }
                if (
                    [string]::IsNullOrWhiteSpace($assetPathValue) -or
                    -not (Test-PathUnderRoot -Path $assetPath -Root $outputRootFull) -or
                    -not (Test-Path -LiteralPath $assetPath -PathType Leaf)
                ) {
                    $ownedOutput = $false
                }
            }
        } catch {
            $ownedOutput = $false
        }
    }
    if (-not $ownedOutput) {
        throw "Refusing to recursively replace an unowned OutputRoot. Remove it manually or use a directory containing a matching asr_components_build.json: $outputRootFull"
    }
    Remove-Item -LiteralPath $outputRootFull -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

function Invoke-Checked {
    param([string]$FileName, [string[]]$Arguments)
    & $FileName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FileName $($Arguments -join ' ')"
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function New-ZipAsset {
    param([string]$Source, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $Source,
        $Destination,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
}

function Get-AssetRecord {
    param([string]$Kind, [string]$Id, [string]$Version, [string]$Path)
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        kind = $Kind
        id = $Id
        version = $Version
        path = $file.Name
        asset_name = $file.Name
        size = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$assets = @()
$runtimeStage = Join-Path $workRoot "runtime"
$pythonEmbedZip = Join-Path $workRoot "python-embed.zip"
Invoke-WebRequest -Uri $PythonEmbedUrl -OutFile $pythonEmbedZip -UseBasicParsing
$actualPythonEmbedHash = (Get-FileHash -LiteralPath $pythonEmbedZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualPythonEmbedHash -ne $PythonEmbedSha256.ToLowerInvariant()) {
    throw "Embedded Python SHA-256 mismatch. Expected $PythonEmbedSha256, got $actualPythonEmbedHash."
}
New-Item -ItemType Directory -Force -Path $runtimeStage | Out-Null
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
    if ($trimmed -eq "Lib\site-packages") { $hasSitePackages = $true }
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
if (-not $hasSitePackages) { $nextPthLines += "Lib\site-packages" }
if (-not $hasImportSite) { $nextPthLines += "import site" }
Write-Utf8NoBom -Path $pthFile.FullName -Text (($nextPthLines -join "`r`n") + "`r`n")

$sitePackages = Join-Path $runtimeStage "Lib\site-packages"
New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
Invoke-Checked -FileName $PythonCommand -Arguments @(
    "-$PythonVersion", "-m", "pip", "install",
    "--disable-pip-version-check", "--only-binary=:all:", "--no-compile",
    "--target", $sitePackages,
    "faster-whisper==$($catalog.runtime.faster_whisper_version)",
    "ctranslate2==$($catalog.runtime.ctranslate2_version)"
)
$runtimePython = Join-Path $runtimeStage "python.exe"
Invoke-Checked -FileName $runtimePython -Arguments @(
    "-c", "import faster_whisper, ctranslate2; print(faster_whisper.__version__); print(ctranslate2.__version__)"
)
$runtimeMarker = [ordered]@{
    id = [string]$catalog.runtime.id
    version = [string]$catalog.runtime.version
    python = "python.exe"
    protocol_version = [int]$catalog.runtime.protocol_version
}
Write-Utf8NoBom -Path (Join-Path $runtimeStage "component.json") -Text ($runtimeMarker | ConvertTo-Json -Depth 5)
$runtimeAsset = Join-Path $outputRootFull ([string]$catalog.runtime.artifact.asset_name)
New-ZipAsset -Source $runtimeStage -Destination $runtimeAsset
$assets += Get-AssetRecord -Kind "runtime" -Id ([string]$catalog.runtime.id) -Version ([string]$catalog.runtime.version) -Path $runtimeAsset

if (-not $RuntimeOnly) {
    foreach ($accelerator in @($catalog.accelerators)) {
        $acceleratorStage = Join-Path $workRoot "accelerator-$($accelerator.id)"
        New-Item -ItemType Directory -Force -Path $acceleratorStage | Out-Null
        $packageSpecs = @()
        foreach ($package in $accelerator.packages.PSObject.Properties) {
            $packageSpecs += "$($package.Name)==$($package.Value)"
        }
        Invoke-Checked -FileName $PythonCommand -Arguments (@(
                "-$PythonVersion", "-m", "pip", "install",
                "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--no-compile",
                "--target", $acceleratorStage
            ) + $packageSpecs)
        foreach ($required in @("nvidia\cuda_runtime\bin", "nvidia\cuda_nvrtc\bin", "nvidia\cublas\bin", "nvidia\cudnn\bin")) {
            if (-not (Test-Path -LiteralPath (Join-Path $acceleratorStage $required))) {
                throw "Accelerator package is missing required directory: $required"
            }
        }
        $acceleratorMarker = [ordered]@{
            id = [string]$accelerator.id
            version = [string]$accelerator.version
        }
        Write-Utf8NoBom -Path (Join-Path $acceleratorStage "component.json") -Text ($acceleratorMarker | ConvertTo-Json -Depth 5)
        $acceleratorAsset = Join-Path $outputRootFull ([string]$accelerator.artifact.asset_name)
        New-ZipAsset -Source $acceleratorStage -Destination $acceleratorAsset
        $assets += Get-AssetRecord -Kind "accelerator" -Id ([string]$accelerator.id) -Version ([string]$accelerator.version) -Path $acceleratorAsset
    }
}

$manifest = [ordered]@{
    schema_version = 1
    release_tag = [string]$catalog.runtime.artifact.release_tag
    catalog_path = $catalogPath
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    assets = $assets
}
$manifestPath = Join-Path $outputRootFull "asr_components_build.json"
Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 10)
Remove-Item -LiteralPath $workRoot -Recurse -Force

if ($Json) {
    $manifest | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$manifest
}
