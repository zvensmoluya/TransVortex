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

class _SmokeDetailTransport implements AppServiceTransport {
  _SmokeDetailTransport(this.service);

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
      throw StateError('本地服务未连接，无法执行任务详情 smoke');
    }
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() => service.shutdown();
}

class TaskDetailWindow extends StatefulWidget {
  const TaskDetailWindow({
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
  State<TaskDetailWindow> createState() => _TaskDetailWindowState();
}

class _TaskDetailWindowState extends State<TaskDetailWindow> {
  late final AppServiceClient _client;
  late final PathOpener _pathOpener;
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'task-detail-smoke');
  LocalServiceController? _smokeService;
  TaskSummary? _task;
  TaskEventsPage? _eventsPage;
  String? _message;
  String? _error;
  bool _loading = false;
  bool _resuming = false;
  bool _smokeResumeAttempted = false;
  bool _resumeSucceeded = false;

  @override
  void initState() {
    super.initState();
    _client = AppServiceClient(_detailTransport());
    _pathOpener = widget.pathOpener ?? SystemPathOpener();
    if (widget.smoke == null) {
      unawaited(widget.bridge.initializeChild());
    }
    unawaited(_loadDetail());
  }

  @override
  void dispose() {
    _smokeService?.dispose();
    super.dispose();
  }

  AppServiceTransport _detailTransport() {
    final smoke = widget.smoke;
    if (smoke == null) return WindowBridgeTransport(widget.bridge);
    final service = LocalServiceController(
      supervisor: LocalServiceSupervisor(serviceRoot: _serviceRoot(smoke)),
    );
    _smokeService = service;
    return _SmokeDetailTransport(service);
  }

  Directory? _serviceRoot(AppSmokeArgs smoke) {
    final root = smoke.serviceRoot;
    if (root == null || root.isEmpty) return null;
    return Directory(root);
  }

  Future<void> _loadDetail() async {
    final taskId = widget.taskId?.trim();
    if (taskId == null || taskId.isEmpty) {
      setState(() {
        _error = '缺少任务 id，无法读取详情。';
      });
      if (widget.smoke != null) {
        await _writeSmokeReport(error: StateError('task_id is required'));
      }
      return;
    }

    setState(() {
      _loading = true;
      _message = null;
      _error = null;
    });
    try {
      final tasks = await _client.taskList();
      final task = tasks.firstWhere(
        (candidate) => candidate.taskId == taskId,
        orElse: () => TaskSummary.fromJson(taskId),
      );
      final eventsPage = await _client.taskEvents(taskId, limit: 120);
      if (!mounted) return;
      setState(() {
        _task = task;
        _eventsPage = eventsPage;
        _loading = false;
        _message = '已读取 ${eventsPage.events.length} 条事件。';
      });
      if (widget.smoke != null && task.canResume && !_smokeResumeAttempted) {
        _smokeResumeAttempted = true;
        await _resumeTask();
        return;
      }
      if (widget.smoke != null) {
        await _writeSmokeReport(task: task, eventsPage: eventsPage);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyDetailError(error);
        _loading = false;
      });
      if (widget.smoke != null) {
        await _writeSmokeReport(error: error);
      }
    }
  }

