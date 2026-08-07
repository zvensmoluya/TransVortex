import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../model/startup_args.dart';
import '../model/task_labels.dart';
import '../model/window_state.dart';
import '../services/app_service_client.dart';
import '../services/current_window_controls.dart';
import '../services/directory_probe.dart';
import '../services/local_service_controller.dart';
import '../services/native_window_lifecycle.dart';
import '../services/path_opener.dart';
import '../services/smoke_render_capture.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'result_review_workspace.dart';
import 'title_bar.dart';

part 'task_processing_window/task_actions.dart';
part 'task_processing_window/task_data.dart';
part 'task_processing_window/task_editor_lifecycle.dart';
part 'task_processing_window/task_processing_widgets.dart';
part 'task_processing_window/task_smoke.dart';

class _SmokeTaskProcessingTransport implements AppServiceTransport {
  _SmokeTaskProcessingTransport(this.service);

  final LocalServiceController service;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    await service.start();
    final client = service.client;
    if (client == null) {
      throw StateError('本地服务未连接，无法执行任务处理 smoke');
    }
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() => service.shutdown();
}

class _TaskProcessingClientTransport implements AppServiceTransport {
  const _TaskProcessingClientTransport(this.client);

  final AppServiceClient client;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() async {}
}

enum _TaskFilter { all, active, needsAction, review, done, cancelled }

class TaskProcessingWindow extends StatefulWidget {
  const TaskProcessingWindow({
    super.key,
    required this.taskId,
    required this.bridge,
    this.pathOpener,
    this.directoryProbe,
    this.smoke,
  });

  final String? taskId;
  final WindowStateBridge bridge;
  final PathOpener? pathOpener;
  final DirectoryWriteProbe? directoryProbe;
  final AppSmokeArgs? smoke;

  @override
  State<TaskProcessingWindow> createState() => _TaskProcessingWindowState();
}

