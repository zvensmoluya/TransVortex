param(
    [string]$ExePath = "",
    [int]$TimeoutSeconds = 60,
    [string]$ScreenshotPath = "",
    [string]$DesktopCompositePath = "",
    [ValidateSet("main", "translationSettings", "asrSettings", "diagnostics", "taskProcessing")]
    [string]$WindowType = "main",
    [ValidateSet("normal", "empty", "ready", "blockedTranslation", "blockedAsr", "running", "failed")]
    [string]$MainPhase = "normal",
    [ValidateSet("normal", "longModels")]
    [string]$TranslationScenario = "normal",
    [ValidateSet("browse", "edit", "failure", "resume", "cancel")]
    [string]$TaskProcessingScenario = "browse",
    [switch]$CheckNotifications,
    [switch]$CheckTray,
    [switch]$CheckAppIdentity,
    [switch]$CheckDesktopComposite,
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"

$script:manualAcceptanceRequired = @(
    "real visible release window end-to-end run; record with scripts/accept_flutter_release_manual.ps1",
    "AppUserModelID shortcut identity acceptance; rerun with -CheckAppIdentity",
    "native Windows installer acceptance"
)

function Remove-SmokeManualAcceptanceRequirement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Requirement
    )

    $script:manualAcceptanceRequired = @(
        $script:manualAcceptanceRequired | Where-Object { $_ -ne $Requirement }
    )
}

function Add-SmokeAcceptanceBoundary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )

    $Report | Add-Member -Force -NotePropertyName automated_scope -NotePropertyValue "single release smoke check for Local Service wiring, selected window rendering, release screenshot sampling when requested, native notification call/registry checks when enabled, tray close/restore lifecycle when enabled, and AppUserModelID shortcut identity checks when enabled"
    $Report | Add-Member -Force -NotePropertyName frontend_design_mvp_complete -NotePropertyValue $false
    $Report | Add-Member -Force -NotePropertyName completion_claim -NotePropertyValue "Automated release smoke passed; this is evidence for Flutter MVP wiring, not proof that the frontend design MVP is complete."
    $Report | Add-Member -Force -NotePropertyName manual_acceptance_required -NotePropertyValue $script:manualAcceptanceRequired
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$appIdentityScript = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "install_flutter_desktop_shortcut.ps1")
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $releaseDir = Join-Path $repoRoot "desktop_flutter\build\windows\x64\runner\Release"
    $newExePath = Join-Path $releaseDir "TransVortex.exe"
    $legacyExePath = Join-Path $releaseDir "transvortex_desktop_flutter.exe"
    $ExePath = if (Test-Path -LiteralPath $newExePath) { $newExePath } else { $legacyExePath }
}
$resolvedExe = Resolve-Path -LiteralPath $ExePath

