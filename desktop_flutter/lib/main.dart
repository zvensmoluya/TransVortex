import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'model/session.dart';
import 'model/spike_state.dart';
import 'painters/source_object_painter.dart';
import 'services/current_window_controls.dart';
import 'services/local_service_controller.dart';
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
    widget.store.addListener(_applySpikeState);
    _service.addListener(_applyLocalServiceState);
    _session = _sessionFromSpikeState(_session);
    unawaited(_service.start());
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
    final readiness = _service.snapshot.desktopSnapshot?.configReadiness;
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

  bool _sameSessionConfig(Session a, Session b) {
    return a.engineTranslate == b.engineTranslate &&
        a.engineRecognize == b.engineRecognize &&
        a.translateConfigured == b.translateConfigured &&
        a.asrConfigured == b.asrConfigured;
  }

  // —— 状态转移 ——

  void _loadFile(String name) {
    final kind = _kindOf(name);
    setState(() {
      _session = _session.copyWith(
        fileName: name,
        kind: kind,
        completed: false,
        running: false,
        progress: 0,
        failure: null,
        engineTranslate: widget.store.value.translationDefaultLabel,
        engineRecognize: widget.store.value.asrDefaultLabel,
        translateConfigured: widget.store.value.translationConfigured,
        asrConfigured: widget.store.value.asrConfigured,
      );
    });
  }

  void _start() {
    setState(() {
      _session = _session.copyWith(running: true, progress: 0, failure: null);
    });
    _run.forward(from: 0);
  }

  void _stop() {
    _run.stop();
    setState(() {
      _session = _session.copyWith(running: false, progress: 0);
    });
  }

  void _reset() {
    _run.reset();
    setState(() => _session = const Session());
  }

  void _onCta() {
    switch (_session.state) {
      case MainState.empty:
        break; // disabled
      case MainState.ready:
        _start();
        break;
      case MainState.blocked:
        if (!_session.translateConfigured) {
          _openToolWindow(SpikeWindowType.translationSettings);
        } else if (!_session.asrConfigured) {
          _openToolWindow(SpikeWindowType.asrSettings);
        }
        break;
      case MainState.running:
        _stop();
        break;
      case MainState.completed:
        _reset();
        break;
      case MainState.failed:
        _start();
        break;
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles();
    final name = res?.files.singleOrNull?.name;
    if (name != null) _loadFile(name);
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

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    return Scaffold(
      body: DropTarget(
        onDragEntered: (_) => _drag.forward(),
        onDragExited: (_) => _drag.reverse(),
        onDragDone: (detail) {
          _drag.reverse();
          final name = detail.files.isNotEmpty ? detail.files.first.name : null;
          if (name != null) _loadFile(name);
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
              _session.progress < 0.5 ? '正在识别语音…' : '正在翻译…',
              style: T.tCaption.copyWith(color: T.accentStrong),
            ),
          ],
        );
      case MainState.completed:
        return Column(
          children: [
            _fileHeader(),
            const SizedBox(height: T.s12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Chip(label: '打开字幕', onTap: () => _toast('打开字幕（占位）')),
                const SizedBox(width: T.s8),
                _Chip(label: '打开所在文件夹', onTap: () => _toast('打开文件夹（占位）')),
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
    MainState.ready => '开始译制',
    MainState.blocked => !_session.translateConfigured ? '去配置翻译' : '去配置识别',
    MainState.running => '停下',
    MainState.completed => '再做一个',
    MainState.failed => '重试',
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
