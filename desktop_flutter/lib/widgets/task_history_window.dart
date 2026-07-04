import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../model/startup_args.dart';
import '../model/task_labels.dart';
import '../model/window_state.dart';
import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/smoke_render_capture.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'title_bar.dart';

class _SmokeHistoryTransport implements AppServiceTransport {
  _SmokeHistoryTransport(this.service);

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
      throw StateError('本地服务未连接，无法执行任务历史 smoke');
    }
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() => service.shutdown();
}

class TaskHistoryWindow extends StatefulWidget {
  const TaskHistoryWindow({
    super.key,
    required this.store,
    required this.bridge,
    this.pathOpener,
    this.smoke,
  });

  final WindowStateStore store;
  final WindowStateBridge bridge;
  final PathOpener? pathOpener;
  final AppSmokeArgs? smoke;

  @override
  State<TaskHistoryWindow> createState() => _TaskHistoryWindowState();
}

class _TaskHistoryWindowState extends State<TaskHistoryWindow> {
  late final AppServiceClient _client;
  late final PathOpener _pathOpener;
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'task-history-smoke');
  LocalServiceController? _smokeService;
  List<TaskSummary> _tasks = const [];
  String? _message;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _client = AppServiceClient(_historyTransport());
    _pathOpener = widget.pathOpener ?? SystemPathOpener();
    if (widget.smoke == null) {
      unawaited(widget.bridge.initializeChild());
    }
    unawaited(_loadTasks());
  }

  @override
  void dispose() {
    _smokeService?.dispose();
    super.dispose();
  }

  AppServiceTransport _historyTransport() {
    final smoke = widget.smoke;
    if (smoke == null) return WindowBridgeTransport(widget.bridge);
    final service = LocalServiceController(
      supervisor: LocalServiceSupervisor(serviceRoot: _serviceRoot(smoke)),
    );
    _smokeService = service;
    return _SmokeHistoryTransport(service);
  }

  Directory? _serviceRoot(AppSmokeArgs smoke) {
    final root = smoke.serviceRoot;
    if (root == null || root.isEmpty) return null;
    return Directory(root);
  }

  Future<void> _loadTasks() async {
    setState(() {
      _loading = true;
      _message = null;
      _error = null;
    });
    try {
      final tasks = await _client.taskList();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loading = false;
        _message = '已读取 ${tasks.length} 个任务。';
      });
      if (widget.smoke != null) {
        await _writeSmokeReport(tasks);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyHistoryError(error);
        _loading = false;
      });
      if (widget.smoke != null) {
        await _writeSmokeReport(const [], error: error);
      }
    }
  }

  Future<void> _openResult(TaskSummary task) async {
    try {
      await widget.bridge.openToolWindow(
        AppWindowType.resultReview,
        taskId: task.taskId,
      );
      if (!mounted) return;
      setState(() {
        _message = '已打开结果审看';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开结果审看失败：${_friendlyHistoryError(error)}';
      });
    }
  }

  Future<void> _openDetail(TaskSummary task) async {
    try {
      await widget.bridge.openToolWindow(
        AppWindowType.taskDetail,
        taskId: task.taskId,
      );
      if (!mounted) return;
      setState(() {
        _message = '已打开任务详情';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开任务详情失败：${_friendlyHistoryError(error)}';
      });
    }
  }

  Future<void> _openTaskDirectory(TaskSummary task) async {
    final dir = task.taskDir.trim();
    if (dir.isEmpty) {
      setState(() {
        _message = null;
        _error = '这个任务没有记录任务目录。';
      });
      return;
    }
    try {
      await _pathOpener.openDirectory(dir);
      if (!mounted) return;
      setState(() {
        _message = '已打开任务目录';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开任务目录失败：$error';
      });
    }
  }

  Future<void> _openOutputDirectory(TaskSummary task) async {
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      setState(() {
        _message = null;
        _error = '这个任务还没有输出目录。';
      });
      return;
    }
    try {
      await _pathOpener.openDirectory(dir);
      if (!mounted) return;
      setState(() {
        _message = '已打开结果目录';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开结果目录失败：$error';
      });
    }
  }

  Future<void> _writeSmokeReport(
    List<TaskSummary> tasks, {
    Object? error,
  }) async {
    final smoke = widget.smoke;
    if (smoke == null) return;
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    final payload = <String, Object?>{
      'ok': error == null && tasks.isNotEmpty,
      'status': error == null ? 'ready' : 'error',
      'window_type': AppWindowType.taskHistory.id,
      'title': AppWindowType.taskHistory.title,
      'history_task_count': tasks.length,
      'history_done_count': tasks.where((task) => task.isDone).length,
      'history_active_count': tasks.where((task) => task.isActive).length,
      'history_failed_count': tasks.where((task) => task.isFailed).length,
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
    return RepaintBoundary(
      key: _renderKey,
      child: Scaffold(
        backgroundColor: T.bg,
        body: Column(
          children: [
            TitleBar(title: '任务历史', status: _statusText),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(T.s32, T.s16, T.s32, T.s24),
                child: _body(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _statusText {
    if (_loading) return '读取任务中';
    if (_error != null) return '任务历史暂不可用';
    return '最近任务 · 只读';
  }

  Widget _body() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _tasks.isEmpty ? '暂无任务' : '最近 ${_tasks.length} 个任务',
                style: T.tFilename,
              ),
            ),
            _HistoryMetric(label: '完成', value: '${_doneCount(_tasks)}'),
            const SizedBox(width: T.s8),
            _HistoryMetric(label: '处理中', value: '${_activeCount(_tasks)}'),
            const SizedBox(width: T.s8),
            _HistoryMetric(label: '失败', value: '${_failedCount(_tasks)}'),
            const SizedBox(width: T.s16),
            _HistoryButton(
              label: _loading ? '刷新中' : '刷新',
              onTap: _loading ? null : _loadTasks,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        if (_error != null)
          Text(_error!, style: T.tBody.copyWith(color: T.danger))
        else if (_message != null)
          Text(_message!, style: T.tCaption)
        else
          const Text('完成任务可进入结果审看。', style: T.tCaption),
        const SizedBox(height: T.s16),
        Expanded(
          child: _loading && _tasks.isEmpty
              ? const Center(child: Text('读取任务中…', style: T.tBody))
              : _tasks.isEmpty
              ? const Center(child: Text('还没有任务记录。', style: T.tBody))
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: _tasks.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) => _HistoryTaskRow(
                    task: _tasks[index],
                    onOpenDetail: () => _openDetail(_tasks[index]),
                    onOpenTaskDirectory: _tasks[index].taskDir.trim().isEmpty
                        ? null
                        : () => _openTaskDirectory(_tasks[index]),
                    onOpenOutputDirectory:
                        _outputDirectoryFor(_tasks[index]) == null
                        ? null
                        : () => _openOutputDirectory(_tasks[index]),
                    onOpenResult: _tasks[index].isDone
                        ? () => _openResult(_tasks[index])
                        : null,
                  ),
                ),
        ),
      ],
    );
  }
}

