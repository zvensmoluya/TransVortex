import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/settings_error.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';

typedef AsrStorageDirectoryPicker =
    Future<String?> Function(String dialogTitle);

/// The single inventory and cleanup surface for ASR resources downloaded and
/// owned by TransVortex.
class AsrResourceManagement extends StatefulWidget {
  const AsrResourceManagement({
    super.key,
    required this.client,
    required this.bridge,
    this.service,
    this.pathOpener,
    this.directoryPicker,
    this.onResourcesChanged,
    this.snapshot,
    this.showHeader = true,
  });

  final AppServiceClient client;
  final WindowStateBridge bridge;
  final LocalServiceController? service;
  final PathOpener? pathOpener;
  final AsrStorageDirectoryPicker? directoryPicker;
  final Future<void> Function()? onResourcesChanged;
  final DesktopSnapshot? snapshot;
  final bool showHeader;

  @override
  State<AsrResourceManagement> createState() => _AsrResourceManagementState();
}

class _AsrResourceManagementState extends State<AsrResourceManagement> {
  DesktopSnapshot? _snapshot;
  bool _loading = false;
  bool _changingStorage = false;
  String? _removingKey;
  String? _message;
  String? _error;
  int _serviceRevision = 0;
  int _mutationRevision = 0;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.snapshot ?? widget.service?.snapshot.desktopSnapshot;
    widget.service?.addListener(_syncFromService);
    if (widget.snapshot == null) _load();
  }

  @override
  void didUpdateWidget(covariant AsrResourceManagement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      oldWidget.service?.removeListener(_syncFromService);
      widget.service?.addListener(_syncFromService);
      _syncFromService();
    }
    if (!identical(oldWidget.snapshot, widget.snapshot) &&
        widget.snapshot != null) {
      _serviceRevision += 1;
      _snapshot = widget.snapshot;
      if (_error != null) _error = null;
    }
  }

  @override
  void dispose() {
    widget.service?.removeListener(_syncFromService);
    super.dispose();
  }

  void _syncFromService() {
    final next = widget.service?.snapshot.desktopSnapshot;
    if (!mounted || next == null || identical(next, _snapshot)) return;
    _serviceRevision += 1;
    setState(() {
      _snapshot = next;
      if (_error != null) _error = null;
    });
  }

  Future<void> _load({bool clearFeedback = true}) async {
    if (!mounted || _loading) return;
    final serviceRevision = _serviceRevision;
    final mutationRevision = _mutationRevision;
    setState(() {
      _loading = true;
      if (clearFeedback) {
        _message = null;
        _error = null;
      }
    });
    try {
      final snapshot = await widget.client.desktopSnapshot();
      if (!mounted ||
          serviceRevision != _serviceRevision ||
          mutationRevision != _mutationRevision) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted ||
          serviceRevision != _serviceRevision ||
          mutationRevision != _mutationRevision) {
        return;
      }
      setState(() => _error = friendlySettingsError(error));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<_ManagedAsrResource> _resources(DesktopSnapshot snapshot) {
    final resources = <_ManagedAsrResource>[];
    final selectedProvider = snapshot.asrProviders
        .where((provider) => provider.name == snapshot.asrProviderName)
        .firstOrNull;
    final localWhisperActive =
        selectedProvider?.kind == 'local_worker' ||
        selectedProvider?.kind == 'local_inprocess';
    final runtime = snapshot.asrRuntime;
    if (runtime?.installed == true) {
      resources.add(
        _ManagedAsrResource(
          kind: 'runtime',
          component: runtime!,
          label: '本机 Whisper',
          active: localWhisperActive,
        ),
      );
    }
    for (final model in snapshot.asrModels.where((item) => item.installed)) {
      resources.add(
        _ManagedAsrResource(
          kind: 'model',
          component: model,
          label: _modelLabel(model),
          active: snapshot.asrModel == model.id,
        ),
      );
    }
    for (final accelerator in snapshot.asrAccelerators.where(
      (item) => item.installed,
    )) {
      resources.add(
        _ManagedAsrResource(
          kind: 'accelerator',
          component: accelerator,
          label: accelerator.displayName.isEmpty
              ? 'NVIDIA 加速组件'
              : accelerator.displayName,
          active: false,
        ),
      );
    }
    return resources;
  }

  Future<void> _requestRemove(_ManagedAsrResource resource) async {
    if (_removingKey != null || _hasActiveOperation) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        surfaceTintColor: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rMd),
          side: const BorderSide(color: T.line),
        ),
        title: Text('删除${resource.label}？', style: T.tSection),
        content: Text(_removeConsequence(resource), style: T.tBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const ValueKey('asr-resource-confirm-remove'),
            style: FilledButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _remove(resource);
  }

  Future<void> _remove(_ManagedAsrResource resource) async {
    final key = resource.key;
    setState(() {
      _mutationRevision += 1;
      _removingKey = key;
      _message = null;
      _error = null;
    });
    try {
      await widget.client.asrComponentRemove(
        resource.kind,
        itemId: resource.component.id,
      );
      await _syncAfterResourceChange('${resource.label}已删除。');
    } on Object catch (error) {
      if (error is RpcRemoteException && error.code == 'component_not_found') {
        await _syncAfterResourceChange('这个识别资源已不存在，列表已自动同步。');
      } else if (mounted) {
        setState(() => _error = friendlySettingsError(error));
      }
    } finally {
      if (mounted) setState(() => _removingKey = null);
    }
  }

  Future<void> _syncAfterResourceChange(String message) async {
    if (mounted) await _load(clearFeedback: false);
    await widget.bridge.refreshServiceSnapshot();
    await widget.onResourcesChanged?.call();
    if (!mounted) return;
    setState(() => _message = message);
  }

  bool get _hasActiveOperation =>
      _snapshot?.asrOperations.any((operation) => operation.active) ?? false;

  Future<void> _openStorage() async {
    final root = _snapshot?.asrStorage.root.trim() ?? '';
    if (root.isEmpty) return;
    try {
      await (widget.pathOpener ?? SystemPathOpener()).openDirectory(root);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '打开识别资源位置失败：$error');
    }
  }

  Future<void> _pickStorage() async {
    final storage = _snapshot?.asrStorage;
    if (storage == null || !storage.canChange || _changingStorage) return;
    final path = await (widget.directoryPicker ?? _pickDirectory)(
      '选择识别资源保存文件夹',
    );
    if (path == null || path.trim().isEmpty || !mounted) return;
    await _setStorage(path.trim());
  }

  Future<String?> _pickDirectory(String dialogTitle) {
    return FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
  }

  Future<void> _setStorage(String path) async {
    setState(() {
      _mutationRevision += 1;
      _changingStorage = true;
      _message = null;
      _error = null;
    });
    try {
      final storage = await widget.client.asrStorageSet(path);
      if (mounted) await _load(clearFeedback: false);
      await widget.bridge.refreshServiceSnapshot();
      await widget.onResourcesChanged?.call();
      if (!mounted) return;
      setState(() {
        _message = '识别组件将保存到：${storage.root}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _changingStorage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final resources = snapshot == null
        ? const <_ManagedAsrResource>[]
        : _resources(snapshot);
    final storage = snapshot?.asrStorage ?? const AsrStorageOption();
    final interactionBusy = _removingKey != null || _changingStorage;
    final resourceList = _buildResourceList(resources, interactionBusy);
    return Column(
      key: const ValueKey('asr-resource-manager'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader) ...[
          Text('识别资源', style: T.tSection),
          const SizedBox(height: T.s8),
        ],
        if (resources.isNotEmpty) ...[
          Text('保存位置', style: T.tSection),
          const SizedBox(height: T.s8),
          _StorageSummary(
            storage: storage,
            changing: _changingStorage,
            onChange: interactionBusy || !storage.canChange
                ? null
                : _pickStorage,
            onOpen: storage.root.trim().isEmpty ? null : _openStorage,
          ),
          if (!storage.canChange && storage.changeBlocker.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(
              _storageChangeBlocker(storage.changeBlocker),
              style: T.tCaption.copyWith(color: T.warn),
            ),
          ],
        ],
        if (_hasActiveOperation) ...[
          const SizedBox(height: T.s8),
          Text(
            '识别资源正在下载或变更，完成或取消后才能删除。',
            style: T.tCaption.copyWith(color: T.warn),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: T.s8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
              if (!_loading && !interactionBusy)
                ActionButton(
                  label: '重试同步',
                  onTap: () => _load(clearFeedback: false),
                ),
            ],
          ),
        ] else if (_message != null) ...[
          const SizedBox(height: T.s8),
          Text(_message!, style: T.tCaption.copyWith(color: T.ok)),
        ],
        if (resources.isNotEmpty) ...[
          const SizedBox(height: T.s16),
          Row(
            children: [
              Expanded(child: Text('已下载的识别组件', style: T.tSection)),
              Text('${resources.length} 项', style: T.tCaption),
            ],
          ),
          const SizedBox(height: T.s8),
        ],
        Expanded(child: resourceList),
      ],
    );
  }

  Widget _buildResourceList(
    List<_ManagedAsrResource> resources,
    bool interactionBusy,
  ) {
    if (_loading && _snapshot == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (resources.isEmpty) return const _EmptyManagedResources();
    return ListView.separated(
      padding: EdgeInsets.zero,
      physics: const ClampingScrollPhysics(),
      itemCount: resources.length,
      separatorBuilder: (_, _) => const SizedBox(height: T.s8),
      itemBuilder: (context, index) {
        final resource = resources[index];
        return _ResourceRow(
          resource: resource,
          enabled: !interactionBusy && !_hasActiveOperation,
          removing: _removingKey == resource.key,
          onRemove: () => _requestRemove(resource),
        );
      },
    );
  }
}

class _StorageSummary extends StatelessWidget {
  const _StorageSummary({
    required this.storage,
    required this.changing,
    required this.onChange,
    required this.onOpen,
  });

  final AsrStorageOption storage;
  final bool changing;
  final VoidCallback? onChange;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final root = storage.root.trim();
    final space = storage.spaceKnown
        ? '可用 ${formatResourceBytes(storage.freeBytes)}'
        : '剩余空间待检查';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.lilacSoft.withValues(alpha: 0.58),
        border: Border.all(color: T.line),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storage_rounded, size: 19, color: T.muted),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: root,
                      child: Text(
                        root.isEmpty ? '位置尚未就绪' : root,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tBody.copyWith(fontWeight: T.wMedium),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s4),
          Row(
            children: [
              Expanded(child: Text(space, style: T.tCaption)),
              ActionButton(
                key: const ValueKey('asr-resource-change-storage'),
                label: changing ? '处理中' : '更改',
                onTap: changing ? null : onChange,
              ),
              if (onOpen != null) ...[
                const SizedBox(width: T.s8),
                ActionButton(label: '打开', onTap: onOpen),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.resource,
    required this.enabled,
    required this.removing,
    required this.onRemove,
  });

  final _ManagedAsrResource resource;
  final bool enabled;
  final bool removing;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: resource.active
            ? T.accentSoft.withValues(alpha: 0.28)
            : T.surface,
        border: Border.all(
          color: resource.active ? T.accent.withValues(alpha: 0.55) : T.line,
        ),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: T.skySoft,
              border: Border.all(color: T.sky.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(T.rSm),
            ),
            child: Icon(resource.icon, size: 18, color: T.sky),
          ),
          const SizedBox(width: T.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(resource.label, style: T.tBody)),
                    if (resource.active) ...[
                      const SizedBox(width: T.s8),
                      Text(
                        '使用中',
                        style: T.tCaption.copyWith(color: T.accentStrong),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${_resourceTypeLabel(resource.kind)} · ${formatResourceBytes(resource.component.size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
              ],
            ),
          ),
          const SizedBox(width: T.s8),
          ActionButton(
            key: ValueKey('asr-resource-remove-${resource.key}'),
            label: removing ? '删除中' : '删除',
            onTap: enabled ? onRemove : null,
          ),
        ],
      ),
    );
  }
}

