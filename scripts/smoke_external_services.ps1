param(
    [string]$Root = "",
    [string]$ProvidersFile = "providers.local.yaml",
    [string]$SegmentsPath = "samples\asr_segments_sample.jsonl",
    [string]$InputPath = "",
    [string]$SourceLang = "en",
    [string]$TargetLang = "zh-CN",
    [string]$Provider = "",
    [string]$Model = "",
    [switch]$SkipProviderProbe,
    [switch]$SkipTranslation,
    [switch]$RequireMediaTask,
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
} else {
    $Root = (Resolve-Path -LiteralPath $Root).Path
}

function Resolve-OptionalPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $PathValue))
}

function Get-TransVortexCommand {
    $command = Get-Command transvortex -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return [ordered]@{ exe = $command.Source; prefix = @() }
    }
    $python = Get-Command python -ErrorAction Stop
    return [ordered]@{ exe = $python.Source; prefix = @("-m", "transvortex.cli") }
}

function Invoke-TransVortexJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$CommandInfo,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Step = "transvortex"
    )
    $allArgs = @($CommandInfo.prefix) + $Arguments
    $raw = & $CommandInfo.exe @allArgs 2>&1
    $text = ($raw | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE`n$text"
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        throw "$Step did not return JSON`n$text"
    }
}

function Invoke-TransVortexText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$CommandInfo,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Step = "transvortex"
    )
    $allArgs = @($CommandInfo.prefix) + $Arguments
    $raw = & $CommandInfo.exe @allArgs 2>&1
    $text = ($raw | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE`n$text"
    }
    return $text
}

function Compress-ReportText {
    param([string]$Text)
    $normalized = ($Text -replace "\r\n", "`n").Trim()
    if ($normalized.Length -le 600) {
        return $normalized
    }
    return $normalized.Substring(0, 600) + "..."
}

function Get-AsrEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )
    $taskDir = Join-Path (Join-Path $Root "artifacts") $TaskId
    $rowsDir = Join-Path $taskDir "source\asr\rows"
    $qualitySummaryPath = Join-Path $taskDir "source\asr\quality\summary.json"
    $eventsPath = Join-Path $taskDir "events.jsonl"
    $asrRows = if (Test-Path -LiteralPath $rowsDir) {
        @(Get-ChildItem -LiteralPath $rowsDir -File -Filter "*.json" -ErrorAction SilentlyContinue).Count
    } else {
        0
    }
    $qualitySummaryExists = Test-Path -LiteralPath $qualitySummaryPath
    $asrEventCount = 0
    if (Test-Path -LiteralPath $eventsPath) {
        $asrEventCount = @(
            Get-Content -LiteralPath $eventsPath -Encoding utf8 |
                Select-String -Pattern '"stage"\s*:\s*"ASR"|Transcribed segment|Transcribing audio'
        ).Count
    }
    $present = $asrRows -gt 0 -or $qualitySummaryExists -or $asrEventCount -gt 0
    return [ordered]@{
        present = $present
        asr_rows = $asrRows
        quality_summary_exists = $qualitySummaryExists
        asr_event_count = $asrEventCount
    }
}

function Add-ProviderAndModelArgs {
    param([System.Collections.Generic.List[string]]$ArgsList)
    if (-not [string]::IsNullOrWhiteSpace($Provider)) {
        $ArgsList.Add("--provider")
        $ArgsList.Add($Provider)
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $ArgsList.Add("--model")
        $ArgsList.Add($Model)
    }
}

$providersFilePath = Resolve-OptionalPath $ProvidersFile
$segmentsFilePath = Resolve-OptionalPath $SegmentsPath
$inputFilePath = Resolve-OptionalPath $InputPath
$commandInfo = Get-TransVortexCommand

$manualAcceptanceRequired = @(
    "real visible release window end-to-end run; record with scripts/accept_flutter_release_manual.ps1",
    "formal MSIX/MSI/NSIS/Inno installer acceptance"
)
if ([string]::IsNullOrWhiteSpace($inputFilePath)) {
    $manualAcceptanceRequired += "real speech recognition or media-task evidence; rerun with -InputPath to collect it"
}

$report = [ordered]@{
    ok = $false
    root = $Root
    providers_file = $providersFilePath
    segments_path = $segmentsFilePath
    input_path = $inputFilePath
    provider = $Provider
    model = $Model
    external_provider_probe_ok = $false
    external_translation_ok = $false
    external_media_task_ok = $false
    external_asr_evidence = if ([string]::IsNullOrWhiteSpace($inputFilePath)) { "not_requested" } else { "media_task_requested" }
    plan_only = [bool]$PlanOnly
    frontend_design_mvp_complete = $false
    automated_scope = "real configured provider probe plus segments translation; optional media task when -InputPath is supplied"
    manual_acceptance_required = $manualAcceptanceRequired
    steps = @()
}

