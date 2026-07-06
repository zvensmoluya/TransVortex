import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'window_state.dart';

@visibleForTesting
String windowArgumentFromSources(String? windowArguments, List<String> args) {
  final fromWindow = windowArguments?.trim();
  if (fromWindow != null && fromWindow.isNotEmpty) return fromWindow;
  return args.isEmpty ? '' : args.first.trim();
}

class AppStartupArgs {
  const AppStartupArgs({required this.window, this.smoke});

  final AppWindowArgs window;
  final AppSmokeArgs? smoke;

  static AppStartupArgs fromSources(
    String? windowArguments,
    List<String> args,
  ) {
    final rawWindowArgument = windowArgumentFromSources(windowArguments, args);
    final reportArg = _optionValue(args, '--tvx-smoke-report');
    final rootArg = _optionValue(args, '--tvx-service-root');
    final timeoutArg = _optionValue(args, '--tvx-smoke-timeout');
    final inputArg = _optionValue(args, '--tvx-smoke-input');
    final expectedTextArg = _optionValue(args, '--tvx-smoke-expected-text');
    final screenshotArg = _optionValue(args, '--tvx-smoke-screenshot');
    final minVisibleSecondsArg = _optionValue(
      args,
      '--tvx-smoke-min-visible-seconds',
    );
    final postReportVisibleSecondsArg = _optionValue(
      args,
      '--tvx-smoke-post-report-seconds',
    );
    final useControllerArg = _optionValue(args, '--tvx-smoke-use-controller');
    final checkNotificationsArg = _optionValue(
      args,
      '--tvx-smoke-check-notifications',
    );
    final mainPhaseArg = _optionValue(args, '--tvx-smoke-main-phase');
    final taskProcessingScenarioArg = _optionValue(
      args,
      '--tvx-smoke-task-processing-scenario',
    );
    final explicitWindowType =
        _optionValue(args, '--tvx-window-type') ??
        _optionValueFromRaw(rawWindowArgument, '--tvx-window-type');
    final explicitTaskId =
        _optionValue(args, '--tvx-task-id') ??
        _optionValueFromRaw(rawWindowArgument, '--tvx-task-id');
    final parsedWindow = AppWindowArgs.parse(rawWindowArgument);
    final window = _windowWithOverrides(
      parsedWindow,
      explicitWindowType: explicitWindowType,
      explicitTaskId: explicitTaskId,
    );
    if (reportArg != null && reportArg.trim().isNotEmpty) {
      return AppStartupArgs(
        window: window,
        smoke: AppSmokeArgs(
          reportPath: reportArg.trim(),
          serviceRoot: _optionalString(rootArg),
          timeout: Duration(
            seconds:
                int.tryParse(timeoutArg ?? '')?.clamp(1, 120).toInt() ?? 15,
          ),
          inputPath: _optionalString(inputArg),
          expectedOutputText: _optionalString(expectedTextArg),
          screenshotPath: _optionalString(screenshotArg),
          minVisibleDuration: Duration(
            seconds:
                int.tryParse(
                  minVisibleSecondsArg ?? '',
                )?.clamp(0, 30).toInt() ??
                0,
          ),
          postReportVisibleDuration: Duration(
            seconds:
                int.tryParse(
                  postReportVisibleSecondsArg ?? '',
                )?.clamp(0, 30).toInt() ??
                0,
          ),
          useControllerSubmission: _boolOption(useControllerArg),
          checkNotifications: _boolOption(checkNotificationsArg),
          mainPhase: SmokeMainPhaseLabel.fromId(mainPhaseArg),
          taskProcessingScenario: _optionalString(taskProcessingScenarioArg),
        ),
      );
    }
    final startup = AppStartupArgs.parse(rawWindowArgument);
    return AppStartupArgs(
      window: _windowWithOverrides(
        startup.window,
        explicitWindowType: explicitWindowType,
        explicitTaskId: explicitTaskId,
      ),
      smoke: startup.smoke,
    );
  }

  static AppStartupArgs parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const AppStartupArgs(
        window: AppWindowArgs(type: AppWindowType.main),
      );
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final smoke = AppSmokeArgs.fromJson(decoded['smoke']);
        return AppStartupArgs(
          window: AppWindowArgs.parse(trimmed),
          smoke: smoke,
        );
      }
    } catch (_) {
      // Fall through to legacy window arg parsing.
    }
    return AppStartupArgs(window: AppWindowArgs.parse(trimmed));
  }
}