class _TaskProcessingWindowState extends State<TaskProcessingWindow> {
  late final AppServiceClient _client;
  late final AppServiceTransport _embeddedResultTransport;
  late final PathOpener _pathOpener;
  late final DirectoryWriteProbe _directoryProbe;
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'task-processing-smoke');
  final TextEditingController _taskSearchController = TextEditingController();
  final TextEditingController _eventSearchController = TextEditingController();
  LocalServiceController? _smokeService;
  List<TaskSummary> _tasks = const [];
  TaskEventsPage? _eventsPage;
  String? _selectedTaskId;
  _TaskFilter _taskFilter = _TaskFilter.all;
  String? _message;
  String? _error;
  bool _loadingTasks = false;
  bool _loadingEvents = false;
  bool _loadingMoreEvents = false;
  bool _resuming = false;
  String? _retranslatingTaskId;
  String? _reexportingTaskId;
  String? _cancellingTaskId;
  bool _checkingOutputDirectory = false;
  String? _editingTaskId;
  bool _resultEditorDirty = false;
  bool _windowCloseAllowed = false;
  bool _windowCloseRequestInProgress = false;
  Future<bool>? _windowCloseApproval;
  bool _smokeRejectWindowClose = false;
  String _smokeScenario = 'browse';
  int _smokeResultSegmentCount = 0;
  int _smokeResultIssueCount = 0;
  bool _smokeEditSaved = false;
  bool _smokeReexported = false;
  bool _smokeOutputContainsEdit = false;
  String _smokeEditedText = '';
  double _smokeEditedStart = 0;
  double _smokeEditedEnd = 0;
  bool _smokeTimingSaved = false;
  bool _smokeOutputUsesRequestedTiming = false;
  String _smokeReexportFormat = '';
  bool? _smokeReexportBilingual;
  String _smokeReexportBilingualOrder = '';
  bool? _smokeReexportPreferSingleLine;
  bool _smokeReexportStyleApplied = false;
  bool _smokeReexportOutputUsesRequestedOrder = false;
  bool _smokeResumeAttempted = false;
  bool _smokeResumeOk = false;
  String _smokeResumeStatus = '';
  bool _smokeCancelAttempted = false;
  bool _smokeCancelOk = false;
  String _smokeCancelStatus = '';
  bool _smokeOutputDirectoryChecked = false;
  bool _smokeOutputDirectoryWritable = false;
  String _smokeOutputDirectoryPath = '';
  String _smokeOutputDirectoryMessage = '';

  @override
  void initState() {
    super.initState();
    _client = AppServiceClient(_processingTransport());
    _embeddedResultTransport = _TaskProcessingClientTransport(_client);
    _pathOpener = widget.pathOpener ?? SystemPathOpener();
    _directoryProbe = widget.directoryProbe ?? SystemDirectoryWriteProbe();
    _selectedTaskId = widget.taskId?.trim();
    _editingTaskId = widget.taskId?.trim();
    _taskSearchController.addListener(_handleTaskSearchChanged);
    _eventSearchController.addListener(_handleEventSearchChanged);
    if (widget.smoke == null) {
      unawaited(widget.bridge.initializeChild());
    }
    registerCurrentWindowRetargetHandler(_retarget);
    registerCurrentWindowCloseRequestHandler(_approveWindowCloseRequest);
    registerCurrentWindowCommandHandler(_handleWindowCommand);
    registerNativeWindowCloseHandler(_handleNativeWindowClose);
    unawaited(_installWindowCloseGuard());
    unawaited(_loadTasks());
  }

  @override
  void dispose() {
    registerCurrentWindowRetargetHandler(null);
    registerCurrentWindowCloseRequestHandler(null);
    registerCurrentWindowCommandHandler(null);
    registerNativeWindowCloseHandler(null);
    _taskSearchController.dispose();
    _eventSearchController.dispose();
    _smokeService?.dispose();
    super.dispose();
  }

  AppServiceTransport _processingTransport() {
    final smoke = widget.smoke;
    if (smoke == null) return WindowBridgeTransport(widget.bridge);
    final service = LocalServiceController(
      supervisor: LocalServiceSupervisor(serviceRoot: _serviceRoot(smoke)),
    );
    _smokeService = service;
    return _SmokeTaskProcessingTransport(service);
  }

  Directory? _serviceRoot(AppSmokeArgs smoke) {
    final root = smoke.serviceRoot;
    if (root == null || root.isEmpty) return null;
    return Directory(root);
  }

  void _setTaskProcessingState(VoidCallback update) => setState(update);

  @override
  Widget build(BuildContext context) {
    final searchQuery = _taskSearchController.text;
    final listTasks = _tasks;
    final visibleTasks = _visibleTasksFor(listTasks, _taskFilter, searchQuery);
    final selected = _selectedTask(visibleTasks);
    final selectedEventsPage = _eventsPage?.taskId == selected?.taskId
        ? _eventsPage
        : null;
    final events = selectedEventsPage?.events ?? const <Object?>[];
    final editingTaskId = selected?.isDone == true
        ? _editingTaskId?.trim()
        : null;
    return RepaintBoundary(
      key: _renderKey,
      child: Scaffold(
        backgroundColor: T.bg,
        body: Column(
          children: [
            TitleBar(
              title: '任务处理',
              status: _statusText(selected),
              canMaximize: true,
              onClose: () => unawaited(_requestWindowClose()),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s24),
                child: _TaskProcessingBody(
                  tasks: visibleTasks,
                  totalTaskCount: listTasks.length,
                  filter: _taskFilter,
                  filterCounts: _taskFilterCounts(listTasks, searchQuery),
                  searchController: _taskSearchController,
                  selected: selected,
                  events: events,
                  eventSearchController: _eventSearchController,
                  editingTaskId: editingTaskId == selected?.taskId
                      ? editingTaskId
                      : null,
                  resultEditorDirty: _resultEditorDirty,
                  bridge: widget.bridge,
                  resultTransportOverride: _embeddedResultTransport,
                  message: _message,
                  error: _error,
                  loadingTasks: _loadingTasks,
                  loadingEvents: _loadingEvents,
                  loadingMoreEvents: _loadingMoreEvents,
                  eventsHasMore: selectedEventsPage?.hasMore == true,
                  resuming: _resuming,
                  retranslatingTaskId: _retranslatingTaskId,
                  reexportingTaskId: _reexportingTaskId,
                  cancellingTaskId: _cancellingTaskId,
                  checkingOutputDirectory: _checkingOutputDirectory,
                  onRefresh: _loadTasks,
                  onFilterChanged: (filter) =>
                      unawaited(_setTaskFilter(filter)),
                  onClearSearch: _taskSearchController.clear,
                  onSelectTask: (task) => unawaited(_selectTask(task)),
                  onLoadMoreEvents: selected == null
                      ? null
                      : () => unawaited(_loadMoreEvents(selected.taskId)),
                  onClearEventSearch: _eventSearchController.clear,
                  onOpenResult: (task) => unawaited(_openResult(task)),
                  onCloseEditor: () => unawaited(_leaveResultEditor()),
                  onResultDirtyChanged: _handleResultDirtyChanged,
                  onResultChanged: () => unawaited(_loadTasks()),
                  onResume: (task) => unawaited(_resumeTask(task)),
                  onRetranslate: (task) => unawaited(_retranslateTask(task)),
                  onCancel: (task) => unawaited(_cancelTask(task)),
                  onOpenFailureRecovery: (task) =>
                      unawaited(_openFailureRecoverySettings(task)),
                  onReexport: (task) => unawaited(
                    _recoverTaskOutput(task, chooseDirectory: false),
                  ),
                  onChooseOutputDirectory: (task) => unawaited(
                    _recoverTaskOutput(task, chooseDirectory: true),
                  ),
                  onOpenTaskDirectory: (task) =>
                      unawaited(_openTaskDirectory(task)),
                  onOpenOutputDirectory: (task) =>
                      unawaited(_openOutputDirectory(task)),
                  onCheckOutputDirectory: (task) =>
                      unawaited(_checkOutputDirectory(task)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(TaskSummary? selected) {
    if (_loadingTasks) return '读取任务中';
    if (_resuming) return '继续任务中';
    if (_reexportingTaskId != null) return '重新导出中';
    if (_checkingOutputDirectory) return '检查结果目录中';
    if (_error != null) return '任务处理暂不可用';
    if (selected == null) return '任务片列';
    return '${taskStatusLabel(selected.status)} · 任务片列';
  }
}
