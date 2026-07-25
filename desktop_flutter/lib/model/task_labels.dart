import 'task_failure_presentation.dart';

export 'task_failure_presentation.dart';

String taskStatusLabel(String status, {String fallback = ''}) {
  final raw = status.trim();
  final label = switch (raw.toUpperCase()) {
    'INIT' => '等待中',
    'QUEUED' => '等待中',
    'PRECHECK' => '检查环境',
    'INGEST' => '读取片源',
    'ASR' => '识别语音',
    'MEMORY' => '准备术语',
    'SEGMENT' => '整理片段',
    'TRANSLATE' => '翻译字幕',
    'ALIGN' => '对齐字幕',
    'QUALITY' => '检查质量',
    'EXPORT' => '写出字幕',
    'RUNNING' => '制作中',
    'CANCEL_REQUESTED' => '正在取消',
    'DONE' => '已完成',
    'FAILED' => '失败',
    'CANCELLED' => '已取消',
    'INTERRUPTED' => '已中断',
    _ => '',
  };
  if (label.isNotEmpty) return label;
  final trimmedFallback = fallback.trim();
  return trimmedFallback.isNotEmpty ? trimmedFallback : raw;
}

String taskEventTypeLabel(String type) {
  final raw = type.trim();
  final lower = raw.toLowerCase();
  if (lower == 'task_created' || lower == 'created') return '创建';
  if (lower == 'resume_requested') return '继续';
  if (lower == 'done' || lower == 'complete' || lower == 'completed') {
    return '完成';
  }
  if (lower == 'error' || lower == 'failed' || lower == 'failure') {
    return '失败';
  }
  if (lower == 'stage') return '阶段';
  if (lower == 'progress') return '进度';
  if (lower == 'provider_attempt') return '模型请求';
  if (lower == 'provider_response') return '模型返回';
  return taskStatusLabel(raw, fallback: raw.isEmpty ? '事件' : raw);
}

String taskStageLabel(String stage) {
  final raw = stage.trim();
  final status = taskStatusLabel(raw);
  if (status != raw || raw.isEmpty) return status;
  final lower = raw.toLowerCase();
  if (lower == 'init' || lower == 'initializing') return '等待中';
  if (lower.contains('asr') ||
      lower.contains('whisper') ||
      lower.contains('transcrib')) {
    return '识别语音';
  }
  if (lower.contains('memory') || lower.contains('术语')) return '准备术语';
  if (lower.contains('translat')) return '翻译字幕';
  if (lower.contains('subtitle') || lower.contains('render')) return '整理字幕';
  if (lower.contains('export') || lower.contains('write')) return '写出字幕';
  return raw;
}

String taskEventMessageLabel({
  String type = '',
  String stage = '',
  String status = '',
  String message = '',
}) {
  final normalized = [
    type,
    stage,
    status,
    message,
  ].where((item) => item.trim().isNotEmpty).join(' ').toLowerCase();
  if (normalized.isEmpty) return '任务事件已记录';
  if (type.trim().toLowerCase() == 'provider_response') {
    return '模型返回已接收';
  }
  if (normalized.contains('resume')) return '已请求继续任务';
  if (normalized.contains('created') || normalized.contains('queued')) {
    return '任务已创建，等待调度';
  }
  if (normalized.contains('asr') ||
      normalized.contains('whisper') ||
      normalized.contains('transcrib')) {
    return '正在识别语音';
  }
  if (normalized.contains('memory') || normalized.contains('术语')) {
    return '正在准备术语';
  }
  if (normalized.contains('translat')) return '正在翻译字幕';
  if (normalized.contains('subtitle') || normalized.contains('render')) {
    return '正在整理字幕';
  }
  if (normalized.contains('export') || normalized.contains('write')) {
    return '正在写出字幕文件';
  }
  if (normalized.contains('failed') || normalized.contains('error')) {
    return '任务失败，等待处理';
  }
  if (normalized.contains('done') || normalized.contains('complete')) {
    return '字幕已生成';
  }
  final trimmed = message.trim();
  return trimmed.isEmpty || looksInternalTaskEventMessage(trimmed)
      ? taskEventTypeLabel(type)
      : trimmed;
}

bool looksInternalTaskEventMessage(String value) {
  final lower = value.trim().toLowerCase();
  return lower == 'task created' ||
      lower == 'task queued' ||
      lower == 'task done' ||
      lower == 'task failed' ||
      lower == 'task completed' ||
      lower == 'resume requested' ||
      lower.startsWith('task ');
}

