part of '../models.dart';

class TaskResultWorkspace {
  const TaskResultWorkspace({
    required this.task,
    required this.segments,
    required this.outputPaths,
    required this.quality,
    required this.delivery,
    required this.reflow,
    required this.memory,
    required this.raw,
  });

  final TaskSummary task;
  final List<ResultSegment> segments;
  final Map<String, String> outputPaths;
  final Map<String, Object?> quality;
  final Map<String, Object?> delivery;
  final Map<String, Object?> reflow;
  final Map<String, Object?> memory;
  final Map<String, Object?> raw;

  factory TaskResultWorkspace.fromJson(Object? value) {
    final map = _stringMap(value);
    final outputPaths = _stringMap(
      map['output_paths'],
    ).map((key, value) => MapEntry(key, '$value'));
    return TaskResultWorkspace(
      task: TaskSummary.fromJson(map['task']),
      segments: _objectList(map['segments'])
          .map(ResultSegment.fromJson)
          .where((segment) => segment.id >= 0)
          .toList(),
      outputPaths: outputPaths,
      quality: _stringMap(map['quality']),
      delivery: _stringMap(map['delivery']),
      reflow: _stringMap(map['reflow']),
      memory: _stringMap(map['memory']),
      raw: map,
    );
  }

  bool get hasSegments => segments.isNotEmpty;

  int get issueCount {
    return segments.fold<int>(
      0,
      (total, segment) => total + segment.issueCount,
    );
  }
}

class ResultSegment {
  const ResultSegment({
    required this.id,
    required this.start,
    required this.end,
    required this.sourceText,
    required this.targetText,
    required this.provider,
    required this.model,
    required this.compatMode,
    required this.chunkId,
    required this.issues,
    required this.qualityIssues,
    required this.raw,
  });

  final int id;
  final double start;
  final double end;
  final String sourceText;
  final String targetText;
  final String provider;
  final String model;
  final String compatMode;
  final String chunkId;
  final List<String> issues;
  final List<Map<String, Object?>> qualityIssues;
  final Map<String, Object?> raw;

  factory ResultSegment.fromJson(Object? value) {
    final map = _stringMap(value);
    return ResultSegment(
      id: _intValue(map['id']) ?? -1,
      start: _numValue(map['start'])?.toDouble() ?? 0,
      end: _numValue(map['end'])?.toDouble() ?? 0,
      sourceText:
          _stringValue(map['text_src']) ??
          _stringValue(map['sourceText']) ??
          '',
      targetText:
          _stringValue(map['text_tgt']) ??
          _stringValue(map['targetText']) ??
          '',
      provider: _stringValue(map['provider']) ?? '',
      model: _stringValue(map['model']) ?? '',
      compatMode: _stringValue(map['compat_mode']) ?? '',
      chunkId: _stringValue(map['chunk_id']) ?? '',
      issues: _stringList(map['issues']),
      qualityIssues: _objectList(
        map['quality_issues'],
      ).map(_stringMap).where((issue) => issue.isNotEmpty).toList(),
      raw: map,
    );
  }

  String get timeRangeLabel {
    return '${_formatTimestamp(start)} - ${_formatTimestamp(end)}';
  }

  int get issueCount {
    final keys = <String>{};
    for (final issue in issues) {
      final key = _resultIssueKey(issue);
      if (key.isNotEmpty) keys.add(key);
    }
    for (final issue in qualityIssues) {
      final code = _stringValue(issue['code']);
      final message = _stringValue(issue['message']);
      final key = _resultIssueKey(code ?? message ?? 'quality_issue');
      if (key.isNotEmpty) keys.add(key);
    }
    return keys.length;
  }
}

String _resultIssueKey(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) return '';
  if (normalized == 'cps_high' ||
      normalized == 'cps_too_high' ||
      normalized.contains('阅读速度')) {
    return 'cps_too_high';
  }
  if (normalized == 'empty_target' || normalized.contains('译文为空')) {
    return 'empty_target';
  }
  if (normalized == 'timeline_overlap' || normalized.contains('时间轴与上一条重叠')) {
    return 'timeline_overlap';
  }
  if (normalized == 'invalid_timing' || normalized.contains('结束时间早于')) {
    return 'invalid_timing';
  }
  if (normalized == 'too_many_lines' || normalized.contains('行数过多')) {
    return 'too_many_lines';
  }
  if (normalized == 'line_too_wide' ||
      normalized == 'line_too_long' ||
      normalized.contains('单行过长')) {
    return 'line_too_wide';
  }
  return normalized;
}