class _HistoryTaskRow extends StatelessWidget {
  const _HistoryTaskRow({
    required this.task,
    required this.onOpenDetail,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
    required this.onOpenResult,
  });

  final TaskSummary task;
  final VoidCallback onOpenDetail;
  final VoidCallback? onOpenTaskDirectory;
  final VoidCallback? onOpenOutputDirectory;
  final VoidCallback? onOpenResult;

  @override
  Widget build(BuildContext context) {
    final filename = _basename(task.inputFile);
    final outputFormats = subtitleFormatListLabel(task.outputPaths.keys);
    final subtitle = [
      taskStatusLabel(task.status),
      if (task.targetLang.isNotEmpty) languageLabel(task.targetLang),
      if (outputFormats.isNotEmpty) outputFormats,
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: 86, child: _StatusTag(status: task.status)),
        const SizedBox(width: T.s16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: _historyTaskTooltip(task, filename),
                child: Text(
                  filename.isEmpty ? _shortTaskId(task.taskId) : filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tBody.copyWith(fontWeight: T.wMedium),
                ),
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
        const SizedBox(width: T.s16),
        const SizedBox(width: T.s16),
        SizedBox(
          width: 344,
          child: Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            alignment: WrapAlignment.end,
            children: [
              _HistoryButton(label: '详情', onTap: onOpenDetail),
              _HistoryButton(label: '任务目录', onTap: onOpenTaskDirectory),
              _HistoryButton(label: '结果目录', onTap: onOpenOutputDirectory),
              _HistoryButton(label: '审看结果', onTap: onOpenResult),
            ],
          ),
        ),
      ],
    );
  }
}

String _historyTaskTooltip(TaskSummary task, String filename) {
  final lines = <String>[
    if (task.inputFile.trim().isNotEmpty)
      fileTooltipLabel(task.inputFile, fallbackName: filename),
    if (task.taskId.trim().isNotEmpty) '任务编号：${shortTaskIdLabel(task.taskId)}',
  ];
  return lines.isEmpty ? '任务' : lines.join('\n');
}

class _HistoryMetric extends StatelessWidget {
  const _HistoryMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 58),
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.tCaption),
          Text(value, style: T.tSection),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'DONE' => T.ok,
      'FAILED' => T.danger,
      'INIT' ||
      'QUEUED' ||
      'PRECHECK' ||
      'INGEST' ||
      'ASR' ||
      'SEGMENT' ||
      'TRANSLATE' ||
      'ALIGN' ||
      'QUALITY' ||
      'EXPORT' ||
      'RUNNING' ||
      'CANCEL_REQUESTED' => T.sky,
      _ => T.muted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color.withValues(alpha: 0.8)),
      ),
      child: Text(
        taskStatusLabel(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: T.tCaption.copyWith(color: T.ink, fontWeight: T.wMedium),
      ),
    );
  }
}

class _HistoryButton extends StatefulWidget {
  const _HistoryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_HistoryButton> createState() => _HistoryButtonState();
}

class _HistoryButtonState extends State<_HistoryButton> {
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

String _friendlyHistoryError(Object error) {
  if (error is RpcRemoteException) {
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
    return '读取任务失败：${error.code}';
  }
  return '读取任务失败：$error';
}

int _doneCount(List<TaskSummary> tasks) {
  return tasks.where((task) => task.isDone).length;
}

int _activeCount(List<TaskSummary> tasks) {
  return tasks.where((task) => task.isActive).length;
}

int _failedCount(List<TaskSummary> tasks) {
  return tasks.where((task) => task.isFailed).length;
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

String _shortTaskId(String taskId) {
  return shortTaskIdLabel(taskId);
}
