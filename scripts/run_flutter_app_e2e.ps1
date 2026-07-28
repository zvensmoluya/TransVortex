param(
    [string]$InputPath = "",
    [string]$PythonExecutable = "",
    [ValidateSet("small", "medium", "large-v3")]
    [string]$ModelId = "large-v3",
    [string]$ModelPath = "",
    [ValidateSet("auto", "cpu", "cuda")]
    [string]$Device = "auto",
    [string]$ComputeType = "auto",
    [string]$PipelineTemplate = "",
    [string]$BaseProvidersFile = "",
    [string]$ProvidersFile = "",
    [string]$AsrProvider = "faster_whisper_large_v3",
    [string]$E2EHome = "",
    [string]$ExePath = "",
    [string]$OutputDir = "",
    [int]$ProbeTimeoutSeconds = 180,
    [switch]$SkipBuild,
    [switch]$PrepareOnly,
    [switch]$LaunchCheck,
    [switch]$NoScreenshots,
    [switch]$PlanOnly,
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$desktopRoot = Join-Path $repoRoot "desktop_flutter"
$helperModule = "transvortex.app.dev_e2e"
$manualAcceptanceScript = Join-Path $PSScriptRoot "accept_flutter_release_manual.ps1"

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "$Label is required."
    }
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
        throw "$Label was not found: $PathValue"
    }
    return (Resolve-Path -LiteralPath $PathValue).Path
}

function Resolve-PythonExecutable {
    param([string]$PathValue)
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        return Resolve-RequiredFile -PathValue $PathValue -Label "Python executable"
    }
    $command = Get-Command python -ErrorAction Stop
    return (Resolve-Path -LiteralPath $command.Source).Path
}

function Write-Result {
    param([object]$Value)
    if ($Json) {
        $Value | ConvertTo-Json -Depth 12
    } else {
        [pscustomobject]$Value
    }
}

function Write-JsonFileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $payload = $Value | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText(
        $Path,
        $payload,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Initialize-E2ESessionRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $markerName = "app_e2e_session_owner.json"
    $markerPath = Join-Path $Path $markerName
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "APP E2E session root is not a directory: $Path"
        }
        $children = @(Get-ChildItem -LiteralPath $Path -Force)
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $ownership = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8 | ConvertFrom-Json
            } catch {
                throw "APP E2E session ownership marker is invalid: $markerPath"
            }
            if ($ownership.purpose -ne "flutter_app_e2e_session") {
                throw "APP E2E session ownership marker is invalid: $markerPath"
            }
        } elseif ($children.Count -gt 0) {
            throw "Refusing to use a non-empty directory that is not an APP E2E session root: $Path"
        }
    } else {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    Write-JsonFileUtf8NoBom -Path $markerPath -Value ([ordered]@{
        schema_version = 1
        purpose = "flutter_app_e2e_session"
        updated_at = (Get-Date).ToUniversalTime().ToString("o")
    })
}

if ([string]::IsNullOrWhiteSpace($PipelineTemplate)) {
    $PipelineTemplate = Join-Path $repoRoot "pipeline.desktop.yaml"
}
if ([string]::IsNullOrWhiteSpace($BaseProvidersFile)) {
    $BaseProvidersFile = Join-Path $repoRoot "providers.yaml"
}
if ([string]::IsNullOrWhiteSpace($ProvidersFile)) {
    $defaultProvidersFile = Join-Path $repoRoot "providers.local.yaml"
    if (Test-Path -LiteralPath $defaultProvidersFile -PathType Leaf) {
        $ProvidersFile = $defaultProvidersFile
    }
}
if ([string]::IsNullOrWhiteSpace($E2EHome)) {
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $E2EHome = Join-Path ([System.IO.Path]::GetTempPath()) (
        "transvortex-app-e2e-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $suffix
    )
}
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Join-Path $desktopRoot "build\windows\x64\runner\Release\TransVortex.exe"
}

