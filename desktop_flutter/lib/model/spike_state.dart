import 'dart:convert';

import 'package:flutter/foundation.dart';

enum SpikeWindowType { main, translationSettings, asrSettings }

extension SpikeWindowTypeLabel on SpikeWindowType {
  String get id => switch (this) {
    SpikeWindowType.main => 'main',
    SpikeWindowType.translationSettings => 'translationSettings',
    SpikeWindowType.asrSettings => 'asrSettings',
  };

  String get title => switch (this) {
    SpikeWindowType.main => 'TransVortex',
    SpikeWindowType.translationSettings => '翻译模型设置',
    SpikeWindowType.asrSettings => '语音识别设置',
  };

  static SpikeWindowType fromId(String? id) => switch (id) {
    'translationSettings' => SpikeWindowType.translationSettings,
    'asrSettings' => SpikeWindowType.asrSettings,
    _ => SpikeWindowType.main,
  };
}

@immutable
class SpikeWindowArgs {
  const SpikeWindowArgs({required this.type});

  final SpikeWindowType type;

  String encode() => jsonEncode({'type': type.id});

  static SpikeWindowArgs parse(String raw) {
    if (raw.trim().isEmpty) {
      return const SpikeWindowArgs(type: SpikeWindowType.main);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return SpikeWindowArgs(
          type: SpikeWindowTypeLabel.fromId(decoded['type'] as String?),
        );
      }
    } catch (_) {
      // Fall through to main; malformed window args should not block startup.
    }
    return const SpikeWindowArgs(type: SpikeWindowType.main);
  }
}

@immutable
class AppSpikeState {
  const AppSpikeState({
    this.translationDefaultLabel = '需配置',
    this.asrDefaultLabel = '本机',
    this.translationConfigured = true,
    this.asrConfigured = true,
  });

  final String translationDefaultLabel;
  final String asrDefaultLabel;
  final bool translationConfigured;
  final bool asrConfigured;

  AppSpikeState copyWith({
    String? translationDefaultLabel,
    String? asrDefaultLabel,
    bool? translationConfigured,
    bool? asrConfigured,
  }) {
    return AppSpikeState(
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

  static AppSpikeState fromJson(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    return AppSpikeState(
      translationDefaultLabel:
          map['translationDefaultLabel'] as String? ?? '需配置',
      asrDefaultLabel: map['asrDefaultLabel'] as String? ?? '本机',
      translationConfigured: map['translationConfigured'] as bool? ?? true,
      asrConfigured: map['asrConfigured'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppSpikeState &&
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
  WindowStateStore([AppSpikeState? initial])
    : _value = initial ?? const AppSpikeState();

  AppSpikeState _value;

  AppSpikeState get value => _value;

  void replace(AppSpikeState next) {
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
    replace(
      _value.copyWith(asrDefaultLabel: label, asrConfigured: configured),
    );
  }
}
