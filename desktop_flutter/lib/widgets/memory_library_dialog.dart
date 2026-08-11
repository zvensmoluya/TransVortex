import 'dart:async';

import 'package:flutter/material.dart';

import '../model/task_labels.dart';
import '../services/app_service_client.dart';
import '../theme/tokens.dart';
import 'language_picker.dart';

enum _CollectionScopeMode { all, specific }

final _collectionSourceLanguages = sourceLanguageOptions
    .where((value) => value != 'auto')
    .toList(growable: false);
final _collectionTargetLanguages = targetLanguageOptions.toList(
  growable: false,
);

const _entryCategoryValues = [
  'term',
  'name',
  'place',
  'organization',
  'expression',
  'asr_correction',
  'other',
];

String _entryCategoryLabel(String value) {
  return switch (value) {
    'term' => '普通术语',
    'name' => '人物 / 专名',
    'place' => '地点',
    'organization' => '组织',
    'expression' => '固定表达',
    'asr_correction' => '识别纠错',
    'other' => '其他',
    _ => value.isEmpty ? '普通术语' : value,
  };
}

String _entryConstraintLabel(String value) {
  return switch (value) {
    '' => '自动',
    'must_use' => '必须使用',
    'preferred' => '优先使用',
    'hint' => '仅提示',
    _ => value,
  };
}

bool _isUniversalLanguagePair(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(' ', '');
  return normalized == '*' || normalized == '*->*';
}

List<String> _specificLanguagePairs(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty && !_isUniversalLanguagePair(value))
    .toSet()
    .toList();

String _languagePairLabel(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || _isUniversalLanguagePair(trimmed)) return '不限语言';
  final separator = trimmed.indexOf('->');
  if (separator <= 0 || separator >= trimmed.length - 2) return trimmed;
  final source = trimmed.substring(0, separator);
  final target = trimmed.substring(separator + 2);
  return '${languageLabel(source)} → ${languageLabel(target)}';
}

String _collectionScopeLabel(Iterable<String> values) {
  if (values.any(_isUniversalLanguagePair)) return '不限语言';
  final pairs = _specificLanguagePairs(values);
  return pairs.isEmpty ? '不限语言' : pairs.map(_languagePairLabel).join('、');
}

String _languagePairComponent(String value, {required bool source}) {
  final separator = value.indexOf('->');
  if (separator <= 0 || separator >= value.length - 2) return '';
  return source
      ? value.substring(0, separator)
      : value.substring(separator + 2);
}

String _languageOptionOrFallback(Iterable<String> options, String candidate) {
  final normalized = candidate.trim().toLowerCase().replaceAll('_', '-');
  return options.firstWhere(
    (option) => option.toLowerCase().replaceAll('_', '-') == normalized,
    orElse: () => options.first,
  );
}

class MemoryLibraryDialog extends StatefulWidget {
  const MemoryLibraryDialog({
    super.key,
    required this.client,
    this.selectedCollectionIds = const [],
    this.selectionOnly = false,
    this.embedded = false,
    this.onManageLibrary,
  });

