import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'model/session.dart';
import 'model/spike_state.dart';
import 'painters/source_object_painter.dart';
import 'services/app_service_client.dart';
import 'services/current_window_controls.dart';
import 'services/local_service_controller.dart';
import 'services/path_opener.dart';
import 'services/window_state_bridge.dart';
import 'theme/tokens.dart';
import 'widgets/job_line.dart';
import 'widgets/primary_action.dart';
import 'widgets/settings_window.dart';
import 'widgets/sidecar_probe_view.dart';
import 'widgets/subtitle_review_spike.dart';
import 'widgets/title_bar.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await _currentWindowController();
  final parsedArgs = SpikeWindowArgs.parse(
    controller?.arguments ?? (args.isNotEmpty ? args.first : ''),
  );
  final store = WindowStateStore();
  final bridge = parsedArgs.type == SpikeWindowType.main
      ? WindowStateBridge.main(store)
      : WindowStateBridge.child(store);
  if (parsedArgs.type == SpikeWindowType.main) {
    await bridge.initializeMain();
  }
  await configureCurrentWindow(parsedArgs.type);
  await registerCurrentWindowControls();

  runApp(
    TransVortexApp(windowType: parsedArgs.type, store: store, bridge: bridge),
  );
}

Future<WindowController?> _currentWindowController() async {
  try {
    return await WindowController.fromCurrentEngine();
  } on Object {
    return null;
  }
}

class TransVortexApp extends StatelessWidget {
  const TransVortexApp({
    super.key,
    this.windowType = SpikeWindowType.main,
    this.store,
    this.bridge,
    this.localServiceController,
  });

  final SpikeWindowType windowType;
  final WindowStateStore? store;
  final WindowStateBridge? bridge;
  final LocalServiceController? localServiceController;

