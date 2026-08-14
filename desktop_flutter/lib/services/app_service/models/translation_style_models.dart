part of '../models.dart';

class TranslationStyleSummary {
  const TranslationStyleSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.revision,
    required this.builtin,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final int revision;
  final bool builtin;
  final String updatedAt;

  factory TranslationStyleSummary.fromJson(Object? value) {
    final map = _stringMap(value);
    return TranslationStyleSummary(
      id: _stringValue(map['id']) ?? '',
      name: _stringValue(map['name']) ?? '',
      description: _stringValue(map['description']) ?? '',
      revision: _intValue(map['revision']) ?? 1,
      builtin: map['builtin'] == true,
      updatedAt:
          _stringValue(map['updated_at']) ??
          _stringValue(map['updatedAt']) ??
          '',
    );
  }
}

class TranslationStyleDetail {
  const TranslationStyleDetail({required this.summary, required this.prompt});

  final TranslationStyleSummary summary;
  final String prompt;

  factory TranslationStyleDetail.fromJson(Object? value) {
    final outer = _stringMap(value);
    final map = _stringMap(outer['style']).isNotEmpty
        ? _stringMap(outer['style'])
        : outer;
    return TranslationStyleDetail(
      summary: TranslationStyleSummary.fromJson(map),
      prompt: _stringValue(map['prompt']) ?? '',
    );
  }
}
