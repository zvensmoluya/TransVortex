import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'model/main_window_controller.dart';
import 'model/session.dart';
import 'model/startup_args.dart';
import 'model/task_labels.dart';
import 'model/window_state.dart';
import 'painters/source_object_painter.dart';
import 'services/app_service_client.dart';
import 'services/directory_probe.dart';
import 'services/current_window_controls.dart';
import 'services/desktop_tray_service.dart';
import 'services/local_service_controller.dart';
import 'services/native_window_lifecycle.dart';
import 'services/path_opener.dart';
import 'services/smoke_render_capture.dart';
import 'services/task_notification_service.dart';
import 'services/window_state_bridge.dart';
import 'services/workspace_data_manager.dart';
import 'theme/tokens.dart';
import 'widgets/application_settings_panel.dart';
import 'widgets/job_line.dart';
import 'widgets/memory_library_dialog.dart';
import 'widgets/translation_style_library.dart';
import 'widgets/primary_action.dart';
import 'widgets/reasoning_effort_picker.dart';
import 'widgets/designed_tooltip.dart';
import 'widgets/settings_window.dart';
import 'widgets/task_processing_window.dart';
import 'widgets/title_bar.dart';

part 'main/main_surface_widgets.dart';
part 'main/main_screen_lifecycle.dart';
part 'main/main_screen_smoke.dart';

Completer<void>? _initialWindowShowCompleter;

String asrTrayStatusLabel(AsrOperationStatus operation) {
  if (operation.state == 'cancelling') return '正在取消识别环境下载';
  return switch (operation.phase) {
    'runtime' => '正在下载本机识别引擎',
    'model' => '正在下载 ${_asrTrayItemLabel(operation.itemId)}',
    'activate' => '正在启用本机识别',
    _ => '正在准备本机识别',
  };
}

String _asrTrayItemLabel(String itemId) => switch (itemId) {
  'small' => 'Whisper Small',
  'medium' => 'Whisper Medium',
  'large-v3' => 'Whisper Large v3',
  _ => '识别模型',
};

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await _currentWindowController();
  final startupArgs = AppStartupArgs.fromSources(controller?.arguments, args);
  final parsedArgs = startupArgs.window;
  final store = WindowStateStore();
  final bridge = parsedArgs.type == AppWindowType.main
      ? WindowStateBridge.main(store)
      : WindowStateBridge.child(store);
  if (parsedArgs.type == AppWindowType.main) {
    await bridge.initializeMain();
  }
  await configureCurrentWindow(parsedArgs);
  await registerCurrentWindowControls();

  final initialWindowShowCompleter = Completer<void>();
  _initialWindowShowCompleter = initialWindowShowCompleter;
  runApp(
    TransVortexApp(
      windowType: parsedArgs.type,
      taskId: parsedArgs.taskId,
      workspaceSection: parsedArgs.workspaceSection,
      store: store,
      bridge: bridge,
      smoke: startupArgs.smoke,
    ),
  );
  unawaited(_showConfiguredWindowAfterFirstRaster(initialWindowShowCompleter));
}

Future<WindowController?> _currentWindowController() async {
  try {
    return await WindowController.fromCurrentEngine();
  } on Object {
    return null;
  }
}

Future<void> _showConfiguredWindowAfterFirstRaster(
  Completer<void> completion,
) async {
  try {
    try {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
        const Duration(seconds: 10),
      );
    } on TimeoutException {
      // Do not leave a window hidden forever if a host cannot report rasterization.
    } on Object {
      // Unsupported test hosts still need the normal best-effort show path below.
    }
    await showConfiguredWindow();
  } finally {
    if (!completion.isCompleted) completion.complete();
  }
}

class TransVortexApp extends StatelessWidget {
  const TransVortexApp({
    super.key,
    this.windowType = AppWindowType.main,
    this.taskId,
    this.workspaceSection,
    this.store,
    this.bridge,
    this.localServiceController,
    this.desktopTrayService,
    this.taskNotificationService,
    this.pathOpener,
    this.directoryProbe,
    this.directoryPicker,
    this.workspaceDataOperations,
    this.mainWindowSurfaceController,
    this.smoke,
  });

  final AppWindowType windowType;
  final String? taskId;
  final String? workspaceSection;
  final WindowStateStore? store;
  final WindowStateBridge? bridge;
  final LocalServiceController? localServiceController;
  final DesktopTrayService? desktopTrayService;
  final TaskNotificationService? taskNotificationService;
  final PathOpener? pathOpener;
  final DirectoryWriteProbe? directoryProbe;
  final SettingsDirectoryPicker? directoryPicker;
  final WorkspaceDataOperations? workspaceDataOperations;
  final MainWindowSurfaceController? mainWindowSurfaceController;
  final AppSmokeArgs? smoke;

