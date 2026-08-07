import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../theme/tokens.dart';

class MemoryLibraryDialog extends StatefulWidget {
  const MemoryLibraryDialog({
    super.key,
    required this.client,
    this.selectedCollectionIds = const [],
  });

  final AppServiceClient client;
  final List<String> selectedCollectionIds;

  @override
  State<MemoryLibraryDialog> createState() => _MemoryLibraryDialogState();
}

class _MemoryLibraryDialogState extends State<MemoryLibraryDialog> {
  late final Set<String> _selected = widget.selectedCollectionIds.toSet();
  List<MemoryCollectionSummary> _collections = const [];
  MemoryCollectionDetail? _detail;
  String? _activeId;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload({String? preferredId}) async {
    if (mounted) setState(() => _loading = true);
    try {
      final collections = await widget.client.memoryCollections();
      if (!mounted) return;
      final availableIds = collections.map((item) => item.id).toSet();
      _selected.removeWhere((id) => !availableIds.contains(id));
      final requested = preferredId ?? _activeId;
      final active = availableIds.contains(requested)
          ? requested
          : collections.isEmpty
          ? null
          : collections.first.id;
      MemoryCollectionDetail? detail;
      if (active != null) {
        detail = await widget.client.memoryCollection(active);
      }
      if (!mounted) return;
      setState(() {
        _collections = collections;
        _activeId = active;
        _detail = detail;
        _error = null;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取术语库失败：$error';
        _loading = false;
      });
    }
  }