  Future<void> _openResult() async {
    final task = _task;
    if (task == null || !task.isDone) return;
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
        _error = '打开结果审看失败：${_friendlyDetailError(error)}';
      });
    }
  }

  Future<void> _openTaskDirectory() async {
    final task = _task;
    final dir = task?.taskDir.trim() ?? '';
    if (task == null || dir.isEmpty) {
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

  Future<void> _openOutputDirectory() async {
    final task = _task;
    final dir = task == null ? null : _outputDirectoryFor(task);
    if (task == null || dir == null || dir.isEmpty) {
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

  Future<bool> _resumeTask() async {
    final task = _task;
    if (task == null || !task.canResume || _resuming) return false;
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
      if (!mounted) return false;
      setState(() {
        _resumeSucceeded = true;
        _resuming = false;
        _message = result.message.isNotEmpty ? result.message : '任务已重新排队。';
      });
      await _loadDetail();
      return true;
    } on Object catch (error) {
      if (!mounted) return false;
      setState(() {
        _error = '继续任务失败：${_friendlyDetailError(error)}';
      });
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _resuming = false;
        });
      }
    }
  }

  Future<void> _writeSmokeReport({
    TaskSummary? task,
    TaskEventsPage? eventsPage,
    Object? error,
  }) async {
    final smoke = widget.smoke;
    if (smoke == null) return;
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    final eventCount = eventsPage?.events.length ?? 0;
    final payload = <String, Object?>{
      'ok': error == null && task != null && eventCount > 0,
      'status': error == null ? 'ready' : 'error',
      'window_type': AppWindowType.taskDetail.id,
      'title': AppWindowType.taskDetail.title,
      'task_id': task?.taskId ?? widget.taskId ?? '',
      'task_detail_status': task?.status ?? '',
      'task_detail_event_count': eventCount,
      'task_detail_can_resume': task?.canResume ?? false,
      'task_detail_resume_attempted': _smokeResumeAttempted,
      'task_detail_resume_ok': _resumeSucceeded,
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
            TitleBar(title: '任务详情', status: _statusText),
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
    if (_loading) return '读取事件中';
    if (_resuming) return '继续任务中';
    if (_error != null) return '任务详情暂不可用';
    final task = _task;
    if (task == null) return '任务事件 · 只读';
    return '${_taskHeaderStatusLabel(task)} · 只读事件';
  }

  Widget _body() {
    final task = _task;
    final events = _eventsPage?.events ?? const <Object?>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                task == null
                    ? '任务详情'
                    : _basename(task.inputFile).isEmpty
                    ? task.taskId
                    : _basename(task.inputFile),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tFilename,
              ),
            ),
            const SizedBox(width: T.s8),
            SizedBox(
              width: 430,
              child: Wrap(
                spacing: T.s8,
                runSpacing: T.s8,
                alignment: WrapAlignment.end,
                children: [
                  _DetailButton(
                    label: _loading ? '刷新中' : '刷新',
                    onTap: _loading || _resuming ? null : _loadDetail,
                  ),
                  _DetailButton(
                    label: _resumeButtonLabel(
                      task,
                      _resuming,
                      _resumeSucceeded,
                    ),
                    onTap: task?.canResume == true && !_loading && !_resuming
                        ? () => unawaited(_resumeTask())
                        : null,
                  ),
                  _DetailButton(
                    label: '任务目录',
                    onTap:
                        task != null &&
                            task.taskDir.trim().isNotEmpty &&
                            !_loading &&
                            !_resuming
                        ? () => unawaited(_openTaskDirectory())
                        : null,
                  ),
                  _DetailButton(
                    label: '结果目录',
                    onTap:
                        task != null &&
                            _outputDirectoryFor(task) != null &&
                            !_loading &&
                            !_resuming
                        ? () => unawaited(_openOutputDirectory())
                        : null,
                  ),
                  _DetailButton(
                    label: '审看结果',
                    onTap: task?.isDone == true && !_resuming
                        ? _openResult
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        if (_error != null)
          Text(_error!, style: T.tBody.copyWith(color: T.danger))
        else if (_message != null)
          Text(_message!, style: T.tCaption)
        else
          const Text('任务事件会按时间顺序显示。', style: T.tCaption),
        const SizedBox(height: T.s16),
        if (task != null) _TaskSummaryPanel(task: task),
        if (task != null) const SizedBox(height: T.s16),
        Expanded(
          child: _loading && events.isEmpty
              ? const Center(child: Text('读取事件中…', style: T.tBody))
              : events.isEmpty
              ? const Center(child: Text('还没有事件记录。', style: T.tBody))
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: events.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) =>
                      _EventRow(event: _eventMap(events[index])),
                ),
        ),
      ],
    );
  }
}

String _resumeButtonLabel(TaskSummary? task, bool resuming, bool resumed) {
  if (resuming) return '继续中';
  if (resumed && task?.canResume != true) return '已继续';
  return '继续任务';
}

String _taskHeaderStatusLabel(TaskSummary task) {
  final status = task.status.trim();
  final statusLabel = taskStatusLabel(status);
  if (statusLabel.isNotEmpty && statusLabel != status) return statusLabel;
  return taskStageLabel(task.displayStatus);
}

