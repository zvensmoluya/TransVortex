import '../../model/task_labels.dart';

part 'models/service_models.dart';
part 'models/config_models.dart';
part 'models/asr_models.dart';
part 'models/task_models.dart';
part 'models/result_models.dart';

Map<String, Object?> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

List<Object?> _objectList(Object? value) {
  if (value is List) return value;
  return const <Object?>[];
}

List<TaskSummary> parseTaskSummaries(Object? value) {
  return _objectList(
    value,
  ).map(TaskSummary.fromJson).where((task) => task.taskId.isNotEmpty).toList();
}

List<String> _stringList(Object? value) {
  return _objectList(value).map((item) => '$item').toList();
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

int? _nonNegativeInt(Object? value) {
  final parsed = _intValue(value);
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

double? _nonNegativeFiniteDouble(Object? value) {
  final parsed = _numValue(value)?.toDouble();
  if (parsed == null || !parsed.isFinite || parsed < 0) return null;
  return parsed;
}

int _sumNumericLeaves(Object? value) {
  final direct = _intValue(value);
  if (direct != null) return direct < 0 ? 0 : direct;
  if (value is Map) {
    return value.values.fold<int>(
      0,
      (total, item) => total + _sumNumericLeaves(item),
    );
  }
  if (value is Iterable) {
    return value.fold<int>(0, (total, item) => total + _sumNumericLeaves(item));
  }
  return 0;
}

num? _numValue(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

String _normalizeInputType(String? value) {
  final raw = (value ?? '').trim();
  if (raw == 'srt' || raw == 'srt_translate') return 'srt_translate';
  if (raw == 'segments' || raw == 'segments_translate') {
    return 'segments_translate';
  }
  if (raw == 'video_asr' || raw == 'video_asr_translate') return raw;
  return '';
}

String _pathBasename(String path) {
  if (path.trim().isEmpty) return '';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String _formatTimestamp(double seconds) {
  final safeSeconds = seconds.isFinite ? seconds.clamp(0, double.infinity) : 0;
  final millis = (safeSeconds * 1000).round();
  final duration = Duration(milliseconds: millis);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final ms = duration.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$secs.$ms';
  }
  return '$minutes:$secs.$ms';
}
