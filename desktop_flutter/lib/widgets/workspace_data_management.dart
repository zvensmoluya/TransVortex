import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/workspace_data_manager.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';

typedef WorkspaceDirectoryPicker = Future<String?> Function(String title);

class WorkspaceDataManagement extends StatefulWidget {
  const WorkspaceDataManagement({
    super.key,
    required this.client,
    required this.service,
    this.operations,
    this.pathOpener,
    this.directoryPicker,
    this.onBusyChanged,
    this.onWorkspaceChanged,
  });

  final AppServiceClient client;
  final LocalServiceController service;
  final WorkspaceDataOperations? operations;
  final PathOpener? pathOpener;
  final WorkspaceDirectoryPicker? directoryPicker;
  final ValueChanged<bool>? onBusyChanged;
  final Future<void> Function()? onWorkspaceChanged;

  @override
  State<WorkspaceDataManagement> createState() =>
      _WorkspaceDataManagementState();
}

class _WorkspaceDataManagementState extends State<WorkspaceDataManagement> {
  late final WorkspaceDataOperations _operations =
      widget.operations ?? WorkspaceDataManager();
  WorkspaceDataStatus? _status;
  bool _loading = false;
  bool _busy = false;
  int _copiedBytes = 0;
  int _totalBytes = 0;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final status = await _operations.inspect();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openWorkspace() async {
    final root = _status?.root.trim() ?? '';
    if (root.isEmpty) return;
    try {
      await (widget.pathOpener ?? SystemPathOpener()).openDirectory(root);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '打开工作数据位置失败：$error');
    }
  }

  Future<void> _clearCache() async {
    final status = _status;
    if (status == null || status.cacheBytes <= 0 || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理临时缓存？'),
        content: Text(
          '将删除 ${_formatBytes(status.cacheBytes)} 临时音频和处理中间缓存。'
          '任务记录与已经导出的文件不会删除；失败或中断任务可能无法从原进度继续。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理缓存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runBusy(() async {
      await _ensureWorkspaceIdle();
      await widget.service.shutdown();
      try {
        await _operations.clearCache();
      } finally {
        await widget.service.start();
      }
      _requireServiceReady();
      try {
        await _refreshAfterChange();
      } on Object {
        if (mounted) {
          setState(() => _status = null);
        }
      }
      if (mounted) setState(() => _message = '临时缓存已清理。');
    });
  }

  Future<void> _changeWorkspace() async {
    if (_busy) return;
    final selected = await (widget.directoryPicker ?? _pickDirectory)(
      '选择新的工作数据文件夹',
    );
    if (selected == null || selected.trim().isEmpty || !mounted) return;
    final sourceRoot =
        _status?.root ?? _operations.currentPaths().workspaceRoot.path;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移工作数据？'),
        content: Text(
          '应用会先确认没有正在处理的任务，将任务和缓存复制到新位置，'
          '校验后切换配置并重启本地服务，再清理旧位置。\n\n'
          '当前位置：$sourceRoot\n新位置：${selected.trim()}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始迁移'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runBusy(() => _migrateWorkspace(selected.trim()));
  }

  Future<void> _migrateWorkspace(String targetRoot) async {
    await _ensureWorkspaceIdle();
    WorkspaceMigrationReceipt? receipt;
    var configurationChanged = false;
    var migrationCommitted = false;
    try {
      receipt = await _operations.copyTo(
        targetRoot,
        onProgress: (copied, total) {
          if (!mounted) return;
          setState(() {
            _copiedBytes = copied;
            _totalBytes = total;
          });
        },
      );
      await widget.client.setWorkspaceStorage(targetRoot);
      configurationChanged = true;
      await widget.service.restart();
      _requireServiceReady();
      final configuredRoot = _operations.currentPaths().workspaceRoot.path;
      if (!_samePath(configuredRoot, targetRoot)) {
        throw WorkspaceDataException(
          'restart_verification_failed',
          '本地服务没有切换到新的工作数据位置。',
        );
      }
      migrationCommitted = true;
      var oldDataRemoved = true;
      try {
        await _operations.removeMigratedSource(receipt);
      } on Object {
        oldDataRemoved = false;
      }
      try {
        await _refreshAfterChange();
      } on Object {
        if (mounted) setState(() => _status = null);
      }
      if (mounted) {
        setState(
          () => _message = oldDataRemoved
              ? '工作数据已迁移到：$configuredRoot'
              : '工作数据已迁移；旧位置未能完全清理，可确认新任务正常后手动删除。',
        );
      }
    } on Object {
      if (migrationCommitted) rethrow;
      if (receipt != null) {
        // The service may have persisted the new path even if its RPC reply
        // was interrupted. Inspect the authoritative config before deciding
        // whether rollback is necessary.
        configurationChanged =
            configurationChanged ||
            _samePath(
              _operations.currentPaths().workspaceRoot.path,
              receipt.targetRoot.path,
            );
        if (configurationChanged) {
          await _operations.restoreConfiguration(receipt);
          await widget.service.restart();
          final rollbackClient = widget.service.client;
          if (rollbackClient != null) {
            try {
              await rollbackClient.setWorkspaceStorage(receipt.sourceRoot.path);
            } on Object {
              // The restored file remains authoritative for the running app.
            }
          }
        }
        await _operations.discardCopiedTarget(receipt);
      }
      rethrow;
    }
  }

  Future<void> _refreshAfterChange() async {
    await widget.service.refresh();
    await widget.onWorkspaceChanged?.call();
    final status = await _operations.inspect();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _ensureWorkspaceIdle() async {
    await widget.service.refresh();
    final snapshot = widget.service.snapshot.desktopSnapshot;
    final active = snapshot?.runtime['active'];
    final queued = snapshot?.runtime['queued'];
    final hasActive = active is Map && active.isNotEmpty;
    final hasQueued = queued is List && queued.isNotEmpty;
    if (hasActive || hasQueued) {
      throw WorkspaceDataException(
        'workspace_busy',
        '还有正在运行或等待处理的任务，完成或取消后才能管理工作数据。',
      );
    }
  }

  void _requireServiceReady() {
    final state = widget.service.snapshot.status;
    if (state != LocalServiceConnectionStatus.ready &&
        state != LocalServiceConnectionStatus.degraded) {
      throw WorkspaceDataException(
        'service_restart_failed',
        '本地服务重启失败，工作数据位置没有完成切换。',
      );
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _copiedBytes = 0;
      _totalBytes = 0;
      _message = null;
      _error = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final totalLabel = status == null
        ? '正在计算占用空间'
        : '${status.taskCount} 个任务 · 任务 ${_formatBytes(status.tasksBytes)} · 缓存 ${_formatBytes(status.cacheBytes)}';
    final progress = _busy && _totalBytes > 0
        ? (_copiedBytes / _totalBytes).clamp(0.0, 1.0)
        : null;
    return Container(
      key: const ValueKey('workspace-data-management'),
      padding: const EdgeInsets.all(T.s12),
      decoration: BoxDecoration(
        color: T.skySoft.withValues(alpha: 0.46),
        border: Border.all(color: T.line),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_copy_outlined, size: 19, color: T.muted),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('工作数据', style: T.tBody.copyWith(fontWeight: T.wBold)),
                    Tooltip(
                      message: status?.root ?? '',
                      child: Text(
                        status?.root ?? '位置读取中',
                        key: const ValueKey('workspace-data-root'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tCaption,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s8),
          Text(totalLabel, style: T.tCaption),
          if (_busy) ...[
            const SizedBox(height: T.s8),
            LinearProgressIndicator(value: progress, minHeight: 4),
            const SizedBox(height: T.s4),
            Text(
              _totalBytes > 0
                  ? '正在迁移 ${_formatBytes(_copiedBytes)} / ${_formatBytes(_totalBytes)}'
                  : '正在安全切换工作数据位置…',
              style: T.tCaption,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: T.s8),
            Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
          ] else if (_message != null) ...[
            const SizedBox(height: T.s8),
            Text(_message!, style: T.tCaption.copyWith(color: T.ok)),
          ],
          const SizedBox(height: T.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ActionButton(
                label: '打开',
                onTap: _busy || status == null ? null : _openWorkspace,
              ),
              const SizedBox(width: T.s8),
              ActionButton(
                key: const ValueKey('workspace-clear-cache'),
                label: '清理缓存',
                onTap: _busy || (status?.cacheBytes ?? 0) <= 0
                    ? null
                    : _clearCache,
              ),
              const SizedBox(width: T.s8),
              ActionButton(
                key: const ValueKey('workspace-change-location'),
                label: '更改位置',
                strong: true,
                onTap: _busy || status == null ? null : _changeWorkspace,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<String?> _pickDirectory(String title) {
  return FilePicker.platform.getDirectoryPath(dialogTitle: title);
}

String _friendlyError(Object error) {
  if (error is WorkspaceDataException) return error.message;
  if (error is RpcRemoteException) {
    return switch (error.code) {
      'workspace_busy' => '还有正在运行或等待处理的任务，完成或取消后再试。',
      'workspace_target_not_empty' => '所选文件夹包含其他文件，请新建一个专用文件夹。',
      'workspace_storage_invalid' => '新的工作数据位置不可用，请检查磁盘连接和写入权限。',
      _ => error.message.isEmpty ? '工作数据操作失败。' : error.message,
    };
  }
  return '工作数据操作失败：$error';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb >= 10 ? 1 : 2)} GB';
}

bool _samePath(String first, String second) {
  String normalize(String value) {
    var result = Directory(value).absolute.path.replaceAll(r'\', '/');
    while (result.endsWith('/') && result.length > 3) {
      result = result.substring(0, result.length - 1);
    }
    return Platform.isWindows ? result.toLowerCase() : result;
  }

  return normalize(first) == normalize(second);
}
