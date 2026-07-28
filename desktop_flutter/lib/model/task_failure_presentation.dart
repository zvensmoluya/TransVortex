enum TaskFailureRecoveryTarget {
  none,
  retry,
  resume,
  translationSettings,
  asrSettings,
  pickSource,
  outputDirectory,
  reexport,
  taskDetails,
}

class TaskFailurePresentation {
  const TaskFailurePresentation({
    required this.reason,
    required this.actionLabel,
    required this.target,
  });

  final String reason;
  final String actionLabel;
  final TaskFailureRecoveryTarget target;

  bool get hasAction => target != TaskFailureRecoveryTarget.none;
}

TaskFailurePresentation taskFailurePresentation({
  String? error,
  Map<String, Object?> errorInfo = const {},
  bool canResume = false,
}) {
  final code = _firstText(errorInfo, const ['code', 'error_code', 'kind']);
  final stage = _firstText(errorInfo, const [
    'stage',
    'failed_stage',
    'last_stage',
  ]);
  final retryable = _firstBool(errorInfo, const [
    'retryable',
    'recoverable',
    'can_retry',
  ]);
  final target = _recoveryTarget(
    code: code,
    stage: stage,
    retryable: retryable,
    canResume: canResume,
  );
  final hint = _firstText(errorInfo, const ['hint_zh', 'hint']);
  return TaskFailurePresentation(
    reason: _failureReason(
      code: code,
      stage: stage,
      hint: hint,
      error: error ?? '',
      target: target,
    ),
    actionLabel: _actionLabel(target),
    target: target,
  );
}

TaskFailureRecoveryTarget _recoveryTarget({
  required String code,
  required String stage,
  required bool retryable,
  required bool canResume,
}) {
  final lowerCode = code.toLowerCase();
  final lowerStage = stage.toLowerCase();
  final asrContext =
      lowerStage == 'asr' ||
      lowerCode.contains('asr') ||
      lowerCode.contains('whisper') ||
      lowerCode.contains('transcription');
  final transient =
      retryable ||
      const {
        'connection',
        'gateway',
        'network',
        'rate_limit',
        'retryable',
        'service_unavailable',
        'timeout',
        'upstream',
        'payload_too_large',
      }.any(lowerCode.contains);

  if (lowerCode == 'task_cancelled') {
    return TaskFailureRecoveryTarget.none;
  }
  if (lowerCode.contains('permission') ||
      lowerCode.contains('output') ||
      lowerCode.contains('writable')) {
    return TaskFailureRecoveryTarget.outputDirectory;
  }
  if (lowerCode.contains('result') ||
      lowerCode.contains('export') ||
      lowerCode.contains('moved') ||
      lowerCode.contains('deleted')) {
    return TaskFailureRecoveryTarget.reexport;
  }
  if (const {
    'input_not_found',
    'invalid_request',
    'media_processing_failed',
    'no_segments',
    'task_not_found',
  }.contains(lowerCode)) {
    return TaskFailureRecoveryTarget.pickSource;
  }
  if (lowerCode == 'missing_executable') {
    return TaskFailureRecoveryTarget.taskDetails;
  }

  if (asrContext) {
    if (canResume && transient) return TaskFailureRecoveryTarget.resume;
    if (transient) return TaskFailureRecoveryTarget.retry;
    return TaskFailureRecoveryTarget.asrSettings;
  }

  if (_isTranslationConfigurationFailure(lowerCode)) {
    return TaskFailureRecoveryTarget.translationSettings;
  }
  if (canResume || lowerCode.contains('interrupt')) {
    return TaskFailureRecoveryTarget.resume;
  }
  return TaskFailureRecoveryTarget.retry;
}

bool _isTranslationConfigurationFailure(String code) {
  if (code.contains('routing') ||
      code.contains('credential') ||
      code.contains('missing_env') ||
      code.contains('env_key') ||
      code.contains('api_key')) {
    return true;
  }
  if (!code.contains('provider')) return false;
  final transient = const {
    'connection',
    'gateway',
    'network',
    'rate_limit',
    'retryable',
    'service_unavailable',
    'timeout',
    'upstream',
  }.any(code.contains);
  if (transient) return false;
  return true;
}