class _TaskSummaryPanel extends StatelessWidget {
  const _TaskSummaryPanel({required this.task});

  final TaskSummary task;

  @override
  Widget build(BuildContext context) {
    final outputs = task.outputPaths.entries
        .map(
          (entry) =>
              '${subtitleFormatLabel(entry.key)}: ${_basename(entry.value)}',
        )
        .join(' · ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusPill(status: task.status),
              _InfoPill(label: '源语', value: languageLabel(task.sourceLang)),
              _InfoPill(label: '目标', value: languageLabel(task.targetLang)),
              _InfoPill(label: '字幕', value: task.bilingual ? '双语' : '单语'),
            ],
          ),
          const SizedBox(height: T.s12),
          _DetailLine(
            label: '编号',
            value: shortTaskIdLabel(task.taskId),
            tooltip: '任务编号：${shortTaskIdLabel(task.taskId)}',
          ),
          if (outputs.isNotEmpty) _DetailLine(label: '输出', value: outputs),
          if ((task.error ?? '').isNotEmpty)
            _DetailLine(
              label: '错误',
              value: taskErrorLabel(task.error, task.errorInfo),
              danger: true,
            ),
          if (task.errorInfo.isNotEmpty)
            _DetailLine(
              label: '建议',
              value: _errorHint(task.errorInfo),
              danger: true,
            ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final Map<String, Object?> event;

  @override
  Widget build(BuildContext context) {
    final type = _eventText(event, 'type', fallback: 'event');
    final stage = _eventText(event, 'stage');
    final status = _eventText(event, 'status');
    final message = _eventText(event, 'message');
    final createdAt = taskTimestampLabel(_eventText(event, 'created_at'));
    final progress = event['progress'];
    final progressLabel = taskProgressLabel(progress);
    final details = _eventDetails(event);
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
          width: 96,
          child: _StatusPill(status: type, label: label),
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
                  if (progressLabel.isNotEmpty) '进度 $progressLabel',
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
              if (details.isNotEmpty) ...[
                const SizedBox(height: T.s4),
                Text(
                  details,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, this.label});

  final String status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.toLowerCase()) {
      'done' => T.ok,
      'failed' || 'error' => T.danger,
      'init' ||
      'queued' ||
      'precheck' ||
      'ingest' ||
      'asr' ||
      'segment' ||
      'translate' ||
      'align' ||
      'quality' ||
      'export' ||
      'running' ||
      'cancel_requested' ||
      'stage' ||
      'progress' => T.sky,
      _ => T.muted,
    };
    return Container(
      constraints: const BoxConstraints(minWidth: 76),
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color.withValues(alpha: 0.8)),
      ),
      child: Text(
        label ?? taskStatusLabel(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: T.tCaption.copyWith(color: T.ink, fontWeight: T.wMedium),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Text(
        '$label ${value.isEmpty ? '未知' : value}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption,
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    this.tooltip,
    this.danger = false,
  });

  final String label;
  final String value;
  final String? tooltip;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: T.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 44, child: Text(label, style: T.tCaption)),
          Expanded(
            child: Tooltip(
              message: tooltip?.trim().isNotEmpty == true ? tooltip! : value,
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tCaption.copyWith(color: danger ? T.danger : T.ink),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailButton extends StatefulWidget {
  const _DetailButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_DetailButton> createState() => _DetailButtonState();
}

class _DetailButtonState extends State<_DetailButton> {
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

String _friendlyDetailError(Object error) {
  if (error is RpcRemoteException) {
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
    return '读取任务详情失败：${error.code}';
  }
  return '读取任务详情失败：$error';
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

String _eventDetails(Map<String, Object?> event) {
  final details = event['details'];
  if (details is Map && details.isNotEmpty) {
    return details.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(' · ');
  }
  return '';
}

String _errorHint(Map<String, Object?> errorInfo) {
  final hint = errorInfo['hint_zh'] ?? errorInfo['hint'];
  if (hint != null && '$hint'.trim().isNotEmpty) return '$hint';
  final code = errorInfo['code'];
  return code == null ? '任务失败，请查看事件。' : '$code';
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
