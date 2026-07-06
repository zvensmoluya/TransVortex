import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

enum AppWindowType {
  main,
  translationSettings,
  asrSettings,
  diagnostics,
  resultReview,
  taskHistory,
  taskDetail,
}

extension AppWindowTypeLabel on AppWindowType {
  String get id => switch (this) {
    AppWindowType.main => 'main',
    AppWindowType.translationSettings => 'translationSettings',
    AppWindowType.asrSettings => 'asrSettings',
    AppWindowType.diagnostics => 'diagnostics',
    AppWindowType.resultReview => 'resultReview',
    AppWindowType.taskHistory => 'taskHistory',
    AppWindowType.taskDetail => 'taskDetail',
  };

  String get title => switch (this) {
    AppWindowType.main => 'TransVortex',
    AppWindowType.translationSettings => '翻译模型设置',
    AppWindowType.asrSettings => '语音识别设置',
    AppWindowType.diagnostics => '诊断',
    AppWindowType.resultReview => '结果审看',
    AppWindowType.taskHistory => '任务历史',
    AppWindowType.taskDetail => '任务详情',
  };

  static AppWindowType fromId(String? id) => switch (id) {
    'translationSettings' => AppWindowType.translationSettings,
    'asrSettings' => AppWindowType.asrSettings,
    'diagnostics' => AppWindowType.diagnostics,
    'resultReview' => AppWindowType.resultReview,
    'taskHistory' => AppWindowType.taskHistory,
    'taskDetail' => AppWindowType.taskDetail,
    _ => AppWindowType.main,
  };

  static AppWindowType? maybeFromId(String? id) => switch (id) {
    'main' => AppWindowType.main,
    'translationSettings' => AppWindowType.translationSettings,
    'asrSettings' => AppWindowType.asrSettings,
    'diagnostics' => AppWindowType.diagnostics,
    'resultReview' => AppWindowType.resultReview,
    'taskHistory' => AppWindowType.taskHistory,
    'taskDetail' => AppWindowType.taskDetail,
    _ => null,
  };
}

@immutable
class AppWindowArgs {
  const AppWindowArgs({required this.type, this.taskId, this.parentBounds});

  final AppWindowType type;
  final String? taskId;
  final Rect? parentBounds;

  String encode() {
    final normalizedTaskId = taskId?.trim();
    return jsonEncode({
      'type': type.id,
      if (normalizedTaskId != null && normalizedTaskId.isNotEmpty)
        'task_id': normalizedTaskId,
      if (parentBounds != null) 'parent_bounds': _rectToJson(parentBounds!),
    });
  }

  static AppWindowArgs parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const AppWindowArgs(type: AppWindowType.main);
    }
    final directType = AppWindowTypeLabel.maybeFromId(trimmed);
    if (directType != null) return AppWindowArgs(type: directType);
    final looseType = RegExp(
      r'^\{\s*type\s*:\s*([A-Za-z]+)\s*\}$',
    ).firstMatch(trimmed)?.group(1);
    final looseWindowType = AppWindowTypeLabel.maybeFromId(looseType);
    if (looseWindowType != null) {
      return AppWindowArgs(type: looseWindowType);
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return AppWindowArgs(
          type: AppWindowTypeLabel.fromId(decoded['type'] as String?),
          taskId: _optionalString(decoded['task_id'] ?? decoded['taskId']),
          parentBounds: _rectFromJson(
            decoded['parent_bounds'] ?? decoded['parentBounds'],
          ),
        );
      }
    } catch (_) {
      // Fall through to main; malformed window args should not block startup.
    }
    return const AppWindowArgs(type: AppWindowType.main);
  }
}

Map<String, double> _rectToJson(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

Rect? _rectFromJson(Object? value) {
  if (value is! Map) return null;
  final x = _numToDouble(value['x'] ?? value['left']);
  final y = _numToDouble(value['y'] ?? value['top']);
  final width = _numToDouble(value['width'] ?? value['w']);
  final height = _numToDouble(value['height'] ?? value['h']);
  if (x == null || y == null || width == null || height == null) {
    return null;
  }
  if (width <= 0 || height <= 0) return null;
  return Rect.fromLTWH(x, y, width, height);
}

double? _numToDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

@immutable
class AppWindowState {
  const AppWindowState({
    this.translationDefaultLabel = '需配置',
    this.asrDefaultLabel = '本机',
    this.translationConfigured = true,
    this.asrConfigured = true,
  });

  final String translationDefaultLabel;
  final String asrDefaultLabel;
  final bool translationConfigured;
  final bool asrConfigured;

  AppWindowState copyWith({
    String? translationDefaultLabel,
    String? asrDefaultLabel,
    bool? translationConfigured,
    bool? asrConfigured,
  }) {
    return AppWindowState(
      translationDefaultLabel:
          translationDefaultLabel ?? this.translationDefaultLabel,
      asrDefaultLabel: asrDefaultLabel ?? this.asrDefaultLabel,
      translationConfigured:
          translationConfigured ?? this.translationConfigured,
      asrConfigured: asrConfigured ?? this.asrConfigured,
    );
  }

  Map<String, Object?> toJson() => {
    'translationDefaultLabel': translationDefaultLabel,
    'asrDefaultLabel': asrDefaultLabel,
    'translationConfigured': translationConfigured,
    'asrConfigured': asrConfigured,
  };

  static AppWindowState fromJson(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    return AppWindowState(
      translationDefaultLabel:
          map['translationDefaultLabel'] as String? ?? '需配置',
      asrDefaultLabel: map['asrDefaultLabel'] as String? ?? '本机',
      translationConfigured: map['translationConfigured'] as bool? ?? true,
      asrConfigured: map['asrConfigured'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppWindowState &&
        other.translationDefaultLabel == translationDefaultLabel &&
        other.asrDefaultLabel == asrDefaultLabel &&
        other.translationConfigured == translationConfigured &&
        other.asrConfigured == asrConfigured;
  }

  @override
  int get hashCode => Object.hash(
    translationDefaultLabel,
    asrDefaultLabel,
    translationConfigured,
    asrConfigured,
  );
}

class WindowStateStore extends ChangeNotifier {
  WindowStateStore([AppWindowState? initial])
    : _value = initial ?? const AppWindowState();

  AppWindowState _value;

  AppWindowState get value => _value;

  void replace(AppWindowState next) {
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  void setTranslationDefault(String label, {required bool configured}) {
    replace(
      _value.copyWith(
        translationDefaultLabel: label,
        translationConfigured: configured,
      ),
    );
  }

  void setAsrDefault(String label, {required bool configured}) {
    replace(_value.copyWith(asrDefaultLabel: label, asrConfigured: configured));
  }
}
