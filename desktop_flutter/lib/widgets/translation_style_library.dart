import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../theme/tokens.dart';

class TranslationStylePickerDialog extends StatefulWidget {
  const TranslationStylePickerDialog({
    super.key,
    required this.client,
    required this.selectedStyleId,
    this.onManageLibrary,
  });

  final AppServiceClient client;
  final String selectedStyleId;
  final Future<void> Function()? onManageLibrary;

  @override
  State<TranslationStylePickerDialog> createState() =>
      _TranslationStylePickerDialogState();
}

class _TranslationStylePickerDialogState
    extends State<TranslationStylePickerDialog> {
  List<TranslationStyleSummary> _styles = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final styles = await widget.client.translationStyles();
      if (!mounted) return;
      setState(() {
        _styles = styles;
        _loading = false;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取风格库失败：$error';
      });
    }
  }

  Future<void> _select(TranslationStyleSummary item) async {
    setState(() => _loading = true);
    try {
      final detail = await widget.client.translationStyle(item.id);
      if (mounted) Navigator.of(context).pop(detail);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取翻译风格失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择翻译风格'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!, style: T.tBody))
            : ListView.separated(
                itemCount: _styles.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = _styles[index];
                  return ListTile(
                    key: ValueKey('translation-style-${item.id}'),
                    selected: item.id == widget.selectedStyleId,
                    leading: Icon(
                      item.builtin ? Icons.auto_awesome_outlined : Icons.tune,
                    ),
                    title: Text(item.name),
                    subtitle: item.description.isEmpty
                        ? null
                        : Text(item.description),
                    trailing: item.id == widget.selectedStyleId
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => unawaited(_select(item)),
                  );
                },
              ),
      ),
      actions: [
        if (widget.onManageLibrary != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(widget.onManageLibrary!());
            },
            child: const Text('管理风格库'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class TranslationStyleLibrary extends StatefulWidget {
  const TranslationStyleLibrary({super.key, required this.client});

  final AppServiceClient client;

  @override
  State<TranslationStyleLibrary> createState() =>
      _TranslationStyleLibraryState();
}

class _TranslationStyleLibraryState extends State<TranslationStyleLibrary> {
  List<TranslationStyleSummary> _styles = const [];
  TranslationStyleDetail? _detail;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload({String? preferredId}) async {
    if (mounted) setState(() => _loading = true);
    try {
      final styles = await widget.client.translationStyles();
      final requested = preferredId ?? _detail?.summary.id;
      final active = styles.any((item) => item.id == requested)
          ? requested
          : styles.isEmpty
          ? null
          : styles.first.id;
      final detail = active == null
          ? null
          : await widget.client.translationStyle(active);
      if (!mounted) return;
      setState(() {
        _styles = styles;
        _detail = detail;
        _loading = false;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取风格库失败：$error';
      });
    }
  }

  Future<void> _open(TranslationStyleSummary item) async {
    try {
      final detail = await widget.client.translationStyle(item.id);
      if (mounted) setState(() => _detail = detail);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '读取翻译风格失败：$error');
    }
  }

  Future<void> _edit({TranslationStyleDetail? existing}) async {
    final draft = await showDialog<_StyleDraft>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _TranslationStyleEditor(existing: existing),
    );
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final saved = existing == null
          ? await widget.client.createTranslationStyle(
              name: draft.name,
              description: draft.description,
              prompt: draft.prompt,
            )
          : await widget.client.updateTranslationStyle(
              existing.summary.id,
              expectedRevision: existing.summary.revision,
              name: draft.name,
              description: draft.description,
              prompt: draft.prompt,
            );
      await _reload(preferredId: saved.summary.id);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '保存翻译风格失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final detail = _detail;
    if (detail == null || detail.summary.builtin) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除翻译风格？'),
        content: Text('“${detail.summary.name}”将从风格库中删除。已经开始的任务不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.client.deleteTranslationStyle(
        detail.summary.id,
        expectedRevision: detail.summary.revision,
      );
      _detail = null;
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '删除翻译风格失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(T.s16, T.s12, T.s16, T.s8),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('风格库', style: T.tSection),
                    SizedBox(height: 3),
                    Text('保存跨任务复用的语气、措辞和本地化要求。固定译名仍由术语库维护。', style: T.tCaption),
                  ],
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('create-translation-style'),
                onPressed: _busy ? null : () => unawaited(_edit()),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建风格'),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: T.s16),
            child: Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
          ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 280,
                child: ListView.builder(
                  padding: const EdgeInsets.all(T.s8),
                  itemCount: _styles.length,
                  itemBuilder: (context, index) {
                    final item = _styles[index];
                    return ListTile(
                      key: ValueKey('style-library-${item.id}'),
                      selected: _detail?.summary.id == item.id,
                      leading: Icon(
                        item.builtin
                            ? Icons.auto_awesome_outlined
                            : Icons.tune_rounded,
                        size: 20,
                      ),
                      title: Text(item.name),
                      subtitle: item.description.isEmpty
                          ? null
                          : Text(item.description, maxLines: 2),
                      onTap: () => unawaited(_open(item)),
                    );
                  },
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _detailPane()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailPane() {
    final detail = _detail;
    if (detail == null) {
      return const Center(child: Text('选择一个翻译风格查看内容', style: T.tCaption));
    }
    return Padding(
      padding: const EdgeInsets.all(T.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(detail.summary.name, style: T.tSection)),
              if (detail.summary.builtin)
                const Chip(label: Text('内置'))
              else ...[
                IconButton(
                  tooltip: '编辑风格',
                  onPressed: _busy
                      ? null
                      : () => unawaited(_edit(existing: detail)),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: '删除风格',
                  onPressed: _busy ? null : () => unawaited(_delete()),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
          if (detail.summary.description.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(detail.summary.description, style: T.tBody),
          ],
          const SizedBox(height: T.s16),
          const Text('风格 Prompt', style: T.tSection),
          const SizedBox(height: T.s8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(T.s12),
              decoration: BoxDecoration(
                color: T.surface,
                border: Border.all(color: T.line),
                borderRadius: BorderRadius.circular(T.rSm),
              ),
              child: SingleChildScrollView(
                child: SelectableText(detail.prompt, style: T.tBody),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleDraft {
  const _StyleDraft({
    required this.name,
    required this.description,
    required this.prompt,
  });

  final String name;
  final String description;
  final String prompt;
}

class _TranslationStyleEditor extends StatefulWidget {
  const _TranslationStyleEditor({this.existing});

  final TranslationStyleDetail? existing;

  @override
  State<_TranslationStyleEditor> createState() =>
      _TranslationStyleEditorState();
}

class _TranslationStyleEditorState extends State<_TranslationStyleEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.summary.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.existing?.summary.description ?? '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.existing?.prompt ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || prompt.isEmpty) return;
    Navigator.of(context).pop(
      _StyleDraft(
        name: name,
        description: _description.text.trim(),
        prompt: prompt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '新建翻译风格' : '编辑翻译风格'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('translation-style-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: T.s12),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: '简短说明（可选）'),
            ),
            const SizedBox(height: T.s12),
            TextField(
              key: const ValueKey('translation-style-prompt'),
              controller: _prompt,
              minLines: 9,
              maxLines: 16,
              decoration: const InputDecoration(
                labelText: '风格 Prompt',
                alignLabelWithHint: true,
                hintText: '描述语气、措辞、本地化、压缩和内容保留偏好。固定译名请放入术语库。',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