AppWindowArgs _windowWithOverrides(
  AppWindowArgs parsed, {
  String? explicitWindowType,
  String? explicitTaskId,
}) {
  final type =
      AppWindowTypeLabel.maybeFromId(explicitWindowType?.trim()) ?? parsed.type;
  final taskId = _optionalString(explicitTaskId) ?? parsed.taskId;
  return AppWindowArgs(type: type, taskId: taskId);
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

class AppSmokeArgs {
  const AppSmokeArgs({
    required this.reportPath,
    this.serviceRoot,
    this.timeout = const Duration(seconds: 15),
    this.inputPath,
    this.expectedOutputText,
    this.screenshotPath,
    this.minVisibleDuration = Duration.zero,
    this.postReportVisibleDuration = Duration.zero,
    this.useControllerSubmission = false,
    this.checkNotifications = false,
    this.mainPhase = SmokeMainPhase.normal,
    this.taskProcessingScenario,
  });

  final String reportPath;
  final String? serviceRoot;
  final Duration timeout;
  final String? inputPath;
  final String? expectedOutputText;
  final String? screenshotPath;
  final Duration minVisibleDuration;
  final Duration postReportVisibleDuration;
  final bool useControllerSubmission;
  final bool checkNotifications;
  final SmokeMainPhase mainPhase;
  final String? taskProcessingScenario;

  static AppSmokeArgs? fromJson(Object? value) {
    final map = value is Map ? value : null;
    final reportPath = map?['reportPath'] ?? map?['report_path'];
    if (reportPath is! String || reportPath.trim().isEmpty) return null;
    final serviceRoot = map?['serviceRoot'] ?? map?['service_root'];
    final timeoutSeconds = map?['timeoutSeconds'] ?? map?['timeout_seconds'];
    final inputPath =
        map?['inputPath'] ?? map?['input_path'] ?? map?['taskInputPath'];
    final expectedOutputText =
        map?['expectedOutputText'] ?? map?['expected_output_text'];
    final screenshotPath = map?['screenshotPath'] ?? map?['screenshot_path'];
    final minVisibleSeconds =
        map?['minVisibleSeconds'] ?? map?['min_visible_seconds'];
    final postReportVisibleSeconds =
        map?['postReportVisibleSeconds'] ?? map?['post_report_visible_seconds'];
    final useControllerSubmission =
        map?['useControllerSubmission'] ?? map?['use_controller_submission'];
    final checkNotifications =
        map?['checkNotifications'] ?? map?['check_notifications'];
    final mainPhase = map?['mainPhase'] ?? map?['main_phase'];
    final taskProcessingScenario =
        map?['taskProcessingScenario'] ?? map?['task_processing_scenario'];
    return AppSmokeArgs(
      reportPath: reportPath.trim(),
      serviceRoot: serviceRoot is String && serviceRoot.trim().isNotEmpty
          ? serviceRoot.trim()
          : null,
      timeout: Duration(
        seconds: timeoutSeconds is num
            ? timeoutSeconds.clamp(1, 120).toInt()
            : 15,
      ),
      inputPath: inputPath is String && inputPath.trim().isNotEmpty
          ? inputPath.trim()
          : null,
      expectedOutputText:
          expectedOutputText is String && expectedOutputText.trim().isNotEmpty
          ? expectedOutputText.trim()
          : null,
      screenshotPath:
          screenshotPath is String && screenshotPath.trim().isNotEmpty
          ? screenshotPath.trim()
          : null,
      minVisibleDuration: Duration(
        seconds: minVisibleSeconds is num
            ? minVisibleSeconds.clamp(0, 30).toInt()
            : 0,
      ),
      postReportVisibleDuration: Duration(
        seconds: postReportVisibleSeconds is num
            ? postReportVisibleSeconds.clamp(0, 30).toInt()
            : 0,
      ),
      useControllerSubmission: useControllerSubmission == true,
      checkNotifications: checkNotifications == true,
      mainPhase: SmokeMainPhaseLabel.fromId(mainPhase as String?),
      taskProcessingScenario: _optionalString(taskProcessingScenario),
    );
  }
}

enum SmokeMainPhase {
  normal,
  empty,
  ready,
  blockedTranslation,
  blockedAsr,
  running,
  failed,
}

extension SmokeMainPhaseLabel on SmokeMainPhase {
  String get id => switch (this) {
    SmokeMainPhase.normal => 'normal',
    SmokeMainPhase.empty => 'empty',
    SmokeMainPhase.ready => 'ready',
    SmokeMainPhase.blockedTranslation => 'blockedTranslation',
    SmokeMainPhase.blockedAsr => 'blockedAsr',
    SmokeMainPhase.running => 'running',
    SmokeMainPhase.failed => 'failed',
  };

  static SmokeMainPhase fromId(String? id) {
    return switch ((id ?? '').trim()) {
      'empty' => SmokeMainPhase.empty,
      'ready' => SmokeMainPhase.ready,
      'blockedTranslation' => SmokeMainPhase.blockedTranslation,
      'blockedAsr' => SmokeMainPhase.blockedAsr,
      'running' => SmokeMainPhase.running,
      'failed' => SmokeMainPhase.failed,
      _ => SmokeMainPhase.normal,
    };
  }
}

String? _optionValue(List<String> args, String name) {
  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    if (arg == name && i + 1 < args.length) return args[i + 1];
    final prefix = '$name=';
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return null;
}

String? _optionValueFromRaw(String raw, String name) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final escaped = RegExp.escape(name);
  final match = RegExp('(?:^|\\s)$escaped(?:=|\\s+)(\\S+)').firstMatch(
    trimmed,
  );
  return match?.group(1);
}

bool _boolOption(String? value) {
  final normalized = (value ?? '').trim().toLowerCase();
  return normalized == '1' || normalized == 'true' || normalized == 'yes';
}