$resolvedPython = Resolve-PythonExecutable -PathValue $PythonExecutable
$resolvedPipelineTemplate = Resolve-RequiredFile -PathValue $PipelineTemplate -Label "Pipeline template"
$resolvedBaseProviders = Resolve-RequiredFile -PathValue $BaseProvidersFile -Label "Base providers file"
$resolvedProviders = ""
if (-not [string]::IsNullOrWhiteSpace($ProvidersFile)) {
    $resolvedProviders = Resolve-RequiredFile -PathValue $ProvidersFile -Label "Local providers file"
}
$resolvedInput = ""
if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $resolvedInput = Resolve-RequiredFile -PathValue $InputPath -Label "E2E input"
}
if (-not $PlanOnly -and -not $PrepareOnly -and -not $LaunchCheck -and [string]::IsNullOrWhiteSpace($resolvedInput)) {
    throw "InputPath is required for a full APP E2E run. Use -LaunchCheck or -PrepareOnly for a partial check."
}
if (-not $PlanOnly -and -not $PrepareOnly) {
    $running = @(
        Get-Process -Name "TransVortex", "transvortex_desktop_flutter" -ErrorAction SilentlyContinue
    )
    if ($running.Count -gt 0) {
        $ids = ($running | ForEach-Object { $_.Id }) -join ", "
        throw "Close the running TransVortex window before APP E2E. Process ids: $ids"
    }
}

$resolvedE2ESessionRoot = [System.IO.Path]::GetFullPath($E2EHome)
$isolatedLocalAppData = Join-Path $resolvedE2ESessionRoot "LocalAppData"
$isolatedAppDataRoot = Join-Path $isolatedLocalAppData "TransVortex"
if (-not $PlanOnly) {
    Initialize-E2ESessionRoot -Path $resolvedE2ESessionRoot
}

$helperArgs = @(
    "-m", $helperModule,
    "--e2e-home", $isolatedAppDataRoot,
    "--python-executable", $resolvedPython,
    "--model-id", $ModelId,
    "--device", $Device,
    "--compute-type", $ComputeType,
    "--pipeline-template", $resolvedPipelineTemplate,
    "--base-providers-file", $resolvedBaseProviders,
    "--asr-engine", $AsrProvider,
    "--probe-timeout-seconds", [string]$ProbeTimeoutSeconds
)
if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
    $helperArgs += @("--model-path", ([System.IO.Path]::GetFullPath($ModelPath)))
}
if (-not [string]::IsNullOrWhiteSpace($resolvedProviders)) {
    $helperArgs += @("--providers-file", $resolvedProviders)
}
if ($Force) {
    $helperArgs += "--force"
}
if ($PlanOnly) {
    $helperArgs += "--plan-only"
}

$previousPythonPath = $env:PYTHONPATH
$workspacePythonPath = Join-Path $repoRoot "src"
$previousErrorActionPreference = $ErrorActionPreference
try {
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
        $workspacePythonPath
    } else {
        "$workspacePythonPath;$previousPythonPath"
    }
    # Windows PowerShell turns native stderr into ErrorRecord objects when the
    # global preference is Stop. Capture the helper's structured failure first.
    $ErrorActionPreference = "Continue"
    $rawPreparation = & $resolvedPython @helperArgs 2>&1
    $prepareExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($null -eq $previousPythonPath) {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONPATH = $previousPythonPath
    }
}
$preparationText = ($rawPreparation | Out-String).Trim()
if ($prepareExitCode -ne 0) {
    throw "Could not prepare the APP E2E environment.`n$preparationText"
}
try {
    $preparation = $preparationText | ConvertFrom-Json
} catch {
    throw "APP E2E preparation did not return JSON.`n$preparationText"
}

if ($PlanOnly) {
    $plan = [ordered]@{
        ok = $true
        plan_only = $true
        preparation = $preparation
        e2e_session_root = $resolvedE2ESessionRoot
        isolated_local_app_data = $isolatedLocalAppData
        build_release = -not [bool]$SkipBuild
        exe_path = [System.IO.Path]::GetFullPath($ExePath)
        input_path = $resolvedInput
        launch_check = [bool]$LaunchCheck
        manual_acceptance = -not [bool]$PrepareOnly
    }
    Write-Result -Value $plan
    exit 0
}

if ($PrepareOnly) {
    Write-Result -Value $preparation
    exit 0
}

if (-not $SkipBuild) {
    Push-Location $desktopRoot
    try {
        & flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter Windows release build failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}
$resolvedExe = Resolve-RequiredFile -PathValue $ExePath -Label "Flutter Release executable"
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $resolvedE2ESessionRoot "Acceptance"
}
$resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)

Write-Host "APP E2E environment prepared: $($preparation.e2e_home)"
Write-Host "Whisper worker runtime: external · $($preparation.runtime.python_executable)"
Write-Host "Whisper model: $($preparation.model.id) · $($preparation.model.device) · $($preparation.model.compute_type)"
Write-Host "Do not save the local Whisper settings during this E2E run; the product editor intentionally restores the managed runtime policy."

