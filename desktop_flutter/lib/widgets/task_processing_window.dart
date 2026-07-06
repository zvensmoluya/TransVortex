import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../model/startup_args.dart';
import '../model/task_labels.dart';
import '../model/window_state.dart';
import '../services/app_service_client.dart';
import '../services/current_window_controls.dart';
import '../services/local_service_controller.dart';
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

class TaskProcessingWindow extends StatefulWidget {
  const TaskProcessingWindow({
    super.key,
    required this.taskId,
    required this.store,
    required this.bridge,
    this.pathOpener,
    this.smoke,
  });

  final String? taskId;
  final WindowStateStore store;
  final WindowStateBridge bridge;
  final PathOpener? pathOpener;
  final AppSmokeArgs? smoke;

  @override
  State<TaskProcessingWindow> createState() => _TaskProcessingWindowState();
}

class _TaskProcessingWindowState extends State<TaskProcessingWindow> {
  late final AppServiceClient _client;
  late final AppServiceTransport _embeddedResultTransport;
  late final PathOpener _pathOpener;
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'task-processing-smoke');
  LocalServiceController? _smokeService;
  List<TaskSummary> _tasks = const [];
  TaskEventsPage? _eventsPage;
  String? _selectedTaskId;
  String? _message;
  String? _error;
  bool _loadingTasks = false;
  bool _loadingEvents = false;
  bool _resuming = false;
  String? _editingTaskId;
  String _smokeScenario = 'browse';
  int _smokeResultSegmentCount = 0;
  int _smokeResultIssueCount = 0;
  bool _smokeEditSaved = false;
  bool _smokeReexported = false;
  bool _smokeOutputContainsEdit = false;
  String _smokeEditedText = '';
  String _smokeReexportFormat = '';
  bool? _smokeReexportBilingual;
  bool _smokeResumeAttempted = false;
  bool _smokeResumeOk = false;
  String _smokeResumeStatus = '';

  @override
  void initState() {
    super.initState();
    _client = AppServiceClient(_processingTransport());
    _embeddedResultTransport = _TaskProcessingClientTransport(_client);
    _pathOpener = widget.pathOpener ?? SystemPathOpener();
    _selectedTaskId = widget.taskId?.trim();
    _editingTaskId = widget.taskId?.trim();
    if (widget.smoke == null) {
      unawaited(widget.bridge.initializeChild());
    }
    registerCurrentWindowRetargetHandler(_retarget);
    unawaited(_loadTasks());
  }

  @override
  void dispose() {
    registerCurrentWindowRetargetHandler(null);
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
      final selected = _selectedTask(tasks);
      setState(() {
        _tasks = tasks;
        _selectedTaskId = selected?.taskId;
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
          if (_smokeScenario == 'resume') {
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
      _selectedTaskId = taskId;
      _editingTaskId = taskId;
    }
    await _loadTasks();
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

  Future<void> _selectTask(TaskSummary task) async {
    if (_selectedTaskId == task.taskId && _eventsPage?.taskId == task.taskId) {
      return;
    }
    setState(() {
      _selectedTaskId = task.taskId;
      _editingTaskId = null;
      _message = null;
      _error = null;
    });
    await _loadEvents(task.taskId);
  }

  Future<void> _loadEvents(String taskId) async {
    setState(() {
      _loadingEvents = true;
    });
    try {
      final events = await _client.taskEvents(taskId, limit: 40);
      if (!mounted) return;
      setState(() {
        _eventsPage = events;
        _loadingEvents = false;
      });
    } on Object catch (_) {
      if (!mounted) return;
      setState(() {
        _eventsPage = null;
        _loadingEvents = false;
      });
    }
  }

  Future<void> _openResult(TaskSummary task) async {
    if (!task.isDone) return;
    setState(() {
      _editingTaskId = task.taskId;
      _message = '正在处理字幕结果。';
      _error = null;
    });
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
    } else if (_smokeScenario == 'resume') {
      await _runSmokeResumeFlow(selected);
    }
  }

  Future<void> _runSmokeEditFlow(TaskSummary task) async {
    if (!task.isDone) return;
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
    _smokeReexportBilingual = false;
    final reexported = await _client.resultReexport(
      task.taskId,
      outputFormat: _smokeReexportFormat,
      bilingual: _smokeReexportBilingual ?? false,
    );
    _smokeReexported = reexported.isNotEmpty;
    final outputPaths = _stringMap(reexported['output_paths']);
    final outputPath =
        _stringValue(outputPaths['ass']) ??
        _stringValue(outputPaths['srt']) ??
        _stringValue(outputPaths['vtt']);
    if (outputPath != null && outputPath.isNotEmpty) {
      final output = File(outputPath);
      if (await output.exists()) {
        final text = await output.readAsString(encoding: utf8);
        _smokeOutputContainsEdit = text.contains(_smokeEditedText);
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
      'task_processing_result_segment_count': _smokeResultSegmentCount,
      'task_processing_result_issue_count': _smokeResultIssueCount,
      'task_processing_edit_saved': _smokeEditSaved,
      'task_processing_reexported': _smokeReexported,
      'task_processing_reexport_output_contains_edit': _smokeOutputContainsEdit,
      'task_processing_edited_text': _smokeEditedText,
      'task_processing_reexport_format': _smokeReexportFormat,
      'task_processing_reexport_bilingual': _smokeReexportBilingual,
      'task_processing_resume_attempted': _smokeResumeAttempted,
      'task_processing_resume_ok': _smokeResumeOk,
      'task_processing_resume_status': _smokeResumeStatus,
      'error': error == null ? '' : '$error',
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };
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
    final selected = _selectedTask(_tasks);
    final events = _eventsPage?.taskId == selected?.taskId
        ? _eventsPage?.events ?? const <Object?>[]
        : const <Object?>[];
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
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s24),
                child: _TaskProcessingBody(
                  tasks: _tasks,
                  selected: selected,
                  events: events,
                  editingTaskId: editingTaskId == selected?.taskId
                      ? editingTaskId
                      : null,
                  store: widget.store,
                  bridge: widget.bridge,
                  resultTransportOverride: _embeddedResultTransport,
                  message: _message,
                  error: _error,
                  loadingTasks: _loadingTasks,
                  loadingEvents: _loadingEvents,
                  resuming: _resuming,
                  onRefresh: _loadTasks,
                  onSelectTask: (task) => unawaited(_selectTask(task)),
                  onOpenResult: (task) => unawaited(_openResult(task)),
                  onCloseEditor: () => setState(() => _editingTaskId = null),
                  onResume: (task) => unawaited(_resumeTask(task)),
                  onOpenTaskDirectory: (task) =>
                      unawaited(_openTaskDirectory(task)),
                  onOpenOutputDirectory: (task) =>
                      unawaited(_openOutputDirectory(task)),
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
    if (_error != null) return '任务处理暂不可用';
    if (selected == null) return '任务片列';
    return '${taskStatusLabel(selected.status)} · 任务片列';
  }
}

class _TaskProcessingBody extends StatelessWidget {
  const _TaskProcessingBody({
    required this.tasks,
    required this.selected,
    required this.events,
    required this.editingTaskId,
    required this.store,
    required this.bridge,
    required this.resultTransportOverride,
    required this.message,
    required this.error,
    required this.loadingTasks,
    required this.loadingEvents,
    required this.resuming,
    required this.onRefresh,
    required this.onSelectTask,
    required this.onOpenResult,
    required this.onCloseEditor,
    required this.onResume,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
  });

  final List<TaskSummary> tasks;
  final TaskSummary? selected;
  final List<Object?> events;
  final String? editingTaskId;
  final WindowStateStore store;
  final WindowStateBridge bridge;
  final AppServiceTransport resultTransportOverride;
  final String? message;
  final String? error;
  final bool loadingTasks;
  final bool loadingEvents;
  final bool resuming;
  final VoidCallback onRefresh;
  final ValueChanged<TaskSummary> onSelectTask;
  final ValueChanged<TaskSummary> onOpenResult;
  final VoidCallback onCloseEditor;
  final ValueChanged<TaskSummary> onResume;
  final ValueChanged<TaskSummary> onOpenTaskDirectory;
  final ValueChanged<TaskSummary> onOpenOutputDirectory;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 292,
          child: _TaskStripList(
            tasks: tasks,
            selectedTaskId: selected?.taskId,
            loading: loadingTasks,
            onRefresh: onRefresh,
            onSelect: onSelectTask,
          ),
        ),
        const SizedBox(width: T.s24),
        Expanded(
          child: _TaskPreview(
            task: selected,
            events: events,
            editingTaskId: editingTaskId,
            store: store,
            bridge: bridge,
            resultTransportOverride: resultTransportOverride,
            message: message,
            error: error,
            loadingTasks: loadingTasks,
            loadingEvents: loadingEvents,
            resuming: resuming,
            onRefresh: onRefresh,
            onOpenResult: onOpenResult,
            onCloseEditor: onCloseEditor,
            onResume: onResume,
            onOpenTaskDirectory: onOpenTaskDirectory,
            onOpenOutputDirectory: onOpenOutputDirectory,
          ),
        ),
      ],
    );
  }
}