try {
    if ($PlanOnly) {
        $report.completion_claim = "Plan only; no external provider or media task was executed."
        $report.steps = @(
            [ordered]@{ name = "probe-provider"; planned = -not [bool]$SkipProviderProbe },
            [ordered]@{ name = "translate"; planned = -not [bool]$SkipTranslation },
            [ordered]@{ name = "media_task"; planned = -not [string]::IsNullOrWhiteSpace($inputFilePath) }
        )
        $report | ConvertTo-Json -Depth 10
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($providersFilePath)) {
        throw "Providers file is required. Pass -ProvidersFile or create providers.local.yaml."
    }
    if (-not (Test-Path -LiteralPath $providersFilePath)) {
        throw "Providers file not found: $providersFilePath"
    }
    if (-not $SkipTranslation -and -not (Test-Path -LiteralPath $segmentsFilePath)) {
        throw "Segments sample not found: $segmentsFilePath"
    }
    if (-not [string]::IsNullOrWhiteSpace($inputFilePath) -and -not (Test-Path -LiteralPath $inputFilePath)) {
        throw "Input media not found: $inputFilePath"
    }
    if ($RequireMediaTask -and [string]::IsNullOrWhiteSpace($inputFilePath)) {
        throw "-RequireMediaTask needs -InputPath."
    }

    if (-not $SkipProviderProbe) {
        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add("--root")
        $args.Add($Root)
        $args.Add("probe-provider")
        $args.Add("--providers-file")
        $args.Add($providersFilePath)
        $args.Add("--strict")
        $args.Add("--source-lang")
        $args.Add($SourceLang)
        $args.Add("--target-lang")
        $args.Add($TargetLang)
        Add-ProviderAndModelArgs -ArgsList $args
        $probeOutput = Invoke-TransVortexText -CommandInfo $commandInfo -Arguments $args.ToArray() -Step "probe-provider"
        $report.external_provider_probe_ok = $true
        try {
            $probe = $probeOutput | ConvertFrom-Json
            $checks = @()
            if ($null -ne $probe.checks) {
                $checks = @($probe.checks)
            }
            $failedChecks = @($checks | Where-Object { $_.status -eq "FAIL" })
            $warnChecks = @($checks | Where-Object { $_.status -eq "WARN" })
            $report.steps += [ordered]@{
                name = "probe-provider"
                ok = $true
                provider = if ($probe.PSObject.Properties.Name -contains "provider") { [string]$probe.provider } else { "" }
                model = if ($probe.PSObject.Properties.Name -contains "model") { [string]$probe.model } else { "" }
                check_count = $checks.Count
                fail_count = $failedChecks.Count
                warn_count = $warnChecks.Count
            }
        } catch {
            $report.steps += [ordered]@{
                name = "probe-provider"
                ok = $true
                output = Compress-ReportText $probeOutput
            }
        }
    }

    if (-not $SkipTranslation) {
        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add("--root")
        $args.Add($Root)
        $args.Add("translate")
        $args.Add("--providers-file")
        $args.Add($providersFilePath)
        $args.Add("--segments")
        $args.Add($segmentsFilePath)
        $args.Add("--src")
        $args.Add($SourceLang)
        $args.Add("--tgt")
        $args.Add($TargetLang)
        $args.Add("--bilingual")
        $args.Add("--json")
        Add-ProviderAndModelArgs -ArgsList $args
        $translation = Invoke-TransVortexJson -CommandInfo $commandInfo -Arguments $args.ToArray() -Step "translate"
        $translationStatus = [string]$translation.status
        if ($translationStatus -ne "DONE") {
            throw "translate finished with status $translationStatus"
        }
        $report.external_translation_ok = $true
        $report.translation_task_id = [string]$translation.task_id
        $report.translation_output_path = [string]$translation.output_path
        $report.steps += [ordered]@{
            name = "translate"
            ok = $true
            task_id = [string]$translation.task_id
            status = $translationStatus
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($inputFilePath)) {
        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add("--root")
        $args.Add($Root)
        $args.Add("run")
        $args.Add("--providers-file")
        $args.Add($providersFilePath)
        $args.Add("--input")
        $args.Add($inputFilePath)
        $args.Add("--src")
        $args.Add($SourceLang)
        $args.Add("--tgt")
        $args.Add($TargetLang)
        $args.Add("--bilingual")
        $args.Add("--json")
        Add-ProviderAndModelArgs -ArgsList $args
        $media = Invoke-TransVortexJson -CommandInfo $commandInfo -Arguments $args.ToArray() -Step "run media task"
        $mediaStatus = [string]$media.status
        if ($mediaStatus -ne "DONE") {
            throw "media task finished with status $mediaStatus"
        }
        $report.external_media_task_ok = $true
        $asrEvidence = Get-AsrEvidence -TaskId ([string]$media.task_id)
        $report.external_asr_evidence = if ($asrEvidence.present) { "asr_artifacts_present" } else { "media_task_done" }
        $report.media_task_id = [string]$media.task_id
        $report.media_output_path = [string]$media.output_path
        $report.steps += [ordered]@{
            name = "media_task"
            ok = $true
            task_id = [string]$media.task_id
            status = $mediaStatus
            asr_evidence = $asrEvidence
        }
    }

    $requestedChecks = 0
    $requestedChecks += if (-not $SkipProviderProbe) { 1 } else { 0 }
    $requestedChecks += if (-not $SkipTranslation) { 1 } else { 0 }
    $requestedChecks += if (-not [string]::IsNullOrWhiteSpace($inputFilePath)) { 1 } else { 0 }
    $providerProbeOk = [bool]$SkipProviderProbe -or $report.external_provider_probe_ok
    $translationOk = [bool]$SkipTranslation -or $report.external_translation_ok
    $mediaOk = [string]::IsNullOrWhiteSpace($inputFilePath) -or $report.external_media_task_ok
    $report.ok = $requestedChecks -gt 0 -and $providerProbeOk -and $translationOk -and $mediaOk
    $report.completion_claim = "External service smoke passed for the requested scope; this does not prove the frontend design MVP is complete."
    $report | ConvertTo-Json -Depth 10
    if (-not $report.ok) {
        exit 1
    }
} catch {
    $report.error = $_.Exception.Message
    $report.completion_claim = "External service smoke failed or was incomplete; do not use it as acceptance evidence."
    $report | ConvertTo-Json -Depth 10
    exit 1
}
