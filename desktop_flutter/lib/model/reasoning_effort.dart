import 'package:flutter/foundation.dart';

import '../services/app_service_client.dart';

const reasoningEffortAuto = 'auto';
const reasoningEffortServiceDefault = 'service_default';

const _knownReasoningEfforts = <String>{
  reasoningEffortAuto,
  reasoningEffortServiceDefault,
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
};

@immutable
class ReasoningEffortChoice {
  const ReasoningEffortChoice({required this.value, required this.label});

  final String value;
  final String label;
}

@immutable
class ReasoningEffortSupport {
  const ReasoningEffortSupport({
    required this.supported,
    required this.automaticEffort,
    required this.currentValue,
    required this.choices,
  });

  const ReasoningEffortSupport.unsupported()
    : supported = false,
      automaticEffort = '',
      currentValue = reasoningEffortAuto,
      choices = const <ReasoningEffortChoice>[];

  final bool supported;
  final String automaticEffort;
  final String currentValue;
  final List<ReasoningEffortChoice> choices;

  List<ReasoningEffortChoice> get manualChoices => choices
      .where(
        (choice) =>
            choice.value != reasoningEffortAuto &&
            choice.value != reasoningEffortServiceDefault,
      )
      .toList(growable: false);

  String get effectiveManualValue {
    final manual = manualChoices;
    if (manual.isEmpty) return '';
    if (manual.any((choice) => choice.value == currentValue)) {
      return currentValue;
    }
    final automatic = automaticEffort.trim().isEmpty
        ? ''
        : normalizeReasoningEffort(automaticEffort);
    if (manual.any((choice) => choice.value == automatic)) {
      return automatic;
    }
    return manual.first.value;
  }

  String get compactLabel {
    if (currentValue == reasoningEffortAuto && automaticEffort.isNotEmpty) {
      return '自动 · ${reasoningEffortLabel(automaticEffort)}';
    }
    return reasoningEffortLabel(currentValue);
  }

  String get displayLabel {
    if (currentValue == reasoningEffortAuto && automaticEffort.isNotEmpty) {
      return reasoningEffortLabel(automaticEffort);
    }
    return reasoningEffortLabel(currentValue);
  }

  String get detailLabel {
    if (currentValue == reasoningEffortAuto && automaticEffort.isNotEmpty) {
      return '自动（当前：${reasoningEffortLabel(automaticEffort)}）';
    }
    return reasoningEffortLabel(currentValue);
  }
}

String normalizeReasoningEffort(Object? value) {
  final normalized = '$value'.trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'null') return reasoningEffortAuto;
  return _knownReasoningEfforts.contains(normalized)
      ? normalized
      : reasoningEffortAuto;
}

String reasoningEffortLabel(String value) {
  return switch (normalizeReasoningEffort(value)) {
    reasoningEffortAuto => '自动',
    reasoningEffortServiceDefault => '由服务决定',
    'none' => '关闭',
    'minimal' => '最低',
    'low' => '低',
    'medium' => '中',
    'high' => '高',
    'xhigh' => '极高',
    'max' => '最大',
    _ => value,
  };
}

ReasoningEffortSupport reasoningEffortSupportFor(
  DesktopSnapshot? snapshot, {
  required String providerName,
  required String model,
  Object? currentValue,
}) {
  final current = normalizeReasoningEffort(currentValue);
  final provider = _providerFor(snapshot, providerName);
  final catalog = _catalogFor(snapshot, model);
  final configured =
      provider?.modelConfigs[model]?.reasoningEffort.trim() ?? '';
  final catalogDefault = catalog?.runtime.reasoningEffort.trim() ?? '';
  final mappedDefault = _mappedReasoningEffort(provider);
  final automatic = configured.isNotEmpty
      ? configured
      : catalogDefault.isNotEmpty
      ? catalogDefault
      : mappedDefault;

  final catalogEfforts = catalog?.reasoningEfforts ?? const <String>[];
  final capabilityEfforts = _stringList(
    provider?.capabilities['reasoning_efforts'] ??
        provider?.capabilities['reasoningEfforts'],
  );
  final efforts = catalog == null ? capabilityEfforts : catalogEfforts;
  final parameter =
      '${provider?.capabilities['reasoning_effort_param'] ?? provider?.capabilities['reasoningEffortParam'] ?? ''}'
          .trim();
  final supported = catalog == null
      ? parameter.isNotEmpty || efforts.isNotEmpty || automatic.isNotEmpty
      : efforts.isNotEmpty;
  return buildReasoningEffortSupport(
    currentValue: current,
    automaticEffort: automatic,
    efforts: efforts,
    supported: supported,
  );
}

ReasoningEffortSupport buildReasoningEffortSupport({
  required Object? currentValue,
  required String automaticEffort,
  required Iterable<String> efforts,
  required bool supported,
}) {
  final current = normalizeReasoningEffort(currentValue);
  final automatic = automaticEffort.trim().isEmpty
      ? ''
      : normalizeReasoningEffort(automaticEffort);
  final values = <String>[
    reasoningEffortAuto,
    reasoningEffortServiceDefault,
    ...efforts,
    if (automatic.isNotEmpty &&
        automatic != reasoningEffortAuto &&
        automatic != reasoningEffortServiceDefault)
      automatic,
    if (current != reasoningEffortAuto &&
        current != reasoningEffortServiceDefault)
      current,
  ];
  final seen = <String>{};
  final normalizedValues = values
      .map(normalizeReasoningEffort)
      .where(seen.add)
      .toList(growable: false);
  return ReasoningEffortSupport(
    supported: supported,
    automaticEffort: automatic,
    currentValue: current,
    choices: [
      for (final value in normalizedValues)
        ReasoningEffortChoice(
          value: value,
          label: value == reasoningEffortAuto && automatic.isNotEmpty
              ? '自动（当前：${reasoningEffortLabel(automatic)}）'
              : reasoningEffortLabel(value),
        ),
    ],
  );
}

ProviderOption? _providerFor(DesktopSnapshot? snapshot, String name) {
  if (snapshot == null) return null;
  for (final provider in snapshot.providers) {
    if (provider.name == name) return provider;
  }
  return null;
}

ModelCatalogOption? _catalogFor(DesktopSnapshot? snapshot, String model) {
  if (snapshot == null) return null;
  for (final entry in snapshot.modelCatalog) {
    if (entry.matches(model)) return entry;
  }
  return null;
}

String _mappedReasoningEffort(ProviderOption? provider) {
  if (provider == null) return '';
  final mapping = _map(
    provider.raw['request_mapping'] ?? provider.raw['requestMapping'],
  );
  final overrides = _map(mapping['body_overrides'] ?? mapping['bodyOverrides']);
  final direct = '${overrides['reasoning_effort'] ?? ''}'.trim();
  if (direct.isNotEmpty) return direct;
  return '${_map(overrides['reasoning'])['effort'] ?? ''}'.trim();
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return value.map((key, item) => MapEntry('$key', item));
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .map((item) => '$item'.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