  Future<void> _activate(String id) async {
    if (_activeId == id && _detail != null) return;
    setState(() {
      _activeId = id;
      _detail = null;
      _error = null;
    });
    try {
      final detail = await widget.client.memoryCollection(id);
      if (!mounted || _activeId != id) return;
      setState(() => _detail = detail);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '读取术语条目失败：$error');
    }
  }

  Future<void> _runMutation(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createCollection() async {
    final draft = await _showCollectionEditor();
    if (draft == null) return;
    await _runMutation(() async {
      final created = await widget.client.createMemoryCollection(
        name: draft.name,
        collectionId: draft.id,
        description: draft.description,
        languagePairs: draft.languagePairs,
        tags: draft.tags,
      );
      _selected.add(created.summary.id);
      await _reload(preferredId: created.summary.id);
    });
  }

  Future<void> _editCollection() async {
    final detail = _detail;
    if (detail == null) return;
    final draft = await _showCollectionEditor(existing: detail.summary);
    if (draft == null) return;
    await _runMutation(() async {
      await widget.client.updateMemoryCollection(
        detail.summary.id,
        expectedRevision: detail.summary.revision,
        changes: {
          'name': draft.name,
          'description': draft.description,
          'language_pairs': draft.languagePairs,
          'tags': draft.tags,
        },
      );
      await _reload(preferredId: detail.summary.id);
    });
  }

  Future<void> _deleteCollection() async {
    final detail = _detail;
    if (detail == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除术语库？'),
        content: Text(
          '“${detail.summary.name}”及其中 ${detail.entries.length} 条术语会被永久删除。已有任务快照不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runMutation(() async {
      await widget.client.deleteMemoryCollection(
        detail.summary.id,
        expectedRevision: detail.summary.revision,
      );
      _selected.remove(detail.summary.id);
      _activeId = null;
      await _reload();
    });
  }

  Future<void> _editEntry([MemoryEntryItem? existing]) async {
    final detail = _detail;
    if (detail == null) return;
    final payload = await _showEntryEditor(existing);
    if (payload == null) return;
    await _runMutation(() async {
      await widget.client.upsertMemoryEntry(
        detail.summary.id,
        expectedRevision: detail.summary.revision,
        entry: payload,
      );
      await _reload(preferredId: detail.summary.id);
    });
  }

  Future<void> _deleteEntry(MemoryEntryItem entry) async {
    final detail = _detail;
    if (detail == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除术语？'),
        content: Text('删除“${entry.source} → ${entry.target}”？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runMutation(() async {
      await widget.client.deleteMemoryEntry(
        detail.summary.id,
        entry.id,
        expectedRevision: detail.summary.revision,
      );
      await _reload(preferredId: detail.summary.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('术语库'),
      content: SizedBox(
        width: 780,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('术语库独立于作品和任务。勾选的是本任务要使用的库；任务开始时会冻结版本快照。', style: T.tCaption),
            const SizedBox(height: T.s12),
            if (_error != null) ...[
              Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
              const SizedBox(height: T.s8),
            ],
            Expanded(
              child: _loading && _collections.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 260, child: _collectionList()),
                        const VerticalDivider(width: T.s24),
                        Expanded(child: _collectionDetail()),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          icon: const Icon(Icons.check, size: 18),
          label: Text('用于本任务（${_selected.length}）'),
        ),
      ],
    );
  }

  Widget _collectionList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('持久术语库', style: T.tSection)),
            IconButton(
              tooltip: '新建术语库',
              onPressed: _busy ? null : _createCollection,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        Expanded(
          child: _collections.isEmpty
              ? Center(
                  child: Text(
                    '还没有术语库\n点击 + 新建',
                    textAlign: TextAlign.center,
                    style: T.tCaption,
                  ),
                )
              : ListView.builder(
                  itemCount: _collections.length,
                  itemBuilder: (context, index) {
                    final item = _collections[index];
                    return ListTile(
                      dense: true,
                      selected: item.id == _activeId,
                      onTap: () => _activate(item.id),
                      leading: Checkbox(
                        value: _selected.contains(item.id),
                        onChanged: _busy
                            ? null
                            : (checked) => setState(() {
                                checked == true
                                    ? _selected.add(item.id)
                                    : _selected.remove(item.id);
                              }),
                      ),
                      title: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item.entryCount} 条 · r${item.revision}',
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _collectionDetail() {
    final detail = _detail;
    if (detail == null) {
      return const Center(child: Text('选择一个术语库查看和维护条目', style: T.tCaption));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(detail.summary.name, style: T.tSection),
                  if (detail.summary.description.isNotEmpty)
                    Text(
                      detail.summary.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: '编辑术语库',
              onPressed: _busy ? null : _editCollection,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除术语库',
              onPressed: _busy ? null : _deleteCollection,
              icon: const Icon(Icons.delete_outline),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : () => _editEntry(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加术语'),
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        if (detail.summary.languagePairs.isNotEmpty ||
            detail.summary.tags.isNotEmpty)
          Text(
            [
              ...detail.summary.languagePairs,
              ...detail.summary.tags.map((tag) => '#$tag'),
            ].join(' · '),
            style: T.tCaption,
          ),
        const Divider(height: T.s24),
        Expanded(
          child: detail.entries.isEmpty
              ? const Center(child: Text('这个术语库还是空的', style: T.tCaption))
              : ListView.separated(
                  itemCount: detail.entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = detail.entries[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${entry.source}  →  ${entry.target.isEmpty ? '（仅提示）' : entry.target}',
                      ),
                      subtitle: Text(
                        '${_statusLabel(entry.status)} · ${entry.category}${entry.notes.isEmpty ? '' : ' · ${entry.notes}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: _busy ? null : () => _editEntry(entry),
                      trailing: IconButton(
                        tooltip: '删除条目',
                        onPressed: _busy ? null : () => _deleteEntry(entry),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<_CollectionDraft?> _showCollectionEditor({
    MemoryCollectionSummary? existing,
  }) async {
    final id = TextEditingController(text: existing?.id ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final description = TextEditingController(
      text: existing?.description ?? '',
    );
    final pairs = TextEditingController(
      text: existing?.languagePairs.join(', ') ?? '',
    );
    final tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
    try {
      return await showDialog<_CollectionDraft>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(existing == null ? '新建术语库' : '编辑术语库'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '名称 *'),
                ),
                if (existing == null)
                  TextField(
                    controller: id,
                    decoration: const InputDecoration(labelText: 'ID（可留空自动生成）'),
                  ),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(labelText: '说明'),
                ),
                TextField(
                  controller: pairs,
                  decoration: const InputDecoration(
                    labelText: '语言对（逗号分隔，如 ja->zh-CN）',
                  ),
                ),
                TextField(
                  controller: tags,
                  decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                Navigator.pop(
                  context,
                  _CollectionDraft(
                    id: id.text.trim(),
                    name: name.text.trim(),
                    description: description.text.trim(),
                    languagePairs: _splitValues(pairs.text),
                    tags: _splitValues(tags.text),
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      id.dispose();
      name.dispose();
      description.dispose();
      pairs.dispose();
      tags.dispose();
    }
  }

  Future<Map<String, Object?>?> _showEntryEditor(
    MemoryEntryItem? existing,
  ) async {
    final source = TextEditingController(text: existing?.source ?? '');
    final target = TextEditingController(text: existing?.target ?? '');
    final aliases = TextEditingController(
      text: existing?.aliases.join(', ') ?? '',
    );
    final category = TextEditingController(text: existing?.category ?? 'term');
    final notes = TextEditingController(text: existing?.notes ?? '');
    final priority = TextEditingController(text: '${existing?.priority ?? 50}');
    var status = existing?.status ?? 'confirmed';
    var constraint = existing?.constraint ?? '';
    try {
      return await showDialog<Map<String, Object?>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(existing == null ? '添加术语' : '编辑术语'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: source,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: '原文 *'),
                    ),
                    TextField(
                      controller: target,
                      decoration: const InputDecoration(
                        labelText: '译文（可留空作为提示）',
                      ),
                    ),
                    TextField(
                      controller: aliases,
                      decoration: const InputDecoration(labelText: '别名（逗号分隔）'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: category,
                            decoration: const InputDecoration(labelText: '分类'),
                          ),
                        ),
                        const SizedBox(width: T.s12),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: status,
                            decoration: const InputDecoration(labelText: '状态'),
                            items: const [
                              DropdownMenuItem(
                                value: 'proposed',
                                child: Text('候选'),
                              ),
                              DropdownMenuItem(
                                value: 'confirmed',
                                child: Text('已确认'),
                              ),
                              DropdownMenuItem(
                                value: 'locked',
                                child: Text('锁定'),
                              ),
                              DropdownMenuItem(
                                value: 'rejected',
                                child: Text('拒绝'),
                              ),
                              DropdownMenuItem(
                                value: 'deprecated',
                                child: Text('停用'),
                              ),
                            ],
                            onChanged: (value) =>
                                setDialogState(() => status = value ?? status),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: constraint,
                            decoration: const InputDecoration(labelText: '约束'),
                            items: const [
                              DropdownMenuItem(value: '', child: Text('自动')),
                              DropdownMenuItem(
                                value: 'must_use',
                                child: Text('必须使用'),
                              ),
                              DropdownMenuItem(
                                value: 'preferred',
                                child: Text('优先使用'),
                              ),
                              DropdownMenuItem(
                                value: 'hint',
                                child: Text('仅提示'),
                              ),
                            ],
                            onChanged: (value) =>
                                setDialogState(() => constraint = value ?? ''),
                          ),
                        ),
                        const SizedBox(width: T.s12),
                        Expanded(
                          child: TextField(
                            controller: priority,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: '优先级'),
                          ),
                        ),
                      ],
                    ),
                    TextField(
                      controller: notes,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: '说明 / 上下文'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  if (source.text.trim().isEmpty) return;
                  Navigator.pop(context, <String, Object?>{
                    if (existing != null) 'id': existing.id,
                    'source': source.text.trim(),
                    'target': target.text.trim(),
                    'aliases': _splitValues(aliases.text),
                    'category': category.text.trim().isEmpty
                        ? 'term'
                        : category.text.trim(),
                    'status': status,
                    'constraint': constraint,
                    'priority': int.tryParse(priority.text.trim()) ?? 50,
                    'notes': notes.text.trim(),
                    if (existing != null && existing.memoryType.isNotEmpty)
                      'memory_type': existing.memoryType,
                  });
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      source.dispose();
      target.dispose();
      aliases.dispose();
      category.dispose();
      notes.dispose();
      priority.dispose();
    }
  }
}

class MemoryPromotionResult {
  const MemoryPromotionResult({required this.applied, required this.conflicts});

  final int applied;
  final int conflicts;
}

class MemoryPromotionDialog extends StatefulWidget {
  const MemoryPromotionDialog({
    super.key,
    required this.client,
    required this.taskId,
    required this.candidates,
  });

  final AppServiceClient client;
  final String taskId;
  final List<MemoryEntryItem> candidates;

  @override
  State<MemoryPromotionDialog> createState() => _MemoryPromotionDialogState();
}

class _MemoryPromotionDialogState extends State<MemoryPromotionDialog> {
  List<MemoryCollectionSummary> _collections = const [];
  final Set<String> _selected = {};
  String? _collectionId;
  String _status = 'confirmed';
  String _conflictPolicy = 'skip';
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCollections());
  }

  Future<void> _loadCollections() async {
    try {
      final collections = await widget.client.memoryCollections();
      if (!mounted) return;
      setState(() {
        _collections = collections;
        _collectionId = collections.any((item) => item.id == _collectionId)
            ? _collectionId
            : collections.isEmpty
            ? null
            : collections.first.id;
        _loading = false;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取术语库失败：$error';
        });
      }
    }
  }

  Future<void> _createDestination() async {
    final controller = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('新建目标术语库'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '名称 *'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text('新建'),
            ),
          ],
        ),
      );
      if (name == null || !mounted) return;
      setState(() => _busy = true);
      final created = await widget.client.createMemoryCollection(name: name);
      await _loadCollections();
      if (mounted) {
        setState(() {
          _collectionId = created.summary.id;
          _busy = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '新建失败：$error';
        });
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _promote() async {
    final collectionId = _collectionId;
    final summary = _collections
        .where((item) => item.id == collectionId)
        .firstOrNull;
    if (summary == null || _selected.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await widget.client.promoteMemoryCandidates(
        taskId: widget.taskId,
        collectionId: summary.id,
        entryIds: _selected.toList(),
        expectedRevision: summary.revision,
        status: _status,
        conflictPolicy: _conflictPolicy,
        dryRun: true,
      );
      if (!mounted) return;
      final applied = _asObjectList(preview['applied']).length;
      final conflicts = _asObjectList(preview['conflicts']).length;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('保存这些术语？'),
          content: Text(
            '将写入 $applied 条到“${summary.name}”${conflicts > 0 ? '；检测到 $conflicts 个冲突，将按当前策略处理' : ''}。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认保存'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        setState(() => _busy = false);
        return;
      }
      final result = await widget.client.promoteMemoryCandidates(
        taskId: widget.taskId,
        collectionId: summary.id,
        entryIds: _selected.toList(),
        expectedRevision: summary.revision,
        status: _status,
        conflictPolicy: _conflictPolicy,
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        MemoryPromotionResult(
          applied: _asObjectList(result['applied']).length,
          conflicts: _asObjectList(result['conflicts']).length,
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '保存失败：$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('将任务候选保存到术语库'),
      content: SizedBox(
        width: 660,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('只有勾选的候选会持久化；未勾选内容仍只属于这个任务。', style: T.tCaption),
            const SizedBox(height: T.s12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_collectionId),
                    initialValue: _collectionId,
                    decoration: const InputDecoration(labelText: '目标术语库'),
                    items: _collections
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.id,
                            child: Text('${item.name} · ${item.entryCount} 条'),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _collectionId = value),
                  ),
                ),
                const SizedBox(width: T.s8),
                TextButton.icon(
                  onPressed: _busy ? null : _createDestination,
                  icon: const Icon(Icons.add),
                  label: const Text('新建'),
                ),
              ],
            ),
            const SizedBox(height: T.s8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    decoration: const InputDecoration(labelText: '保存状态'),
                    items: const [
                      DropdownMenuItem(value: 'confirmed', child: Text('已确认')),
                      DropdownMenuItem(value: 'locked', child: Text('锁定')),
                      DropdownMenuItem(value: 'proposed', child: Text('候选')),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _status = value ?? _status),
                  ),
                ),
                const SizedBox(width: T.s12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _conflictPolicy,
                    decoration: const InputDecoration(labelText: '遇到同源不同译'),
                    items: const [
                      DropdownMenuItem(value: 'skip', child: Text('跳过冲突')),
                      DropdownMenuItem(
                        value: 'replace',
                        child: Text('用本次候选替换'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _conflictPolicy = value ?? _conflictPolicy,
                          ),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: T.s8),
                child: Text(
                  _error!,
                  style: T.tCaption.copyWith(color: T.danger),
                ),
              ),
            const Divider(height: T.s24),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: widget.candidates.length,
                      itemBuilder: (context, index) {
                        final entry = widget.candidates[index];
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(entry.id),
                          onChanged: _busy
                              ? null
                              : (checked) => setState(() {
                                  checked == true
                                      ? _selected.add(entry.id)
                                      : _selected.remove(entry.id);
                                }),
                          title: Text(
                            '${entry.source}  →  ${entry.target.isEmpty ? '（仅提示）' : entry.target}',
                          ),
                          subtitle: Text(
                            '${_statusLabel(entry.status)}${entry.notes.isEmpty ? '' : ' · ${entry.notes}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || _collectionId == null || _selected.isEmpty
              ? null
              : _promote,
          child: Text(_busy ? '处理中…' : '保存所选（${_selected.length}）'),
        ),
      ],
    );
  }
}

class _CollectionDraft {
  const _CollectionDraft({
    required this.id,
    required this.name,
    required this.description,
    required this.languagePairs,
    required this.tags,
  });

  final String id;
  final String name;
  final String description;
  final List<String> languagePairs;
  final List<String> tags;
}

List<String> _splitValues(String value) => value
    .split(RegExp(r'[,，\n]'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList();

String _statusLabel(String status) => switch (status) {
  'locked' => '锁定',
  'confirmed' => '已确认',
  'rejected' => '拒绝',
  'deprecated' => '停用',
  _ => '候选',
};

List<Object?> _asObjectList(Object? value) => value is List ? value : const [];
