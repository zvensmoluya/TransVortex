import 'package:flutter/foundation.dart';

/// 主窗口六态（design spec §8 状态矩阵）。
/// 全部就地落在「主体 + job 描述 + 主动作」一条竖轴上。
enum MainState { empty, ready, blocked, running, completed, failed }

/// 片源类型签（§4.2）。
enum SourceKind { video, audio, subtitle }

extension SourceKindLabel on SourceKind {
  String get zh => switch (this) {
    SourceKind.video => '视频',
    SourceKind.audio => '音频',
    SourceKind.subtitle => '字幕',
  };
}

/// 一次任务的会话状态。不可变，转移时整体替换，便于推断「态」。
@immutable
class Session {
  const Session({
    this.fileName,
    this.filePath,
    this.kind,
    this.sourceLang = 'en',
    this.targetLang = 'zh-CN',
    this.translateConfigured = true,
    this.asrConfigured = true,
    this.engineTranslate = 'Opus',
    this.engineRecognize = '本机',
    this.bilingual = true,
    this.formats = const ['SRT', 'ASS'],
    this.termsEnabled = true,
    this.taskId,
    this.statusText,
    this.running = false,
    this.canceling = false,
    this.progress = 0.0,
    this.completed = false,
    this.outputPaths = const {},
    this.failure,
  });

  /// 片源（null = 空态）。
  final String? fileName;
  final String? filePath;
  final SourceKind? kind;
  final String sourceLang;
  final String targetLang;

  /// 准备配置是否就绪（false 且有片源 → 受阻态，对应 spec「翻译需配置」）。
  final bool translateConfigured;
  final bool asrConfigured;

  // 任务配置（§4.3 两行可点词）。
  final String engineTranslate;
  final String engineRecognize;
  final bool bilingual;
  final List<String> formats;
  final bool termsEnabled;

  // 运行期。
  final String? taskId;
  final String? statusText;
  final bool running;
  final bool canceling;
  final double progress; // 0..1，只反映真实进度（G6：无真实进度不伪造）
  final bool completed;
  final Map<String, String> outputPaths;

  /// 失败信息（一句话阻塞点 + 恢复动作标签），null = 未失败。
  final Failure? failure;

  /// 由字段推导当前态——单一来源，避免「界面态」和「数据态」打架。
  MainState get state {
    if (failure != null) return MainState.failed;
    if (completed) return MainState.completed;
    if (running) return MainState.running;
    if (fileName == null) return MainState.empty;
    if (!translateConfigured || !asrConfigured) return MainState.blocked;
    return MainState.ready;
  }

  Session copyWith({
    Object? fileName = _unset,
    Object? filePath = _unset,
    Object? kind = _unset,
    String? sourceLang,
    String? targetLang,
    bool? translateConfigured,
    bool? asrConfigured,
    String? engineTranslate,
    String? engineRecognize,
    bool? bilingual,
    List<String>? formats,
    bool? termsEnabled,
    Object? taskId = _unset,
    Object? statusText = _unset,
    bool? running,
    bool? canceling,
    double? progress,
    bool? completed,
    Map<String, String>? outputPaths,
    Object? failure = _unset,
  }) {
    return Session(
      fileName: fileName == _unset ? this.fileName : fileName as String?,
      filePath: filePath == _unset ? this.filePath : filePath as String?,
      kind: kind == _unset ? this.kind : kind as SourceKind?,
      sourceLang: sourceLang ?? this.sourceLang,
      targetLang: targetLang ?? this.targetLang,
      translateConfigured: translateConfigured ?? this.translateConfigured,
      asrConfigured: asrConfigured ?? this.asrConfigured,
      engineTranslate: engineTranslate ?? this.engineTranslate,
      engineRecognize: engineRecognize ?? this.engineRecognize,
      bilingual: bilingual ?? this.bilingual,
      formats: formats ?? this.formats,
      termsEnabled: termsEnabled ?? this.termsEnabled,
      taskId: taskId == _unset ? this.taskId : taskId as String?,
      statusText: statusText == _unset
          ? this.statusText
          : statusText as String?,
      running: running ?? this.running,
      canceling: canceling ?? this.canceling,
      progress: progress ?? this.progress,
      completed: completed ?? this.completed,
      outputPaths: outputPaths ?? this.outputPaths,
      failure: failure == _unset ? this.failure : failure as Failure?,
    );
  }

  static const _unset = Object();
}

/// 失败态数据（§8：由 doctor 的 code/hint_zh/details.path 喂；此处先静态）。
@immutable
class Failure {
  const Failure({required this.reason, required this.recoverLabel});
  final String reason; // 一句话阻塞点
  final String recoverLabel; // 恢复动作标签
}