if ($CheckTray -and $WindowType -ne "main") {
    throw "Tray lifecycle smoke is only supported for the main window."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("transvortex_release_smoke_" + [System.Guid]::NewGuid().ToString("N"))
$serviceRoot = Join-Path $tempRoot "service"
$fixtureRoot = Join-Path $tempRoot "fixture"
$reportPath = Join-Path $tempRoot "report.json"
New-Item -ItemType Directory -Force -Path $serviceRoot | Out-Null
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

$pipeline = @"
artifacts_dir: artifacts
asr:
  provider: __SMOKE_ASR_PROVIDER__
asr_providers:
  - name: local
    kind: local_inprocess
    protocol: faster_whisper
    model: large-v3
    local:
      device: cpu
      compute_type: int8
"@
$providerModels = @("demo-model")
if ($TranslationScenario -eq "longModels") {
    $providerModels = @(
        "gemini-3.5-flash",
        "gemini-3.1-pro-preview",
        "gemini-3.1-flash-lite-preview",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash-lite-preview-02-05",
        "claude-4-sonnet-preview-20260514",
        "deepseek-v4-flash",
        "qwen3-235b-a22b-instruct-2507"
    )
}
$providerModelsYaml = ($providerModels | ForEach-Object { "      - $_" }) -join "`n"
$primaryModel = $providerModels[0]

$providers = @"
providers:
  - name: DemoTranslator
    api_type: openai-compatible
    compat_mode: openai_chat
    base_url: __SMOKE_PROVIDER_BASE_URL__
    env_key: SMOKE_PROVIDER_KEY
    models:
__SMOKE_PROVIDER_MODELS__
    limits:
      streaming_enabled: false
      retry: 1
      timeout_seconds: 10
routing:
  primary: {provider: DemoTranslator, model: __SMOKE_PRIMARY_MODEL__}
"@

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$smokeAsrProvider = if ($MainPhase -eq "blockedAsr") { "missing_local" } else { "local" }
$pipeline = $pipeline.Replace("__SMOKE_ASR_PROVIDER__", $smokeAsrProvider)
[System.IO.File]::WriteAllText((Join-Path $serviceRoot "pipeline.yaml"), $pipeline, $utf8NoBom)
if ($MainPhase -ne "blockedTranslation") {
    [System.IO.File]::WriteAllText((Join-Path $serviceRoot ".env"), "SMOKE_PROVIDER_KEY=example-token`n", $utf8NoBom)
}

function Start-SmokeProviderServer {
    $scriptPath = Join-Path $tempRoot "smoke_provider.py"
    $readyPath = Join-Path $tempRoot "smoke_provider_ready.json"
    $serverScript = @'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ready_path = Path(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/models":
            self._send({"object": "list", "data": [{"id": "demo-model", "object": "model"}]})
        else:
            self._send({"error": "not found"}, status=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length:
            self.rfile.read(length)
        if self.path == "/v1/chat/completions":
            self._send({
                "choices": [
                    {"message": {"content": "[1] The opening line is ready for review."}}
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
        else:
            self._send({"error": "not found"}, status=404)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
ready_path.write_text(json.dumps({"port": server.server_address[1]}), encoding="utf-8")
server.serve_forever()
'@
    [System.IO.File]::WriteAllText($scriptPath, $serverScript, $utf8NoBom)
    $process = Start-Process -FilePath "python" -ArgumentList @($scriptPath, $readyPath) -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $readyPath) {
            $ready = Get-Content -LiteralPath $readyPath -Raw -Encoding utf8 | ConvertFrom-Json
            return [pscustomobject]@{
                Process = $process
                BaseUrl = "http://127.0.0.1:$($ready.port)/v1"
            }
        }
        if ($process.HasExited) {
            throw "Smoke provider server exited before ready. ExitCode=$($process.ExitCode)"
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    throw "Timed out waiting for local smoke provider server."
}

$smokeProvider = Start-SmokeProviderServer
$providers = $providers.Replace("__SMOKE_PROVIDER_BASE_URL__", $smokeProvider.BaseUrl)
$providers = $providers.Replace("__SMOKE_PROVIDER_MODELS__", $providerModelsYaml)
$providers = $providers.Replace("__SMOKE_PRIMARY_MODEL__", $primaryModel)
if ($MainPhase -eq "blockedTranslation") {
    $providers = $providers.Replace("env_key: SMOKE_PROVIDER_KEY", "env_key: SMOKE_PROVIDER_KEY_MISSING")
}
[System.IO.File]::WriteAllText((Join-Path $serviceRoot "providers.yaml"), $providers, $utf8NoBom)

function Write-SmokeTaskFixture {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Status,
        [hashtable]$OutputPaths = @{},
        [string]$ErrorMessage = "",
        [string]$ErrorCode = "",
        [string]$ErrorHint = "",
        [string]$ErrorStage = "",
        [string]$ErrorRetryable = "",
        [hashtable]$Checkpoint = @{}
    )

    $taskDir = Join-Path (Join-Path $serviceRoot "artifacts") $TaskId
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    $taskPayload = [pscustomobject]@{
        task_id = $TaskId
        input_file = $InputFile
        source_lang = "en"
        target_lang = "zh-CN"
        bilingual = $true
        status = $Status
        created_at = "2026-01-01T00:00:00Z"
        updated_at = "2026-01-01T00:00:02Z"
        output_paths = $OutputPaths
        settings = [pscustomobject]@{
            memory = [pscustomobject]@{
                enabled = $false
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $errorInfo = [ordered]@{
            code = $ErrorCode
            hint_zh = $ErrorHint
        }
        if (-not [string]::IsNullOrWhiteSpace($ErrorStage)) {
            $errorInfo.stage = $ErrorStage
        }
        if (-not [string]::IsNullOrWhiteSpace($ErrorRetryable)) {
            $errorInfo.retryable = $ErrorRetryable -eq "true"
        }
        $taskPayload | Add-Member -NotePropertyName error -NotePropertyValue $ErrorMessage
        $taskPayload | Add-Member -NotePropertyName error_info -NotePropertyValue ([pscustomobject]$errorInfo)
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $taskDir "task.json"),
        ($taskPayload | ConvertTo-Json -Depth 8),
        $utf8NoBom
    )
    if ($Checkpoint.Count -gt 0) {
        [System.IO.File]::WriteAllText(
            (Join-Path $taskDir "checkpoint.json"),
            ($Checkpoint | ConvertTo-Json -Depth 8),
            $utf8NoBom
        )
    }
    return $taskDir
}

function Write-SmokeTaskEvent {
    param(
        [Parameter(Mandatory = $true)][string]$TaskDir,
        [Parameter(Mandatory = $true)][string]$Type,
        [string]$Stage = "",
        [string]$Message = "",
        [double]$Progress = -1
    )
    $event = [ordered]@{
        type = $Type
        task_id = Split-Path -Leaf $TaskDir
        created_at = "2026-01-01T00:00:01Z"
    }
    if (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $event.stage = $Stage
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $event.message = $Message
    }
    if ($Progress -ge 0) {
        $event.progress = $Progress
    }
    $line = ($event | ConvertTo-Json -Compress -Depth 6)
    [System.IO.File]::AppendAllText((Join-Path $TaskDir "events.jsonl"), "$line`n", $utf8NoBom)
}

function Write-SmokeTaskRuntimeActive {
    param(
        [Parameter(Mandatory = $true)][string]$TaskDir
    )

    $taskId = Split-Path -Leaf $TaskDir
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $workerPayload = [ordered]@{
        task_id = $taskId
        pid = $PID
        owner = "release_smoke"
        command = "smoke"
        state = "running"
        started_at = $now
        last_seen = $now
        ended_at = ""
        exit_code = $null
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $TaskDir "worker.json"),
        ($workerPayload | ConvertTo-Json -Depth 6),
        $utf8NoBom
    )

    $runtimeDir = Join-Path (Join-Path $serviceRoot "artifacts") ".runtime"
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $activePayload = [ordered]@{
        task_id = $taskId
        pid = $PID
        owner = "release_smoke"
        command = "smoke"
        state = "running"
        started_at = $now
        last_seen = $now
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $runtimeDir "active.json"),
        ($activePayload | ConvertTo-Json -Depth 6),
        $utf8NoBom
    )
}

$smokeContextTaskId = "tvx_demo_context_task"

if ($WindowType -eq "diagnostics" -or $WindowType -eq "taskProcessing") {
    $smokeTaskId = $smokeContextTaskId
    $contextFileName = switch ($WindowType) {
        "taskProcessing" { "sample-task-processing-session.mp4" }
        default { "sample-diagnostics-context.mp4" }
    }
    $taskOutputPaths = @{}
    if ($WindowType -eq "taskProcessing") {
        $taskOutputPaths = @{srt = (Join-Path $fixtureRoot "result-review.zh-CN.srt")}
    } elseif ($WindowType -eq "diagnostics") {
        $diagnosticOutputPath = Join-Path $fixtureRoot "diagnostics-context.zh-CN.srt"
        [System.IO.File]::WriteAllText($diagnosticOutputPath, "1`n00:00:00,000 --> 00:00:01,000`n诊断 smoke 字幕`n", $utf8NoBom)
        $taskOutputPaths = @{srt = $diagnosticOutputPath}
    }
    $isTaskProcessingFailure = $WindowType -eq "taskProcessing" -and $TaskProcessingScenario -in @("failure", "resume")
    $contextStatus = if ($isTaskProcessingFailure) {
        "FAILED"
    } elseif ($WindowType -eq "taskProcessing" -and $TaskProcessingScenario -eq "cancel") {
        "RUNNING"
    } else {
        "DONE"
    }
    $fixtureErrorMessage = ""
    $fixtureErrorCode = ""
    $fixtureErrorHint = ""
    $fixtureErrorStage = ""
    $fixtureErrorRetryable = ""
    if ($isTaskProcessingFailure) {
        $fixtureErrorMessage = "Smoke detail resumable failure"
        $fixtureErrorCode = "smoke_detail_resumable"
        $fixtureErrorHint = -join @(
            [char]0x53EF,
            [char]0x4EE5,
            [char]0x7EE7,
            [char]0x7EED,
            [char]0x4EFB,
            [char]0x52A1,
            [char]0x3002
        )
        $fixtureErrorStage = "TRANSLATE"
        $fixtureErrorRetryable = "true"
    }
    $contextFixtureArgs = @{
        TaskId = $smokeTaskId
        InputFile = Join-Path $fixtureRoot $contextFileName
        Status = $contextStatus
        OutputPaths = $taskOutputPaths
        ErrorMessage = $fixtureErrorMessage
        ErrorCode = $fixtureErrorCode
        ErrorHint = $fixtureErrorHint
        ErrorStage = $fixtureErrorStage
        ErrorRetryable = $fixtureErrorRetryable
    }
    if ($WindowType -eq "taskProcessing") {
        $checkpointStatus = if ($isTaskProcessingFailure) {
            "TRANSLATE"
        } elseif ($TaskProcessingScenario -eq "cancel") {
            "TRANSLATE"
        } else {
            "DONE"
        }
        $contextFixtureArgs.Checkpoint = @{
            status = $checkpointStatus
            asr_done_count = 61
            asr_total_segments = 61
            translate_done_count = $(if ($checkpointStatus -eq "DONE") { 8 } else { 4 })
            translate_total_chunks = 8
            model_request_count = 14
            model_request_counts = @{
                translate = 8
                memory_bootstrap_extract = 1
                memory_bootstrap_classify = 1
                memory_patch = 3
                batch_recovery = 1
            }
        }
    }
    $taskDir = Write-SmokeTaskFixture @contextFixtureArgs
    Write-SmokeTaskEvent -TaskDir $taskDir -Type "task_created" -Stage "QUEUED" -Message "Task created"
    if ($isTaskProcessingFailure) {
        Write-SmokeTaskEvent -TaskDir $taskDir -Type "error" -Stage "FAILED" -Message "Smoke detail resumable failure"
    } elseif ($WindowType -eq "taskProcessing" -and $TaskProcessingScenario -eq "cancel") {
        Write-SmokeTaskEvent -TaskDir $taskDir -Type "stage" -Stage "RUNNING" -Message "Task running" -Progress 0.4
        Write-SmokeTaskRuntimeActive -TaskDir $taskDir
    } else {
        Write-SmokeTaskEvent -TaskDir $taskDir -Type "done" -Stage "DONE" -Message "Task done" -Progress 1.0
    }
    if ($WindowType -eq "taskProcessing") {
        New-Item -ItemType Directory -Force -Path (Join-Path $taskDir "final") | Out-Null
        $reviewSourceOne = "The train leaves in ten minutes."
        $reviewTargetOne = "$([char]0x5217)$([char]0x8F66)$([char]0x5341)$([char]0x5206)$([char]0x949F)$([char]0x540E)$([char]0x51FA)$([char]0x53D1)$([char]0x3002)"
        $reviewSourceTwo = "Please check the platform number."
        $segments = @(
            [ordered]@{
                id = 1
                start = 0.0
                end = 1.5
                text_src = $reviewSourceOne
                text_tgt = $reviewTargetOne
                meta = @{}
            },
            [ordered]@{
                id = 2
                start = 1.6
                end = 3.0
                text_src = $reviewSourceTwo
                text_tgt = ""
                meta = @{}
            }
        )
        [System.IO.File]::WriteAllText(
            (Join-Path (Join-Path $taskDir "final") "segments.final.json"),
            ($segments | ConvertTo-Json -Depth 8),
            $utf8NoBom
        )
    }
}

function Add-WindowCaptureTypes {
    if ("TransVortexWindowCapture" -as [type]) {
        return
    }
    $referencedAssemblies = @("System.Drawing")
    foreach ($assemblyName in @(
        "System.Drawing.Common.dll",
        "System.Drawing.Primitives.dll",
        "System.Threading.Thread.dll",
        "System.Private.Windows.Core.dll"
    )) {
        $assemblyPath = Join-Path $PSHOME $assemblyName
        if (Test-Path -LiteralPath $assemblyPath) {
            $referencedAssemblies += $assemblyPath
        }
    }
    $captureCode = @(
        'using System;',
        'using System.Drawing;',
        'using System.Threading;',
        '',
        'public static class TransVortexWindowCapture',
        '{',
        '    public struct Rect',
        '    {',
        '        public int Left;',
        '        public int Top;',
        '        public int Right;',
        '        public int Bottom;',
        '    }',
        '',
        '    [System.Runtime.InteropServices.DllImport("user32.dll")]',
        '    public static extern bool SetProcessDPIAware();',
        '',
        '    [System.Runtime.InteropServices.DllImport("user32.dll")]',
        '    public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);',
        '',
        '    [System.Runtime.InteropServices.DllImport("user32.dll")]',
        '    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);',
        '',
        '    [System.Runtime.InteropServices.DllImport("user32.dll")]',
        '    public static extern bool SetForegroundWindow(IntPtr hWnd);',
        '',
        '    [System.Runtime.InteropServices.DllImport("user32.dll")]',
        '    public static extern bool BringWindowToTop(IntPtr hWnd);',
        '',
        '    [System.Runtime.InteropServices.DllImport("user32.dll")]',
        '    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);',
        '',
        '    public static void ActivateWindow(IntPtr handle)',
        '    {',
        '        if (handle == IntPtr.Zero)',
        '        {',
        '            throw new InvalidOperationException("Release process has no main window handle.");',
        '        }',
        '        const int SW_RESTORE = 9;',
        '        const uint SWP_NOSIZE = 0x0001;',
        '        const uint SWP_NOMOVE = 0x0002;',
        '        const uint SWP_SHOWWINDOW = 0x0040;',
        '        IntPtr HWND_TOPMOST = new IntPtr(-1);',
        '        ShowWindow(handle, SW_RESTORE);',
        '        BringWindowToTop(handle);',
        '        SetWindowPos(handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);',
        '        SetForegroundWindow(handle);',
        '    }',
        '',
        '    public static int[] WindowRect(IntPtr handle)',
        '    {',
        '        SetProcessDPIAware();',
        '        Rect rect;',
        '        if (!GetWindowRect(handle, out rect))',
        '        {',
        '            throw new InvalidOperationException("Could not read release window bounds.");',
        '        }',
        '        return new int[] { rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top };',
        '    }',
        '',
        '    public static int[] ImageStats(string path)',
        '    {',
        '        using (Bitmap bitmap = new Bitmap(path))',
        '        {',
        '            int width = bitmap.Width;',
        '            int height = bitmap.Height;',
        '            int xStep = Math.Max(1, width / 96);',
        '            int yStep = Math.Max(1, height / 72);',
        '            int samples = 0;',
        '            int nonBackground = 0;',
        '            int dark = 0;',
        '            int bright = 0;',
        '            int pink = 0;',
        '            int flutterOverflowStripe = 0;',
        '            Color previous = Color.Empty;',
        '            bool hasPrevious = false;',
        '            for (int y = 0; y < height; y += yStep)',
        '            {',
        '                for (int x = 0; x < width; x += xStep)',
        '                {',
        '                    Color pixel = bitmap.GetPixel(x, y);',
        '                    samples++;',
        '                    int deltaFromBackground =',
        '                        Math.Abs(pixel.R - 255) +',
        '                        Math.Abs(pixel.G - 247) +',
        '                        Math.Abs(pixel.B - 241);',
        '                    if (deltaFromBackground > 22)',
        '                    {',
        '                        nonBackground++;',
        '                    }',
        '                    if (pixel.R < 95 && pixel.G < 95 && pixel.B < 105)',
        '                    {',
        '                        dark++;',
        '                    }',
        '                    if (pixel.R > 225 && pixel.G > 215 && pixel.B > 205)',
        '                    {',
        '                        bright++;',
        '                    }',
        '                    if (pixel.R > 210 && pixel.G < 150 && pixel.B > 160)',
        '                    {',
        '                        pink++;',
        '                    }',
        '                    bool isOverflowYellow = pixel.R > 210 && pixel.G > 190 && pixel.B < 70;',
        '                    bool isOverflowBlack = pixel.R < 45 && pixel.G < 45 && pixel.B < 45;',
        '                    if (hasPrevious)',
        '                    {',
        '                        bool previousYellow = previous.R > 210 && previous.G > 190 && previous.B < 70;',
        '                        bool previousBlack = previous.R < 45 && previous.G < 45 && previous.B < 45;',
        '                        if ((isOverflowYellow && previousBlack) || (isOverflowBlack && previousYellow))',
        '                        {',
        '                            flutterOverflowStripe++;',
        '                        }',
        '                    }',
        '                    previous = pixel;',
        '                    hasPrevious = true;',
        '                }',
        '                hasPrevious = false;',
        '            }',
        '            return new int[] { width, height, samples, nonBackground, dark, bright, pink, flutterOverflowStripe };',
        '        }',
        '    }',
        '}'
    ) -join "`n"
    Add-Type -ReferencedAssemblies $referencedAssemblies -TypeDefinition $captureCode
}

function Capture-DesktopCompositeScreenshot {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WindowType = ""
    )
    Add-WindowCaptureTypes
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($null -eq $ffmpeg) {
        return [pscustomobject]@{
            ok = $false
            source = "windows_desktop_duplication"
            path = $Path
            error = "ffmpeg is not available"
        }
    }
    $screenshotFile = [System.IO.FileInfo]::new($Path)
    if ($null -ne $screenshotFile.Directory -and -not $screenshotFile.Directory.Exists) {
        $screenshotFile.Directory.Create()
    }
    $Process.Refresh()
    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) {
        return [pscustomobject]@{
            ok = $false
            source = "windows_desktop_duplication"
            path = $screenshotFile.FullName
            error = "release process has no main window handle"
        }
    }
    [TransVortexWindowCapture]::ActivateWindow($Process.MainWindowHandle)
    Start-Sleep -Milliseconds 500
    $Process.Refresh()
    $rect = [TransVortexWindowCapture]::WindowRect($Process.MainWindowHandle)
    $input = "ddagrab=output_idx=0:framerate=1:offset_x=$($rect[0]):offset_y=$($rect[1]):video_size=$($rect[2])x$($rect[3])"
    & $ffmpeg.Source @(
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "lavfi",
        "-i", $input,
        "-vf", "hwdownload,format=bgra",
        "-frames:v", "1",
        $screenshotFile.FullName
    )
    if ($LASTEXITCODE -ne 0 -or -not $screenshotFile.Exists) {
        return [pscustomobject]@{
            ok = $false
            source = "windows_desktop_duplication"
            path = $screenshotFile.FullName
            x = $rect[0]
            y = $rect[1]
            width = $rect[2]
            height = $rect[3]
            error = "ffmpeg ddagrab failed"
        }
    }
    $stats = [TransVortexWindowCapture]::ImageStats($screenshotFile.FullName)
    $minNonBackgroundSamples = if ($WindowType -eq "taskProcessing") { 120 } else { 240 }
    $looksBlank = $stats[3] -lt $minNonBackgroundSamples
    $backgroundLikeSamples = $stats[2] - $stats[3]
    $minBackgroundLikeSamples = [Math]::Max(360, [int]($stats[2] * 0.12))
    $looksOccluded = $backgroundLikeSamples -lt $minBackgroundLikeSamples
    for ($attempt = 1; ($looksBlank -or $looksOccluded) -and $attempt -le 2; $attempt++) {
        [TransVortexWindowCapture]::ActivateWindow($Process.MainWindowHandle)
        Start-Sleep -Milliseconds (700 + (300 * $attempt))
        $Process.Refresh()
        if ($Process.MainWindowHandle -eq [IntPtr]::Zero) {
            break
        }
        $rect = [TransVortexWindowCapture]::WindowRect($Process.MainWindowHandle)
        $input = "ddagrab=output_idx=0:framerate=1:offset_x=$($rect[0]):offset_y=$($rect[1]):video_size=$($rect[2])x$($rect[3])"
        & $ffmpeg.Source @(
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", $input,
            "-vf", "hwdownload,format=bgra",
            "-frames:v", "1",
            $screenshotFile.FullName
        )
        if ($LASTEXITCODE -ne 0 -or -not $screenshotFile.Exists) {
            return [pscustomobject]@{
                ok = $false
                source = "windows_desktop_duplication"
                path = $screenshotFile.FullName
                x = $rect[0]
                y = $rect[1]
                width = $rect[2]
                height = $rect[3]
                error = "ffmpeg ddagrab failed"
            }
        }
        $stats = [TransVortexWindowCapture]::ImageStats($screenshotFile.FullName)
        $minNonBackgroundSamples = if ($WindowType -eq "taskProcessing") { 120 } else { 240 }
        $looksBlank = $stats[3] -lt $minNonBackgroundSamples
        $backgroundLikeSamples = $stats[2] - $stats[3]
        $minBackgroundLikeSamples = [Math]::Max(360, [int]($stats[2] * 0.12))
        $looksOccluded = $backgroundLikeSamples -lt $minBackgroundLikeSamples
    }
    $errorText = if ($looksBlank) {
        "desktop composite capture appears blank; Flutter render-tree screenshot remains authoritative for automated smoke in this environment"
    } elseif ($looksOccluded) {
        "desktop composite capture does not resemble the TransVortex light workspace; the release window may be occluded or not foregrounded"
    } else {
        ""
    }
    return [pscustomobject]@{
        ok = -not ($looksBlank -or $looksOccluded)
        source = "windows_desktop_duplication"
        path = $screenshotFile.FullName
        x = $rect[0]
        y = $rect[1]
        width = $stats[0]
        height = $stats[1]
        samples = $stats[2]
        non_background_samples = $stats[3]
        min_non_background_samples = $minNonBackgroundSamples
        background_like_samples = $backgroundLikeSamples
        min_background_like_samples = $minBackgroundLikeSamples
        dark_samples = $stats[4]
        bright_samples = $stats[5]
        pink_samples = $stats[6]
        flutter_overflow_stripe_samples = $stats[7]
        error = $errorText
    }
}

function Test-ReleaseRenderScreenshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WindowType
    )
    Add-WindowCaptureTypes
    $screenshotFile = [System.IO.FileInfo]::new($Path)
    if (-not $screenshotFile.Exists) {
        throw "Release render screenshot was not written: $($screenshotFile.FullName)"
    }
    $stats = [TransVortexWindowCapture]::ImageStats($screenshotFile.FullName)
    $minWidth = 650
    $minHeight = 460
    if ($WindowType -eq "translationSettings") {
        $minWidth = 780
        $minHeight = 560
    } elseif ($WindowType -eq "asrSettings" -or $WindowType -eq "diagnostics") {
        $minWidth = 720
        $minHeight = 520
    } elseif ($WindowType -eq "taskProcessing") {
        $minWidth = 900
        $minHeight = 640
    }
    if ($stats[0] -lt $minWidth -or $stats[1] -lt $minHeight) {
        throw "Release render screenshot is unexpectedly small: $($stats[0])x$($stats[1])"
    }
    if ($stats[7] -ge 24) {
        throw "Release render screenshot contains a Flutter overflow warning stripe: stripeSamples=$($stats[7]) samples=$($stats[2]) nonBackground=$($stats[3])"
    }
    if ($stats[3] -lt 120 -or $stats[4] -lt 12 -or $stats[5] -lt 120) {
        throw "Release render screenshot appears blank or incomplete: samples=$($stats[2]) nonBackground=$($stats[3]) dark=$($stats[4]) bright=$($stats[5]) pink=$($stats[6]) overflowStripe=$($stats[7])"
    }
    return [pscustomobject]@{
        path = $screenshotFile.FullName
        source = "flutter_render_tree"
        width = $stats[0]
        height = $stats[1]
        samples = $stats[2]
        non_background_samples = $stats[3]
        dark_samples = $stats[4]
        bright_samples = $stats[5]
        pink_samples = $stats[6]
        flutter_overflow_stripe_samples = $stats[7]
    }
}