class _TaskStripList extends StatelessWidget {
  const _TaskStripList({
    required this.tasks,
    required this.selectedTaskId,
    required this.loading,
    required this.onRefresh,
    required this.onSelect,
  });

  final List<TaskSummary> tasks;
  final String? selectedTaskId;
  final bool loading;
  final VoidCallback onRefresh;
  final ValueChanged<TaskSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('任务片列', style: T.tFilename)),
            _TaskActionButton(
              label: loading ? '刷新中' : '刷新',
              onTap: loading ? null : onRefresh,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Text(
          tasks.isEmpty ? '完成、失败和制作中的任务会出现在这里。' : '最近 ${tasks.length} 个任务',
          style: T.tCaption,
        ),
        const SizedBox(height: T.s16),
        Expanded(
          child: loading && tasks.isEmpty
              ? const Center(child: Text('读取任务中…', style: T.tBody))
              : tasks.isEmpty
              ? const Center(child: Text('还没有任务记录。', style: T.tBody))
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
    final name = _basename(task.inputFile);
    final outputs = subtitleFormatListLabel(task.outputPaths.keys);
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
    required this.editingTaskId,
    required this.store,
    required this.bridge,
    required this.resultTransportOverride,
    required this.message,
    required this.error,
    required this.loadingTasks,
    required this.loadingEvents,
    required this.resuming,
    required this.onRefresh,
    required this.onOpenResult,
    required this.onCloseEditor,
    required this.onResume,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
  });

  final TaskSummary? task;
  final List<Object?> events;
  final String? editingTaskId;
  final WindowStateStore store;
  final WindowStateBridge bridge;
  final AppServiceTransport resultTransportOverride;
  final String? message;
  final String? error;
  final bool loadingTasks;
  final bool loadingEvents;
  final bool resuming;
  final VoidCallback onRefresh;
  final ValueChanged<TaskSummary> onOpenResult;
  final VoidCallback onCloseEditor;
  final ValueChanged<TaskSummary> onResume;
  final ValueChanged<TaskSummary> onOpenTaskDirectory;
  final ValueChanged<TaskSummary> onOpenOutputDirectory;

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
              store: store,
              bridge: bridge,
              embedded: true,
              transportOverride: resultTransportOverride,
            ),
          ),
        ],
      );
    }
    final outputDir = _outputDirectoryFor(task);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
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
                  Text(_taskSubtitle(task), style: T.tCaption),
                ],
              ),
            ),
            const SizedBox(width: T.s16),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              alignment: WrapAlignment.end,
              children: [
                _TaskActionButton(label: '刷新', onTap: onRefresh),
                _TaskActionButton(
                  label: task.isDone ? '编辑字幕' : '编辑字幕',
                  onTap: task.isDone ? () => onOpenResult(task) : null,
                ),
                _TaskActionButton(
                  label: resuming ? '继续中' : '继续任务',
                  onTap: task.canResume && !resuming
                      ? () => onResume(task)
                      : null,
                ),
                _TaskActionButton(
                  label: '任务目录',
                  onTap: task.taskDir.trim().isNotEmpty
                      ? () => onOpenTaskDirectory(task)
                      : null,
                ),
                _TaskActionButton(
                  label: '结果目录',
                  onTap: outputDir == null
                      ? null
                      : () => onOpenOutputDirectory(task),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        if (error != null)
          Text(error!, style: T.tBody.copyWith(color: T.danger))
        else if (message != null)
          Text(message!, style: T.tCaption)
        else
          const Text('在这里处理任务、继续失败任务，或进入字幕编辑。', style: T.tCaption),
        const SizedBox(height: T.s16),
        _TaskSummaryPanel(task: task),
        const SizedBox(height: T.s16),
        Text('最近事件', style: T.tSection),
        const SizedBox(height: T.s8),
        Expanded(
          child: loadingEvents && events.isEmpty
              ? const Center(child: Text('读取事件中…', style: T.tBody))
              : events.isEmpty
              ? const Center(child: Text('还没有事件记录。', style: T.tBody))
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: events.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) =>
                      _EventPreviewRow(event: _eventMap(events[index])),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.surface,
        border: Border.all(color: T.line),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Wrap(
        spacing: T.s8,
        runSpacing: T.s8,
        children: [
          _InfoPill(label: '状态', value: taskStatusLabel(task.status)),
          _InfoPill(label: '源语', value: languageLabel(task.sourceLang)),
          _InfoPill(label: '目标', value: languageLabel(task.targetLang)),
          _InfoPill(label: '字幕', value: task.bilingual ? '双语' : '单语'),
          if (outputs.isNotEmpty) _InfoPill(label: '输出', value: outputs),
          _InfoPill(label: '编号', value: shortTaskIdLabel(task.taskId)),
          if ((task.error ?? '').isNotEmpty)
            _InfoPill(
              label: '错误',
              value: taskErrorLabel(task.error, task.errorInfo),
              danger: true,
            ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.value,
    this.danger = false,
  });

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: danger ? T.danger : T.line),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Text(
        '$label ${value.isEmpty ? '未知' : value}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(color: danger ? T.danger : T.ink),
      ),
    );
  }
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
  const _TaskActionButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_TaskActionButton> createState() => _TaskActionButtonState();
}

class _TaskActionButtonState extends State<_TaskActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
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
            color: _hover ? T.accentSoft : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: enabled ? T.accentStrong : T.line,
              width: 1.2,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: T.tCaption.copyWith(
              color: enabled ? T.accentStrong : T.muted,
              fontWeight: T.wBold,
            ),
          ),
        ),
      ),
    );
  }
}

Color _taskStatusColor(TaskSummary task) {
  if (task.isDone) return T.ok;
  if (task.isFailed) return T.danger;
  if (task.isActive) return T.sky;
  return T.muted;
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
  for (final key in const ['srt', 'ass', 'vtt']) {
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

String _normalizedSmokeScenario(String? value) {
  return switch ((value ?? '').trim().toLowerCase()) {
    'edit' => 'edit',
    'resume' => 'resume',
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

String _friendlyTaskProcessingError(Object error) {
  if (error is RpcRemoteException) {
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
    return '任务处理失败：${error.code}';
  }
  return '任务处理失败：$error';
}
