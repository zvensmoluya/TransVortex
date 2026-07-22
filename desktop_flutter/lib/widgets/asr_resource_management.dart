import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../services/path_opener.dart';
import '../services/settings_error.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';

/// Direct management for ASR resources downloaded and owned by TransVortex.
///
/// This surface is intentionally reusable: application settings and the ASR
/// workflow can both expose it without routing users through one another.
class AsrResourceManagement extends StatefulWidget {
  const AsrResourceManagement({
    super.key,
    required this.client,
    required this.bridge,
    this.pathOpener,
    this.onResourcesChanged,
  });

  final AppServiceClient client;
  final WindowStateBridge bridge;
  final PathOpener? pathOpener;
  final Future<void> Function()? onResourcesChanged;

  @override
  State<AsrResourceManagement> createState() => _AsrResourceManagementState();
}

class _AsrResourceManagementState extends State<AsrResourceManagement> {
  DesktopSnapshot? _snapshot;
  bool _loading = false;
  String? _removingKey;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool clearFeedback = true}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (clearFeedback) {
        _message = null;
        _error = null;
      }
    });
    try {
      final snapshot = await widget.client.desktopSnapshot();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
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
          label: '本机 Whisper 运行组件',
          detail: runtime.version.isEmpty
              ? 'TransVortex 管理的隔离运行环境'
              : '版本 ${runtime.version} · 隔离运行环境',
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
          detail: model.revision.isEmpty
              ? '由 TransVortex 下载的模型'
              : '固定版本 ${_shortRevision(model.revision)}',
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
          detail: accelerator.version.isEmpty
              ? '本机识别加速依赖'
              : '版本 ${accelerator.version} · 本机识别加速依赖',
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
      _removingKey = key;
      _message = null;
      _error = null;
    });
    try {
      await widget.client.asrComponentRemove(
        resource.kind,
        itemId: resource.component.id,
      );
      await _load(clearFeedback: false);
      await widget.bridge.refreshServiceSnapshot();
      await widget.onResourcesChanged?.call();
      if (!mounted) return;
      setState(() => _message = '${resource.label}已删除。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _removingKey = null);
    }
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

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final resources = snapshot == null
        ? const <_ManagedAsrResource>[]
        : _resources(snapshot);
    final storage = snapshot?.asrStorage ?? const AsrStorageOption();
    final busy = _loading || _removingKey != null;
    return Column(
      key: const ValueKey('asr-resource-manager'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本机识别资源', style: T.tSection),
                  const SizedBox(height: 2),
                  Text(
                    '只管理由 TransVortex 下载的文件，不会删除用户自己的模型。',
                    style: T.tCaption,
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('asr-resource-refresh'),
              tooltip: '刷新资源状态',
              onPressed: busy ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 19),
              color: T.muted,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        _StorageSummary(
          storage: storage,
          onOpen: storage.root.trim().isEmpty ? null : _openStorage,
        ),
        if (_hasActiveOperation) ...[
          const SizedBox(height: T.s8),
          Text(
            '识别资源正在下载或变更，完成或取消后才能删除。',
            style: T.tCaption.copyWith(color: T.warn),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: T.s8),
          Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
        ] else if (_message != null) ...[
          const SizedBox(height: T.s8),
          Text(_message!, style: T.tCaption.copyWith(color: T.ok)),
        ],
        const SizedBox(height: T.s12),
        Expanded(
          child: _loading && snapshot == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : resources.isEmpty
              ? _EmptyManagedResources(onRefresh: busy ? null : _load)
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: resources.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: T.line),
                  itemBuilder: (context, index) {
                    final resource = resources[index];
                    return _ResourceRow(
                      resource: resource,
                      removing: _removingKey == resource.key,
                      removeEnabled: !busy && !_hasActiveOperation,
                      onRemove: () => _requestRemove(resource),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _StorageSummary extends StatelessWidget {
  const _StorageSummary({required this.storage, required this.onOpen});

  final AsrStorageOption storage;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final root = storage.root.trim();
    final space = storage.spaceKnown
        ? '可用 ${formatResourceBytes(storage.freeBytes)}'
        : '剩余空间待检查';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s12),
      decoration: BoxDecoration(
        color: T.lilacSoft.withValues(alpha: 0.58),
        border: Border.all(color: T.line),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded, size: 19, color: T.muted),
          const SizedBox(width: T.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('识别资源位置', style: T.tCaption),
                Tooltip(
                  message: root,
                  child: Text(
                    root.isEmpty ? '位置尚未就绪' : root,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.tBody,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: T.s8),
          Text(space, style: T.tCaption),
          if (onOpen != null) ...[
            const SizedBox(width: T.s8),
            ActionButton(label: '打开', onTap: onOpen),
          ],
        ],
      ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.resource,
    required this.removing,
    required this.removeEnabled,
    required this.onRemove,
  });

  final _ManagedAsrResource resource;
  final bool removing;
  final bool removeEnabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final sizeLabel = resource.component.size > 0
        ? ' · 约 ${formatResourceBytes(resource.component.size)}'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: T.s12),
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
                        '当前使用',
                        style: T.tCaption.copyWith(color: T.accentStrong),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${resource.detail}$sizeLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
              ],
            ),
          ),
          const SizedBox(width: T.s12),
          FeedbackActionButton(
            key: ValueKey('asr-resource-remove-${resource.key}'),
            label: removing ? '删除中' : '删除',
            danger: true,
            busy: removing,
            onTap: removeEnabled && !removing ? onRemove : null,
          ),
        ],
      ),
    );
  }
}

class _EmptyManagedResources extends StatelessWidget {
  const _EmptyManagedResources({required this.onRefresh});

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inventory_2_outlined, size: 28, color: T.muted),
          const SizedBox(height: T.s8),
          Text('没有由 TransVortex 下载的识别资源', style: T.tBody),
          const SizedBox(height: T.s4),
          Text('用户自己选择的模型不会出现在这里。', style: T.tCaption),
          const SizedBox(height: T.s12),
          ActionButton(label: '刷新', onTap: onRefresh),
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
    required this.detail,
    required this.active,
  });

  final String kind;
  final AsrComponentOption component;
  final String label;
  final String detail;
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

String _shortRevision(String revision) {
  final value = revision.trim();
  return value.length <= 12 ? value : value.substring(0, 12);
}

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
