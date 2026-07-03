import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model/main_window_controller.dart';
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
  late final LocalServiceController _service;
  late final bool _ownsService;
  late final MainWindowController _controller;
  final Map<SpikeWindowType, WindowController> _toolWindows = {};

  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  late final AnimationController _drag = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void initState() {
    super.initState();
    _service = widget.localServiceController ?? LocalServiceController();
    _ownsService = widget.localServiceController == null;
    _controller = MainWindowController(service: _service)
      ..addListener(_syncBridgeState);
    widget.bridge.attachServiceCaller((method, params) async {
      await _service.start();
      final client = _service.client;
      if (client == null) throw StateError('Local Service 未连接');
      return client.call(method, params);
    });
    unawaited(_controller.startService());
  }

  @override
  void dispose() {
    _controller.removeListener(_syncBridgeState);
    _controller.dispose();
    if (_ownsService) _service.dispose();
    _breathe.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _syncBridgeState() {
    final view = _controller.view;
    widget.store.replace(
      widget.store.value.copyWith(
        translationDefaultLabel: view.translationLabel,
        translationConfigured: view.translationConfigured,
        asrDefaultLabel: view.asrLabel,
        asrConfigured: view.asrConfigured,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final view = _controller.view;
        return Scaffold(
          body: DropTarget(
            onDragEntered: (_) => _drag.forward(),
            onDragExited: (_) => _drag.reverse(),
            onDragDone: (detail) {
              _drag.reverse();
              final file = detail.files.isNotEmpty ? detail.files.first : null;
              final path = file?.path;
              if (path != null) _controller.pickSource(path, name: file?.name);
            },
            child: Container(
              color: T.bg,
              child: Column(
                children: [
                  TitleBar(
                    status: view.statusLine,
                    onMenu: () => unawaited(_showChromeMenu()),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        T.s32,
                        T.s8,
                        T.s32,
                        T.s16,
                      ),
                      child: _body(view),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(MainWindowViewModel view) {
    return Column(
      children: [
        Expanded(child: _subject(view)),
        if (view.hasSource) ...[
          JobLine(
            view: view,
            onPickTranslation: _pickTranslation,
            onPickAsr: _pickAsr,
            onPickBilingual: _pickBilingual,
            onPickFormats: _pickFormats,
            onToggleTerms: _toggleTerms,
            onConfigureTranslation: () =>
                _openToolWindow(SpikeWindowType.translationSettings),
            onConfigureAsr: () => _openToolWindow(SpikeWindowType.asrSettings),
          ),
          const SizedBox(height: T.s24),
        ],
        PrimaryAction(
          label: _ctaLabel(view),
          variant: _ctaVariant(view.state),
          onTap: () => _onCta(view),
        ),
        const SizedBox(height: T.s12),
      ],
    );
  }

  Widget _subject(MainWindowViewModel view) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: view.state == MainState.empty ? _pickFile : null,
            onSecondaryTapDown: view.source == null
                ? null
                : (details) => _showSourceContextMenu(details.globalPosition),
            child: SizedBox(
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
                            state: view.state,
                            progress: view.progress,
                            breathe: _breathe.value,
                            dragOver: _drag.value,
                          ),
                        ),
                        if (view.state == MainState.empty) _emptyPrompt(),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: T.s16),
          _subjectCaption(view),
        ],
      ),
    );
  }

  Widget _emptyPrompt() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: 8),
        Text('放入片源', style: T.tFilename),
        SizedBox(height: T.s4),
        Text('拖进来，或点击选择 · 视频 / 音频 / SRT 字幕', style: T.tCaption),
      ],
    );
  }

  Widget _subjectCaption(MainWindowViewModel view) {
    return switch (view.state) {
      MainState.empty => const SizedBox.shrink(),
      MainState.ready || MainState.blocked => _fileHeader(view),
      MainState.running => Column(
        children: [
          _fileHeader(view),
          const SizedBox(height: T.s8),
          Text(
            view.runningText ?? (view.canceling ? '正在取消…' : '制作中…'),
            style: T.tCaption.copyWith(color: T.accentStrong),
          ),
        ],
      ),
      MainState.completed => Column(
        children: [
          _fileHeader(view),
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
      ),
      MainState.failed => Column(
        children: [
          _fileHeader(view),
          const SizedBox(height: T.s8),
          _RepairStrip(
            failure: view.failure,
            onTap: () => _runRecovery(view.failure),
          ),
        ],
      ),
    };
  }

  Widget _fileHeader(MainWindowViewModel view) {
    final source = view.source;
    if (source == null) return const SizedBox.shrink();
    return Column(
      children: [
        Tooltip(
          message: source.path,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 390),
            child: Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: T.tFilename,
            ),
          ),
        ),
        const SizedBox(height: T.s8),
        _TypeTag(kind: source.kind),
      ],
    );
  }

  String _ctaLabel(MainWindowViewModel view) {
    return switch (view.state) {
      MainState.empty => '放入片源',
      MainState.ready => view.submitting ? '提交中…' : '开始译制',
      MainState.blocked => !view.translationConfigured ? '去配置翻译' : '去配置识别',
      MainState.running => view.canceling ? '取消中…' : '停下',
      MainState.completed => '再做一个',
      MainState.failed => view.failure?.actionLabel ?? '重试',
    };
  }

  CtaVariant _ctaVariant(MainState state) {
    return switch (state) {
      MainState.empty => CtaVariant.disabled,
      MainState.running => CtaVariant.outline,
      _ => CtaVariant.filled,
    };
  }

  void _onCta(MainWindowViewModel view) {
    switch (view.state) {
      case MainState.empty:
        break;
      case MainState.ready:
        unawaited(_controller.submitRun());
        break;
      case MainState.blocked:
        if (!view.translationConfigured) {
          _openToolWindow(SpikeWindowType.translationSettings);
        } else {
          _openToolWindow(SpikeWindowType.asrSettings);
        }
        break;
      case MainState.running:
        unawaited(_controller.cancelRun());
        break;
      case MainState.completed:
        unawaited(_controller.resetForNext());
        break;
      case MainState.failed:
        _runRecovery(view.failure);
        break;
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles();
    final file = res?.files.singleOrNull;
    final path = file?.path;
    if (path != null) _controller.pickSource(path, name: file?.name);
  }

  Future<void> _showChromeMenu() async {
    final selected = await showMenu<String>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(560, 40, 28, 0),
      items: [
        _menuItem('translation', '翻译模型设置'),
        _menuItem('asr', '语音识别设置'),
      ],
    );
    switch (selected) {
      case 'translation':
        _openToolWindow(SpikeWindowType.translationSettings);
        break;
      case 'asr':
        _openToolWindow(SpikeWindowType.asrSettings);
        break;
    }
  }

  PopupMenuItem<String> _menuItem(String value, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Text(label, style: T.tBody),
    );
  }

  Future<void> _showSourceContextMenu(Offset position) async {
    final selected = await showMenu<String>(
      context: context,
      color: T.surface,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        _menuItem('replace', '换片源'),
        _menuItem('remove', '移除'),
        _menuItem('copy_path', '复制完整路径'),
      ],
    );
    switch (selected) {
      case 'replace':
        await _pickFile();
        break;
      case 'remove':
        _controller.removeSource();
        break;
      case 'copy_path':
        final path = _controller.view.source?.path;
        if (path != null) {
          await Clipboard.setData(ClipboardData(text: path));
          _toast('已复制完整路径');
        }
        break;
    }
  }

  Future<void> _pickTranslation() async {
    final view = _controller.view;
    final selected = await _showOptionMenu<TaskOption>(
      title: '翻译模型',
      options: view.translationOptions,
      emptyLabel: '还没有可用翻译模型',
      footerLabel: '去翻译模型设置',
      onFooter: () => _openToolWindow(SpikeWindowType.translationSettings),
      labelOf: (option) => option.label,
    );
    if (selected != null) _controller.selectTranslation(selected);
  }

  Future<void> _pickAsr() async {
    final view = _controller.view;
    final selected = await _showOptionMenu<TaskOption>(
      title: '语音识别引擎',
      options: view.asrOptions,
      emptyLabel: '还没有可用识别引擎',
      footerLabel: '去语音识别设置',
      onFooter: () => _openToolWindow(SpikeWindowType.asrSettings),
      labelOf: (option) => option.label,
    );
    if (selected != null) _controller.selectAsr(selected);
  }

  Future<void> _pickBilingual() async {
    final selected = await _showOptionMenu<bool>(
      title: '字幕语言',
      options: const [true, false],
      emptyLabel: '',
      labelOf: (value) => value ? '双语' : '单语',
    );
    if (selected != null) _controller.setBilingual(selected);
  }

  Future<void> _pickFormats() async {
    final selected = await _showOptionMenu<List<String>>(
      title: '输出格式',
      options: const [
        ['SRT'],
        ['ASS'],
        ['VTT'],
        ['SRT', 'ASS'],
      ],
      emptyLabel: '',
      labelOf: (value) => value.join('·'),
    );
    if (selected != null) _controller.setFormats(selected);
  }

  void _toggleTerms() {
    _controller.setTermsEnabled(!_controller.view.termsEnabled);
  }

  Future<TValue?> _showOptionMenu<TValue>({
    required String title,
    required List<TValue> options,
    required String emptyLabel,
    required String Function(TValue option) labelOf,
    String? footerLabel,
    VoidCallback? onFooter,
  }) async {
    final selected = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(248, 318, 248, 0),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text(title, style: T.tSection),
        ),
        if (options.isEmpty)
          PopupMenuItem<Object>(
            enabled: false,
            child: Text(emptyLabel, style: T.tCaption),
          )
        else
          for (final option in options)
            PopupMenuItem<Object>(
              value: option as Object,
              child: Text(labelOf(option), style: T.tBody),
            ),
        if (footerLabel != null) const PopupMenuDivider(),
        if (footerLabel != null)
          PopupMenuItem<Object>(
            value: _menuFooter,
            child: Text(
              footerLabel,
              style: T.tBody.copyWith(color: T.accentStrong),
            ),
          ),
      ],
    );
    if (identical(selected, _menuFooter)) {
      onFooter?.call();
      return null;
    }
    return selected as TValue?;
  }

  Future<void> _runRecovery(MainFailureView? failure) async {
    switch (failure?.target ?? MainRecoveryTarget.retry) {
      case MainRecoveryTarget.translationSettings:
        _openToolWindow(SpikeWindowType.translationSettings);
        break;
      case MainRecoveryTarget.asrSettings:
        _openToolWindow(SpikeWindowType.asrSettings);
        break;
      case MainRecoveryTarget.pickSource:
        await _pickFile();
        break;
      case MainRecoveryTarget.resume:
      case MainRecoveryTarget.retry:
        unawaited(_controller.retryRun());
        break;
      case MainRecoveryTarget.outputDirectory:
        _toast('输出目录选择将在后续修复件中接入。');
        break;
    }
  }

  Future<void> _openOutputFile() async {
    try {
      await _controller.openResultFile();
    } on Object catch (error) {
      _toast('打开字幕失败：$error');
    }
  }

  Future<void> _openOutputFolder() async {
    try {
      await _controller.openResultFolder();
    } on Object catch (error) {
      _toast('打开文件夹失败：$error');
    }
  }

  Future<void> _reexportResult() async {
    try {
      await _controller.reexportResult();
      _toast('已重新导出字幕');
    } on Object catch (error) {
      _toast('重新导出失败：$error');
    }
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
}

const Object _menuFooter = Object();

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

class _RepairStrip extends StatelessWidget {
  const _RepairStrip({required this.failure, required this.onTap});

  final MainFailureView? failure;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 430),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: const Color(0xFFFBE4E0),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.danger, width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              failure?.reason ?? '制作失败',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: T.tCaption.copyWith(color: T.ink),
            ),
          ),
          const SizedBox(width: T.s12),
          _Chip(
            label: failure?.actionLabel ?? '重试',
            danger: true,
            onTap: onTap,
          ),
        ],
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
                ? (widget.danger ? const Color(0xFFFFF7F1) : T.accentSoft)
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
