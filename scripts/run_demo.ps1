param(
    [string]$InputPath = "",
    [string]$ProvidersFile = "providers.local.yaml",
    [string]$SourceLang = "en",
    [string]$TargetLang = "zh-CN",
    [bool]$Bilingual = $true,
    [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$tvx = Join-Path $root ".venv\\Scripts\\transvortex.exe"

if (-not (Test-Path $tvx)) {
    throw "Missing transvortex executable: $tvx"
}

if ($ApiKey) {
    $env:TVX_MODEL_API_KEY = $ApiKey
}

$providersPath = if ([System.IO.Path]::IsPathRooted($ProvidersFile)) { $ProvidersFile } else { Join-Path $root $ProvidersFile }
if ($InputPath) {
    $inputFile = if ([System.IO.Path]::IsPathRooted($InputPath)) { $InputPath } else { Join-Path $root $InputPath }
} else {
    $demoDir = Join-Path $root "DemoTest"
    $demoVideo = Get-ChildItem -LiteralPath $demoDir -Filter "*.mp4" | Select-Object -First 1
    if (-not $demoVideo) {
        throw "No demo mp4 found in $demoDir"
    }
    $inputFile = $demoVideo.FullName
}

Write-Host "[1/4] Doctor..."
& $tvx doctor --providers-file $providersPath
if ($LASTEXITCODE -ne 0) { throw "doctor failed" }

Write-Host "[2/4] Probe provider..."
& $tvx probe-provider --providers-file $providersPath --strict
if ($LASTEXITCODE -ne 0) { throw "probe-provider failed" }

$args = @(
    "run",
    "--providers-file", $providersPath,
    "--input", $inputFile,
    "--src", $SourceLang,
    "--tgt", $TargetLang
)
if ($Bilingual) {
    $args += "--bilingual"
}

Write-Host "[3/4] Run pipeline..."
$runOutput = & $tvx @args
if ($LASTEXITCODE -ne 0) { throw "run failed" }
$taskId = ($runOutput | Select-Object -Last 1).Trim()
if (-not $taskId) { throw "run did not return a task id" }

Write-Host "[4/4] Task status..."
& $tvx status --task-id $taskId
if ($LASTEXITCODE -ne 0) { throw "status failed" }