  @override
  Widget build(BuildContext context) {
    final appStore = store ?? WindowStateStore();
    final appBridge =
        bridge ??
        (windowType == AppWindowType.main
            ? WindowStateBridge.main(appStore)
            : WindowStateBridge.child(appStore));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: windowType.title,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: T.fontFamily,
        scaffoldBackgroundColor: T.bg,
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: T.line, width: 1),
          ),
          textStyle: T.tCaption.copyWith(color: T.ink, height: 1.25),
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          margin: const EdgeInsets.all(T.s12),
          waitDuration: const Duration(milliseconds: 450),
          showDuration: const Duration(seconds: 3),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: T.accent,
          brightness: Brightness.light,
        ).copyWith(surface: T.surface, onSurface: T.ink, error: T.danger),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: T.surface,
          hintStyle: T.tCaption,
          labelStyle: T.tCaption,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rMd),
            borderSide: const BorderSide(color: T.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rMd),
            borderSide: const BorderSide(color: T.line, width: 1.1),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rMd),
            borderSide: BorderSide(color: T.line.withValues(alpha: 0.72)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rMd),
            borderSide: const BorderSide(color: T.accent, width: 1.5),
          ),
        ),
      ),
      home: switch (windowType) {
        AppWindowType.main => MainScreen(
          store: appStore,
          bridge: appBridge,
          localServiceController: localServiceController,
          desktopTrayService: desktopTrayService,
          taskNotificationService: taskNotificationService,
          pathOpener: pathOpener,
          directoryPicker: directoryPicker,
          workspaceDataOperations: workspaceDataOperations,
          mainWindowSurfaceController: mainWindowSurfaceController,
          smoke: smoke,
        ),
        AppWindowType.taskProcessing => TaskProcessingWindow(
          taskId: taskId,
          initialSection: workspaceSection,
          bridge: appBridge,
          pathOpener: pathOpener,
          directoryProbe: directoryProbe,
          smoke: smoke,
        ),
        _ => SettingsWindow(
          type: windowType,
          store: appStore,
          bridge: appBridge,
          localServiceController: localServiceController,
          pathOpener: pathOpener,
          directoryProbe: directoryProbe,
          directoryPicker: directoryPicker,
          smoke: smoke,
        ),
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.store,
    required this.bridge,
    this.localServiceController,
    this.desktopTrayService,
    this.taskNotificationService,
    this.pathOpener,
    this.directoryPicker,
    this.workspaceDataOperations,
    this.mainWindowSurfaceController,
    this.smoke,
  });

  final WindowStateStore store;
  final WindowStateBridge bridge;
  final LocalServiceController? localServiceController;
  final DesktopTrayService? desktopTrayService;
  final TaskNotificationService? taskNotificationService;
  final PathOpener? pathOpener;
  final SettingsDirectoryPicker? directoryPicker;
  final WorkspaceDataOperations? workspaceDataOperations;
  final MainWindowSurfaceController? mainWindowSurfaceController;
  final AppSmokeArgs? smoke;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  static const _exitRpcTimeout = Duration(milliseconds: 500);
  static const _exitProcessTimeout = Duration(milliseconds: 500);
  static const _exitPluginTimeout = Duration(milliseconds: 750);
  static const _toolWindowInventoryTimeout = Duration(milliseconds: 750);

  late final LocalServiceController _service;
  late final bool _ownsService;
  late final MainWindowController _controller;
  SmokeWindowsNotificationSink? _smokeNotificationSink;
  late final TaskNotificationObserver _notificationObserver;
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'main-smoke-render');
  final GlobalKey _mainMenuAnchorKey = GlobalKey(
    debugLabel: 'main-menu-anchor',
  );
  final Map<String, WindowController> _toolWindows = {};
  DesktopTrayService? _trayService;
  StreamSubscription<DesktopTrayAction>? _trayActionSubscription;
  bool _trayReady = false;
  bool _exitRequested = false;
  bool _exitRequestInProgress = false;
  bool _trayHideInProgress = false;
  bool _trayCloseEventObserved = false;
  bool _trayHideAttempted = false;
  String _trayHideError = '';
  bool _dropTargetHover = false;
  bool _dropTargetDown = false;
  late final MainWindowSurfaceController _mainWindowSurface;
  bool _applicationSettingsVisible = false;
  bool _applicationSettingsUseOverlay = false;
  bool _applicationSettingsChanging = false;
  bool _applicationSettingsClosing = false;
  bool _workspaceManagementBusy = false;
  Rect? _applicationSettingsOriginalBounds;
  Rect? _applicationSettingsExpectedBounds;
  late final AnimationController _applicationSettingsAnimation =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
        reverseDuration: const Duration(milliseconds: 160),
      );
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
    _service =
        widget.localServiceController ??
        LocalServiceController(supervisor: _localServiceSupervisor());
    _ownsService = widget.localServiceController == null;
    _mainWindowSurface =
        widget.mainWindowSurfaceController ??
        const SystemMainWindowSurfaceController();
    _notificationObserver = TaskNotificationObserver(_notificationService());
    _controller = MainWindowController(service: _service)
      ..addListener(_syncBridgeState);
    widget.bridge.attachServiceCaller((method, params) async {
      await _service.start();
      final client = _service.client;
      if (client == null) throw StateError('本地服务未连接');
      return client.call(method, params);
    });
    widget.bridge.attachToolWindowOpener(_openToolWindowFromArgs);
    widget.bridge.attachServiceRefresher(_controller.refreshSnapshot);
    registerNativeWindowCloseHandler(_handleNativeWindowClose);
    unawaited(_controller.startService());
    if (widget.smoke == null ||
        widget.smoke?.checkTray == true ||
        widget.desktopTrayService != null) {
      unawaited(_initializeDesktopLifecycle());
    }
    final smoke = widget.smoke;
    if (smoke != null) {
      unawaited(_runStartupSmoke(smoke));
    }
  }

  @override
  void dispose() {
    registerNativeWindowCloseHandler(null);
    unawaited(_trayActionSubscription?.cancel());
    _trayActionSubscription = null;
    final trayService = _trayService;
    _trayService = null;
    if (trayService != null) unawaited(trayService.dispose());
    _controller.removeListener(_syncBridgeState);
    _controller.dispose();
    if (_ownsService) _service.dispose();
    _breathe.dispose();
    _drag.dispose();
    _applicationSettingsAnimation.dispose();
    super.dispose();
  }

  Future<void> _focusMainWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // Notification activation is best-effort; the in-window task state remains authoritative.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final view = _controller.view;
        final mainWorkspace = _buildMainWorkspace(view);
        final settingsOpen = _applicationSettingsVisible;
        final useOverlay = settingsOpen && _applicationSettingsUseOverlay;
        final surface = useOverlay
            ? Stack(
                key: const ValueKey('main-with-settings-overlay'),
                children: [
                  mainWorkspace,
                  Positioned.fill(child: _buildSettingsOverlayBarrier()),
                  Positioned(
                    top: 0,
                    right: 0,
                    width: applicationSettingsPanelWidth,
                    height: mainWindowSize.height,
                    child: _buildApplicationSettingsPanel(),
                  ),
                ],
              )
            : Stack(
                key: const ValueKey('main-with-settings-extension'),
                clipBehavior: Clip.hardEdge,
                children: [
                  mainWorkspace,
                  if (_workspaceManagementBusy)
                    Positioned(
                      left: 0,
                      top: 0,
                      width: mainWindowSize.width,
                      height: mainWindowSize.height,
                      child: const AbsorbPointer(
                        child: ColoredBox(color: Color(0x14000000)),
                      ),
                    ),
                  if (settingsOpen)
                    Positioned(
                      left: mainWindowSize.width,
                      top: 0,
                      width: applicationSettingsPanelWidth,
                      height: mainWindowSize.height,
                      child: _buildApplicationSettingsPanel(),
                    ),
                ],
              );
        return Material(
          color: T.bg,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: useOverlay || !settingsOpen
                  ? mainWindowSize.width
                  : applicationSettingsExpandedWindowSize.width,
              height: mainWindowSize.height,
              child: surface,
            ),
          ),
        );
      },
    );
  }

  Widget _buildMainWorkspace(MainWindowViewModel view) {
    return SizedBox(
      key: const ValueKey('main-workspace'),
      width: mainWindowSize.width,
      height: mainWindowSize.height,
      child: RepaintBoundary(
        key: _renderKey,
        child: Scaffold(
          body: DropTarget(
            onDragEntered: (_) => _drag.forward(),
            onDragExited: (_) {
              _drag.reverse();
              if (_dropTargetHover) {
                setState(() => _dropTargetHover = false);
              }
            },
            onDragDone: (detail) {
              _drag.reverse();
              if (_dropTargetHover || _dropTargetDown) {
                setState(() {
                  _dropTargetHover = false;
                  _dropTargetDown = false;
                });
              }
              final file = detail.files.isNotEmpty ? detail.files.first : null;
              final path = file?.path;
              if (path != null) {
                _controller.pickSource(path, name: file?.name);
              }
            },
            child: Container(
              decoration: BoxDecoration(
                color: T.bg,
                border: Border.all(color: T.line, width: 1),
              ),
              child: Column(
                children: [
                  TitleBar(
                    menuKey: const ValueKey('main-menu-button'),
                    menuAnchorKey: _mainMenuAnchorKey,
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
        ),
      ),
    );
  }

  Widget _buildSettingsOverlayBarrier() {
    return AnimatedBuilder(
      animation: _applicationSettingsAnimation,
      builder: (context, _) {
        final progress = Curves.easeOutCubic.transform(
          _applicationSettingsAnimation.value,
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap:
              _applicationSettingsChanging ||
                  _applicationSettingsClosing ||
                  _workspaceManagementBusy
              ? null
              : () => unawaited(_closeApplicationSettings()),
          child: ColoredBox(
            color: const Color(0xFF1F1C26).withValues(alpha: progress * 0.12),
          ),
        );
      },
    );
  }

  Widget _buildApplicationSettingsPanel() {
    return RepaintBoundary(
      key: const ValueKey('application-settings-shell'),
      child: ApplicationSettingsPanel(
        bridge: widget.bridge,
        service: _service,
        pathOpener: widget.pathOpener,
        workspaceOperations: widget.workspaceDataOperations,
        directoryPicker: widget.directoryPicker,
        onWorkspaceBusyChanged: (busy) {
          if (!mounted || _workspaceManagementBusy == busy) return;
          setState(() => _workspaceManagementBusy = busy);
        },
        entranceAnimation: _applicationSettingsAnimation,
        overlay: _applicationSettingsUseOverlay,
        onClose: () {
          if (_workspaceManagementBusy) return;
          unawaited(_closeApplicationSettings());
        },
      ),
    );
  }

  Widget _body(MainWindowViewModel view) {
    return Column(
      children: [
        Expanded(
          child: Align(alignment: Alignment.center, child: _subject(view)),
        ),
        if (view.state == MainState.empty ||
            view.state == MainState.ready ||
            view.state == MainState.blocked) ...[
          JobLine(
            view: view,
            onPickTranslation: _pickTranslation,
            onPickAsr: _pickAsr,
            onPickReasoning: _pickReasoningEffort,
            onSelectSourceLanguage: _controller.setSourceLang,
            onSelectTargetLanguage: _controller.setTargetLang,
            onPickBilingual: _pickBilingual,
            onPickFormats: _pickFormats,
            onPickTranslationStyle: _pickTranslationStyle,
            onToggleTerms: _toggleTerms,
            onPickMemoryCollections: _pickMemoryCollections,
            onConfigureTranslation: () =>
                _openToolWindow(AppWindowType.translationSettings),
            onConfigureAsr: () => _openToolWindow(AppWindowType.asrSettings),
          ),
          const SizedBox(height: T.s16),
        ],
        if (view.state != MainState.failed) ...[
          PrimaryAction(
            key: ValueKey(
              'main-cta-${view.state.name}-${_ctaVariant(view).name}',
            ),
            label: _ctaLabel(view),
            variant: _ctaVariant(view),
            onTap: () => _onCta(view),
          ),
          if (view.state == MainState.completed) ...[
            const SizedBox(height: T.s8),
            _TextAction(
              label: '制作新片源',
              onTap: () => unawaited(_controller.resetForNext()),
            ),
          ],
          const SizedBox(height: T.s4),
        ] else if (view.state == MainState.failed)
          const SizedBox(height: 50),
      ],
    );
  }

  Widget _subject(MainWindowViewModel view) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 300.0;
        final hasSource = view.state != MainState.empty;
        final objectHeight = hasSource
            ? (maxHeight - 96).clamp(126.0, 170.0).toDouble()
            : 170.0;
        final objectWidth = hasSource
            ? (objectHeight * 1.76).clamp(230.0, 300.0).toDouble()
            : 300.0;
        final captionHeight = hasSource
            ? (maxHeight - objectHeight - T.s8).clamp(64.0, 92.0).toDouble()
            : null;

        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: objectWidth,
              height: objectHeight,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_breathe, _drag]),
                  builder: (context, _) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: Size(objectWidth, objectHeight),
                          painter: SourceObjectPainter(
                            state: view.state,
                            progress: view.progress,
                            phaseIndex: view.runProgress?.phaseIndex ?? 0,
                            phaseCount: view.runProgress?.phaseCount ?? 9,
                            phaseProgress: view.runProgress?.phaseProgress ?? 0,
                            breathe: _breathe.value,
                            dragOver: _drag.value,
                            pickHover: _dropTargetHover,
                            pickDown: _dropTargetDown,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: T.s8),
            if (view.state == MainState.empty) ...[
              _emptyPrompt(),
              if (view.homeTaskReminder != null) ...[
                const SizedBox(height: T.s8),
                _PendingTaskSlip(
                  reminder: view.homeTaskReminder!,
                  onResume: _resumeHomeTaskReminder,
                  onOpen: () => _openToolWindow(
                    AppWindowType.taskProcessing,
                    taskId: view.homeTaskReminder!.taskId,
                  ),
                  onDismiss: () => _controller.dismissHomeTaskReminder(
                    view.homeTaskReminder!.taskId,
                  ),
                ),
              ],
            ] else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: captionHeight!),
                child: _subjectCaption(view),
              ),
          ],
        );
        return GestureDetector(
          behavior: view.state == MainState.empty
              ? HitTestBehavior.translucent
              : HitTestBehavior.deferToChild,
          onSecondaryTapDown: view.source == null
              ? null
              : (details) => _showSourceContextMenu(details.globalPosition),
          child: view.state == MainState.empty
              ? _DropPickTarget(
                  onTap: () => unawaited(_pickFile()),
                  onHoverChanged: (hover) =>
                      setState(() => _dropTargetHover = hover),
                  onDownChanged: (down) =>
                      setState(() => _dropTargetDown = down),
                  child: content,
                )
              : content,
        );
      },
    );
  }

  Widget _emptyPrompt() {
    return AnimatedBuilder(
      animation: _drag,
      builder: (context, _) {
        final active = _drag.value > 0.35;
        return _HeroPrompt(
          text: active ? '松手就收下啦' : '把音频、视频或字幕放进来吧',
          active: active,
        );
      },
    );
  }

  Widget _subjectCaption(MainWindowViewModel view) {
    final caption = switch (view.state) {
      MainState.empty => const SizedBox.shrink(),
      MainState.ready || MainState.blocked => _fileHeader(view),
      MainState.running => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileHeader(view, showType: false),
          const SizedBox(height: T.s4),
          _runningStatus(view),
        ],
      ),
      MainState.completed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileHeader(view, showType: false),
          if (view.completionNotice != null) ...[
            const SizedBox(height: T.s4),
            Text(
              view.completionNotice!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.tCaption.copyWith(color: T.warn),
            ),
          ],
          const SizedBox(height: T.s8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: T.s8,
            runSpacing: 6,
            children: [
              _Chip(label: '打开字幕', onTap: _openOutputFile),
              _Chip(label: '打开文件夹', onTap: _openOutputFolder),
              _Chip(label: '重新导出', onTap: _reexportResult),
            ],
          ),
        ],
      ),
      MainState.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileHeader(view, showType: false),
          const SizedBox(height: 6),
          _RepairStrip(
            failure: view.failure,
            onTap: () => _runRecovery(view.failure),
          ),
        ],
      ),
    };
    return caption;
  }

  Widget _runningStatus(MainWindowViewModel view) {
    final run = view.runProgress;
    if (run == null) {
      return Text(
        view.runningText ?? (view.canceling ? '正在取消…' : '制作中…'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(color: T.accentStrong),
      );
    }
    final detail = run.activity.isNotEmpty ? run.activity : run.detail;
    return _RunningStatusSlip(
      title: run.title,
      counter: run.counter,
      detail: detail,
      progress: view.progress,
      canceling: view.canceling,
    );
  }

  Widget _fileHeader(MainWindowViewModel view, {bool showType = true}) {
    final source = view.source;
    if (source == null) return const SizedBox.shrink();
    return Column(
      children: [
        DesignedTooltip(
          message: fileTooltipLabel(source.path, fallbackName: source.name),
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
        if (showType) ...[
          const SizedBox(height: T.s8),
          _TypeTag(kind: source.kind),
        ],
      ],
    );
  }

  String _ctaLabel(MainWindowViewModel view) {
    return switch (view.state) {
      MainState.empty => '选择片源',
      MainState.ready =>
        view.sourceInspectionPending
            ? '检查片源中…'
            : view.submitting
            ? '提交中…'
            : '开始译制',
      MainState.blocked => !view.translationConfigured ? '去配置翻译' : '去配置识别',
      MainState.running => view.canceling ? '取消中…' : '取消任务',
      MainState.completed => '审看结果',
      MainState.failed => view.failure?.actionLabel ?? '重试',
    };
  }

  CtaVariant _ctaVariant(MainWindowViewModel view) {
    if (view.state == MainState.ready && view.sourceInspectionPending) {
      return CtaVariant.disabled;
    }
    return switch (view.state) {
      MainState.empty => CtaVariant.filled,
      MainState.running => CtaVariant.outline,
      _ => CtaVariant.filled,
    };
  }

  void _onCta(MainWindowViewModel view) {
    switch (view.state) {
      case MainState.empty:
        unawaited(_pickFile());
        break;
      case MainState.ready:
        if (view.sourceInspectionPending) return;
        unawaited(_controller.submitRun());
        break;
      case MainState.blocked:
        if (!view.translationConfigured) {
          _openToolWindow(AppWindowType.translationSettings);
        } else {
          _openToolWindow(AppWindowType.asrSettings);
        }
        break;
      case MainState.running:
        unawaited(_controller.cancelRun());
        break;
      case MainState.completed:
        _openResultReview(view);
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
    if (mounted && (_dropTargetHover || _dropTargetDown)) {
      setState(() {
        _dropTargetHover = false;
        _dropTargetDown = false;
      });
    }
    if (path != null) _controller.pickSource(path, name: file?.name);
  }

  Future<void> _showChromeMenu() async {
    final anchorContext = _mainMenuAnchorKey.currentContext;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final anchor = anchorContext?.findRenderObject() as RenderBox?;
    if (overlay == null || anchor == null || !anchor.hasSize) return;
    final anchorRect = Rect.fromPoints(
      anchor.localToGlobal(Offset.zero, ancestor: overlay),
      anchor.localToGlobal(
        anchor.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    final selected = await showMenu<String>(
      context: context,
      color: T.surface,
      position: RelativeRect.fromRect(anchorRect, Offset.zero & overlay.size),
      items: [
        _menuItem('translation', '翻译模型设置'),
        _menuItem('asr', '语音识别设置'),
        _menuItem('history', '工作台'),
        const PopupMenuDivider(),
        _menuItem('application_settings', '应用设置'),
      ],
    );
    switch (selected) {
      case 'translation':
        _openToolWindow(AppWindowType.translationSettings);
        break;
      case 'asr':
        _openToolWindow(AppWindowType.asrSettings);
        break;
      case 'history':
        _openToolWindow(AppWindowType.taskProcessing);
        break;
      case 'application_settings':
        unawaited(_openApplicationSettings());
        break;
    }
  }

  PopupMenuItem<String> _menuItem(String value, String label) {
    return PopupMenuItem<String>(
      key: ValueKey('main-menu-$value'),
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
    final windowSize = MediaQuery.sizeOf(context);
    final reasoningAnchor = Rect.fromLTWH(
      windowSize.width <= 336 ? 8 : (windowSize.width - 320) / 2,
      windowSize.height * 0.28,
      320,
      36,
    );
    final selected = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(248, 318, 248, 0),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text('翻译模型', style: T.tSection),
        ),
        if (view.translationOptions.isEmpty)
          const PopupMenuItem<Object>(
            enabled: false,
            child: Text('还没有常用翻译模型', style: T.tCaption),
          )
        else
          for (final option in view.translationOptions)
            _translationMenuItem(option),
        if (view.reasoningConfigurable) ...[
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            key: const ValueKey('translation-reasoning-effort'),
            value: _menuReasoningEffort,
            child: SizedBox(
              width: 300,
              child: Row(
                children: [
                  const Icon(
                    Icons.bolt_rounded,
                    size: 17,
                    color: T.accentStrong,
                  ),
                  const SizedBox(width: T.s8),
                  Text('本次思考程度', style: T.tBody),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      view.reasoningLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                  ),
                  const SizedBox(width: T.s4),
                  const Icon(
                    Icons.keyboard_arrow_right_rounded,
                    size: 17,
                    color: T.muted,
                  ),
                ],
              ),
            ),
          ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          key: const ValueKey('translation-more-models'),
          value: _menuMoreTranslationModels,
          child: Text('更多模型', style: T.tBody),
        ),
        PopupMenuItem<Object>(
          value: _menuFooter,
          child: Text(
            '去翻译模型设置',
            style: T.tBody.copyWith(color: T.accentStrong),
          ),
        ),
      ],
    );
    if (identical(selected, _menuFooter)) {
      _openToolWindow(AppWindowType.translationSettings);
      return;
    }
    if (identical(selected, _menuMoreTranslationModels)) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      await _selectDirectTranslation();
      return;
    }
    if (identical(selected, _menuReasoningEffort)) {
      await Future<void>.delayed(const Duration(milliseconds: 140));
      if (!mounted) return;
      await _pickReasoningEffort(anchorRect: reasoningAnchor);
      return;
    }
    if (selected is TranslationRuntimeChoice) {
      _controller.selectTranslation(selected);
    }
  }

  Future<void> _selectDirectTranslation() async {
    final direct = await _pickDirectTranslation();
    if (!mounted || direct == null) return;
    _controller.selectTranslation(direct);
  }

  Future<TranslationRuntimeChoice?> _pickDirectTranslation() async {
    final view = _controller.view;
    final selected = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(248, 318, 248, 0),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text('更多翻译模型', style: T.tSection),
        ),
        if (view.translationDirectOptions.isEmpty)
          const PopupMenuItem<Object>(
            enabled: false,
            child: Text('还没有可用翻译模型', style: T.tCaption),
          )
        else
          for (final option in view.translationDirectOptions)
            _translationMenuItem(option),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: _menuFooter,
          child: Text(
            '去翻译模型设置',
            style: T.tBody.copyWith(color: T.accentStrong),
          ),
        ),
      ],
    );
    if (identical(selected, _menuFooter)) {
      _openToolWindow(AppWindowType.translationSettings);
      return null;
    }
    return selected is TranslationRuntimeChoice ? selected : null;
  }

  Future<void> _pickAsr() async {
    final view = _controller.view;
    final selected = await _showOptionMenu<TaskOption>(
      title: '语音识别引擎',
      options: view.asrOptions,
      emptyLabel: '还没有可用识别引擎',
      footerLabel: '去语音识别设置',
      onFooter: () => _openToolWindow(AppWindowType.asrSettings),
      labelOf: (option) => option.label,
      detailOf: (option) => option.detail,
      enabledOf: (option) => option.configured,
    );
    if (selected != null) _controller.selectAsr(selected);
  }

  Future<void> _pickReasoningEffort({Rect? anchorRect}) async {
    final view = _controller.view;
    final selected = await showReasoningEffortPicker(
      context,
      support: view.reasoningSupport,
      anchorRect: anchorRect,
    );
    if (selected != null) _controller.selectReasoningEffortValue(selected);
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
        ['LRC'],
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

  Future<void> _pickTranslationStyle() async {
    await _service.start();
    final client = _service.client;
    if (client == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地服务尚未连接，暂时无法读取风格库。')));
      }
      return;
    }
    final view = _controller.view;
    final selected = await showDialog<TranslationStyleDetail>(
      context: context,
      barrierDismissible: false,
      builder: (context) => TranslationStylePickerDialog(
        client: client,
        selectedStyleId: view.translationStyleId,
        onManageLibrary: () => _openToolWindow(
          AppWindowType.taskProcessing,
          workspaceSection: 'terminology',
        ),
      ),
    );
    if (selected != null) _controller.setTranslationStyle(selected);
  }

  Future<void> _pickMemoryCollections() async {
    await _service.start();
    final client = _service.client;
    if (client == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地服务尚未连接，暂时无法读取术语库。')));
      }
      return;
    }
    final view = _controller.view;
    final selected = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MemoryLibraryDialog(
        client: client,
        selectedCollectionIds: view.memoryCollectionIds,
        selectionOnly: true,
        suggestedSourceLanguage: view.sourceLang,
        suggestedTargetLanguage: view.targetLang,
        onManageLibrary: () => _openToolWindow(
          AppWindowType.taskProcessing,
          workspaceSection: 'terminology',
        ),
      ),
    );
    if (selected != null) _controller.setMemoryCollectionIds(selected);
  }

  Future<TValue?> _showOptionMenu<TValue>({
    required String title,
    required List<TValue> options,
    required String emptyLabel,
    required String Function(TValue option) labelOf,
    String Function(TValue option)? detailOf,
    bool Function(TValue option)? enabledOf,
    Key? Function(TValue option)? keyOf,
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
              key: keyOf?.call(option),
              value: option as Object,
              enabled: enabledOf?.call(option) ?? true,
              child: Builder(
                builder: (context) {
                  final detail = detailOf?.call(option) ?? '';
                  if (detail.isEmpty) {
                    return Text(labelOf(option), style: T.tBody);
                  }
                  return SizedBox(
                    width: 260,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(labelOf(option), style: T.tBody),
                        const SizedBox(height: 2),
                        Text(detail, style: T.tCaption),
                      ],
                    ),
                  );
                },
              ),
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

  PopupMenuItem<Object> _translationMenuItem(TranslationRuntimeChoice option) {
    return PopupMenuItem<Object>(
      key: ValueKey(
        'translation-choice-${option.source.name}-${option.provider ?? ''}-${option.model ?? ''}',
      ),
      value: option,
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              option.label,
              style: T.tBody,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (option.detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                option.detail,
                style: T.tCaption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _runRecovery(MainFailureView? failure) async {
    switch (failure?.target ?? MainRecoveryTarget.retry) {
      case MainRecoveryTarget.translationSettings:
        _openToolWindow(AppWindowType.translationSettings);
        break;
      case MainRecoveryTarget.asrSettings:
        _openToolWindow(AppWindowType.asrSettings);
        break;
      case MainRecoveryTarget.pickSource:
        await _pickFile();
        break;
      case MainRecoveryTarget.resume:
        unawaited(_controller.resumeRun());
        break;
      case MainRecoveryTarget.retry:
        unawaited(_controller.retryRun());
        break;
      case MainRecoveryTarget.cancel:
        unawaited(_controller.cancelRun());
        break;
      case MainRecoveryTarget.outputDirectory:
        await _pickOutputDirectoryAndRetry();
        break;
      case MainRecoveryTarget.reexportDirectory:
        await _pickOutputDirectoryAndReexport();
        break;
      case MainRecoveryTarget.reexport:
        unawaited(_reexportResult());
        break;
      case MainRecoveryTarget.taskProcessing:
        await _openToolWindow(
          AppWindowType.taskProcessing,
          taskId: _controller.view.taskId,
        );
        break;
    }
  }

  Future<void> _resumeHomeTaskReminder() async {
    try {
      await _controller.resumeHomeTaskReminder();
    } on Object catch (error) {
      _toast('$error');
    }
  }

  Future<void> _pickOutputDirectoryAndRetry() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择输出目录',
        lockParentWindow: true,
        initialDirectory: _controller.view.outputDirectory,
      );
      if (selected == null || selected.trim().isEmpty) return;
      _controller.setOutputDirectory(selected);
      _toast('已选择输出目录，正在重试');
      unawaited(_controller.retryRun());
    } on Object catch (error) {
      _toast('选择输出目录失败：$error');
    }
  }

  Future<void> _pickOutputDirectoryAndReexport() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择输出目录',
        lockParentWindow: true,
        initialDirectory: _controller.view.outputDirectory,
      );
      if (selected == null || selected.trim().isEmpty) return;
      _controller.setOutputDirectory(selected);
      _toast('已选择输出目录，正在重新导出');
      unawaited(_reexportResult(outputDirectory: selected));
    } on Object catch (error) {
      _toast('选择输出目录失败：$error');
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

  Future<void> _reexportResult({String? outputDirectory}) async {
    try {
      if (outputDirectory == null || outputDirectory.trim().isEmpty) {
        await _controller.reexportResult();
      } else {
        await _controller.reexportResultToDirectory(outputDirectory);
      }
      _toast('已重新导出字幕');
    } on Object catch (error) {
      _toast('重新导出失败：$error');
    }
  }

  Future<void> _openResultReview(MainWindowViewModel view) async {
    final taskId = view.taskId?.trim();
    if (taskId == null || taskId.isEmpty) {
      _toast('没有可审看的任务结果');
      return;
    }
    await _openToolWindow(AppWindowType.taskProcessing, taskId: taskId);
  }

  Future<void> _openToolWindowFromArgs(AppWindowArgs args) {
    return _openToolWindow(
      args.type,
      taskId: args.taskId,
      workspaceSection: args.workspaceSection,
    );
  }

  Future<void> _openApplicationSettings() async {
    if (_applicationSettingsVisible ||
        _applicationSettingsChanging ||
        _applicationSettingsClosing) {
      return;
    }
    _applicationSettingsChanging = true;
    Rect? initialBounds;
    try {
      initialBounds = await _mainWindowSurface.getBounds();
      if (initialBounds == null) {
        _toast('无法读取主窗口位置，请稍后重试');
        return;
      }
      final visibleBounds = await _mainWindowSurface.visibleBoundsFor(
        initialBounds,
      );
      final plan = applicationSettingsExpansionPlanFor(
        initialBounds,
        visibleBounds,
      );
      _applicationSettingsOriginalBounds = initialBounds;
      _applicationSettingsExpectedBounds = plan.windowBounds;
      if (!_sameWindowBounds(initialBounds, plan.windowBounds)) {
        await _mainWindowSurface.setBounds(plan.windowBounds);
        _applicationSettingsExpectedBounds =
            await _mainWindowSurface.getBounds() ?? plan.windowBounds;
      }
      if (!mounted) return;
      setState(() {
        _applicationSettingsUseOverlay = plan.useOverlay;
        _applicationSettingsVisible = true;
      });
      _applicationSettingsChanging = false;
      if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
        _applicationSettingsAnimation.value = 1;
      } else {
        unawaited(_applicationSettingsAnimation.forward(from: 0));
      }
    } on Object catch (error) {
      final expected = _applicationSettingsExpectedBounds;
      if (initialBounds != null && expected != null) {
        try {
          final current = await _mainWindowSurface.getBounds();
          if (current != null && _sameWindowBounds(current, expected)) {
            await _mainWindowSurface.setBounds(initialBounds);
          }
        } on Object {
          // The panel remains closed even if best-effort bounds recovery fails.
        }
      }
      _applicationSettingsAnimation.value = 0;
      _applicationSettingsOriginalBounds = null;
      _applicationSettingsExpectedBounds = null;
      if (!mounted) return;
      setState(() {
        _applicationSettingsVisible = false;
        _applicationSettingsUseOverlay = false;
      });
      _toast('打开应用设置失败：$error');
    } finally {
      _applicationSettingsChanging = false;
    }
  }

  Future<void> _closeApplicationSettings({bool animate = true}) async {
    if (!_applicationSettingsVisible || _applicationSettingsClosing) return;
    _applicationSettingsClosing = true;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    try {
      final current = await _mainWindowSurface.getBounds();
      final original = _applicationSettingsOriginalBounds;
      final expected = _applicationSettingsExpectedBounds;
      final target = _collapsedBoundsAfterApplicationSettings(
        current: current,
        original: original,
        expected: expected,
      );
      final resizeNeeded =
          target != null &&
          (current == null || !_sameWindowBounds(current, target));
      if (animate && !reduceMotion) {
        await _applicationSettingsAnimation.reverse();
        await WidgetsBinding.instance.endOfFrame;
        if (resizeNeeded) await _mainWindowSurface.setBounds(target);
      } else {
        _applicationSettingsAnimation
          ..stop()
          ..value = 0;
        if (resizeNeeded) await _mainWindowSurface.setBounds(target);
      }
      if (!mounted) return;
      setState(() => _applicationSettingsVisible = false);
      _applicationSettingsOriginalBounds = null;
      _applicationSettingsExpectedBounds = null;
      if (mounted) {
        setState(() => _applicationSettingsUseOverlay = false);
      }
    } on Object catch (error) {
      final expected = _applicationSettingsExpectedBounds;
      if (expected != null) {
        try {
          final current = await _mainWindowSurface.getBounds();
          if (current != null && !_sameWindowBounds(current, expected)) {
            await _mainWindowSurface.setBounds(expected);
          }
        } on Object {
          // Keep the still-visible panel usable at the best available size.
        }
      }
      _applicationSettingsAnimation.value = 1;
      if (!mounted) return;
      _toast('收起应用设置失败：$error');
    } finally {
      _applicationSettingsClosing = false;
    }
  }

  Rect? _collapsedBoundsAfterApplicationSettings({
    required Rect? current,
    required Rect? original,
    required Rect? expected,
  }) {
    if (current == null) return original;
    if (original != null &&
        expected != null &&
        _sameWindowBounds(current, expected)) {
      return original;
    }
    return Rect.fromLTWH(
      current.left,
      current.top,
      mainWindowSize.width,
      mainWindowSize.height,
    );
  }

  bool _sameWindowBounds(Rect a, Rect b) {
    const tolerance = 2.0;
    return (a.left - b.left).abs() <= tolerance &&
        (a.top - b.top).abs() <= tolerance &&
        (a.width - b.width).abs() <= tolerance &&
        (a.height - b.height).abs() <= tolerance;
  }

  Future<void> _openToolWindow(
    AppWindowType type, {
    String? taskId,
    String? workspaceSection,
  }) async {
    final parentBounds = await _currentWindowBounds();
    final args = AppWindowArgs(
      type: type,
      taskId: taskId,
      workspaceSection: workspaceSection,
      parentBounds: parentBounds,
      visibleBounds: await currentDisplayVisibleBoundsFor(parentBounds),
    );
    final windowKey = _toolWindowKey(type, taskId: taskId);
    final existing = _toolWindows[windowKey];
    if (existing != null) {
      try {
        if (type == AppWindowType.taskProcessing) {
          await existing.invokeMethod<void>('window_retarget', args.encode());
        } else {
          await existing.invokeMethod<void>('window_focus');
        }
        return;
      } on Object {
        _toolWindows.remove(windowKey);
      }
    }
    try {
      final controller = await WindowController.create(
        WindowConfiguration(hiddenAtLaunch: true, arguments: args.encode()),
      );
      _toolWindows[windowKey] = controller;
      // Child windows reveal themselves after their first Flutter frame. Showing
      // here races the child render path and can expose a blank native window.
    } on Object catch (exc) {
      _toast('打开${type.title}失败：$exc');
    }
  }

  String _toolWindowKey(AppWindowType type, {String? taskId}) {
    if (type == AppWindowType.taskProcessing) {
      return type.id;
    }
    return '${type.id}:${taskId?.trim() ?? ''}';
  }

  Future<Rect?> _currentWindowBounds() async {
    try {
      return await windowManager.getBounds();
    } on Object {
      return null;
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