  final AppServiceClient client;
  final List<String> selectedCollectionIds;
  final bool selectionOnly;
  final bool embedded;
  final Future<void> Function()? onManageLibrary;

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
      final requested = widget.selectionOnly ? null : preferredId ?? _activeId;
      final active = availableIds.contains(requested)
          ? requested
          : collections.isEmpty
          ? null
          : collections.first.id;
      MemoryCollectionDetail? detail;
      if (active != null && !widget.selectionOnly) {
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
    if (widget.selectionOnly) return _selectionDialog();
    final content = _managementContent();
    if (widget.embedded) return content;
    return AlertDialog(
      title: const Text('术语库'),
      content: SizedBox(width: 780, height: 520, child: content),
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

  Widget _managementContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.embedded
              ? '术语库是一组可跨任务复用的术语；任务使用的是开始制作时冻结的版本快照。'
              : '术语库独立于作品和任务。勾选本任务要使用的库，开始制作时会冻结版本快照。',
          style: T.tCaption,
        ),
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
    );
  }

  Widget _selectionDialog() {
    return AlertDialog(
      title: const Text('本任务使用的术语库'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('只选择本次任务要使用的术语库；开始制作时会冻结版本快照。', style: T.tCaption),
            const SizedBox(height: T.s12),
            if (_error != null) ...[
              Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
              const SizedBox(height: T.s8),
            ],
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _collections.isEmpty
                  ? Center(
                      child: Text(
                        '还没有术语库。\n可以前往工作台创建和维护。',
                        textAlign: TextAlign.center,
                        style: T.tCaption,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _collections.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _collections[index];
                        return CheckboxListTile(
                          value: _selected.contains(item.id),
                          onChanged: _busy
                              ? null
                              : (checked) => setState(() {
                                  checked == true
                                      ? _selected.add(item.id)
                                      : _selected.remove(item.id);
                                }),
                          title: Text(item.name),
                          subtitle: Text(
                            '${item.entryCount} 条术语 · ${_collectionScopeLabel(item.languagePairs)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.onManageLibrary != null)
          TextButton.icon(
            onPressed: _busy ? null : _openManager,
            icon: const Icon(Icons.open_in_new, size: 17),
            label: const Text('管理术语库'),
          ),
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

  void _openManager() {
    final callback = widget.onManageLibrary;
    Navigator.pop(context);
    if (callback != null) unawaited(callback());
  }

  Widget _collectionList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('术语库', style: T.tSection)),
            IconButton(
              tooltip: '新建术语库',
              onPressed: _busy ? null : _createCollection,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        Expanded(
          child: _collections.isEmpty
              ? _emptyCollectionList()
              : ListView.builder(
                  itemCount: _collections.length,
                  itemBuilder: (context, index) {
                    final item = _collections[index];
                    return ListTile(
                      dense: true,
                      selected: item.id == _activeId,
                      onTap: () => _activate(item.id),
                      leading: widget.embedded
                          ? null
                          : Checkbox(
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
                        '${item.entryCount} 条术语 · ${_collectionScopeLabel(item.languagePairs)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyCollectionList() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: T.s8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 28, color: T.muted),
            const SizedBox(height: T.s8),
            const Text('还没有术语库', style: T.tBody),
            const SizedBox(height: T.s4),
            const Text(
              '创建后可以添加多条术语，跨任务复用。',
              textAlign: TextAlign.center,
              style: T.tCaption,
            ),
            const SizedBox(height: T.s12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _createCollection,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('新建术语库'),
            ),
          ],
        ),
      ),
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
              if (detail.summary.languagePairs.isNotEmpty)
                _collectionScopeLabel(detail.summary.languagePairs),
              ...detail.summary.tags.map((tag) => '#$tag'),
            ].join(' · '),
            style: T.tCaption,
          ),
        const Divider(height: T.s24),
        Row(
          children: [
            const Expanded(child: Text('术语', style: T.tSection)),
            Text('${detail.entries.length} 条', style: T.tCaption),
          ],
        ),
        const SizedBox(height: T.s8),
        Expanded(
          child: detail.entries.isEmpty
              ? _emptyEntryList()
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
                        '${_statusLabel(entry.status)} · ${_entryCategoryLabel(entry.category)}${entry.notes.isEmpty ? '' : ' · ${entry.notes}'}',
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

  Widget _emptyEntryList() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.translate_outlined, size: 32, color: T.muted),
          const SizedBox(height: T.s8),
          const Text('这个术语库还没有术语', style: T.tBody),
          const SizedBox(height: T.s4),
          const Text(
            '添加一条原文和译文，之后就能在多个任务中复用。',
            style: T.tCaption,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: T.s12),
          FilledButton.icon(
            onPressed: _busy ? null : () => _editEntry(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加第一条术语'),
          ),
        ],
      ),
    );
  }

  Future<_CollectionDraft?> _showCollectionEditor({
    MemoryCollectionSummary? existing,
  }) async {
    var nameValue = existing?.name ?? '';
    var descriptionValue = existing?.description ?? '';
    var tagsValue = existing?.tags.join(', ') ?? '';
    final formKey = GlobalKey<FormState>();
    var selectedPairs = _specificLanguagePairs(
      existing?.languagePairs ?? const [],
    );
    var scopeMode = selectedPairs.isEmpty
        ? _CollectionScopeMode.all
        : _CollectionScopeMode.specific;
    var sourceLanguage = _collectionSourceLanguages.first;
    var targetLanguage = _collectionTargetLanguages.first;
    if (selectedPairs.isNotEmpty) {
      sourceLanguage = _languageOptionOrFallback(
        _collectionSourceLanguages,
        _languagePairComponent(selectedPairs.first, source: true),
      );
      targetLanguage = _languageOptionOrFallback(
        _collectionTargetLanguages,
        _languagePairComponent(selectedPairs.first, source: false),
      );
    }
    var showAdvanced =
        existing != null &&
        (descriptionValue.trim().isNotEmpty || tagsValue.trim().isNotEmpty);
    String? scopeError;
    return showDialog<_CollectionDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void addPair() {
            final pair = '$sourceLanguage->$targetLanguage';
            if (!selectedPairs.any(
              (value) => value.toLowerCase() == pair.toLowerCase(),
            )) {
              setDialogState(() {
                selectedPairs = [...selectedPairs, pair];
                scopeError = null;
              });
            }
          }

          return AlertDialog(
            title: Text(existing == null ? '新建术语库' : '编辑术语库'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        existing == null
                            ? '一个术语库可以包含多条跨任务复用的术语。创建后会进入术语列表。'
                            : '这里只修改术语库属性；已有任务仍使用创建时冻结的版本。',
                        style: T.tCaption,
                      ),
                      const SizedBox(height: T.s12),
                      TextFormField(
                        initialValue: nameValue,
                        autofocus: existing == null,
                        onChanged: (value) => nameValue = value,
                        decoration: const InputDecoration(
                          labelText: '术语库名称',
                          hintText: '例如：日语角色名库',
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '请填写术语库名称'
                            : null,
                      ),
                      const SizedBox(height: T.s12),
                      Text('适用范围', style: T.tSection),
                      const SizedBox(height: T.s4),
                      Text('不限语言时，这个术语库可以用于所有任务。', style: T.tCaption),
                      const SizedBox(height: T.s8),
                      DropdownButtonFormField<_CollectionScopeMode>(
                        initialValue: scopeMode,
                        decoration: const InputDecoration(labelText: '术语适用于'),
                        items: const [
                          DropdownMenuItem(
                            value: _CollectionScopeMode.all,
                            child: Text('不限语言'),
                          ),
                          DropdownMenuItem(
                            value: _CollectionScopeMode.specific,
                            child: Text('指定语言对'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() {
                            scopeMode = value;
                            scopeError = null;
                          });
                        },
                      ),
                      if (scopeMode == _CollectionScopeMode.specific) ...[
                        const SizedBox(height: T.s8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: sourceLanguage,
                                decoration: const InputDecoration(
                                  labelText: '原语言',
                                ),
                                items: [
                                  for (final option
                                      in _collectionSourceLanguages)
                                    DropdownMenuItem(
                                      value: option,
                                      child: Text(languageLabel(option)),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(
                                      () => sourceLanguage = value,
                                    );
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: T.s8),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: targetLanguage,
                                decoration: const InputDecoration(
                                  labelText: '目标语言',
                                ),
                                items: [
                                  for (final option
                                      in _collectionTargetLanguages)
                                    DropdownMenuItem(
                                      value: option,
                                      child: Text(languageLabel(option)),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(
                                      () => targetLanguage = value,
                                    );
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: addPair,
                            icon: const Icon(Icons.add, size: 17),
                            label: const Text('添加语言对'),
                          ),
                        ),
                        if (selectedPairs.isNotEmpty)
                          Wrap(
                            spacing: T.s8,
                            runSpacing: T.s4,
                            children: [
                              for (final pair in selectedPairs)
                                InputChip(
                                  label: Text(_languagePairLabel(pair)),
                                  onDeleted: () => setDialogState(
                                    () => selectedPairs = selectedPairs
                                        .where((value) => value != pair)
                                        .toList(),
                                  ),
                                ),
                            ],
                          ),
                        if (scopeError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: T.s4),
                            child: Text(
                              scopeError!,
                              style: T.tCaption.copyWith(color: T.danger),
                            ),
                          ),
                      ],
                      const SizedBox(height: T.s4),
                      TextButton.icon(
                        onPressed: () =>
                            setDialogState(() => showAdvanced = !showAdvanced),
                        icon: Icon(
                          showAdvanced
                              ? Icons.expand_less
                              : Icons.tune_outlined,
                          size: 17,
                        ),
                        label: Text(showAdvanced ? '收起更多属性' : '更多属性（可选）'),
                      ),
                      if (showAdvanced) ...[
                        TextFormField(
                          initialValue: descriptionValue,
                          onChanged: (value) => descriptionValue = value,
                          decoration: const InputDecoration(
                            labelText: '说明',
                            hintText: '例如：人物、地名和组织名的固定译法',
                          ),
                        ),
                        const SizedBox(height: T.s8),
                        TextFormField(
                          initialValue: tagsValue,
                          onChanged: (value) => tagsValue = value,
                          decoration: const InputDecoration(
                            labelText: '标签',
                            hintText: '多个标签用逗号分隔',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;
                  if (scopeMode == _CollectionScopeMode.specific &&
                      selectedPairs.isEmpty) {
                    setDialogState(() => scopeError = '请先添加一个语言对，或选择“不限语言”');
                    return;
                  }
                  Navigator.pop(
                    dialogContext,
                    _CollectionDraft(
                      id: existing?.id ?? '',
                      name: nameValue.trim(),
                      description: descriptionValue.trim(),
                      languagePairs: scopeMode == _CollectionScopeMode.all
                          ? const []
                          : selectedPairs,
                      tags: _splitValues(tagsValue),
                    ),
                  );
                },
                child: Text(existing == null ? '创建并进入术语库' : '保存更改'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<Map<String, Object?>?> _showEntryEditor(
    MemoryEntryItem? existing,
  ) async {
    var sourceValue = existing?.source ?? '';
    var targetValue = existing?.target ?? '';
    var aliasesValue = existing?.aliases.join(', ') ?? '';
    var notesValue = existing?.notes ?? '';
    var priorityValue = '${existing?.priority ?? 50}';
    final formKey = GlobalKey<FormState>();
    var category = existing?.category.trim().isNotEmpty == true
        ? existing!.category
        : 'term';
    var status = existing?.status ?? 'confirmed';
    var constraint = existing?.constraint ?? '';
    var showAdvanced =
        existing != null &&
        (aliasesValue.trim().isNotEmpty ||
            notesValue.trim().isNotEmpty ||
            priorityValue.trim() != '50' ||
            constraint.trim().isNotEmpty);
    final categoryValues = <String>[..._entryCategoryValues];
    if (!categoryValues.contains(category)) categoryValues.add(category);
    final statusValues = <String>[
      'proposed',
      'confirmed',
      'locked',
      'rejected',
      'deprecated',
    ];
    if (!statusValues.contains(status)) statusValues.add(status);
    final constraintValues = <String>['', 'must_use', 'preferred', 'hint'];
    if (constraint.isNotEmpty && !constraintValues.contains(constraint)) {
      constraintValues.add(constraint);
    }
    return showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加术语' : '编辑术语'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('只填写术语本身；别名、约束和备注可以稍后补充。', style: T.tCaption),
                    const SizedBox(height: T.s12),
                    TextFormField(
                      initialValue: sourceValue,
                      autofocus: true,
                      onChanged: (value) => sourceValue = value,
                      decoration: const InputDecoration(
                        labelText: '原文',
                        hintText: '例如：スバル',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请填写原文'
                          : null,
                    ),
                    const SizedBox(height: T.s8),
                    TextFormField(
                      initialValue: targetValue,
                      onChanged: (value) => targetValue = value,
                      decoration: const InputDecoration(
                        labelText: '译文（可选）',
                        hintText: '留空表示仅作为提示',
                      ),
                      validator: (value) {
                        if (value?.trim().isNotEmpty == true ||
                            aliasesValue.trim().isNotEmpty ||
                            notesValue.trim().isNotEmpty) {
                          return null;
                        }
                        return '请填写译文；如仅作提示，请在“更多属性”中填写别名或备注';
                      },
                    ),
                    const SizedBox(height: T.s8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: category,
                            decoration: const InputDecoration(labelText: '类型'),
                            items: [
                              for (final value in categoryValues)
                                DropdownMenuItem(
                                  value: value,
                                  child: Text(_entryCategoryLabel(value)),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => category = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: T.s8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: status,
                            decoration: const InputDecoration(labelText: '状态'),
                            items: [
                              for (final value in statusValues)
                                DropdownMenuItem(
                                  value: value,
                                  child: Text(_statusLabel(value)),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => status = value);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: T.s4),
                    TextButton.icon(
                      onPressed: () =>
                          setDialogState(() => showAdvanced = !showAdvanced),
                      icon: Icon(
                        showAdvanced ? Icons.expand_less : Icons.tune_outlined,
                        size: 17,
                      ),
                      label: Text(showAdvanced ? '收起更多属性' : '更多属性（可选）'),
                    ),
                    if (showAdvanced) ...[
                      TextFormField(
                        initialValue: aliasesValue,
                        onChanged: (value) => aliasesValue = value,
                        decoration: const InputDecoration(
                          labelText: '别名',
                          hintText: '多个别名用逗号分隔',
                        ),
                      ),
                      const SizedBox(height: T.s8),
                      DropdownButtonFormField<String>(
                        initialValue: constraint,
                        decoration: const InputDecoration(labelText: '使用方式'),
                        items: [
                          for (final value in constraintValues)
                            DropdownMenuItem(
                              value: value,
                              child: Text(_entryConstraintLabel(value)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => constraint = value);
                          }
                        },
                      ),
                      const SizedBox(height: T.s8),
                      TextFormField(
                        initialValue: priorityValue,
                        onChanged: (value) => priorityValue = value,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '优先级',
                          helperText: '通常保持默认即可',
                        ),
                      ),
                      const SizedBox(height: T.s8),
                      TextFormField(
                        initialValue: notesValue,
                        onChanged: (value) => notesValue = value,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '备注 / 上下文',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(dialogContext, <String, Object?>{
                  if (existing != null) 'id': existing.id,
                  'source': sourceValue.trim(),
                  'target': targetValue.trim(),
                  'aliases': _splitValues(aliasesValue),
                  'category': category,
                  'status': status,
                  'constraint': constraint,
                  'priority': int.tryParse(priorityValue.trim()) ?? 50,
                  'notes': notesValue.trim(),
                  if (existing != null && existing.memoryType.isNotEmpty)
                    'memory_type': existing.memoryType,
                });
              },
              child: Text(existing == null ? '添加术语' : '保存更改'),
            ),
          ],
        ),
      ),
    );
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