$previousHome = $env:TRANSVORTEX_HOME
$previousLocalAppData = $env:LOCALAPPDATA
$previousPath = $env:PATH
$pythonDirectory = Split-Path -Parent $resolvedPython
$acceptanceArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $manualAcceptanceScript,
    "-ExePath", $resolvedExe,
    "-OutputDir", $resolvedOutputDir
)
if (-not [string]::IsNullOrWhiteSpace($resolvedInput)) {
    $acceptanceArgs += @("-InputPath", $resolvedInput)
}
if ($LaunchCheck) {
    $acceptanceArgs += "-LaunchCheck"
}
if ($NoScreenshots) {
    $acceptanceArgs += "-NoScreenshots"
}
$windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source

try {
    # Isolate APP data through LOCALAPPDATA so the credential resolver can keep
    # using the normal user-level ~/.transvortex/auth.json.
    Remove-Item Env:TRANSVORTEX_HOME -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $isolatedLocalAppData
    $env:PATH = "$pythonDirectory;$previousPath"
    & $windowsPowerShell @acceptanceArgs | Out-Host
    $acceptanceExitCode = $LASTEXITCODE
} finally {
    if ($null -eq $previousHome) {
        Remove-Item Env:TRANSVORTEX_HOME -ErrorAction SilentlyContinue
    } else {
        $env:TRANSVORTEX_HOME = $previousHome
    }
    if ($null -eq $previousLocalAppData) {
        Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
    } else {
        $env:LOCALAPPDATA = $previousLocalAppData
    }
    $env:PATH = $previousPath
}

if ($acceptanceExitCode -ne 0) {
    exit $acceptanceExitCode
}

$manualReportPath = Join-Path $resolvedOutputDir "manual_release_acceptance.json"
if (-not (Test-Path -LiteralPath $manualReportPath -PathType Leaf)) {
    throw "Manual APP acceptance report was not created: $manualReportPath"
}

if ($LaunchCheck) {
    $manualReport = Get-Content -LiteralPath $manualReportPath -Raw -Encoding utf8 | ConvertFrom-Json
    $sessionReportPath = Join-Path $resolvedE2ESessionRoot "app_e2e_session.json"
    $launchReport = [ordered]@{
        ok = [bool]$manualReport.ok
        schema_version = 1
        purpose = "flutter_app_e2e_session"
        scope = "visible_release_launch_check_only"
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
        session_root = $resolvedE2ESessionRoot
        preparation = $preparation
        manual_acceptance = [ordered]@{
            report_path = $manualReportPath
            launch_visible_ok = [bool]$manualReport.launch_visible_ok
        }
        validated = @("visible_flutter_release_launch")
        not_covered = @(
            "real_media_task",
            "external_worker_task_execution",
            "managed_component_download",
            "installer_path",
            "clean_windows_machine"
        )
        report_path = $sessionReportPath
    }
    Write-JsonFileUtf8NoBom -Path $sessionReportPath -Value $launchReport
    Write-Result -Value $launchReport
    exit 0
}

$sessionReportPath = Join-Path $resolvedE2ESessionRoot "app_e2e_session.json"
$verificationArgs = @(
    "-m", $helperModule,
    "--verify-session",
    "--e2e-home", $isolatedAppDataRoot,
    "--session-root", $resolvedE2ESessionRoot,
    "--manual-report", $manualReportPath,
    "--expected-input", $resolvedInput,
    "--exe-path", $resolvedExe,
    "--repo-root", $repoRoot,
    "--session-report", $sessionReportPath,
    "--asr-engine", $AsrProvider
)

$previousPythonPath = $env:PYTHONPATH
$previousErrorActionPreference = $ErrorActionPreference
try {
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
        $workspacePythonPath
    } else {
        "$workspacePythonPath;$previousPythonPath"
    }
    $ErrorActionPreference = "Continue"
    $rawVerification = & $resolvedPython @verificationArgs 2>&1
    $verificationExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($null -eq $previousPythonPath) {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONPATH = $previousPythonPath
    }
}
$verificationText = ($rawVerification | Out-String).Trim()
if ($verificationExitCode -ne 0) {
    throw "Manual APP steps passed, but task evidence verification failed.`n$verificationText"
}
try {
    $verification = $verificationText | ConvertFrom-Json
} catch {
    throw "APP E2E verification did not return JSON.`n$verificationText"
}
Write-Result -Value $verification