String _failureReason({
  required String code,
  required String stage,
  required String hint,
  required String error,
  required TaskFailureRecoveryTarget target,
}) {
  final lowerCode = code.toLowerCase();
  final asrContext =
      stage.toLowerCase() == 'asr' ||
      lowerCode.contains('asr') ||
      lowerCode.contains('whisper');
  switch (lowerCode) {
    case 'task_cancelled':
      return '任务已取消。';
    case 'missing_env':
      return asrContext
          ? '语音识别凭据还没有配置，请在识别设置中补充后再继续。'
          : '翻译模型凭据还没有配置，请在翻译设置中补充后再继续。';
    case 'missing_asr_dependency':
      return '本机识别组件还没有准备好，请在识别设置中完成安装或选择其他方案。';
    case 'openrouter_asr_timestamps_missing':
      return 'OpenRouter 上游只返回了转写文本，没有返回所选模型制作字幕所需的分段或词级时间轴。可以重试；持续失败时请切换模型。';
    case 'unsupported_openrouter_asr_model':
      return '这个 OpenRouter 识别模型尚未完成专项适配，请选择已支持的模型。';
    case 'provider_payment_required':
      return '模型服务账户余额不足，请充值或更换可用凭据。';
    case 'provider_auth_error':
      return asrContext
          ? '语音识别凭据无效或没有调用权限，请检查识别设置。'
          : '翻译模型凭据无效或没有调用权限，请检查翻译设置。';
    case 'provider_rate_limit':
      return '模型服务正在限流，请稍后重试。';
    case 'provider_request_rejected':
      return asrContext
          ? '识别服务不接受当前模型的专项请求，请检查识别设置。'
          : '翻译服务不接受当前模型请求，请检查翻译设置。';
    case 'provider_payload_too_large':
      return '上传内容超过模型服务限制，请减小任务分片后重试。';
    case 'provider_content_policy_violation':
      return '模型服务因账户或内容策略拒绝了本次请求。';
    case 'missing_executable':
      return '应用所需的媒体组件不可用，请查看任务线索并修复或重新安装 TransVortex。';
    case 'input_not_found':
      return '原片源已被移动或删除，请重新选择文件。';
    case 'invalid_request':
      return '本次任务参数无法提交，请重新选择片源并确认制作设置。';
    case 'task_not_found':
      return '这条任务记录已经不存在，请重新选择片源开始制作。';
    case 'no_segments':
      return '没有读到可用字幕，请确认片源确实包含字幕或声音，或换一个文件。';
    case 'media_processing_failed':
      return '片源无法正常读取，请确认文件可以播放，或换一个文件重试。';
    case 'artifact_missing':
      return '任务中间文件不完整，可以从已有检查点继续重建。';
    case 'runtime_error':
      return '任务运行失败，可以先重试；如果仍失败，请在任务处理中查看失败线索。';
  }

  final candidate = hint.trim().isNotEmpty ? hint.trim() : error.trim();
  if (candidate.isNotEmpty && !_looksInternal(candidate)) {
    return candidate.replaceAll(
      RegExp('provider', caseSensitive: false),
      '翻译服务',
    );
  }
  return switch (target) {
    TaskFailureRecoveryTarget.translationSettings =>
      '翻译连接还没有准备好，请检查服务地址、模型和凭据。',
    TaskFailureRecoveryTarget.asrSettings => '语音识别方案还没有准备好，请打开识别设置检查。',
    TaskFailureRecoveryTarget.pickSource => '当前片源无法继续处理，请重新选择文件。',
    TaskFailureRecoveryTarget.outputDirectory => '当前输出位置不可用，请选择一个可写目录。',
    TaskFailureRecoveryTarget.reexport => '字幕结果需要重新写出。',
    TaskFailureRecoveryTarget.resume => '任务在中途停住了，可以从已有进度继续。',
    TaskFailureRecoveryTarget.taskDetails => '这次制作需要进一步处理，请查看任务中的失败线索。',
    TaskFailureRecoveryTarget.retry => '制作在这里停住了，可以重试一次。',
    TaskFailureRecoveryTarget.none => '任务失败，等待处理。',
  };
}

String _actionLabel(TaskFailureRecoveryTarget target) => switch (target) {
  TaskFailureRecoveryTarget.none => '',
  TaskFailureRecoveryTarget.retry => '重试',
  TaskFailureRecoveryTarget.resume => '继续任务',
  TaskFailureRecoveryTarget.translationSettings => '检查翻译设置',
  TaskFailureRecoveryTarget.asrSettings => '检查识别设置',
  TaskFailureRecoveryTarget.pickSource => '重新选择片源',
  TaskFailureRecoveryTarget.outputDirectory => '选择输出目录',
  TaskFailureRecoveryTarget.reexport => '重新导出',
  TaskFailureRecoveryTarget.taskDetails => '查看失败线索',
};

bool _looksInternal(String value) {
  final lower = value.toLowerCase();
  if (!RegExp(r'[\u3400-\u9fff]').hasMatch(value)) return true;
  return const {
    '.env',
    '--input',
    '--provider',
    'bad state',
    'credential_id',
    'diagnostic',
    'doctor',
    'env_key',
    'exception',
    'events.json',
    'faster-whisper',
    'methodchannel',
    'platformexception',
    'python',
    'rpc',
    'segments file',
    'stack trace',
    'stderr',
    'task_id',
  }.any(lower.contains);
}

String _firstText(Map<String, Object?> values, List<String> keys) {
  for (final key in keys) {
    final value = values[key];
    if (value == null) continue;
    final text = '$value'.trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

bool _firstBool(Map<String, Object?> values, List<String> keys) {
  for (final key in keys) {
    final value = values[key];
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
  }
  return false;
}
