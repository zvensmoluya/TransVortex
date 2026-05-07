param(
    [string]$InputPath = "DemoTest/英文视频.mp4",
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
$inputFile = if ([System.IO.Path]::IsPathRooted($InputPath)) { $InputPath } else { Join-Path $root $InputPath }

Write-Host "[1/3] Probe provider..."
& $tvx probe-provider --providers-file $providersPath --strict

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

Write-Host "[2/3] Run pipeline..."
$taskId = (& $tvx @args | Select-Object -Last 1).Trim()

Write-Host "[3/3] Task status..."
& $tvx status --task-id $taskId