  @override
  Widget build(BuildContext context) {
    final appStore = store ?? WindowStateStore();
    final appBridge =
        bridge ??
        (windowType == SpikeWindowType.main
            ? WindowStateBridge.main(appStore)
            : WindowStateBridge.child(appStore));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: windowType.title,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: T.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: T.accent,
          brightness: Brightness.light,
        ),
      ),
      home: windowType == SpikeWindowType.main
          ? MainScreen(
              store: appStore,
              bridge: appBridge,
              localServiceController: localServiceController,
            )
          : SettingsWindow(
              type: windowType,
              store: appStore,
              bridge: appBridge,
            ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.store,
    required this.bridge,
    this.localServiceController,
  });

  final WindowStateStore store;
  final WindowStateBridge bridge;
  final LocalServiceController? localServiceController;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  Session _session = const Session();
  String _panel = 'main';
  final Map<SpikeWindowType, WindowController> _toolWindows = {};
  late final LocalServiceController _service;
  late final bool _ownsService;
  final PathOpener _pathOpener = PathOpener();
  Timer? _taskPoll;
  int _eventCursor = 0;
  bool _submitting = false;
  List<Map<String, Object?>> _recentEvents = const [];

  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  late final AnimationController _drag = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void initState() {
    super.initState();
    _service = widget.localServiceController ?? LocalServiceController();
    _ownsService = widget.localServiceController == null;
    widget.bridge.attachServiceCaller((method, params) async {
      await _service.start();
      final client = _service.client;
      if (client == null) {
        throw StateError('Local Service 未连接');
      }
      return client.call(method, params);
    });
    widget.store.addListener(_applySpikeState);
    _service.addListener(_applyLocalServiceState);
    _session = _sessionFromSpikeState(_session);
    unawaited(_service.start().then((_) => _refreshTaskState()));
    _run
      ..addListener(() {
        setState(() => _session = _session.copyWith(progress: _run.value));
      })
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          setState(() {
            _session = _session.copyWith(
              running: false,
              completed: true,
              progress: 1,
            );
          });
        }
      });
  }

  @override
  void dispose() {
    _taskPoll?.cancel();
    _service.removeListener(_applyLocalServiceState);
    if (_ownsService) {
      _service.dispose();
    }
    widget.store.removeListener(_applySpikeState);
    _breathe.dispose();
    _drag.dispose();
    _run.dispose();
    super.dispose();
  }

  void _applySpikeState() {
    final next = _sessionFromSpikeState(_session);
    if (_sameSessionConfig(_session, next)) return;
    setState(() => _session = next);
  }

  void _applyLocalServiceState() {
    final snapshot = _service.snapshot.desktopSnapshot;
    final readiness = snapshot?.configReadiness;
    if (readiness != null) {
      final nextStoreValue = widget.store.value.copyWith(
        translationDefaultLabel: readiness.translationLabel,
        translationConfigured: readiness.translationConfigured,
        asrDefaultLabel: readiness.asrLabel,
        asrConfigured: readiness.asrConfigured,
      );
      widget.store.replace(nextStoreValue);
      _session = _session.copyWith(
        engineTranslate: nextStoreValue.translationDefaultLabel,
        engineRecognize: nextStoreValue.asrDefaultLabel,
        translateConfigured: nextStoreValue.translationConfigured,
        asrConfigured: nextStoreValue.asrConfigured,
      );
    }
    final taskId = _session.taskId;
    final task = taskId == null ? null : snapshot?.taskById(taskId);
    if (task != null) {
      _session = _sessionFromTask(_session, task);
    }
    if (mounted) setState(() {});
  }

  Session _sessionFromSpikeState(Session base) {
    final s = widget.store.value;
    return base.copyWith(
      engineTranslate: s.translationDefaultLabel,
      engineRecognize: s.asrDefaultLabel,
      translateConfigured: s.translationConfigured,
      asrConfigured: s.asrConfigured,
    );
  }

  Session _sessionFromTask(Session base, TaskSummary task) {
    final progress = task.latestProgress ?? base.progress;
    final failure = task.isFailed || task.isCancelled
        ? Failure(
            reason: _taskFailureReason(task),
            recoverLabel: task.canResume ? '继续任务' : '重试',
          )
        : null;
    return base.copyWith(
      fileName: base.fileName ?? _basename(task.inputFile),
      filePath: base.filePath ?? task.inputFile,
      sourceLang: task.sourceLang.isEmpty ? base.sourceLang : task.sourceLang,
      targetLang: task.targetLang.isEmpty ? base.targetLang : task.targetLang,
      bilingual: task.bilingual,
      running: !task.isTerminal,
      canceling: task.status == 'CANCEL_REQUESTED',
      completed: task.isDone,
      progress: task.isDone ? 1 : progress,
      outputPaths: task.outputPaths,
      statusText: _taskStatusLabel(task),
      failure: failure,
    );
  }

  bool _sameSessionConfig(Session a, Session b) {
    return a.engineTranslate == b.engineTranslate &&
        a.engineRecognize == b.engineRecognize &&
        a.translateConfigured == b.translateConfigured &&
        a.asrConfigured == b.asrConfigured;
  }

  // —— 状态转移 ——

  void _loadFile(String path, {String? name}) {
    final displayName = name ?? _basename(path);
    final kind = _kindOf(displayName);
    setState(() {
      _session = _session.copyWith(
        fileName: displayName,
        filePath: path,
        kind: kind,
        taskId: null,
        statusText: null,
        completed: false,
        running: false,
        canceling: false,
        progress: 0,
        outputPaths: const <String, String>{},
        failure: null,
        engineTranslate: widget.store.value.translationDefaultLabel,
        engineRecognize: widget.store.value.asrDefaultLabel,
        translateConfigured: widget.store.value.translationConfigured,
        asrConfigured: widget.store.value.asrConfigured,
      );
    });
    _recentEvents = const [];
    _eventCursor = 0;
  }

  Future<void> _start() async {
    if (_submitting) return;
    if (_session.filePath == null) {
      await _pickFile();
      return;
    }
    if (!_session.translateConfigured) {
      _openToolWindow(SpikeWindowType.translationSettings);
      return;
    }
    if (!_session.asrConfigured) {
      _openToolWindow(SpikeWindowType.asrSettings);
      return;
    }
    _run.stop();
    setState(() {
      _submitting = true;
      _session = _session.copyWith(
        running: true,
        canceling: false,
        progress: 0,
        completed: false,
        statusText: '正在排队',
        failure: null,
      );
    });
    try {
      await _service.start();
      final client = _service.client;
      if (client == null) {
        throw StateError('Local Service 未连接');
      }
      final result = await client.submitRun(_runRequestPayload());
      _eventCursor = 0;
      _recentEvents = const [];
      setState(() {
        _session = _session.copyWith(
          taskId: result.taskId,
          statusText: result.status,
          running: true,
          failure: null,
        );
      });
      _ensureTaskPolling();
      await _refreshTaskState();
    } on Object catch (error) {
      setState(() {
        _session = _session.copyWith(
          running: false,
          canceling: false,
          statusText: null,
          failure: Failure(reason: '$error', recoverLabel: '重试'),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      } else {
        _submitting = false;
      }
    }
  }

  Future<void> _stop() async {
    final taskId = _session.taskId;
    if (taskId == null) {
      _run.stop();
      setState(() {
        _session = _session.copyWith(running: false, progress: 0);
      });
      return;
    }
    setState(() {
      _session = _session.copyWith(canceling: true, statusText: '正在取消');
    });
    try {
      await _service.client?.cancel(taskId);
      await _refreshTaskState();
    } on Object catch (error) {
      setState(() {
        _session = _session.copyWith(
          canceling: false,
          failure: Failure(reason: '$error', recoverLabel: '重试取消'),
        );
      });
    }
  }

  void _reset() {
    _taskPoll?.cancel();
    _taskPoll = null;
    _run.reset();
    _recentEvents = const [];
    _eventCursor = 0;
    setState(() => _session = _sessionFromSpikeState(const Session()));
  }

  void _onCta() {
    switch (_session.state) {
      case MainState.empty:
        break; // disabled
      case MainState.ready:
        unawaited(_start());
        break;
      case MainState.blocked:
        if (!_session.translateConfigured) {
          _openToolWindow(SpikeWindowType.translationSettings);
        } else if (!_session.asrConfigured) {
          _openToolWindow(SpikeWindowType.asrSettings);
        }
        break;
      case MainState.running:
        unawaited(_stop());
        break;
      case MainState.completed:
        _reset();
        break;
      case MainState.failed:
        unawaited(_start());
        break;
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles();
    final file = res?.files.singleOrNull;
    final path = file?.path;
    if (path != null) _loadFile(path, name: file?.name);
  }

  static SourceKind _kindOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const video = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv'};
    const audio = {'mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg'};
    const sub = {'srt', 'ass', 'vtt'};
    if (audio.contains(ext)) return SourceKind.audio;
    if (sub.contains(ext)) return SourceKind.subtitle;
    if (video.contains(ext)) return SourceKind.video;
    return SourceKind.video;
  }

  Map<String, Object?> _runRequestPayload() {
    final snapshot = _service.snapshot.desktopSnapshot;
    final provider = snapshot?.translationProvider;
    final model = snapshot?.translationModel;
    final asrProvider = snapshot?.asrProviderName;
    final asrModel = snapshot?.asrModel;
    final overrides = <String, Object?>{
      'output_format': _outputFormatValue(_session.formats),
      'subtitle_quality_mode': 'balanced',
      'memory_bootstrap_enabled': _session.termsEnabled,
      'memory_patch_enabled': _session.termsEnabled,
      if (asrProvider != null && asrProvider.isNotEmpty)
        'asr_provider': asrProvider,
      if (asrModel != null && asrModel.isNotEmpty) 'asr_model': asrModel,
    };
    return {
      'request_version': 1,
      'input': _session.filePath,
      'input_type': _inputTypeFor(_session.kind),
      'source_lang': _session.sourceLang,
      'target_lang': _session.targetLang,
      'bilingual': _session.bilingual,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      if (model != null && model.isNotEmpty) 'model': model,
      'overrides': overrides,
    };
  }

  static String _inputTypeFor(SourceKind? kind) {
    return switch (kind) {
      SourceKind.subtitle => 'srt_translate',
      _ => 'video_asr_translate',
    };
  }

  static String _outputFormatValue(List<String> formats) {
    final selected = formats.map((item) => item.toLowerCase()).toSet();
    if (selected.contains('srt') && selected.contains('ass')) return 'both';
    if (selected.contains('ass')) return 'ass';
    if (selected.contains('vtt')) return 'vtt';
    return 'srt';
  }

  void _ensureTaskPolling() {
    if (_taskPoll != null) return;
    _taskPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshTaskState()),
    );
  }

  Future<void> _refreshTaskState() async {
    final taskId = _session.taskId;
    if (taskId == null) return;
    final client = _service.client;
    if (client == null) return;
    try {
      await _service.refresh();
      final page = await client.taskEvents(taskId, cursor: _eventCursor);
      final nextEvents = page.events
          .map(_asStringMap)
          .where((event) => event.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _eventCursor = page.nextCursor;
        _recentEvents = [..._recentEvents, ...nextEvents];
        if (_recentEvents.length > 12) {
          _recentEvents = _recentEvents.sublist(_recentEvents.length - 12);
        }
        final progress = _latestEventProgress(_recentEvents);
        final message = _latestEventMessage(_recentEvents);
        _session = _session.copyWith(
          progress: progress ?? _session.progress,
          statusText: message ?? _session.statusText,
        );
      });
      if (_session.state != MainState.running) {
        _taskPoll?.cancel();
        _taskPoll = null;
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _session = _session.copyWith(statusText: '刷新失败：$error');
      });
    }
  }

  static Map<String, Object?> _asStringMap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return const {};
  }

  static double? _latestEventProgress(List<Map<String, Object?>> events) {
    for (final event in events.reversed) {
      final value = event['progress'];
      if (value is num) return value.toDouble().clamp(0.0, 1.0);
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed.clamp(0.0, 1.0);
      }
    }
    return null;
  }

  static String? _latestEventMessage(List<Map<String, Object?>> events) {
    for (final event in events.reversed) {
      final message = '${event['message'] ?? ''}'.trim();
      if (message.isNotEmpty) return message;
      final stage = '${event['stage'] ?? ''}'.trim();
      if (stage.isNotEmpty) return stage;
    }
    return null;
  }

  static String _taskFailureReason(TaskSummary task) {
    final hint = '${task.errorInfo['hint_zh'] ?? ''}'.trim();
    if (hint.isNotEmpty) return hint;
    final message = '${task.errorInfo['message'] ?? ''}'.trim();
    if (message.isNotEmpty) return message;
    return task.error ?? '制作失败';
  }

  static String _taskStatusLabel(TaskSummary task) {
    return switch (task.status) {
      'QUEUED' => '等待本地服务调度',
      'CANCEL_REQUESTED' => '正在取消',
      'DONE' => '字幕已生成',
      'FAILED' => '制作失败',
      'CANCELLED' => '已取消',
      'INTERRUPTED' => '任务中断',
      _ => task.displayStatus,
    };
  }

  static String _basename(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    return Scaffold(
      body: DropTarget(
        onDragEntered: (_) => _drag.forward(),
        onDragExited: (_) => _drag.reverse(),
        onDragDone: (detail) {
          _drag.reverse();
          final file = detail.files.isNotEmpty ? detail.files.first : null;
          final path = file?.path;
          if (path != null) _loadFile(path, name: file?.name);
        },
        child: Container(
          color: T.bg,
          child: Column(
            children: [
              TitleBar(status: _statusLine(state), onMenu: _showMenu),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(T.s32, T.s8, T.s32, T.s16),
                  child: _body(state),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(MainState state) {
    if (_panel == 'sidecar') {
      return SidecarProbeView(controller: _service);
    }
    if (_panel == 'review') {
      return const SubtitleReviewSpike();
    }
    return Column(
      children: [
        Expanded(child: _subject(state)),
        if (state != MainState.empty) ...[
          JobLine(
            session: _session,
            onConfigureTranslation: () =>
                _openToolWindow(SpikeWindowType.translationSettings),
            onConfigureAsr: () => _openToolWindow(SpikeWindowType.asrSettings),
            onChanged: (s) => setState(() => _session = s),
          ),
          const SizedBox(height: T.s24),
        ],
        PrimaryAction(
          label: _ctaLabel(state),
          variant: _ctaVariant(state),
          onTap: _onCta,
        ),
        const SizedBox(height: T.s12),
        _debugStateBar(),
      ],
    );
  }

  // —— 主体（唯一主角，居中）——
  Widget _subject(MainState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 320,
            height: 196,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([_breathe, _drag]),
                builder: (context, _) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(320, 196),
                        painter: SourceObjectPainter(
                          state: state,
                          progress: _session.progress,
                          breathe: _breathe.value,
                          dragOver: _drag.value,
                        ),
                      ),
                      if (state == MainState.empty) _emptyPrompt(),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: T.s16),
          _subjectCaption(state),
        ],
      ),
    );
  }

  Widget _emptyPrompt() {
    return GestureDetector(
      onTap: _pickFile,
      behavior: HitTestBehavior.opaque,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 8),
          Text('放入片源', style: T.tFilename),
          SizedBox(height: T.s4),
          Text('拖进来，或点击选择 · 视频 / 音频 / 字幕', style: T.tCaption),
        ],
      ),
    );
  }

  Widget _subjectCaption(MainState state) {
    switch (state) {
      case MainState.empty:
        return const SizedBox.shrink();
      case MainState.ready:
      case MainState.blocked:
        return _fileHeader();
      case MainState.running:
        return Column(
          children: [
            _fileHeader(),
            const SizedBox(height: T.s8),
            Text(
              _session.statusText ?? (_session.canceling ? '正在取消…' : '制作中…'),
              style: T.tCaption.copyWith(color: T.accentStrong),
            ),
          ],
        );
      case MainState.completed:
        return Column(
          children: [
            _fileHeader(),
            const SizedBox(height: T.s12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                _Chip(label: '打开字幕', onTap: _openOutputFile),
                _Chip(label: '打开所在文件夹', onTap: _openOutputFolder),
                _Chip(label: '重新导出', onTap: _reexportResult),
              ],
            ),
          ],
        );
      case MainState.failed:
        final f = _session.failure;
        return Column(
          children: [
            _fileHeader(),
            const SizedBox(height: T.s8),
            Text(
              f?.reason ?? '制作失败',
              style: T.tCaption.copyWith(color: T.danger),
            ),
            const SizedBox(height: T.s8),
            _Chip(label: f?.recoverLabel ?? '重试', danger: true, onTap: _onCta),
          ],
        );
    }
  }

  Future<void> _openOutputFile() async {
    final taskId = _session.taskId;
    if (taskId == null) {
      _toast('还没有可打开的任务结果');
      return;
    }
    try {
      final outputs = await _resultOutputPaths(taskId);
      final path = _primaryOutputPath(outputs);
      if (path == null) {
        _toast('还没有输出文件记录');
        return;
      }
      await _pathOpener.revealFile(path);
    } on Object catch (error) {
      _toast('打开字幕失败：$error');
    }
  }

  Future<void> _openOutputFolder() async {
    final taskId = _session.taskId;
    if (taskId == null) {
      _toast('还没有可打开的任务目录');
      return;
    }
    try {
      final outputs = await _resultOutputPaths(taskId);
      final path = _primaryOutputPath(outputs);
      final dir = path == null ? null : _parentPath(path);
      if (dir == null || dir.isEmpty) {
        _toast('还没有输出目录记录');
        return;
      }
      await _pathOpener.openDirectory(dir);
    } on Object catch (error) {
      _toast('打开文件夹失败：$error');
    }
  }

  Future<void> _reexportResult() async {
    final taskId = _session.taskId;
    if (taskId == null) {
      _toast('还没有可重新导出的任务');
      return;
    }
    try {
      await _service.client?.resultReexport(
        taskId,
        outputFormat: _outputFormatValue(_session.formats),
        bilingual: _session.bilingual,
      );
      await _refreshTaskState();
      _toast('已重新导出字幕');
    } on Object catch (error) {
      _toast('重新导出失败：$error');
    }
  }

  Future<Map<String, Object?>> _resultOutputPaths(String taskId) async {
    if (_session.outputPaths.isNotEmpty) {
      return Map<String, Object?>.from(_session.outputPaths);
    }
    final result = await _service.client?.resultOpen(taskId);
    return _asStringMap(result?['output_paths']);
  }

  static String? _primaryOutputPath(Map<String, Object?> outputs) {
    for (final key in const ['srt', 'ass', 'vtt']) {
      final value = '${outputs[key] ?? ''}'.trim();
      if (value.isNotEmpty) return value;
    }
    for (final value in outputs.values) {
      final text = '$value'.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static String? _parentPath(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

  Widget _fileHeader() {
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            _session.fileName ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: T.tFilename,
          ),
        ),
        const SizedBox(height: T.s8),
        if (_session.kind != null) _TypeTag(kind: _session.kind!),
      ],
    );
  }

  // —— 文案 / 标签映射 ——

  String _statusLine(MainState s) {
    final base = switch (s) {
      _ when _panel == 'sidecar' =>
        'Local Service · ${_service.snapshot.status.zh}',
      _ when _panel == 'review' => 'Phase A · 1000 条字幕审看',
      MainState.empty => '等待片源',
      MainState.ready => '就绪 · 可开始',
      MainState.blocked =>
        !_session.translateConfigured ? '需要先配置翻译' : '需要先配置识别',
      MainState.running => '制作中…',
      MainState.completed => '已完成',
      MainState.failed => '制作失败',
    };
    return switch (_service.snapshot.status) {
      LocalServiceConnectionStatus.starting => '服务启动中 · $base',
      LocalServiceConnectionStatus.ready => '服务已连接 · $base',
      LocalServiceConnectionStatus.degraded => '服务降级 · $base',
      LocalServiceConnectionStatus.unavailable => '服务不可用 · $base',
      LocalServiceConnectionStatus.stopped => '服务已停止 · $base',
      LocalServiceConnectionStatus.idle => base,
    };
  }

  String _ctaLabel(MainState s) => switch (s) {
    MainState.empty => '放入片源',
    MainState.ready => _submitting ? '提交中…' : '开始译制',
    MainState.blocked => !_session.translateConfigured ? '去配置翻译' : '去配置识别',
    MainState.running => _session.canceling ? '取消中…' : '停下',
    MainState.completed => '再做一个',
    MainState.failed => _session.failure?.recoverLabel ?? '重试',
  };

  CtaVariant _ctaVariant(MainState s) => switch (s) {
    MainState.empty => CtaVariant.disabled,
    MainState.running => CtaVariant.outline,
    _ => CtaVariant.filled,
  };

  void _showMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: T.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(T.rLg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('准备配置', style: T.tSection),
              ),
            ),
            for (final e in const [
              '翻译模型设置',
              '语音识别设置',
              'Local Service 诊断',
              '字幕审看小样',
              '术语管理',
              '任务历史',
              '诊断',
            ])
              ListTile(
                title: Text(e, style: T.tBody),
                onTap: () {
                  Navigator.pop(ctx);
                  switch (e) {
                    case '翻译模型设置':
                      _openToolWindow(SpikeWindowType.translationSettings);
                      break;
                    case '语音识别设置':
                      _openToolWindow(SpikeWindowType.asrSettings);
                      break;
                    case 'Local Service 诊断':
                      setState(() => _panel = 'sidecar');
                      break;
                    case '字幕审看小样':
                      setState(() => _panel = 'review');
                      break;
                    default:
                      _toast('$e（后续设计轮次）');
                      break;
                  }
                },
              ),
            ListTile(
              title: const Text('回到主屏', style: T.tBody),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _panel = 'main');
              },
            ),
            const SizedBox(height: T.s8),
          ],
        ),
      ),
    );
  }

  Future<void> _openToolWindow(SpikeWindowType type) async {
    final existing = _toolWindows[type];
    if (existing != null) {
      try {
        await existing.invokeMethod<void>('window_focus');
        return;
      } on Object {
        _toolWindows.remove(type);
      }
    }
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          hiddenAtLaunch: true,
          arguments: SpikeWindowArgs(type: type).encode(),
        ),
      );
      _toolWindows[type] = controller;
      await controller.show();
    } on Object catch (exc) {
      _toast('打开${type.title}失败：$exc');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: T.tBody.copyWith(color: T.ink)),
          backgroundColor: T.surface,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // —— 调试态切换条（仅探路用，看全六态；非产品 chrome）——
  Widget _debugStateBar() {
    const demoName = 'Spirited.Away.2001.BluRay.1080p.x265.mkv';
    void setDemo(MainState s) {
      _run.stop();
      final currentConfig = widget.store.value;
      setState(() {
        _session = switch (s) {
          MainState.empty => const Session(),
          MainState.ready => Session(
            fileName: demoName,
            kind: SourceKind.video,
            engineTranslate: currentConfig.translationDefaultLabel,
            engineRecognize: currentConfig.asrDefaultLabel,
            translateConfigured: currentConfig.translationConfigured,
            asrConfigured: currentConfig.asrConfigured,
          ),
          MainState.blocked => Session(
            fileName: demoName,
            kind: SourceKind.video,
            translateConfigured: false,
            asrConfigured: true,
          ),
          MainState.running => Session(
            fileName: demoName,
            kind: SourceKind.video,
            running: true,
            progress: 0.4,
            engineTranslate: currentConfig.translationDefaultLabel,
            engineRecognize: currentConfig.asrDefaultLabel,
            translateConfigured: currentConfig.translationConfigured,
            asrConfigured: currentConfig.asrConfigured,
          ),
          MainState.completed => Session(
            fileName: demoName,
            kind: SourceKind.video,
            completed: true,
            progress: 1,
            engineTranslate: currentConfig.translationDefaultLabel,
            engineRecognize: currentConfig.asrDefaultLabel,
            translateConfigured: currentConfig.translationConfigured,
            asrConfigured: currentConfig.asrConfigured,
          ),
          MainState.failed => const Session(
            fileName: demoName,
            kind: SourceKind.video,
            failure: Failure(reason: '输出目录不可写', recoverLabel: '选个文件夹'),
          ),
        };
      });
      if (s == MainState.running) _run.forward(from: 0.4);
    }

    const labels = {
      MainState.empty: '空',
      MainState.ready: '就绪',
      MainState.blocked: '受阻',
      MainState.running: '制作中',
      MainState.completed: '完成',
      MainState.failed: '失败',
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('调试态：', style: T.tCaption),
        for (final e in labels.entries)
          GestureDetector(
            onTap: () => setDemo(e.key),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  e.value,
                  style: T.tCaption.copyWith(
                    color: _session.state == e.key ? T.accentStrong : T.muted,
                    fontWeight: _session.state == e.key ? T.wBold : T.wRegular,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TypeTag extends StatelessWidget {
  const _TypeTag({required this.kind});
  final SourceKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 3),
      decoration: BoxDecoration(
        color: T.accentSoft,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.accent, width: 1),
      ),
      child: Text(
        kind.zh,
        style: T.tCaption.copyWith(
          color: T.accentStrong,
          fontWeight: T.wMedium,
        ),
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({required this.label, required this.onTap, this.danger = false});
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.danger ? T.danger : T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover
                ? (widget.danger ? const Color(0xFFFBE4E0) : T.accentSoft)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: c, width: 1.4),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(color: c, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}
