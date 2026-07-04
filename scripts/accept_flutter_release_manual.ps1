param(
    [string]$ExePath = "",
    [string]$InputPath = "",
    [string]$OutputDir = "",
    [int]$StartupTimeoutSeconds = 20,
    [int]$LaunchCheckSeconds = 3,
    [switch]$PlanOnly,
    [switch]$LaunchCheck,
    [switch]$NoScreenshots,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Add-ManualCaptureType {
    if ([System.Management.Automation.PSTypeName]'TransVortexManualCapture'.Type) {
        return
    }

    Add-Type -AssemblyName System.Drawing
    $source = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class TransVortexManualCapture {
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);

    public static void CaptureWindow(IntPtr hwnd, string path) {
        if (hwnd == IntPtr.Zero) {
            throw new InvalidOperationException("Window handle is not available.");
        }
        Rect rect;
        if (!GetWindowRect(hwnd, out rect)) {
            throw new InvalidOperationException("Could not read window rectangle.");
        }
        int width = Math.Max(1, rect.Right - rect.Left);
        int height = Math.Max(1, rect.Bottom - rect.Top);
        using (Bitmap bitmap = new Bitmap(width, height)) {
            using (Graphics graphics = Graphics.FromImage(bitmap)) {
                graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height));
            }
            bitmap.Save(path, ImageFormat.Png);
        }
    }
}
"@

    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies "System.Drawing.dll"
}

function Wait-ManualWindow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "TransVortex release process exited before a visible window was available. ExitCode=$($Process.ExitCode)"
        }
        if ($Process.MainWindowHandle -ne 0) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out waiting for TransVortex release window."
}

function Save-ManualScreenshot {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Process.Refresh()
    [TransVortexManualCapture]::CaptureWindow($Process.MainWindowHandle, $Path)
}

function Read-ManualStep {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Step,
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [int]$Total,
        [Parameter(Mandatory = $true)]
        [string]$ScreenshotDir,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [bool]$CaptureScreenshots
    )

    Write-Host ""
    Write-Host "[$Index/$Total] $($Step.title)"
    Write-Host $Step.instruction
    $answer = Read-Host "Enter y when done; otherwise enter failure notes"
    $confirmed = $answer -match '^(y|yes|ok|done)$'
    $screenshotPath = ""
    $screenshotError = ""
    if ($CaptureScreenshots) {
        $screenshotPath = Join-Path $ScreenshotDir ("{0:00}_{1}.png" -f $Index, $Step.id)
        try {
            Save-ManualScreenshot -Process $Process -Path $screenshotPath
        } catch {
            $screenshotError = $_.Exception.Message
            $screenshotPath = ""
        }
    }

    return [ordered]@{
        id = $Step.id
        title = $Step.title
        required = [bool]$Step.required
        confirmed = $confirmed
        notes = $(if ($confirmed) { "" } else { $answer })
        screenshot_path = $screenshotPath
        screenshot_error = $screenshotError
    }
}

$repoRootPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $releaseDir = Join-Path $repoRootPath "desktop_flutter\build\windows\x64\runner\Release"
    $newExePath = Join-Path $releaseDir "TransVortex.exe"
    $legacyExePath = Join-Path $releaseDir "transvortex_desktop_flutter.exe"
    $ExePath = if (Test-Path -LiteralPath $newExePath) { $newExePath } else { $legacyExePath }
}
$resolvedExe = Resolve-Path -LiteralPath $ExePath
$exeDirectory = [System.IO.Path]::GetDirectoryName($resolvedExe.Path)
if ([string]::IsNullOrWhiteSpace($exeDirectory)) {
    throw "Could not determine executable directory for $($resolvedExe.Path)"
}
$resolvedInputPath = ""
if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("transvortex_manual_acceptance_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$screenshotDir = Join-Path $resolvedOutputDir "screenshots"
if (-not $NoScreenshots) {
    New-Item -ItemType Directory -Force -Path $screenshotDir | Out-Null
}

$sourceInstruction = "In the visible app, click the source picker or drag in a real video/subtitle file."
if ($resolvedInputPath) {
    $sourceInstruction = "In the visible app, click the source picker or drag in this file: $resolvedInputPath"
}

$steps = @(
    @{
        id = "visible_release_window"
        title = "Visible release window"
        instruction = "Confirm this is the TransVortex.exe Release window from build\\windows\\x64\\runner\\Release, not Flutter debug, HTML mock, or a smoke-only screenshot."
        required = $true
    },
    @{
        id = "source_selected"
        title = "Manual source selection"
        instruction = $sourceInstruction
        required = $true
    },
    @{
        id = "task_started"
        title = "Manual start action"
        instruction = "Check the job summary, click the primary start action, and confirm the window enters the running state."
        required = $true
    },
    @{
        id = "running_observed"
        title = "Real running state observed"
        instruction = "Wait until the window shows real task progress, task state, or event changes. This must not be a static completed screenshot."
        required = $true
    },
    @{
        id = "task_completed"
        title = "Task completed"
        instruction = "Wait for the task to complete and confirm the window reaches the completed state with result actions visible. A failed task means this strict end-to-end acceptance does not pass."
        required = $true
    },
    @{
        id = "result_opened"
        title = "Result opened"
        instruction = "From the completed state, open the subtitle, task directory, or result directory, and confirm the OS opens the expected result location."
        required = $true
    },
    @{
        id = "result_reviewed"
        title = "Result review opened"
        instruction = "Open the result review window, confirm subtitle segments and output/problem information are visible, then return to the main flow."
        required = $true
    }
)

$reportPath = Join-Path $resolvedOutputDir "manual_release_acceptance.json"
$report = [ordered]@{
    ok = $false
    plan_only = [bool]$PlanOnly
    launch_check = [bool]$LaunchCheck
    launch_visible_ok = $false
    launch_screenshot_path = ""
    launch_screenshot_error = ""
    manual_visible_e2e_ok = $false
    frontend_design_mvp_complete = $false
    completion_claim = "Manual visible release evidence only; combine with current automated smoke, external-service, notification, AppUserModelID, and formal installer evidence before claiming the frontend design MVP is complete."
    acceptance_scope = "real visible release window manual end-to-end run"
    exe_path = $resolvedExe.Path
    input_path = $resolvedInputPath
    working_directory = $exeDirectory
    output_dir = $resolvedOutputDir
    report_path = $reportPath
    started_at = (Get-Date).ToString("o")
    ended_at = ""
    process_id = $null
    steps = @()
    missing_required_steps = @()
}

if ($PlanOnly) {
    $report.steps = $steps | ForEach-Object {
        [ordered]@{
            id = $_.id
            title = $_.title
            required = [bool]$_.required
            instruction = $_.instruction
        }
    }
    $report.ended_at = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
    if ($Json) {
        $report | ConvertTo-Json -Depth 8
    } else {
        [pscustomobject]$report
    }
    return
}

$process = $null
try {
    if (-not $NoScreenshots) {
        Add-ManualCaptureType
    }

    $process = Start-Process -FilePath $resolvedExe.Path -WorkingDirectory $exeDirectory -PassThru -WindowStyle Normal
    $report.process_id = $process.Id
    [void](Wait-ManualWindow -Process $process -TimeoutSeconds $StartupTimeoutSeconds)

    if ($LaunchCheck) {
        Start-Sleep -Seconds ([Math]::Max(0, $LaunchCheckSeconds))
        $report.launch_visible_ok = $true
        if (-not $NoScreenshots) {
            $launchScreenshotPath = Join-Path $screenshotDir "00_launch_check.png"
            try {
                Save-ManualScreenshot -Process $process -Path $launchScreenshotPath
                $report.launch_screenshot_path = $launchScreenshotPath
            } catch {
                $report.launch_screenshot_error = $_.Exception.Message
            }
        }
        $report.ok = $true
        $report.ended_at = (Get-Date).ToString("o")
        $report.completion_claim = "Launch check only; this does not prove the manual visible end-to-end acceptance."
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
        if (-not $process.HasExited) {
            $process.CloseMainWindow() | Out-Null
            if (-not $process.WaitForExit(5000)) {
                Stop-Process -Id $process.Id -Force
            }
        }
        $process = $null
        if ($Json) {
            $report | ConvertTo-Json -Depth 8
        } else {
            [pscustomobject]$report
        }
        return
    }

    $results = @()
    for ($index = 0; $index -lt $steps.Count; $index += 1) {
        $results += Read-ManualStep `
            -Step $steps[$index] `
            -Index ($index + 1) `
            -Total $steps.Count `
            -ScreenshotDir $screenshotDir `
            -Process $process `
            -CaptureScreenshots (-not [bool]$NoScreenshots)
    }

    $missing = @(
        $results | Where-Object { $_.required -and -not $_.confirmed } | ForEach-Object { $_.id }
    )
    $report.steps = $results
    $report.missing_required_steps = $missing
    $report.manual_visible_e2e_ok = $missing.Count -eq 0
    $report.ok = $report.manual_visible_e2e_ok
    $report.ended_at = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

    Write-Host ""
    Write-Host "Manual acceptance report: $reportPath"
    if ($report.ok) {
        Write-Host "Manual visible release end-to-end acceptance: PASS"
    } else {
        Write-Host "Manual visible release end-to-end acceptance: NOT PASSED"
    }

    if ($Json) {
        $report | ConvertTo-Json -Depth 8
    } else {
        [pscustomobject]$report
    }

    if (-not $report.ok) {
        exit 1
    }
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $close = Read-Host "Close the TransVortex release window? Enter y to close; anything else leaves it open"
        if ($close -match '^(y|yes|ok|close)$') {
            try {
                $process.CloseMainWindow() | Out-Null
                if (-not $process.WaitForExit(5000)) {
                    Stop-Process -Id $process.Id -Force
                }
            } catch {
                Write-Warning "Could not close TransVortex release window: $($_.Exception.Message)"
            }
        }
    }
}