class _EmptyManagedResources extends StatelessWidget {
  const _EmptyManagedResources();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.surface,
        border: Border.all(color: T.line),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Row(
        children: [
          const Icon(Icons.inventory_2_outlined, size: 20, color: T.muted),
          const SizedBox(width: T.s8),
          Expanded(child: Text('暂无已下载的识别组件', style: T.tBody)),
        ],
      ),
    );
  }
}

class _ManagedAsrResource {
  const _ManagedAsrResource({
    required this.kind,
    required this.component,
    required this.label,
    required this.active,
  });

  final String kind;
  final AsrComponentOption component;
  final String label;
  final bool active;

  String get key => '$kind-${component.id}';

  IconData get icon => switch (kind) {
    'runtime' => Icons.memory_rounded,
    'model' => Icons.graphic_eq_rounded,
    'accelerator' => Icons.speed_rounded,
    _ => Icons.inventory_2_outlined,
  };
}

String _modelLabel(AsrComponentOption model) {
  if (model.displayName.trim().isNotEmpty) return model.displayName.trim();
  return switch (model.id) {
    'small' => 'Whisper Small',
    'medium' => 'Whisper Medium',
    'large-v3' => 'Whisper Large v3',
    _ => model.id,
  };
}

String _resourceTypeLabel(String kind) => switch (kind) {
  'runtime' => '运行组件',
  'model' => '识别模型',
  'accelerator' => '加速组件',
  _ => '识别资源',
};

