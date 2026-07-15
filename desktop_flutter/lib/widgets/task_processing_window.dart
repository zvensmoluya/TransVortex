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

  Future<void> _loadTasks() async {
    setState(() {
      _loadingTasks = true;
      _message = null;
      _error = null;
    });
    try {
      final tasks = await _client.taskList();
      if (!mounted) return;
      final selected = _selectedTask(
        _visibleTasksFor(tasks, _taskFilter, _taskSearchController.text),
      );
      final previousTaskId = _selectedTaskId;
      setState(() {
        _tasks = tasks;
        _selectedTaskId = selected?.taskId;
        if (previousTaskId != selected?.taskId) {
          _setEventSearchTextSilently('');
        }
        _loadingTasks = false;
        _message = tasks.isEmpty ? '还没有任务记录。' : '已读取 ${tasks.length} 个任务。';
      });
      if (selected != null) {
        if (widget.smoke != null) {
          await _loadEvents(selected.taskId);
        } else {
          unawaited(_loadEvents(selected.taskId));
        }
      }
      if (widget.smoke != null) {
        var reportTasks = tasks;
        var reportSelected = selected;
        if (selected != null) {
          await _runSmokeScenario(selected);
          if (_smokeScenario == 'review') {
            reportSelected = _selectedTask(
              _visibleTasksFor(
                reportTasks,
                _taskFilter,
                _taskSearchController.text,
              ),
            );
          } else if (_smokeScenario == 'edit') {
            reportTasks = await _client.taskList();
            reportSelected = _selectedTask(reportTasks);
            if (mounted && reportSelected != null) {
              setState(() {
                _tasks = reportTasks;
                _selectedTaskId = reportSelected?.taskId;
                _editingTaskId = null;
              });
              await WidgetsBinding.instance.endOfFrame;
              if (mounted) {
                setState(() => _editingTaskId = reportSelected?.taskId);
                await Future<void>.delayed(const Duration(milliseconds: 300));
                if (mounted) await WidgetsBinding.instance.endOfFrame;
              }
            }
          } else if (_smokeScenario == 'resume' || _smokeScenario == 'cancel') {
            reportTasks = await _client.taskList();
            reportSelected = _selectedTask(reportTasks);
            if (mounted) {
              setState(() {
                _tasks = reportTasks;
                _selectedTaskId = reportSelected?.taskId;
              });
            }
          }
        }
        await _writeSmokeReport(tasks: reportTasks, selected: reportSelected);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyTaskProcessingError(error);
        _loadingTasks = false;
      });
      if (widget.smoke != null) {
        await _writeSmokeReport(tasks: const [], error: error);
      }
    }
  }

  Future<void> _retarget(AppWindowArgs args) async {
    if (args.type != AppWindowType.taskProcessing) return;
    final taskId = args.taskId?.trim();
    if (taskId != null && taskId.isNotEmpty) {
      if (taskId != _editingTaskId && !await _leaveResultEditor()) return;
      _setTaskSearchTextSilently('');
      _setEventSearchTextSilently('');
      _selectedTaskId = taskId;
      _editingTaskId = taskId;
      _resultEditorDirty = false;
      _taskFilter = _TaskFilter.all;
    }
    await _loadTasks();
  }

  List<TaskSummary> _visibleTasksFor(
    List<TaskSummary> tasks,
    _TaskFilter filter,
    String searchQuery,
  ) {
    return tasks
        .where(
          (task) =>
              _taskMatchesFilter(task, filter) &&
              _taskMatchesSearch(task, searchQuery),
        )
        .toList(growable: false);
  }

  Map<_TaskFilter, int> _taskFilterCounts(
    List<TaskSummary> tasks,
    String searchQuery,
  ) {
    return {
      for (final filter in _TaskFilter.values)
        filter: tasks
            .where(
              (task) =>
                  _taskMatchesFilter(task, filter) &&
                  _taskMatchesSearch(task, searchQuery),
            )
            .length,
    };
  }

  TaskSummary? _selectedTask(List<TaskSummary> tasks) {
    if (tasks.isEmpty) return null;
    final selectedId = _selectedTaskId?.trim();
    if (selectedId != null && selectedId.isNotEmpty) {
      for (final task in tasks) {
        if (task.taskId == selectedId) return task;
      }
    }
    return tasks.first;
  }

  Future<void> _setTaskFilter(_TaskFilter filter) async {
    if (_taskFilter == filter) return;
    if (!await _leaveResultEditor()) return;
    final visibleTasks = _visibleTasksFor(
      _tasks,
      filter,
      _taskSearchController.text,
    );
    final selected = _selectedTask(visibleTasks);
    final previousTaskId = _selectedTaskId;
    setState(() {
      _taskFilter = filter;
      _selectedTaskId = selected?.taskId;
      _editingTaskId = null;
      _resultEditorDirty = false;
      if (previousTaskId != selected?.taskId) {
        _setEventSearchTextSilently('');
      }
      _message = null;
      _error = null;
    });
    if (selected != null) {
      await _loadEvents(selected.taskId);
    }
  }

  void _handleTaskSearchChanged() {
    if (!mounted) return;
    if (_resultEditorDirty) return;
    final visibleTasks = _visibleTasksFor(
      _tasks,
      _taskFilter,
      _taskSearchController.text,
    );
    final selected = _selectedTask(visibleTasks);
    final previousTaskId = _selectedTaskId;
    final nextTaskId = selected?.taskId;
    setState(() {
      _selectedTaskId = nextTaskId;
      if (previousTaskId != nextTaskId) {
        _editingTaskId = null;
        _setEventSearchTextSilently('');
      }
      _message = null;
      _error = null;
    });
    if (selected != null && previousTaskId != nextTaskId) {
      unawaited(_loadEvents(selected.taskId));
    }
  }

  void _setTaskSearchTextSilently(String text) {
    _taskSearchController.removeListener(_handleTaskSearchChanged);
    _taskSearchController.text = text;
    _taskSearchController.addListener(_handleTaskSearchChanged);
  }

  void _handleEventSearchChanged() {
    if (mounted) setState(() {});
  }

  void _setEventSearchTextSilently(String text) {
    _eventSearchController.removeListener(_handleEventSearchChanged);
    _eventSearchController.text = text;
    _eventSearchController.addListener(_handleEventSearchChanged);
  }

  Future<void> _selectTask(TaskSummary task) async {
    if (_selectedTaskId == task.taskId && _eventsPage?.taskId == task.taskId) {
      return;
    }
    if (!await _leaveResultEditor()) return;
    setState(() {
      _selectedTaskId = task.taskId;
      _editingTaskId = null;
      _resultEditorDirty = false;
      _setEventSearchTextSilently('');
      _message = null;
      _error = null;
    });
    await _loadEvents(task.taskId);
  }

  Future<void> _loadEvents(String taskId) async {
    setState(() {
      _loadingEvents = true;
      _loadingMoreEvents = false;
    });
    try {
      final events = await _client.taskEvents(taskId, limit: 40);
      if (!mounted) return;
      setState(() {
        _eventsPage = events;
        _loadingEvents = false;
        _loadingMoreEvents = false;
      });
    } on Object catch (_) {
      if (!mounted) return;
      setState(() {
        _eventsPage = null;
        _loadingEvents = false;
        _loadingMoreEvents = false;
      });
    }
  }

  Future<void> _loadMoreEvents(String taskId) async {
    final current = _eventsPage;
    if (current == null || !current.hasMore || _loadingMoreEvents) return;
    setState(() {
      _loadingMoreEvents = true;
      _error = null;
    });
    try {
      final next = await _client.taskEvents(
        taskId,
        cursor: current.nextCursor,
        limit: 40,
      );
      if (!mounted || _selectedTaskId != taskId) return;
      setState(() {
        _eventsPage = TaskEventsPage(
          taskId: next.taskId.isEmpty ? taskId : next.taskId,
          events: [...current.events, ...next.events],
          cursor: current.cursor,
          nextCursor: next.nextCursor,
          hasMore: next.hasMore,
        );
        _loadingMoreEvents = false;
      });
    } on Object catch (error) {
      if (!mounted || _selectedTaskId != taskId) return;
      setState(() {
        _error = '读取更多事件失败：${_friendlyTaskProcessingError(error)}';
        _loadingMoreEvents = false;
      });
    }
  }

  Future<void> _openResult(TaskSummary task) async {
    if (!task.isDone) return;
    setState(() {
      _editingTaskId = task.taskId;
      _resultEditorDirty = false;
      _message = '正在处理字幕结果。';
      _error = null;
    });
  }

  Future<bool> _leaveResultEditor() async {
    if (_editingTaskId == null) return true;
    if (!await _confirmDiscardResultEdits() || !mounted) return false;
    setState(() {
      _editingTaskId = null;
      _resultEditorDirty = false;
    });
    return true;
  }

  Future<bool> _confirmDiscardResultEdits({bool closingWindow = false}) async {
    if (!_resultEditorDirty) return true;
    if (closingWindow) {
      unawaited(_focusWindowForClosePrompt());
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        surfaceTintColor: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rMd),
          side: const BorderSide(color: T.line),
        ),
        title: Row(
          children: [
            const Icon(Icons.edit_note_rounded, color: T.accentStrong),
            const SizedBox(width: T.s8),
            Text('放弃未保存修改？', style: T.tSection),
          ],
        ),
        content: Text(
          closingWindow ? '字幕修改尚未保存，关闭任务处理后这些修改会丢失。' : '字幕修改尚未保存，离开后这些修改会丢失。',
          style: T.tBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(closingWindow ? '继续校对' : '继续编辑'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(closingWindow ? '放弃并关闭' : '放弃修改'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _focusWindowForClosePrompt() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // The dialog still protects the edit if native focus is unavailable.
    }
  }

  Future<bool> _approveWindowCloseRequest() {
    if (_windowCloseAllowed) return Future<bool>.value(true);
    final pending = _windowCloseApproval;
    if (pending != null) return pending;
    late final Future<bool> approval;
    approval = _resolveWindowCloseRequest().whenComplete(() {
      if (identical(_windowCloseApproval, approval)) {
        _windowCloseApproval = null;
      }
    });
    _windowCloseApproval = approval;
    return approval;
  }

  Future<bool> _resolveWindowCloseRequest() async {
    if (_smokeRejectWindowClose) return false;
    final approved = await _confirmDiscardResultEdits(closingWindow: true);
    if (approved) _windowCloseAllowed = true;
    return approved;
  }

  Future<Object?> _handleWindowCommand(MethodCall call) async {
    if (call.method != 'window_smoke_set_close_refusal') {
      throw MissingPluginException('No handler for ${call.method}');
    }
    final arguments = call.arguments;
    final enabled =
        arguments == true || (arguments is Map && arguments['enabled'] == true);
    _smokeRejectWindowClose = enabled;
    return {'ok': true, 'enabled': enabled};
  }

  Future<void> _installWindowCloseGuard() async {
    try {
      await windowManager.setPreventClose(true);
    } on Object {
      // Unsupported test hosts still use the in-window close button guard.
    }
  }

  Future<void> _handleNativeWindowClose() async {
    if (_windowCloseAllowed) return;
    await _requestWindowClose();
  }

  Future<void> _requestWindowClose() async {
    if (_windowCloseRequestInProgress) return;
    _windowCloseRequestInProgress = true;
    try {
      if (!await _approveWindowCloseRequest()) return;
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object catch (error) {
      _windowCloseAllowed = false;
      if (mounted) {
        setState(() => _error = '关闭任务处理失败：$error');
      }
    } finally {
      _windowCloseRequestInProgress = false;
    }
  }

  void _handleResultDirtyChanged(bool dirty) {
    if (!mounted || _resultEditorDirty == dirty) return;
    setState(() => _resultEditorDirty = dirty);
  }

  Future<void> _resumeTask(TaskSummary task) async {
    if (!task.canResume || _resuming) return;
    setState(() {
      _resuming = true;
      _message = '正在继续任务…';
      _error = null;
    });
    try {
      final result = await _client.submitResume({
        'request_version': 1,
        'task_id': task.taskId,
      });
      if (!mounted) return;
      setState(() {
        _message = result.message.isNotEmpty ? result.message : '任务已重新排队。';
        _resuming = false;
      });
      await _loadTasks();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '继续任务失败：${_friendlyTaskProcessingError(error)}';
        _resuming = false;
      });
    }
  }

  Future<void> _retranslateTask(TaskSummary task) async {
    if (!task.isDone || _retranslatingTaskId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新翻译当前识别稿'),
        content: const Text('将使用已保存的识别稿和当前翻译设置创建新任务，不会重新运行语音识别。该操作会调用翻译模型。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.translate, size: 16),
            label: const Text('创建翻译任务'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _retranslatingTaskId = task.taskId;
      _message = '正在从已有识别稿创建翻译任务…';
      _error = null;
    });
    try {
      final result = await _client.retranslate(task.taskId);
      if (!mounted) return;
      _selectedTaskId = result.taskId;
      await _loadTasks();
      if (!mounted) return;
      setState(() {
        _message = result.message.isNotEmpty ? result.message : '新的翻译任务已排队。';
        _retranslatingTaskId = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '创建翻译任务失败：${_friendlyTaskProcessingError(error)}';
        _message = null;
        _retranslatingTaskId = null;
      });
    }
  }

  Future<void> _cancelTask(TaskSummary task) async {
    if (!task.canCancel || _cancellingTaskId != null) return;
    setState(() {
      _cancellingTaskId = task.taskId;
      _message = '正在请求取消任务…';
      _error = null;
    });
    try {
      final cancelled = await _client.cancel(task.taskId);
      if (!mounted) return;
      final message = cancelled.status == 'CANCEL_REQUESTED'
          ? '已请求取消任务。'
          : '任务已更新为${taskStatusLabel(cancelled.status)}。';
      setState(() {
        _selectedTaskId = cancelled.taskId.isEmpty
            ? task.taskId
            : cancelled.taskId;
        _cancellingTaskId = null;
      });
      await _loadTasks();
      if (!mounted || _error != null) return;
      setState(() {
        _message = message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '取消任务失败：${_friendlyTaskProcessingError(error)}';
        _message = null;
        _cancellingTaskId = null;
      });
    }
  }

  Future<void> _openTaskDirectory(TaskSummary task) async {
    final dir = task.taskDir.trim();
    if (dir.isEmpty) {
      setState(() {
        _error = '这个任务没有记录任务目录。';
        _message = null;
      });
      return;
    }
    await _openDirectory(dir, successMessage: '已打开任务目录');
  }

  Future<void> _openOutputDirectory(TaskSummary task) async {
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      setState(() {
        _error = '这个任务还没有输出目录。';
        _message = null;
      });
      return;
    }
    await _openDirectory(dir, successMessage: '已打开结果目录');
  }

  Future<void> _checkOutputDirectory(TaskSummary task) async {
    if (_checkingOutputDirectory) return;
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      setState(() {
        _error = '这个任务还没有输出目录。';
        _message = null;
      });
      return;
    }
    setState(() {
      _checkingOutputDirectory = true;
      _message = '正在检查结果目录…';
      _error = null;
    });
    try {
      final result = await _directoryProbe.checkWritable(dir);
      if (!mounted) return;
      setState(() {
        if (result.ok) {
          _message = '结果目录可写，可以重新导出。';
          _error = null;
        } else {
          _message = null;
          _error = '结果目录不可用：${result.message}';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '检查结果目录失败：$error';
      });
    } finally {
      if (mounted) setState(() => _checkingOutputDirectory = false);
    }
  }

  Future<void> _recoverTaskOutput(
    TaskSummary task, {
    required bool chooseDirectory,
  }) async {
    if (_reexportingTaskId != null) return;
    final recovery = taskFailurePresentation(
      error: task.error,
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    if (recovery.target != TaskFailureRecoveryTarget.outputDirectory &&
        recovery.target != TaskFailureRecoveryTarget.reexport) {
      return;
    }

    String? outputDirectory;
    if (chooseDirectory) {
      try {
        outputDirectory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择新的字幕输出目录',
          initialDirectory: _outputDirectoryFor(task),
        );
      } on Object {
        if (!mounted) return;
        setState(() {
          _message = null;
          _error = '打开目录选择器失败，请稍后重试。';
        });
        return;
      }
      if (!mounted || outputDirectory == null) return;
    }

    setState(() {
      _reexportingTaskId = task.taskId;
      _message = chooseDirectory ? '正在写入新的输出目录…' : '正在重新导出字幕…';
      _error = null;
    });
    try {
      final reexportStyle = _stringMap(
        task.settings['reexport_subtitle_ass_style'],
      );
      final subtitleStyle = reexportStyle.isNotEmpty
          ? reexportStyle
          : _stringMap(task.settings['subtitle_ass_style']);
      final reexportBilingual = _firstDiagnosticBool(task.settings, const [
        'reexport_bilingual',
      ]);
      await _client.resultReexport(
        task.taskId,
        outputFormat: _taskOutputFormat(task),
        outputDir: outputDirectory,
        bilingual: reexportBilingual ?? task.bilingual,
        subtitleBilingualOrder: _stringValue(subtitleStyle['bilingual_order']),
        subtitlePreferSingleLine: _firstDiagnosticBool(subtitleStyle, const [
          'prefer_single_line',
        ]),
      );
      if (!mounted) return;
      await _loadTasks();
      if (!mounted) return;
      setState(() {
        _reexportingTaskId = null;
        if (_error == null) {
          _message = chooseDirectory ? '字幕已重新导出到新目录。' : '字幕已重新导出。';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _reexportingTaskId = null;
        _message = null;
        _error = '重新导出失败：${_friendlyTaskProcessingError(error)}';
      });
    }
  }

  Future<void> _openFailureRecoverySettings(TaskSummary task) async {
    final recovery = taskFailurePresentation(
      error: task.error,
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    final type = switch (recovery.target) {
      TaskFailureRecoveryTarget.translationSettings =>
        AppWindowType.translationSettings,
      TaskFailureRecoveryTarget.asrSettings => AppWindowType.asrSettings,
      _ => null,
    };
    if (type == null) return;
    setState(() {
      _message = '正在打开${type.title}…';
      _error = null;
    });
    try {
      await widget.bridge.openToolWindow(type);
      if (!mounted) return;
      setState(() {
        _message = '已打开${type.title}，修好后可以回来继续任务。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开${type.title}失败：$error';
      });
    }
  }

  Future<void> _openDirectory(
    String path, {
    required String successMessage,
  }) async {
    try {
      await _pathOpener.openDirectory(path);
      if (!mounted) return;
      setState(() {
        _message = successMessage;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '打开目录失败：$error';
        _message = null;
      });
    }
  }

  Future<void> _runSmokeScenario(TaskSummary selected) async {
    _smokeScenario = _normalizedSmokeScenario(
      widget.smoke?.taskProcessingScenario,
    );
    if (_smokeScenario == 'edit') {
      await _runSmokeEditFlow(selected);
    } else if (_smokeScenario == 'review') {
      TaskSummary? reviewTask;
      for (final task in _tasks) {
        if (task.needsReview) {
          reviewTask = task;
          break;
        }
      }
      if (reviewTask != null && mounted) {
        setState(() {
          _taskFilter = _TaskFilter.review;
          _selectedTaskId = reviewTask?.taskId;
          _editingTaskId = null;
        });
      }
    } else if (_smokeScenario == 'failure' ||
        _smokeScenario == 'outputFailure') {
      return;
    } else if (_smokeScenario == 'resume') {
      await _runSmokeResumeFlow(selected);
    } else if (_smokeScenario == 'cancel') {
      await _runSmokeCancelFlow(selected);
    } else {
      await _runSmokeOutputDirectoryCheck(selected);
    }
  }

  Future<void> _runSmokeEditFlow(TaskSummary task) async {
    if (!task.isDone) return;
    await _runSmokeOutputDirectoryCheck(task);
    final result = await _client.openTaskResult(task.taskId);
    _smokeResultSegmentCount = result.segments.length;
    _smokeResultIssueCount = result.issueCount;
    if (result.segments.isEmpty) return;
    final first = result.segments.first;
    _smokeEditedText = '已校对的字幕译文';
    final payload = result.segments
        .map(
          (segment) => <String, Object?>{
            ...segment.raw,
            'id': segment.id,
            'start': segment.start,
            'end': segment.end,
            'text_src': segment.sourceText,
            'text_tgt': segment.id == first.id
                ? _smokeEditedText
                : segment.targetText,
          },
        )
        .toList();
    final saved = await _client.resultSegmentsSave(task.taskId, payload);
    _smokeEditSaved = saved.segments.any(
      (segment) => segment.targetText == _smokeEditedText,
    );
    _smokeResultSegmentCount = saved.segments.length;
    _smokeResultIssueCount = saved.issueCount;
    _smokeReexportFormat = 'ass';
    _smokeReexportBilingual = true;
    _smokeReexportBilingualOrder = 'source_target';
    _smokeReexportPreferSingleLine = false;
    final reexported = await _client.resultReexport(
      task.taskId,
      outputFormat: _smokeReexportFormat,
      bilingual: _smokeReexportBilingual ?? true,
      subtitleBilingualOrder: _smokeReexportBilingualOrder,
      subtitlePreferSingleLine: _smokeReexportPreferSingleLine,
    );
    _smokeReexported = reexported.isNotEmpty;
    _smokeReexportStyleApplied =
        _stringValue(reexported['subtitle_bilingual_order']) ==
            _smokeReexportBilingualOrder &&
        reexported['subtitle_prefer_single_line'] ==
            _smokeReexportPreferSingleLine;
    final outputPaths = _stringMap(reexported['output_paths']);
    final outputPath =
        _stringValue(outputPaths['ass']) ??
        _stringValue(outputPaths['srt']) ??
        _stringValue(outputPaths['vtt']) ??
        _stringValue(outputPaths['lrc']);
    if (outputPath != null && outputPath.isNotEmpty) {
      final output = File(outputPath);
      if (await output.exists()) {
        final text = await output.readAsString(encoding: utf8);
        _smokeOutputContainsEdit = text.contains(_smokeEditedText);
        final sourceIndex = text.indexOf(first.sourceText);
        final targetIndex = text.indexOf(_smokeEditedText);
        _smokeReexportOutputUsesRequestedOrder =
            sourceIndex >= 0 && targetIndex >= 0 && sourceIndex < targetIndex;
      }
    }
  }

  Future<void> _runSmokeResumeFlow(TaskSummary task) async {
    if (!task.canResume) return;
    _smokeResumeAttempted = true;
    final result = await _client.submitResume({
      'request_version': 1,
      'task_id': task.taskId,
    });
    _smokeResumeOk = result.taskId == task.taskId && result.status == 'QUEUED';
    _smokeResumeStatus = result.status;
  }

  Future<void> _runSmokeCancelFlow(TaskSummary task) async {
    if (!task.canCancel) return;
    _smokeCancelAttempted = true;
    final result = await _client.cancel(task.taskId);
    _smokeCancelOk =
        result.taskId == task.taskId &&
        (result.status == 'CANCEL_REQUESTED' || result.status == 'CANCELLED');
    _smokeCancelStatus = result.status;
  }

  Future<void> _runSmokeOutputDirectoryCheck(TaskSummary task) async {
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) return;
    _smokeOutputDirectoryChecked = true;
    _smokeOutputDirectoryPath = dir;
    final result = await _directoryProbe.checkWritable(dir);
    _smokeOutputDirectoryWritable = result.ok;
    _smokeOutputDirectoryMessage = result.message;
  }

  Future<void> _writeSmokeReport({
    required List<TaskSummary> tasks,
    TaskSummary? selected,
    Object? error,
  }) async {
    final smoke = widget.smoke;
    if (smoke == null) return;
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    final payload = <String, Object?>{
      'ok': error == null && tasks.isNotEmpty,
      'status': error == null ? 'ready' : 'error',
      'window_type': AppWindowType.taskProcessing.id,
      'title': AppWindowType.taskProcessing.title,
      'task_processing_scenario': _smokeScenario,
      'task_processing_task_count': tasks.length,
      'task_processing_selected_task_id': selected?.taskId ?? '',
      'task_processing_selected_status': selected?.status ?? '',
      'task_processing_review_task_count': tasks
          .where((task) => task.needsReview)
          .length,
      'task_processing_selected_needs_review': selected?.needsReview ?? false,
      'task_processing_selected_review_issue_count':
          selected?.reviewIssueCount ?? 0,
      'task_processing_selected_quality_status': selected?.qualityStatus ?? '',
      'task_processing_selected_delivery_status':
          selected?.deliveryStatus ?? '',
      'task_processing_editor_visible':
          selected?.isDone == true && _editingTaskId == selected?.taskId,
      'task_processing_model_request_count': selected?.modelRequestCount ?? 0,
      'task_processing_model_request_counts':
          selected?.modelRequestCounts ?? const <String, int>{},
      'task_processing_result_segment_count': _smokeResultSegmentCount,
      'task_processing_result_issue_count': _smokeResultIssueCount,
      'task_processing_edit_saved': _smokeEditSaved,
      'task_processing_reexported': _smokeReexported,
      'task_processing_reexport_output_contains_edit': _smokeOutputContainsEdit,
      'task_processing_edited_text': _smokeEditedText,
      'task_processing_reexport_format': _smokeReexportFormat,
      'task_processing_reexport_bilingual': _smokeReexportBilingual,
      'task_processing_reexport_bilingual_order': _smokeReexportBilingualOrder,
      'task_processing_reexport_prefer_single_line':
          _smokeReexportPreferSingleLine,
      'task_processing_reexport_style_applied': _smokeReexportStyleApplied,
      'task_processing_reexport_output_uses_requested_order':
          _smokeReexportOutputUsesRequestedOrder,
      'task_processing_resume_attempted': _smokeResumeAttempted,
      'task_processing_resume_ok': _smokeResumeOk,
      'task_processing_resume_status': _smokeResumeStatus,
      'task_processing_cancel_attempted': _smokeCancelAttempted,
      'task_processing_cancel_ok': _smokeCancelOk,
      'task_processing_cancel_status': _smokeCancelStatus,
      'task_processing_output_dir_checked': _smokeOutputDirectoryChecked,
      'task_processing_output_dir_writable': _smokeOutputDirectoryWritable,
      'task_processing_output_dir_path': _smokeOutputDirectoryPath,
      'task_processing_output_dir_message': _smokeOutputDirectoryMessage,
      'error': error == null ? '' : '$error',
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };
    payload.addAll(_taskDiagnosticSmokeFields(selected));
    payload.addAll(
      await captureSmokeRender(
        boundaryKey: _renderKey,
        path: smoke.screenshotPath,
      ),
    );
    if (smoke.screenshotPath != null) {
      payload['ok'] =
          payload['ok'] == true && payload['render_capture_ok'] == true;
    }
    await reportFile.writeAsString(jsonEncode(payload), encoding: utf8);
    final hold = smoke.postReportVisibleDuration;
    if (hold > Duration.zero) {
      await Future<void>.delayed(hold);
    }
    if (!mounted) return;
    try {
      await _smokeService?.shutdown();
      await windowManager.close();
    } on Object {
      exit(0);
    }
  }

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

class _TaskProcessingBody extends StatelessWidget {
  const _TaskProcessingBody({
    required this.tasks,
    required this.totalTaskCount,
    required this.filter,
    required this.filterCounts,
    required this.searchController,
    required this.selected,
    required this.events,
    required this.eventSearchController,
    required this.editingTaskId,
    required this.resultEditorDirty,
    required this.bridge,
    required this.resultTransportOverride,
    required this.message,
    required this.error,
    required this.loadingTasks,
    required this.loadingEvents,
    required this.loadingMoreEvents,
    required this.eventsHasMore,
    required this.resuming,
    required this.retranslatingTaskId,
    required this.reexportingTaskId,
    required this.cancellingTaskId,
    required this.checkingOutputDirectory,
    required this.onRefresh,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onSelectTask,
    required this.onLoadMoreEvents,
    required this.onClearEventSearch,
    required this.onOpenResult,
    required this.onCloseEditor,
    required this.onResultDirtyChanged,
    required this.onResultChanged,
    required this.onResume,
    required this.onRetranslate,
    required this.onCancel,
    required this.onOpenFailureRecovery,
    required this.onReexport,
    required this.onChooseOutputDirectory,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
    required this.onCheckOutputDirectory,
  });

  final List<TaskSummary> tasks;
  final int totalTaskCount;
  final _TaskFilter filter;
  final Map<_TaskFilter, int> filterCounts;
  final TextEditingController searchController;
  final TaskSummary? selected;
  final List<Object?> events;
  final TextEditingController eventSearchController;
  final String? editingTaskId;
  final bool resultEditorDirty;
  final WindowStateBridge bridge;
  final AppServiceTransport resultTransportOverride;
  final String? message;
  final String? error;
  final bool loadingTasks;
  final bool loadingEvents;
  final bool loadingMoreEvents;
  final bool eventsHasMore;
  final bool resuming;
  final String? retranslatingTaskId;
  final String? reexportingTaskId;
  final String? cancellingTaskId;
  final bool checkingOutputDirectory;
  final VoidCallback onRefresh;
  final ValueChanged<_TaskFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<TaskSummary> onSelectTask;
  final VoidCallback? onLoadMoreEvents;
  final VoidCallback onClearEventSearch;
  final ValueChanged<TaskSummary> onOpenResult;
  final VoidCallback onCloseEditor;
  final ValueChanged<bool> onResultDirtyChanged;
  final VoidCallback onResultChanged;
  final ValueChanged<TaskSummary> onResume;
  final ValueChanged<TaskSummary> onRetranslate;
  final ValueChanged<TaskSummary> onCancel;
  final ValueChanged<TaskSummary> onOpenFailureRecovery;
  final ValueChanged<TaskSummary> onReexport;
  final ValueChanged<TaskSummary> onChooseOutputDirectory;
  final ValueChanged<TaskSummary> onOpenTaskDirectory;
  final ValueChanged<TaskSummary> onOpenOutputDirectory;
  final ValueChanged<TaskSummary> onCheckOutputDirectory;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 292,
          child: _TaskStripList(
            tasks: tasks,
            totalTaskCount: totalTaskCount,
            filter: filter,
            filterCounts: filterCounts,
            searchController: searchController,
            selectedTaskId: selected?.taskId,
            loading: loadingTasks,
            passiveControlsEnabled: !resultEditorDirty,
            onRefresh: onRefresh,
            onFilterChanged: onFilterChanged,
            onClearSearch: onClearSearch,
            onSelect: onSelectTask,
          ),
        ),
        const SizedBox(width: T.s8),
        Container(width: 1, color: T.line),
        const SizedBox(width: T.s8),
        Expanded(
          child: _TaskPreview(
            task: selected,
            events: events,
            eventSearchController: eventSearchController,
            editingTaskId: editingTaskId,
            bridge: bridge,
            resultTransportOverride: resultTransportOverride,
            message: message,
            error: error,
            loadingTasks: loadingTasks,
            loadingEvents: loadingEvents,
            loadingMoreEvents: loadingMoreEvents,
            eventsHasMore: eventsHasMore,
            resuming: resuming,
            retranslatingTaskId: retranslatingTaskId,
            reexportingTaskId: reexportingTaskId,
            cancellingTaskId: cancellingTaskId,
            checkingOutputDirectory: checkingOutputDirectory,
            onLoadMoreEvents: onLoadMoreEvents,
            onClearEventSearch: onClearEventSearch,
            onOpenResult: onOpenResult,
            onCloseEditor: onCloseEditor,
            onResultDirtyChanged: onResultDirtyChanged,
            onResultChanged: onResultChanged,
            onResume: onResume,
            onRetranslate: onRetranslate,
            onCancel: onCancel,
            onOpenFailureRecovery: onOpenFailureRecovery,
            onReexport: onReexport,
            onChooseOutputDirectory: onChooseOutputDirectory,
            onOpenTaskDirectory: onOpenTaskDirectory,
            onOpenOutputDirectory: onOpenOutputDirectory,
            onCheckOutputDirectory: onCheckOutputDirectory,
          ),
        ),
      ],
    );
  }
}