String taskErrorLabel(String? error, Map<String, Object?> errorInfo) {
  return taskFailurePresentation(error: error, errorInfo: errorInfo).reason;
}

String taskTimestampLabel(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  return '${_pad4(local.year)}-${_pad2(local.month)}-${_pad2(local.day)} '
      '${_pad2(local.hour)}:${_pad2(local.minute)}:${_pad2(local.second)}';
}

String shortTaskIdLabel(String taskId) {
  final raw = taskId.trim();
  if (raw.length <= 14) return raw;
  return '${raw.substring(0, 8)}…${raw.substring(raw.length - 6)}';
}

String subtitleFormatLabel(String format) {
  final raw = format.trim();
  final lower = raw.toLowerCase();
  return switch (lower) {
    'srt' => 'SRT',
    'ass' => 'ASS',
    'vtt' => 'VTT',
    'lrc' => 'LRC',
    'both' => 'SRT+ASS',
    _ => raw.isEmpty ? '未知' : raw.toUpperCase(),
  };
}

String subtitleFormatListLabel(Iterable<String> formats) {
  final labels = formats
      .map(subtitleFormatLabel)
      .where((label) => label.trim().isNotEmpty)
      .toList();
  return labels.isEmpty ? '' : labels.join(' · ');
}

String languageLabel(String code) {
  final raw = code.trim();
  if (raw.isEmpty) return '未知语言';
  final normalized = raw.toLowerCase().replaceAll('_', '-');
  return switch (normalized) {
    'auto' || 'detect' || 'auto-detect' => '自动识别',
    'zh' || 'zh-cn' || 'zh-hans' || 'cmn-hans' => '简体中文',
    'zh-tw' || 'zh-hk' || 'zh-hant' || 'cmn-hant' => '繁体中文',
    'en' => '英语',
    'en-us' => '英语（美国）',
    'en-gb' => '英语（英国）',
    'ja' || 'jp' => '日语',
    'ko' || 'kr' => '韩语',
    'fr' => '法语',
    'de' => '德语',
    'es' => '西班牙语',
    'it' => '意大利语',
    'pt' => '葡萄牙语',
    'ru' => '俄语',
    _ => raw,
  };
}

String whisperModelLabel(String modelId, {bool includeEngine = true}) {
  final normalized = modelId.trim();
  final model = normalized.startsWith('custom-')
      ? '自定义 Whisper'
      : switch (normalized) {
          'small' => 'Small',
          'medium' => 'Medium',
          'large-v3' => 'Large v3',
          _ => normalized,
        };
  if (!includeEngine || model.isEmpty || model == '自定义 Whisper') {
    return model;
  }
  return 'Whisper $model';
}

String fileTooltipLabel(String path, {String fallbackName = ''}) {
  final trimmedPath = path.trim();
  final name = fallbackName.trim().isNotEmpty
      ? fallbackName.trim()
      : _pathBasename(trimmedPath);
  final parent = _pathParent(trimmedPath);
  final lines = <String>[
    if (name.isNotEmpty) '文件：$name',
    if (parent.isNotEmpty) '位置：${compactMiddleLabel(parent, maxLength: 48)}',
  ];
  if (lines.isEmpty) return '文件';
  return lines.join('\n');
}

String compactMiddleLabel(String value, {int maxLength = 64}) {
  final text = value.trim();
  if (text.length <= maxLength || maxLength < 8) return text;
  final left = ((maxLength - 1) / 2).floor();
  final right = maxLength - left - 1;
  return '${text.substring(0, left)}…${text.substring(text.length - right)}';
}

String taskProgressLabel(Object? progress) {
  if (progress is num) {
    final percent = progress <= 1 ? progress * 100 : progress;
    return '${percent.clamp(0, 100).round()}%';
  }
  final text = '$progress'.trim();
  if (text.isEmpty || text == 'null') return '';
  final parsed = num.tryParse(text);
  if (parsed == null) return text;
  final percent = parsed <= 1 ? parsed * 100 : parsed;
  return '${percent.clamp(0, 100).round()}%';
}

String _pad2(int value) => value.toString().padLeft(2, '0');

String _pad4(int value) => value.toString().padLeft(4, '0');

String _pathBasename(String path) {
  if (path.isEmpty) return '';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String _pathParent(String path) {
  if (path.isEmpty) return '';
  final lastSlash = path.lastIndexOf(RegExp(r'[\\/]'));
  if (lastSlash <= 0) return '';
  return path.substring(0, lastSlash);
}
