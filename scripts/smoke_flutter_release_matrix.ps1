param(
    [string]$ExePath = "",
    [int]$TimeoutSeconds = 60,
    [string]$OutputDir = "",
    [switch]$SkipCompletedTask,
    [switch]$CheckAppIdentity,
    [switch]$CheckDesktopComposite
)

$ErrorActionPreference = "Stop"

$smokeScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "smoke_flutter_release.ps1")).Path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("transvortex_release_smoke_matrix_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$cases = [System.Collections.Generic.List[object]]::new()
if (-not $SkipCompletedTask) {
    $cases.Add([ordered]@{
        name = "main_completed"
        window_type = "main"
        main_phase = "normal"
        translation_scenario = "normal"
        check_notifications = $false
    })
    $cases.Add([ordered]@{
        name = "main_completed_notifications"
        window_type = "main"
        main_phase = "normal"
        translation_scenario = "normal"
        check_notifications = $true
    })
}
foreach ($phase in @("empty", "ready", "blockedTranslation", "blockedAsr", "running", "failed")) {
    $cases.Add([ordered]@{
        name = "main_$phase"
        window_type = "main"
        main_phase = $phase
        translation_scenario = "normal"
        check_notifications = $false
    })
}
foreach ($windowType in @("translationSettings", "asrSettings", "diagnostics", "taskProcessing")) {
    $cases.Add([ordered]@{
        name = $windowType
        window_type = $windowType
        main_phase = "normal"
        translation_scenario = "normal"
        task_processing_scenario = if ($windowType -eq "taskProcessing") { "browse" } else { "" }
        check_notifications = $false
    })
}
foreach ($scenario in @("edit", "resume", "cancel")) {
    $cases.Add([ordered]@{
        name = "taskProcessing_$scenario"
        window_type = "taskProcessing"
        main_phase = "normal"
        translation_scenario = "normal"
        task_processing_scenario = $scenario
        check_notifications = $false
    })
}
$cases.Add([ordered]@{
    name = "translationSettings_longModels"
    window_type = "translationSettings"
    main_phase = "normal"
    translation_scenario = "longModels"
    check_notifications = $false
})

$summary = [System.Collections.Generic.List[object]]::new()
$appIdentityCovered = $false
$appIdentityCaseAssigned = $false
foreach ($case in $cases) {
    $name = [string]$case.name
    $screenshotPath = Join-Path $resolvedOutputDir "$name.png"
    $desktopCompositePath = Join-Path $resolvedOutputDir "$name.desktop.png"
    $reportPath = Join-Path $resolvedOutputDir "$name.report.json"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $smokeScript,
        "-TimeoutSeconds",
        "$TimeoutSeconds",
        "-ScreenshotPath",
        $screenshotPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ExePath)) {
        $args += @("-ExePath", $ExePath)
    }
    if ($case.window_type -ne "main") {
        $args += @("-WindowType", $case.window_type)
    }
    if ($case.main_phase -ne "normal") {
        $args += @("-MainPhase", $case.main_phase)
    }
    if ($case.translation_scenario -ne "normal") {
        $args += @("-TranslationScenario", $case.translation_scenario)
    }
    if ($case.window_type -eq "taskProcessing" -and $case.task_processing_scenario -ne "browse") {
        $args += @("-TaskProcessingScenario", $case.task_processing_scenario)
    }
    if ($case.check_notifications -eq $true) {
        $args += "-CheckNotifications"
    }
    $caseChecksAppIdentity = $false
    if ($CheckAppIdentity -and -not $appIdentityCaseAssigned) {
        $args += "-CheckAppIdentity"
        $caseChecksAppIdentity = $true
        $appIdentityCaseAssigned = $true
    }
    if ($CheckDesktopComposite) {
        $args += @("-CheckDesktopComposite", "-DesktopCompositePath", $desktopCompositePath)
    }

    Write-Host "=== $name ==="
    $rawOutput = & powershell @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Release smoke matrix case failed: $name`n$($rawOutput | Out-String)"
    }

    $jsonText = ($rawOutput | Out-String).Trim()
    try {
        $report = $jsonText | ConvertFrom-Json
    } catch {
        throw "Release smoke matrix case did not return JSON: $name`n$jsonText"
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8

    $screenshot = $report.screenshot
    $windowType = [string]$report.window_type
    if ([string]::IsNullOrWhiteSpace($windowType)) {
        $windowType = [string]$case.window_type
    }
    if ($report.PSObject.Properties.Name -contains "app_identity_ok" -and $report.app_identity_ok -eq $true) {
        $appIdentityCovered = $true
    }
    $summary.Add([ordered]@{
        name = $name
        window_type = $windowType
        main_phase = if ($report.PSObject.Properties.Name -contains "main_phase") { $report.main_phase } else { $case.main_phase }
        translation_scenario = $case.translation_scenario
        task_processing_scenario = if ($report.PSObject.Properties.Name -contains "task_processing_scenario") { $report.task_processing_scenario } elseif ($case.window_type -eq "taskProcessing") { $case.task_processing_scenario } else { "" }
        controller_state = if ($report.PSObject.Properties.Name -contains "controller_state") { $report.controller_state } else { "" }
        status = $report.status
        task_status = if ($report.PSObject.Properties.Name -contains "task_status") { $report.task_status } else { "" }
        selected_provider_model_count = if ($report.PSObject.Properties.Name -contains "selected_provider_model_count") { $report.selected_provider_model_count } else { "" }
        history_active_count = if ($report.PSObject.Properties.Name -contains "history_active_count") { $report.history_active_count } else { "" }
        history_failed_count = if ($report.PSObject.Properties.Name -contains "history_failed_count") { $report.history_failed_count } else { "" }
        diagnostic_output_dir_writable = if ($report.PSObject.Properties.Name -contains "diagnostic_output_dir_writable") { $report.diagnostic_output_dir_writable } else { "" }
        task_processing_task_count = if ($report.PSObject.Properties.Name -contains "task_processing_task_count") { $report.task_processing_task_count } else { "" }
        task_processing_selected_status = if ($report.PSObject.Properties.Name -contains "task_processing_selected_status") { $report.task_processing_selected_status } else { "" }
        task_processing_edit_saved = if ($report.PSObject.Properties.Name -contains "task_processing_edit_saved") { $report.task_processing_edit_saved } else { "" }
        task_processing_reexported = if ($report.PSObject.Properties.Name -contains "task_processing_reexported") { $report.task_processing_reexported } else { "" }
        task_processing_resume_ok = if ($report.PSObject.Properties.Name -contains "task_processing_resume_ok") { $report.task_processing_resume_ok } else { "" }
        task_processing_cancel_ok = if ($report.PSObject.Properties.Name -contains "task_processing_cancel_ok") { $report.task_processing_cancel_ok } else { "" }
        task_processing_output_dir_writable = if ($report.PSObject.Properties.Name -contains "task_processing_output_dir_writable") { $report.task_processing_output_dir_writable } else { "" }
        result_issue_count = if ($report.PSObject.Properties.Name -contains "result_issue_count") { $report.result_issue_count } else { "" }
        notification_check_ok = if ($report.PSObject.Properties.Name -contains "notification_check_ok") { $report.notification_check_ok } else { "" }
        notification_show_calls = if ($report.PSObject.Properties.Name -contains "notification_show_calls") { $report.notification_show_calls } else { "" }
        notification_registry_ok = if ($report.PSObject.Properties.Name -contains "notification_registry_ok") { $report.notification_registry_ok } else { "" }
        notification_settings_registry_ok = if ($report.PSObject.Properties.Name -contains "notification_settings_registry_ok") { $report.notification_settings_registry_ok } else { "" }
        notification_settings_setting = if ($report.PSObject.Properties.Name -contains "notification_settings_setting") { $report.notification_settings_setting } else { "" }
        notification_settings_periodic_count = if ($report.PSObject.Properties.Name -contains "notification_settings_periodic_count") { $report.notification_settings_periodic_count } else { "" }
        app_identity_check_requested = $caseChecksAppIdentity
        app_identity_ok = if ($report.PSObject.Properties.Name -contains "app_identity_ok") { $report.app_identity_ok } else { "" }
        app_identity_shortcut_path = if ($report.PSObject.Properties.Name -contains "app_identity") { $report.app_identity.shortcut_path } else { "" }
        app_identity_app_user_model_id = if ($report.PSObject.Properties.Name -contains "app_identity") { $report.app_identity.app_user_model_id } else { "" }
        screenshot_path = $screenshotPath
        report_path = $reportPath
        render_width = if ($null -ne $screenshot) { $screenshot.width } else { "" }
        render_height = if ($null -ne $screenshot) { $screenshot.height } else { "" }
        non_background_samples = if ($null -ne $screenshot) { $screenshot.non_background_samples } else { "" }
        flutter_overflow_stripe_samples = if ($null -ne $screenshot) { $screenshot.flutter_overflow_stripe_samples } else { "" }
        desktop_composite_ok = if ($report.PSObject.Properties.Name -contains "desktop_composite") { $report.desktop_composite.ok } else { "" }
        desktop_composite_path = if ($report.PSObject.Properties.Name -contains "desktop_composite") { $report.desktop_composite.path } else { "" }
        desktop_composite_non_background_samples = if ($report.PSObject.Properties.Name -contains "desktop_composite") { $report.desktop_composite.non_background_samples } else { "" }
        desktop_composite_background_like_samples = if ($report.PSObject.Properties.Name -contains "desktop_composite") { $report.desktop_composite.background_like_samples } else { "" }
        desktop_composite_overflow_stripe_samples = if ($report.PSObject.Properties.Name -contains "desktop_composite") { $report.desktop_composite.flutter_overflow_stripe_samples } else { "" }
        desktop_composite_error = if ($report.PSObject.Properties.Name -contains "desktop_composite") { $report.desktop_composite.error } else { "" }
    }) | Out-Null
}

$manualAcceptanceRequired = @(
    "real visible release window end-to-end run; record with scripts/accept_flutter_release_manual.ps1",
    "formal MSIX/MSI/NSIS/Inno installer acceptance"
)
if (-not $appIdentityCovered) {
    $manualAcceptanceRequired += "AppUserModelID shortcut identity acceptance; rerun with -CheckAppIdentity"
}

$matrix = [ordered]@{
    ok = $true
    output_dir = $resolvedOutputDir
    case_count = $summary.Count
    automated_scope = "release render-tree smoke, optional desktop-composite screenshot sampling, Local Service workflow checks, overflow stripe sampling, native notification call/registry checks when enabled, and AppUserModelID shortcut identity checks when enabled"
    frontend_design_mvp_complete = $false
    completion_claim = "Automated release smoke matrix passed; this is evidence for Flutter MVP wiring, not proof that the frontend design MVP is complete."
    manual_acceptance_required = $manualAcceptanceRequired
    cases = $summary
}
$matrixPath = Join-Path $resolvedOutputDir "matrix.summary.json"
$matrix | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $matrixPath -Encoding utf8
$matrix | ConvertTo-Json -Depth 20