class _TaskStripList extends StatelessWidget {
  const _TaskStripList({
    required this.tasks,
    required this.totalTaskCount,
    required this.filter,
    required this.filterCounts,
    required this.searchController,
    required this.selectedTaskId,
    required this.loading,
    required this.passiveControlsEnabled,
    required this.onRefresh,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onSelect,
  });

  final List<TaskSummary> tasks;
  final int totalTaskCount;
  final _TaskFilter filter;
  final Map<_TaskFilter, int> filterCounts;
  final TextEditingController searchController;
  final String? selectedTaskId;
  final bool loading;
  final bool passiveControlsEnabled;
  final VoidCallback onRefresh;
  final ValueChanged<_TaskFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<TaskSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    final searchQuery = searchController.text.trim();
    final hasSearch = searchQuery.isNotEmpty;
    final hasListControls = totalTaskCount > 0;
    final summary = totalTaskCount == 0
        ? '完成、失败和制作中的任务会出现在这里。'
        : filter == _TaskFilter.all && !hasSearch
        ? '最近 $totalTaskCount 个任务'
        : '显示 ${tasks.length} / $totalTaskCount 个任务';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('任务片列', style: T.tFilename)),
            _TaskActionButton(
              label: loading ? '刷新中' : '刷新',
              onTap: loading || !passiveControlsEnabled ? null : onRefresh,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Text(summary, style: T.tCaption),
        if (hasListControls) ...[
          const SizedBox(height: T.s12),
          if (totalTaskCount > 0)
            _TaskFilterControls(
              selected: filter,
              counts: filterCounts,
              onChanged: onFilterChanged,
            ),
          if (totalTaskCount > 0) ...[
            const SizedBox(height: T.s12),
            _TaskSearchField(
              controller: searchController,
              enabled: !loading && passiveControlsEnabled,
              onClear: onClearSearch,
            ),
          ],
        ],
        const SizedBox(height: T.s16),
        Expanded(
          child: loading && tasks.isEmpty
              ? const Center(child: Text('读取任务中…', style: T.tBody))
              : tasks.isEmpty
              ? Center(
                  child: Text(
                    totalTaskCount == 0
                        ? '还没有任务记录。'
                        : _taskListEmptyText(filter, searchQuery),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: T.tBody,
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: T.s8),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return _TaskStripTile(
                      task: task,
                      selected: task.taskId == selectedTaskId,
                      onTap: () => onSelect(task),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TaskSearchField extends StatelessWidget {
  const _TaskSearchField({
    required this.controller,
    required this.enabled,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasSearch = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: 1,
      style: T.tCaption,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索任务',
        prefixIcon: const Icon(Icons.search, size: 16),
        suffixIcon: hasSearch
            ? IconButton(
                tooltip: '清除任务搜索',
                icon: const Icon(Icons.close, size: 16),
                onPressed: enabled ? onClear : null,
              )
            : null,
        filled: true,
        fillColor: T.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: T.s8,
          vertical: T.s8,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          borderSide: const BorderSide(color: T.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          borderSide: const BorderSide(color: T.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          borderSide: const BorderSide(color: T.accentStrong, width: 1.4),
        ),
      ),
    );
  }
}

class _EventSearchField extends StatelessWidget {
  const _EventSearchField({
    required this.controller,
    required this.enabled,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasSearch = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: 1,
      style: T.tCaption,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索事件',
        prefixIcon: const Icon(Icons.search, size: 16),
        suffixIcon: hasSearch
            ? IconButton(
                tooltip: '清除事件搜索',
                icon: const Icon(Icons.close, size: 16),
                onPressed: enabled ? onClear : null,
              )
            : null,
        filled: true,
        fillColor: T.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: T.s8,
          vertical: T.s8,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          borderSide: const BorderSide(color: T.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          borderSide: const BorderSide(color: T.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          borderSide: const BorderSide(color: T.accentStrong, width: 1.4),
        ),
      ),
    );
  }
}

class _TaskFilterControls extends StatelessWidget {
  const _TaskFilterControls({
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final _TaskFilter selected;
  final Map<_TaskFilter, int> counts;
  final ValueChanged<_TaskFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: T.s8,
      runSpacing: T.s8,
      children: [
        for (final filter in _TaskFilter.values)
          _TaskFilterButton(
            label: '${_taskFilterLabel(filter)} ${counts[filter] ?? 0}',
            selected: selected == filter,
            onTap: () => onChanged(filter),
          ),
      ],
    );
  }
}

class _TaskFilterButton extends StatefulWidget {
  const _TaskFilterButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TaskFilterButton> createState() => _TaskFilterButtonState();
}

class _TaskFilterButtonState extends State<_TaskFilterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 142,
            constraints: const BoxConstraints(minHeight: 32),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? T.accentSoft
                  : _hover
                  ? T.surface
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(T.rSm),
              border: Border.all(
                color: selected ? T.accentStrong : T.line,
                width: 1.2,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: T.tCaption.copyWith(
                color: selected ? T.accentStrong : T.ink,
                fontWeight: selected ? T.wBold : T.wMedium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskStripTile extends StatelessWidget {
  const _TaskStripTile({
    required this.task,
    required this.selected,
    required this.onTap,
  });

  final TaskSummary task;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _taskStatusColor(task);
    final name = task.displayName;
    final outputs = subtitleFormatListLabel(task.outputPaths.keys);
    final reviewSummary = task.needsReview ? _taskReviewSummary(task) : '';
    final subtitle = [
      taskStatusLabel(task.status),
      if (task.targetLang.isNotEmpty) languageLabel(task.targetLang),
      if (outputs.isNotEmpty) outputs,
    ].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 82),
          decoration: BoxDecoration(
            color: selected ? T.accentSoft.withValues(alpha: 0.5) : T.surface,
            border: Border.all(color: selected ? T.accentStrong : T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            children: [
              SizedBox(width: 5, height: 82, child: ColoredBox(color: color)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(T.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? shortTaskIdLabel(task.taskId) : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tBody.copyWith(fontWeight: T.wMedium),
                      ),
                      const SizedBox(height: T.s4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tCaption,
                      ),
                      if ((task.error ?? '').isNotEmpty) ...[
                        const SizedBox(height: T.s4),
                        Text(
                          taskErrorLabel(task.error, task.errorInfo),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: T.tCaption.copyWith(color: T.danger),
                        ),
                      ] else if (reviewSummary.isNotEmpty) ...[
                        const SizedBox(height: T.s4),
                        Row(
                          children: [
                            const Icon(
                              Icons.rate_review_rounded,
                              size: 14,
                              color: T.warn,
                            ),
                            const SizedBox(width: T.s4),
                            Expanded(
                              child: Text(
                                reviewSummary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: T.tCaption.copyWith(
                                  color: T.warn,
                                  fontWeight: T.wMedium,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskPreview extends StatelessWidget {
  const _TaskPreview({
    required this.task,
    required this.events,
    required this.eventSearchController,
    required this.editingTaskId,
    required this.bridge,
    required this.resultTransportOverride,
    required this.message,
    required this.error,
    required this.loadingTasks,
    required this.loadingEvents,
    required this.loadingMoreEvents,
    required this.eventsHasMore,
    required this.resuming,
    required this.retranslatingTaskId,
    required this.reexportingTaskId,
    required this.cancellingTaskId,
    required this.checkingOutputDirectory,
    required this.onLoadMoreEvents,
    required this.onClearEventSearch,
    required this.onOpenResult,
    required this.onCloseEditor,
    required this.onResultDirtyChanged,
    required this.onResultChanged,
    required this.onResume,
    required this.onRetranslate,
    required this.onCancel,
    required this.onOpenFailureRecovery,
    required this.onReexport,
    required this.onChooseOutputDirectory,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
    required this.onCheckOutputDirectory,
  });

  final TaskSummary? task;
  final List<Object?> events;
  final TextEditingController eventSearchController;
  final String? editingTaskId;
  final WindowStateBridge bridge;
  final AppServiceTransport resultTransportOverride;
  final String? message;
  final String? error;
  final bool loadingTasks;
  final bool loadingEvents;
  final bool loadingMoreEvents;
  final bool eventsHasMore;
  final bool resuming;
  final String? retranslatingTaskId;
  final String? reexportingTaskId;
  final String? cancellingTaskId;
  final bool checkingOutputDirectory;
  final VoidCallback? onLoadMoreEvents;
  final VoidCallback onClearEventSearch;
  final ValueChanged<TaskSummary> onOpenResult;
  final VoidCallback onCloseEditor;
  final ValueChanged<bool> onResultDirtyChanged;
  final VoidCallback onResultChanged;
  final ValueChanged<TaskSummary> onResume;
  final ValueChanged<TaskSummary> onRetranslate;
  final ValueChanged<TaskSummary> onCancel;
  final ValueChanged<TaskSummary> onOpenFailureRecovery;
  final ValueChanged<TaskSummary> onReexport;
  final ValueChanged<TaskSummary> onChooseOutputDirectory;
  final ValueChanged<TaskSummary> onOpenTaskDirectory;
  final ValueChanged<TaskSummary> onOpenOutputDirectory;
  final ValueChanged<TaskSummary> onCheckOutputDirectory;

  @override
  Widget build(BuildContext context) {
    final task = this.task;
    if (task == null) {
      return Center(
        child: Text(loadingTasks ? '读取任务中…' : '选择一个任务后查看处理动作。', style: T.tBody),
      );
    }
    if (editingTaskId == task.taskId && task.isDone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '字幕编辑',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tFilename,
                ),
              ),
              _TaskActionButton(label: '返回概览', onTap: onCloseEditor),
            ],
          ),
          const SizedBox(height: T.s12),
          Expanded(
            child: ResultReviewWorkspace(
              taskId: task.taskId,
              bridge: bridge,
              transportOverride: resultTransportOverride,
              focusIssuesInitially: task.needsReview,
              onDirtyChanged: onResultDirtyChanged,
              onResultChanged: onResultChanged,
            ),
          ),
        ],
      );
    }
    final outputDir = _outputDirectoryFor(task);
    final cancelling = cancellingTaskId == task.taskId;
    final retranslating = retranslatingTaskId == task.taskId;
    final reexporting = reexportingTaskId == task.taskId;
    final eventSearchQuery = eventSearchController.text.trim();
    final visibleEvents = events
        .where(
          (event) => _eventMatchesSearch(_eventMap(event), eventSearchQuery),
        )
        .toList(growable: false);
    final diagnosticClues = _taskDiagnosticClues(task);
    final recovery = taskFailurePresentation(
      error: task.error,
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    final hasSettingsRecovery =
        (task.isFailed || task.isRuntimeStale) &&
        (recovery.target == TaskFailureRecoveryTarget.translationSettings ||
            recovery.target == TaskFailureRecoveryTarget.asrSettings);
    final hasOutputRecovery =
        (task.isFailed || task.isRuntimeStale) &&
        (recovery.target == TaskFailureRecoveryTarget.outputDirectory ||
            recovery.target == TaskFailureRecoveryTarget.reexport);
    final hasPrimaryFailureRecovery = hasSettingsRecovery || hasOutputRecovery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _basename(task.inputFile).isEmpty
              ? shortTaskIdLabel(task.taskId)
              : _basename(task.inputFile),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.tFilename,
        ),
        const SizedBox(height: T.s8),
        Text(
          _taskSubtitle(task),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: T.tCaption,
        ),
        const SizedBox(height: T.s12),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            if (task.isDone)
              _TaskActionButton(
                label: '编辑字幕',
                strong: true,
                onTap: () => onOpenResult(task),
              ),
            if (task.isDone)
              _TaskActionButton(
                label: retranslating ? '创建中' : '重新翻译',
                onTap: retranslatingTaskId == null
                    ? () => onRetranslate(task)
                    : null,
              ),
            if (hasSettingsRecovery)
              _TaskActionButton(
                label: recovery.actionLabel,
                strong: true,
                onTap: () => onOpenFailureRecovery(task),
              ),
            if (hasOutputRecovery)
              _TaskActionButton(
                label: reexporting ? '导出中' : recovery.actionLabel,
                strong: true,
                onTap: reexportingTaskId != null
                    ? null
                    : recovery.target ==
                          TaskFailureRecoveryTarget.outputDirectory
                    ? () => onChooseOutputDirectory(task)
                    : () => onReexport(task),
              ),
            if (task.canResume)
              _TaskActionButton(
                label: resuming ? '继续中' : '继续任务',
                strong: !hasPrimaryFailureRecovery,
                onTap: resuming ? null : () => onResume(task),
              ),
            if (task.canCancel)
              _TaskActionButton(
                label: cancelling ? '取消中' : '取消任务',
                danger: true,
                onTap: cancellingTaskId == null ? () => onCancel(task) : null,
              ),
            if (task.isDone && outputDir != null)
              _TaskActionButton(
                label: '结果目录',
                onTap: () => onOpenOutputDirectory(task),
              ),
            if (hasOutputRecovery && outputDir != null)
              _TaskActionButton(
                label: checkingOutputDirectory ? '检查中' : '检查结果目录',
                onTap: checkingOutputDirectory
                    ? null
                    : () => onCheckOutputDirectory(task),
              ),
            if (task.taskDir.trim().isNotEmpty)
              _TaskActionButton(
                label: '任务目录',
                onTap: () => onOpenTaskDirectory(task),
              ),
          ],
        ),
        const SizedBox(height: T.s12),
        if (error != null)
          Text(error!, style: T.tBody.copyWith(color: T.danger))
        else if (message != null)
          Text(message!, style: T.tCaption)
        else
          Text(_taskActionHint(task), style: T.tCaption),
        const SizedBox(height: T.s16),
        _TaskSummaryPanel(task: task),
        if (task.needsReview) ...[
          const SizedBox(height: T.s12),
          _TaskReviewNote(task: task),
        ],
        if (diagnosticClues.isNotEmpty) ...[
          const SizedBox(height: T.s12),
          _TaskDiagnosticsPanel(
            title: _taskDiagnosticTitle(task),
            clues: diagnosticClues,
          ),
        ],
        const SizedBox(height: T.s16),
        Row(
          children: [
            Expanded(child: Text('最近事件', style: T.tSection)),
            const SizedBox(width: T.s8),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: _EventSearchField(
                    controller: eventSearchController,
                    enabled: !loadingEvents && events.isNotEmpty,
                    onClear: onClearEventSearch,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Expanded(
          child: loadingEvents && events.isEmpty
              ? const Center(child: Text('读取事件中…', style: T.tBody))
              : events.isEmpty
              ? const Center(child: Text('还没有事件记录。', style: T.tBody))
              : visibleEvents.isEmpty && eventSearchQuery.isNotEmpty
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '没有匹配“$eventSearchQuery”的事件。',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: T.tBody,
                    ),
                    if (eventsHasMore) ...[
                      const SizedBox(height: T.s12),
                      _TaskActionButton(
                        label: loadingMoreEvents ? '读取中' : '加载更多事件',
                        onTap: loadingMoreEvents ? null : onLoadMoreEvents,
                      ),
                    ],
                  ],
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: visibleEvents.length + (eventsHasMore ? 1 : 0),
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) {
                    if (index >= visibleEvents.length) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: _TaskActionButton(
                          label: loadingMoreEvents ? '读取中' : '加载更多事件',
                          onTap: loadingMoreEvents ? null : onLoadMoreEvents,
                        ),
                      );
                    }
                    return _EventPreviewRow(
                      event: _eventMap(visibleEvents[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TaskSummaryPanel extends StatelessWidget {
  const _TaskSummaryPanel({required this.task});

  final TaskSummary task;

  @override
  Widget build(BuildContext context) {
    final outputs = subtitleFormatListLabel(task.outputPaths.keys);
    final createdAt = taskTimestampLabel(task.createdAt);
    final updatedAt = taskTimestampLabel(task.updatedAt);
    final runtimeState = _runtimeStateLabel(task.runtimeState);
    final requestCounts = task.modelRequestCounts;
    final translationRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'translate',
    );
    final protocolRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'protocol_recovery',
    );
    final batchRecoveryRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'batch_recovery',
    );
    final repairRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'repair',
    );
    final memoryRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode.startsWith('memory_'),
    );
    final qualityRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode.startsWith('quality_'),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: T.s12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: T.line),
          bottom: BorderSide(color: T.line),
        ),
      ),
      child: Wrap(
        spacing: T.s24,
        runSpacing: T.s12,
        children: [
          _InfoPill(label: '状态', value: taskStatusLabel(task.status)),
          _InfoPill(label: '源语', value: languageLabel(task.sourceLang)),
          _InfoPill(label: '目标', value: languageLabel(task.targetLang)),
          _InfoPill(label: '字幕', value: task.bilingual ? '双语' : '单语'),
          if (outputs.isNotEmpty) _InfoPill(label: '输出', value: outputs),
          if (createdAt.isNotEmpty) _InfoPill(label: '创建', value: createdAt),
          if (updatedAt.isNotEmpty) _InfoPill(label: '更新', value: updatedAt),
          if (runtimeState.isNotEmpty)
            _InfoPill(
              label: '运行记录',
              value: runtimeState,
              danger: task.isRuntimeStale,
            ),
          if (task.asrTotalSegments > 0)
            _InfoPill(
              label: '语音分窗',
              value: '${task.asrDoneCount}/${task.asrTotalSegments}',
            ),
          if (task.translationTotalChunks > 0)
            _InfoPill(
              label: '翻译分片',
              value:
                  '${task.translationDoneCount}/${task.translationTotalChunks}',
            ),
          if (task.modelRequestCount > 0)
            _InfoPill(label: '模型请求', value: '${task.modelRequestCount} 次'),
          if (translationRequests > 0)
            _InfoPill(label: '分片翻译', value: '$translationRequests 次'),
          if (protocolRequests > 0)
            _InfoPill(label: '格式重试', value: '$protocolRequests 次'),
          if (batchRecoveryRequests > 0)
            _InfoPill(label: '批量补回', value: '$batchRecoveryRequests 次'),
          if (repairRequests > 0)
            _InfoPill(
              label: '单行修复',
              value: '$repairRequests 次',
              danger: repairRequests > 8,
            ),
          if (memoryRequests > 0)
            _InfoPill(label: '术语请求', value: '$memoryRequests 次'),
          if (qualityRequests > 0)
            _InfoPill(label: '质量请求', value: '$qualityRequests 次'),
          if (task.qualityStatus.isNotEmpty)
            _InfoPill(
              label: '质量检查',
              value: _reviewCheckStatusLabel(task.qualityStatus),
              warn: task.needsReview,
            ),
          if (task.deliveryStatus.isNotEmpty)
            _InfoPill(
              label: '交付检查',
              value: _reviewCheckStatusLabel(task.deliveryStatus),
              warn: task.needsReview,
            ),
          if (task.reviewIssueCount > 0)
            _InfoPill(
              label: '待校对',
              value: '${task.reviewIssueCount} 条',
              warn: true,
            ),
          if (task.hasSavedResultPendingExport)
            const _InfoPill(label: '字幕文件', value: '等待更新', warn: true),
        ],
      ),
    );
  }
}

class _TaskReviewNote extends StatelessWidget {
  const _TaskReviewNote({required this.task});

  final TaskSummary task;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: T.s4),
          padding: const EdgeInsets.all(T.s12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF8E3),
            border: Border.all(color: T.warn.withValues(alpha: 0.48)),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 42,
                decoration: BoxDecoration(
                  color: T.warn,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: T.s12),
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.rate_review_rounded, size: 18, color: T.warn),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('还有字幕值得再看一眼', style: T.tSection),
                    const SizedBox(height: T.s4),
                    Text(_taskReviewDetail(task), style: T.tCaption),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 0,
          right: T.s24,
          child: IgnorePointer(
            child: Container(
              width: 46,
              height: 8,
              decoration: BoxDecoration(
                color: T.skySoft,
                border: Border.all(color: T.sky.withValues(alpha: 0.42)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

int _requestModeTotal(
  Map<String, int> counts,
  bool Function(String mode) matches,
) {
  return counts.entries
      .where((entry) => matches(entry.key))
      .fold(0, (total, entry) => total + entry.value);
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.value,
    this.danger = false,
    this.warn = false,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final bool danger;
  final bool warn;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Text(
        '$label ${value.isEmpty ? '未知' : value}',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(
          color: danger
              ? T.danger
              : warn
              ? T.warn
              : T.ink,
          fontWeight: danger || warn ? T.wMedium : T.wRegular,
        ),
      ),
    );
  }
}

class _TaskDiagnosticsPanel extends StatelessWidget {
  const _TaskDiagnosticsPanel({required this.title, required this.clues});

  final String title;
  final List<_TaskDiagnosticClue> clues;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: T.s4),
          padding: const EdgeInsets.all(T.s12),
          decoration: BoxDecoration(
            color: T.lilacSoft.withValues(alpha: 0.62),
            border: Border.all(color: T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 44,
                decoration: BoxDecoration(
                  color: T.danger,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: T.s12),
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.handyman_rounded, size: 18, color: T.danger),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: T.tSection),
                    const SizedBox(height: T.s8),
                    Wrap(
                      spacing: T.s24,
                      runSpacing: T.s8,
                      children: [
                        for (final clue in clues)
                          _InfoPill(
                            label: clue.label,
                            value: clue.value,
                            danger: clue.danger,
                            maxLines: clue.maxLines,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 0,
          left: T.s24,
          child: IgnorePointer(
            child: Container(
              width: 46,
              height: 8,
              decoration: BoxDecoration(
                color: T.accentSoft,
                border: Border.all(color: T.accent.withValues(alpha: 0.42)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskDiagnosticClue {
  const _TaskDiagnosticClue({
    required this.label,
    required this.value,
    this.danger = false,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final bool danger;
  final int maxLines;
}

class _EventPreviewRow extends StatelessWidget {
  const _EventPreviewRow({required this.event});

  final Map<String, Object?> event;

  @override
  Widget build(BuildContext context) {
    final type = _eventText(event, 'type', fallback: 'event');
    final stage = _eventText(event, 'stage');
    final status = _eventText(event, 'status');
    final message = _eventText(event, 'message');
    final createdAt = taskTimestampLabel(_eventText(event, 'created_at'));
    final progress = taskProgressLabel(event['progress']);
    final label = taskEventTypeLabel(type);
    final stageLabel = taskStageLabel(stage);
    final messageLabel = taskEventMessageLabel(
      type: type,
      stage: stage,
      status: status,
      message: message,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: _EventTag(label: label, type: type),
        ),
        const SizedBox(width: T.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (stageLabel.isNotEmpty) stageLabel,
                  if (createdAt.isNotEmpty) createdAt,
                  if (progress.isNotEmpty) '进度 $progress',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tCaption,
              ),
              const SizedBox(height: T.s4),
              Text(
                messageLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: T.tBody,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventTag extends StatelessWidget {
  const _EventTag({required this.label, required this.type});

  final String label;
  final String type;

  @override
  Widget build(BuildContext context) {
    final color = type.toLowerCase() == 'error' ? T.danger : T.sky;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: T.tCaption,
      ),
    );
  }
}

class _TaskActionButton extends StatefulWidget {
  const _TaskActionButton({
    required this.label,
    required this.onTap,
    this.strong = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool strong;
  final bool danger;

  @override
  State<_TaskActionButton> createState() => _TaskActionButtonState();
}

class _TaskActionButtonState extends State<_TaskActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final actionColor = widget.danger ? T.danger : T.accentStrong;
    final background = !enabled
        ? const Color(0x00000000)
        : widget.strong
        ? (_hover ? T.accentStrong : T.accent)
        : _hover
        ? (widget.danger ? T.danger.withValues(alpha: 0.08) : T.accentSoft)
        : const Color(0x00000000);
    final foreground = !enabled
        ? T.muted
        : widget.strong
        ? const Color(0xFFFFFFFF)
        : actionColor;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enabled ? (_) => setState(() => _hover = true) : null,
      onExit: enabled ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 76),
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: enabled
                  ? (widget.strong ? background : actionColor)
                  : T.line,
              width: 1.2,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: T.tCaption.copyWith(color: foreground, fontWeight: T.wBold),
          ),
        ),
      ),
    );
  }
}

Color _taskStatusColor(TaskSummary task) {
  if (task.needsReview) return T.warn;
  if (task.isDone) return T.ok;
  if (task.isFailed) return T.danger;
  if (task.isActive) return T.sky;
  return T.muted;
}

bool _taskMatchesFilter(TaskSummary task, _TaskFilter filter) {
  return switch (filter) {
    _TaskFilter.all => true,
    _TaskFilter.active =>
      task.isActive || task.isRuntimeActive || task.canCancel,
    _TaskFilter.needsAction =>
      task.canResume ||
          task.isFailed ||
          task.status == 'INTERRUPTED' ||
          task.isRuntimeStale,
    _TaskFilter.review => task.needsReview,
    _TaskFilter.done => task.isDone,
    _TaskFilter.cancelled => task.status == 'CANCELLED',
  };
}

bool _taskMatchesSearch(TaskSummary task, String searchQuery) {
  final terms = searchQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) return true;
  final outputDir = _outputDirectoryFor(task);
  final searchText = [
    task.taskId,
    shortTaskIdLabel(task.taskId),
    task.status,
    taskStatusLabel(task.status),
    task.displayStatus,
    taskStatusLabel(task.displayStatus),
    _runtimeStateLabel(task.runtimeState),
    _taskActionabilityLabel(task),
    if (task.needsReview) '待校对',
    if (task.needsReview) _taskReviewSummary(task),
    _reviewCheckStatusLabel(task.qualityStatus),
    _reviewCheckStatusLabel(task.deliveryStatus),
    task.sourceLang,
    task.targetLang,
    languageLabel(task.sourceLang),
    languageLabel(task.targetLang),
    task.inputFile,
    task.displayName,
    task.inputType,
    _basename(task.inputFile),
    task.taskDir,
    ?task.outputPath,
    ?outputDir,
    ...task.outputPaths.keys,
    ...task.outputPaths.values,
    subtitleFormatListLabel(task.outputPaths.keys),
    ?task.error,
    taskErrorLabel(task.error, task.errorInfo),
    ...task.errorInfo.values.map((value) => '$value'),
    for (final clue in _taskDiagnosticClues(task)) ...[clue.label, clue.value],
    task.createdAt,
    task.updatedAt,
  ].join('\n').toLowerCase();
  return terms.every((term) => searchText.contains(term));
}

String _runtimeStateLabel(String state) {
  return switch (state.trim().toLowerCase()) {
    '' => '',
    'running' => '运行中',
    'claimed' => '正在处理',
    'queued' => '排队中',
    'stale' => '记录过期',
    'interrupted' => '已中断',
    'terminal' => '已结束',
    'idle' => '空闲',
    _ => state.trim(),
  };
}

String _taskActionabilityLabel(TaskSummary task) {
  final recovery = taskFailurePresentation(
    error: task.error,
    errorInfo: task.errorInfo,
    canResume: task.canResume,
  );
  if (recovery.target == TaskFailureRecoveryTarget.translationSettings ||
      recovery.target == TaskFailureRecoveryTarget.asrSettings) {
    return recovery.actionLabel;
  }
  if (recovery.target == TaskFailureRecoveryTarget.outputDirectory ||
      recovery.target == TaskFailureRecoveryTarget.reexport) {
    return recovery.actionLabel;
  }
  if (task.canResume) return '可继续任务';
  if (task.canCancel) return '可取消任务';
  if (task.hasSavedResultPendingExport) return '修改待导出';
  if (task.needsReview) return '待校对';
  if (task.isDone) return '可编辑结果';
  if (task.isFailed || task.isRuntimeStale) return '无可用恢复动作';
  if (task.isCancelled) return '已结束';
  if (task.isActive || task.isRuntimeActive) return '等待处理';
  return '只读查看';
}

String _taskActionHint(TaskSummary task) {
  if (task.needsReview) {
    return '结果已经生成，但质量或交付检查仍有提醒，建议先校对再交付。';
  }
  if (task.isDone) return '结果已经生成，可以进入字幕编辑或打开结果目录。';
  final recovery = taskFailurePresentation(
    error: task.error,
    errorInfo: task.errorInfo,
    canResume: task.canResume,
  );
  if (recovery.target == TaskFailureRecoveryTarget.translationSettings ||
      recovery.target == TaskFailureRecoveryTarget.asrSettings) {
    return task.canResume
        ? '先${recovery.actionLabel}，修好后可以继续已有进度。'
        : recovery.reason;
  }
  if (recovery.target == TaskFailureRecoveryTarget.outputDirectory) {
    return '选择一个可写目录后，会直接重新导出已有字幕结果。';
  }
  if (recovery.target == TaskFailureRecoveryTarget.reexport) {
    return '字幕结果需要重新写出，不必重新制作整项任务。';
  }
  if (task.canResume) return '这个任务可以从已有进度继续。';
  if (task.canCancel) return '任务仍在制作中，需要时可以取消。';
  if (task.isFailed || task.isRuntimeStale) {
    return '请根据下方失败线索调整配置或片源后重试。';
  }
  if (task.isCancelled) return '这个任务已经结束，没有待执行操作。';
  return '当前任务只提供记录查看。';
}

String _taskDiagnosticTitle(TaskSummary task) {
  if (task.isFailed) return '失败线索';
  if (task.status == 'INTERRUPTED') return '中断线索';
  if (task.isRuntimeStale) return '运行线索';
  return '处理线索';
}

List<_TaskDiagnosticClue> _taskDiagnosticClues(TaskSummary task) {
  final hasError = (task.error ?? '').trim().isNotEmpty;
  final hasDiagnosticInfo = task.errorInfo.isNotEmpty;
  final shouldShow =
      task.isFailed ||
      task.isCancelled ||
      task.isRuntimeStale ||
      hasError ||
      hasDiagnosticInfo;
  if (!shouldShow) return const [];

  final clues = <_TaskDiagnosticClue>[];
  final summary = hasError || hasDiagnosticInfo
      ? taskErrorLabel(task.error, task.errorInfo)
      : '';
  if (summary.trim().isNotEmpty) {
    clues.add(
      _TaskDiagnosticClue(
        label: '提示',
        value: summary,
        danger: task.isFailed || task.isRuntimeStale,
        maxLines: 2,
      ),
    );
  }

  final stage = _firstDiagnosticText(task.errorInfo, const [
    'stage',
    'failed_stage',
    'last_stage',
  ]);
  if (stage != null) {
    clues.add(_TaskDiagnosticClue(label: '阶段', value: taskStageLabel(stage)));
  }

  return clues;
}

Map<String, Object?> _taskDiagnosticSmokeFields(TaskSummary? task) {
  if (task == null) {
    return const <String, Object?>{
      'task_processing_diagnostic_title': '',
      'task_processing_diagnostic_clue_count': 0,
      'task_processing_diagnostic_prompt': '',
      'task_processing_diagnostic_code': '',
      'task_processing_diagnostic_stage': '',
      'task_processing_diagnostic_stage_label': '',
      'task_processing_diagnostic_retryable': null,
      'task_processing_diagnostic_runtime_state': '',
      'task_processing_diagnostic_runtime_state_label': '',
      'task_processing_diagnostic_can_resume': false,
      'task_processing_diagnostic_recovery': '',
      'task_processing_recovery_target': '',
      'task_processing_recovery_action': '',
    };
  }
  final visibleClues = _taskDiagnosticClues(task);
  final stage = _firstDiagnosticText(task.errorInfo, const [
    'stage',
    'failed_stage',
    'last_stage',
  ]);
  final runtimeState = task.runtimeState;
  final recovery = taskFailurePresentation(
    error: task.error,
    errorInfo: task.errorInfo,
    canResume: task.canResume,
  );
  return <String, Object?>{
    'task_processing_diagnostic_title': visibleClues.isEmpty
        ? ''
        : _taskDiagnosticTitle(task),
    'task_processing_diagnostic_clue_count': visibleClues.length,
    'task_processing_diagnostic_prompt': _diagnosticClueValue(
      visibleClues,
      '提示',
    ),
    'task_processing_diagnostic_code':
        _firstDiagnosticText(task.errorInfo, const [
          'code',
          'error_code',
          'kind',
        ]) ??
        '',
    'task_processing_diagnostic_stage': stage ?? '',
    'task_processing_diagnostic_stage_label': stage == null
        ? ''
        : taskStageLabel(stage),
    'task_processing_diagnostic_retryable': _firstDiagnosticBool(
      task.errorInfo,
      const ['retryable', 'recoverable', 'can_retry'],
    ),
    'task_processing_diagnostic_runtime_state': runtimeState,
    'task_processing_diagnostic_runtime_state_label': _runtimeStateLabel(
      runtimeState,
    ),
    'task_processing_diagnostic_can_resume': task.canResume,
    'task_processing_diagnostic_recovery': recovery.actionLabel,
    'task_processing_recovery_target': recovery.target.name,
    'task_processing_recovery_action': recovery.actionLabel,
  };
}

String _diagnosticClueValue(List<_TaskDiagnosticClue> clues, String label) {
  for (final clue in clues) {
    if (clue.label == label) return clue.value;
  }
  return '';
}

String? _firstDiagnosticText(
  Map<String, Object?> values,
  Iterable<String> keys,
) {
  for (final key in keys) {
    final value = _stringValue(values[key]);
    if (value != null) return value;
  }
  return null;
}

bool? _firstDiagnosticBool(Map<String, Object?> values, Iterable<String> keys) {
  for (final key in keys) {
    final value = values[key];
    if (value is bool) return value;
    final text = _stringValue(value)?.toLowerCase();
    if (text == null) continue;
    if (text == 'true' || text == 'yes' || text == '1') return true;
    if (text == 'false' || text == 'no' || text == '0') return false;
  }
  return null;
}

String _taskFilterLabel(_TaskFilter filter) {
  return switch (filter) {
    _TaskFilter.all => '全部',
    _TaskFilter.active => '制作中',
    _TaskFilter.needsAction => '待处理',
    _TaskFilter.review => '待校对',
    _TaskFilter.done => '已完成',
    _TaskFilter.cancelled => '已取消',
  };
}

String _taskFilterEmptyText(_TaskFilter filter) {
  return switch (filter) {
    _TaskFilter.all => '还没有任务记录。',
    _TaskFilter.active => '没有正在制作的任务。',
    _TaskFilter.needsAction => '没有需要处理的失败或中断任务。',
    _TaskFilter.review => '没有需要继续校对的完成任务。',
    _TaskFilter.done => '还没有完成的任务。',
    _TaskFilter.cancelled => '还没有已取消的任务。',
  };
}

String _taskListEmptyText(_TaskFilter filter, String searchQuery) {
  final query = searchQuery.trim();
  if (query.isNotEmpty) return '没有匹配“$query”的任务。';
  return _taskFilterEmptyText(filter);
}

String _taskSubtitle(TaskSummary task) {
  final outputs = subtitleFormatListLabel(task.outputPaths.keys);
  return [
    taskStatusLabel(task.status),
    if (task.sourceLang.isNotEmpty || task.targetLang.isNotEmpty)
      '${languageLabel(task.sourceLang)} → ${languageLabel(task.targetLang)}',
    task.bilingual ? '双语字幕' : '单语字幕',
    if (outputs.isNotEmpty) outputs,
  ].join(' · ');
}

String _taskReviewSummary(TaskSummary task) {
  if (task.hasSavedResultPendingExport) return '待导出 · 修改已保存';
  final count = task.reviewIssueCount;
  return count > 0 ? '待校对 · $count 条提示' : '待校对 · 有检查提醒';
}

String _taskReviewDetail(TaskSummary task) {
  if (task.hasSavedResultPendingExport) {
    return '字幕修改已经保存，但成品文件仍是旧版本；打开字幕后重新导出即可更新。';
  }
  final count = task.reviewIssueCount;
  if (count > 0) {
    return '还有 $count 条质量或交付提示，打开字幕会先显示有问题的片段。';
  }
  return '质量或交付检查留下了提醒，打开字幕后建议逐条确认。';
}

String _reviewCheckStatusLabel(String status) {
  return switch (status.trim().toUpperCase()) {
    'PASS' => '已通过',
    'WARN' => '有提醒',
    'FAIL' => '需校对',
    _ => '',
  };
}

String _basename(String path) {
  if (path.trim().isEmpty) return '';
  return path.split(RegExp(r'[\\/]')).last;
}

String? _outputDirectoryFor(TaskSummary task) {
  final path = _primaryOutputPath(task);
  if (path == null || path.trim().isEmpty) return null;
  return _dirname(path);
}

String? _primaryOutputPath(TaskSummary task) {
  final direct = task.outputPath?.trim();
  if (direct != null && direct.isNotEmpty) return direct;
  for (final key in const ['srt', 'ass', 'vtt', 'lrc']) {
    final value = task.outputPaths[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  if (task.outputPaths.isNotEmpty) {
    final value = task.outputPaths.values.first.trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

String _dirname(String path) {
  final trimmed = path.trim();
  final lastSlash = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (lastSlash <= 0) return '';
  return trimmed.substring(0, lastSlash);
}

String _taskOutputFormat(TaskSummary task) {
  final saved = (_stringValue(task.settings['output_format']) ?? '')
      .toLowerCase();
  if (saved == 'webvtt') return 'vtt';
  if (const {'srt', 'ass', 'vtt', 'lrc', 'both'}.contains(saved)) return saved;

  final formats = task.outputPaths.keys
      .map((value) => value.trim().toLowerCase())
      .toSet();
  if (formats.contains('srt') && formats.contains('ass')) return 'both';
  for (final format in const ['srt', 'ass', 'vtt', 'lrc']) {
    if (formats.contains(format)) return format;
  }
  return 'srt';
}

String _normalizedSmokeScenario(String? value) {
  return switch ((value ?? '').trim().toLowerCase()) {
    'edit' => 'edit',
    'failure' => 'failure',
    'outputfailure' => 'outputFailure',
    'review' => 'review',
    'resume' => 'resume',
    'cancel' => 'cancel',
    _ => 'browse',
  };
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

Map<String, Object?> _eventMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return {'type': 'event', 'message': '$value'};
}

String _eventText(
  Map<String, Object?> event,
  String key, {
  String fallback = '',
}) {
  final value = event[key];
  if (value == null) return fallback;
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

bool _eventMatchesSearch(Map<String, Object?> event, String searchQuery) {
  final terms = searchQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) return true;
  final type = _eventText(event, 'type', fallback: 'event');
  final stage = _eventText(event, 'stage');
  final status = _eventText(event, 'status');
  final message = _eventText(event, 'message');
  final createdAt = taskTimestampLabel(_eventText(event, 'created_at'));
  final progress = taskProgressLabel(event['progress']);
  final searchText = [
    type,
    taskEventTypeLabel(type),
    stage,
    taskStageLabel(stage),
    status,
    taskStatusLabel(status),
    message,
    taskEventMessageLabel(
      type: type,
      stage: stage,
      status: status,
      message: message,
    ),
    createdAt,
    progress,
    ...event.values.map((value) => '$value'),
  ].join('\n').toLowerCase();
  return terms.every((term) => searchText.contains(term));
}

String _friendlyTaskProcessingError(Object error) {
  if (error is RpcRemoteException) {
    final details = _stringMap(error.details);
    final errorInfo = _stringMap(details['error_info']);
    return taskFailurePresentation(
      error: error.message,
      errorInfo: {
        ...errorInfo,
        if ((_stringValue(errorInfo['code']) ?? '').isEmpty) 'code': error.code,
      },
    ).reason;
  }
  return taskFailurePresentation(error: '$error').reason;
}