$sourceText = "The opening line is ready."
$expectedText = "The opening line is ready for review."
$subtitlePath = Join-Path $fixtureRoot "sample-opening-line.en.srt"
$videoPath = Join-Path $fixtureRoot "sample-opening-line.mkv"
if ($WindowType -eq "main") {
    $subtitle = @(
        "1"
        "00:00:00,000 --> 00:00:00,800"
        $sourceText
        ""
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($subtitlePath, $subtitle, $utf8NoBom)

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($null -eq $ffmpeg -or $null -eq $ffprobe) {
        throw "ffmpeg and ffprobe are required for release task smoke."
    }
    & $ffmpeg.Source @(
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "lavfi",
        "-i", "color=c=black:s=160x90:d=1",
        "-f", "srt",
        "-i", $subtitlePath,
        "-map", "0:v:0",
        "-map", "1:s:0",
        "-c:v", "ffv1",
        "-c:s", "srt",
        "-metadata:s:s:0", "language=eng",
        $videoPath
    )
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $videoPath)) {
        throw "ffmpeg could not create release smoke fixture: $videoPath"
    }
}

try {
    $showWindow = -not [string]::IsNullOrWhiteSpace($ScreenshotPath) -or $CheckDesktopComposite -or $CheckTray
    $postReportSeconds = if ($CheckDesktopComposite) { 24 } elseif ($showWindow) { 6 } else { 0 }
    $appArgs = @()
    if ($WindowType -ne "main") {
        $appArgs += "--tvx-window-type=$WindowType"
    }
    if ($WindowType -eq "taskProcessing") {
        $appArgs += "--tvx-smoke-task-processing-scenario=$TaskProcessingScenario"
        if ($TaskProcessingScenario -eq "edit") {
            $appArgs += "--tvx-task-id=$smokeContextTaskId"
        }
    }
    $appArgs += @(
        "--tvx-smoke-report=$reportPath",
        "--tvx-service-root=$serviceRoot",
        "--tvx-smoke-main-phase=$MainPhase",
        "--tvx-smoke-min-visible-seconds=0",
        "--tvx-smoke-post-report-seconds=$postReportSeconds",
        "--tvx-smoke-timeout=$([Math]::Max(1, [Math]::Min($TimeoutSeconds, 120)))"
    )
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
        $appArgs += "--tvx-smoke-screenshot=$ScreenshotPath"
    }
    if ($CheckTray) {
        $appArgs += "--tvx-smoke-check-tray=true"
    }
    if ($WindowType -eq "main" -and $MainPhase -eq "normal") {
        $appArgs += @(
            "--tvx-smoke-input=$videoPath",
            "--tvx-smoke-expected-text=$expectedText",
            "--tvx-smoke-use-controller=true"
        )
        if ($CheckNotifications) {
            $appArgs += "--tvx-smoke-check-notifications=true"
        }
    }
    $windowStyle = if ($showWindow) { "Normal" } else { "Hidden" }
    $process = Start-Process -FilePath $resolvedExe -ArgumentList $appArgs -PassThru -WindowStyle $windowStyle
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 10)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $reportPath) {
            break
        }
        if ($process.HasExited -and -not (Test-Path -LiteralPath $reportPath)) {
            throw "Release smoke exited before writing report. ExitCode=$($process.ExitCode)"
        }
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Path -LiteralPath $reportPath)) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
        }
        throw "Timed out waiting for smoke report: $reportPath"
    }
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($report.ok -ne $true) {
        throw "Release smoke reported failure: $($report | ConvertTo-Json -Compress -Depth 5)"
    }
    if ($WindowType -eq "main") {
        if ($MainPhase -ne "normal") {
            $expectedControllerState = if ($MainPhase -eq "blockedTranslation" -or $MainPhase -eq "blockedAsr") { "blocked" } else { $MainPhase }
            if ($report.main_phase -ne $MainPhase -or $report.controller_state -ne $expectedControllerState) {
                throw "Release main phase smoke rendered the wrong state: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
        } else {
            if ($report.task_status -ne "DONE" -or $report.task_output_ok -ne $true -or $report.task_done_event -ne $true) {
                throw "Release smoke did not complete a real task: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
            if ($report.task_submission_path -eq "controller" -and ($report.controller_state -ne "completed" -or $report.result_open_ok -ne $true -or $report.result_open_same_directory -ne $true -or $report.reexport_ok -ne $true -or $report.reexport_event -ne $true -or $report.reexport_same_directory -ne $true)) {
                throw "Release smoke did not open and re-export completed task results: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
            if ($report.task_submission_path -eq "controller" -and ($report.task_model_request_count -lt 1 -or $report.task_model_request_counts.translate -lt 1)) {
                throw "Release smoke did not expose model request lifecycle counts through task status: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
        }
        if ($CheckNotifications) {
            if ($report.notification_check_ok -ne $true -or $report.notification_show_calls -ne 1 -or $report.notification_trigger_path -ne "observer_state_transition") {
                throw "Release smoke did not complete a native notification show call through the task observer: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
            $aumid = [string]$report.notification_app_user_model_id
            $guid = [string]$report.notification_activation_guid
            $appInfoKey = "HKCU:\Software\Classes\AppUserModelId\$aumid"
            $pushKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\$aumid"
            $settingsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$aumid"
            if (-not (Test-Path -LiteralPath $appInfoKey)) {
                throw "Notification AppUserModelId registry key was not created: $appInfoKey"
            }
            if (-not (Test-Path -LiteralPath $pushKey)) {
                throw "Notification PushNotifications registry key was not created: $pushKey"
            }
            if (-not (Test-Path -LiteralPath $settingsKey)) {
                throw "Notification settings registry key was not created: $settingsKey"
            }
            $appInfo = Get-ItemProperty -LiteralPath $appInfoKey
            $pushInfo = Get-ItemProperty -LiteralPath $pushKey
            $settingsInfo = Get-ItemProperty -LiteralPath $settingsKey
            if ($appInfo.DisplayName -ne "TransVortex" -or $appInfo.CustomActivator -ne "{$guid}") {
                throw "Notification AppUserModelId registry values are incomplete: display=$($appInfo.DisplayName) activator=$($appInfo.CustomActivator)"
            }
            if ($pushInfo.appType -ne "app:desktop" -or $pushInfo.wnsId -ne "NonImmersivePackage") {
                throw "Notification PushNotifications registry values are incomplete: appType=$($pushInfo.appType) wnsId=$($pushInfo.wnsId)"
            }
            $report | Add-Member -NotePropertyName notification_registry_ok -NotePropertyValue $true
            $report | Add-Member -NotePropertyName notification_settings_registry_ok -NotePropertyValue $true
            $report | Add-Member -NotePropertyName notification_settings_key -NotePropertyValue $settingsKey
            $report | Add-Member -NotePropertyName notification_settings_setting -NotePropertyValue $(if ($settingsInfo.PSObject.Properties.Name -contains "Setting") { $settingsInfo.Setting } else { "" })
            $report | Add-Member -NotePropertyName notification_settings_last_added_time -NotePropertyValue $(if ($settingsInfo.PSObject.Properties.Name -contains "LastNotificationAddedTime") { $settingsInfo.LastNotificationAddedTime } else { "" })
            $report | Add-Member -NotePropertyName notification_settings_periodic_count -NotePropertyValue $(if ($settingsInfo.PSObject.Properties.Name -contains "PeriodicNotificationCount") { $settingsInfo.PeriodicNotificationCount } else { "" })
        }
        if ($CheckTray) {
            if ($report.tray_initialized -ne $true -or $report.tray_prevent_close -ne $true -or $report.tray_visible_before_close -ne $true -or $report.tray_close_hid_window -ne $true -or $report.tray_service_alive_after_hide -ne $true -or $report.tray_restore_visible -ne $true -or $report.tray_restore_trigger -ne "second_instance_activation" -or $report.tray_activation_process_exited -ne $true -or $report.tray_activation_exit_code -ne 0 -or [string]::IsNullOrWhiteSpace([string]$report.tray_service_health)) {
                throw "Release smoke did not complete the tray close/restore lifecycle: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
            if ($MainPhase -eq "normal" -and $report.tray_task_active_before_close -ne $true) {
                throw "Release smoke did not close the main window while a task was active: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
        }
    } else {
        if ($report.window_type -ne $WindowType) {
            throw "Release settings smoke opened the wrong window: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "translationSettings" -and ($report.provider_count -lt 1 -or [string]::IsNullOrWhiteSpace($report.selected_provider))) {
            throw "Release translation settings smoke did not read provider config: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "translationSettings" -and $TranslationScenario -eq "longModels" -and $report.selected_provider_model_count -lt 10) {
            throw "Release translation settings long-model smoke did not read the full model list: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "asrSettings" -and ($report.asr_provider_count -lt 1 -or [string]::IsNullOrWhiteSpace($report.selected_asr_provider))) {
            throw "Release ASR settings smoke did not read ASR config: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "diagnostics" -and ($report.diagnostic_check_count -lt 1 -or [string]::IsNullOrWhiteSpace($report.diagnostic_status))) {
            throw "Release diagnostics smoke did not read doctor report: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "diagnostics" -and ($report.diagnostic_task_count -lt 1)) {
            throw "Release diagnostics smoke did not read task context: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "diagnostics" -and ($report.diagnostic_output_dir_checked -ne $true -or $report.diagnostic_output_dir_writable -ne $true -or [string]::IsNullOrWhiteSpace($report.diagnostic_output_dir_path))) {
            throw "Release diagnostics smoke did not verify the latest task output directory: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and ($TaskProcessingScenario -in @("browse", "edit")) -and ($report.task_processing_task_count -lt 1 -or $report.task_processing_selected_task_id -ne $smokeContextTaskId -or $report.task_processing_selected_status -ne "DONE")) {
            throw "Release task processing smoke did not read and select the completed task: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and ($TaskProcessingScenario -in @("browse", "edit")) -and ($report.task_processing_model_request_count -ne 14 -or $report.task_processing_model_request_counts.batch_recovery -ne 1)) {
            throw "Release task processing smoke did not expose the structured model request summary: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and ($TaskProcessingScenario -in @("browse", "edit")) -and ($report.task_processing_output_dir_checked -ne $true -or $report.task_processing_output_dir_writable -ne $true -or [string]::IsNullOrWhiteSpace($report.task_processing_output_dir_path))) {
            throw "Release task processing smoke did not verify the selected task output directory: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and $TaskProcessingScenario -eq "edit" -and ($report.task_processing_editor_visible -ne $true -or $report.task_processing_result_segment_count -lt 1 -or $report.task_processing_result_issue_count -lt 1 -or $report.task_processing_edit_saved -ne $true -or $report.task_processing_reexported -ne $true -or $report.task_processing_reexport_output_contains_edit -ne $true -or $report.task_processing_reexport_format -ne "ass" -or $report.task_processing_reexport_bilingual -ne $false)) {
            throw "Release task processing edit smoke did not save edits and re-export edited subtitles: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and $TaskProcessingScenario -eq "failure" -and ($report.task_processing_task_count -lt 1 -or $report.task_processing_selected_task_id -ne $smokeContextTaskId -or $report.task_processing_selected_status -ne "FAILED" -or $report.task_processing_resume_attempted -ne $false -or $report.task_processing_diagnostic_clue_count -lt 2 -or $report.task_processing_diagnostic_code -ne $fixtureErrorCode -or $report.task_processing_diagnostic_stage -ne $fixtureErrorStage -or $report.task_processing_diagnostic_retryable -ne $true -or $report.task_processing_diagnostic_can_resume -ne $true)) {
            throw "Release task processing failure smoke did not stay on the failed task with diagnostic clues: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and $TaskProcessingScenario -eq "resume" -and ($report.task_processing_resume_attempted -ne $true -or $report.task_processing_resume_ok -ne $true -or $report.task_processing_selected_status -ne "QUEUED")) {
            throw "Release task processing resume smoke did not resume the failed task: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
        if ($WindowType -eq "taskProcessing" -and $TaskProcessingScenario -eq "cancel" -and ($report.task_processing_cancel_attempted -ne $true -or $report.task_processing_cancel_ok -ne $true -or $report.task_processing_cancel_status -ne "CANCEL_REQUESTED" -or $report.task_processing_selected_status -ne "CANCEL_REQUESTED")) {
            throw "Release task processing cancel smoke did not cancel the running task: $($report | ConvertTo-Json -Compress -Depth 5)"
        }
    }
    if ($showWindow) {
        if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
            if ($report.render_capture_ok -ne $true) {
                throw "Release smoke did not write a Flutter render screenshot: $($report | ConvertTo-Json -Compress -Depth 5)"
            }
            $screenshot = Test-ReleaseRenderScreenshot -Path $ScreenshotPath -WindowType $WindowType
            $phase = if ($WindowType -eq "main" -and $MainPhase -ne "normal") { "main_$MainPhase" } elseif ($WindowType -eq "main") { "post_report_completed" } else { "post_report_settings_ready" }
            $screenshot | Add-Member -NotePropertyName phase -NotePropertyValue $phase
            $report | Add-Member -NotePropertyName screenshot -NotePropertyValue $screenshot
        }
        if ($CheckDesktopComposite) {
            $desktopCompositePath = if ([string]::IsNullOrWhiteSpace($DesktopCompositePath)) {
                Join-Path $tempRoot "desktop_composite.png"
            } else {
                $DesktopCompositePath
            }
            $desktopComposite = Capture-DesktopCompositeScreenshot -Process $process -Path $desktopCompositePath -WindowType $WindowType
            $report | Add-Member -NotePropertyName desktop_composite -NotePropertyValue $desktopComposite
            if ($desktopComposite.ok -ne $true) {
                throw "Release desktop composite capture failed: $($desktopComposite | ConvertTo-Json -Compress -Depth 5)"
            }
            if ($desktopComposite.flutter_overflow_stripe_samples -ge 24) {
                throw "Release desktop composite screenshot contains a Flutter overflow warning stripe: $($desktopComposite | ConvertTo-Json -Compress -Depth 5)"
            }
        }
    }
    if (-not $process.HasExited) {
        $waitMillis = 1000 * [Math]::Max(3, $postReportSeconds + 3)
        if (-not $process.WaitForExit($waitMillis)) {
            Stop-Process -Id $process.Id -Force
            throw "Release smoke did not exit after writing report."
        }
    }
    if ($CheckAppIdentity) {
        $identityOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $appIdentityScript -ExePath $resolvedExe.Path -Json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Release smoke AppUserModelID shortcut identity check failed: $($identityOutput | Out-String)"
        }
        $identityJson = ($identityOutput | Out-String).Trim()
        $identityReport = $identityJson | ConvertFrom-Json
        if ($identityReport.ok -ne $true -or $identityReport.shortcut_app_user_model_id_ok -ne $true -or $identityReport.shortcut_target_ok -ne $true) {
            throw "Release smoke AppUserModelID shortcut identity check did not pass: $identityJson"
        }
        if ($report.PSObject.Properties.Name -contains "notification_app_user_model_id") {
            if ([string]$report.notification_app_user_model_id -ne [string]$identityReport.app_user_model_id) {
                throw "Notification AUMID and shortcut AUMID differ: notification=$($report.notification_app_user_model_id) shortcut=$($identityReport.app_user_model_id)"
            }
        }
        $report | Add-Member -Force -NotePropertyName app_identity_ok -NotePropertyValue $true
        $report | Add-Member -Force -NotePropertyName app_identity -NotePropertyValue $identityReport
        Remove-SmokeManualAcceptanceRequirement -Requirement "AppUserModelID shortcut identity acceptance; rerun with -CheckAppIdentity"
    }
    Add-SmokeAcceptanceBoundary -Report $report
    $finalReportJson = $report | ConvertTo-Json -Depth 6
    $finalReportJson | Set-Content -LiteralPath $reportPath -Encoding utf8
    $finalReportJson
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    if ($null -ne $smokeProvider -and $null -ne $smokeProvider.Process -and -not $smokeProvider.Process.HasExited) {
        Stop-Process -Id $smokeProvider.Process.Id -Force
        $smokeProvider.Process.WaitForExit(3000) | Out-Null
    }
    if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Release smoke could not remove temp directory '$tempRoot': $($_.Exception.Message)"
        }
    } elseif ($KeepTemp) {
        Write-Host "Smoke temp kept at: $tempRoot"
    }
}