String _storageChangeBlocker(String blocker) => switch (blocker) {
  'active_operation' => '完成当前下载后可更改保存位置。',
  'managed_resources_present' => '删除下方已下载资源后可更改保存位置。',
  'partial_downloads_present' => '清理未完成的下载后可更改保存位置。',
  'storage_config_invalid' => '当前保存位置无效，请先检查磁盘。',
  'storage_unreadable' => '当前位置暂时无法读取，请重新连接磁盘。',
  _ => '当前暂时不能更改保存位置。',
};

String _removeConsequence(_ManagedAsrResource resource) {
  return switch (resource.kind) {
    'runtime' => '删除后，本机 Whisper 暂时无法运行；下次使用时需要重新下载运行组件。已经下载的模型会保留。',
    'model' when resource.active =>
      '这是当前使用的识别模型。删除后，本机识别会变为未就绪；再次使用时需要重新下载或改选其他模型。',
    'model' => '删除后可以释放磁盘空间；再次选择这个模型时需要重新下载。',
    'accelerator' => '删除后将不能使用这套 NVIDIA 加速组件；CPU 识别资源不会受到影响。',
    _ => '删除后如需再次使用，需要重新下载。',
  };
}

String formatResourceBytes(int bytes) {
  if (bytes <= 0) return '未知大小';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  final digits = value >= 100 || index == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}
