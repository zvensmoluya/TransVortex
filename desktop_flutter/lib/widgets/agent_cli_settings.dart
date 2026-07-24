import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_service_client.dart';
import '../services/path_opener.dart';
import '../services/settings_error.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';

class AgentCliSettings extends StatefulWidget {
  const AgentCliSettings({super.key, required this.client, this.pathOpener});

  final AppServiceClient client;
  final PathOpener? pathOpener;

  @override
  State<AgentCliSettings> createState() => _AgentCliSettingsState();
}

class _AgentCliSettingsState extends State<AgentCliSettings> {
  late final PathOpener _pathOpener = widget.pathOpener ?? SystemPathOpener();
  AgentEntryInfo? _entry;
  bool _loading = false;
  bool _acting = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _message = null;
      _error = null;
    });
    try {
      final entry = await widget.client.agentEntry();
      if (!mounted) return;
      setState(() => _entry = entry);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _agentEntryError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyEntry() async {
    final text = _entry?.handoffText.trim() ?? '';
    if (_acting || text.isEmpty) return;
    await _runAction(
      () => Clipboard.setData(ClipboardData(text: text)),
      success: 'Agent 入口已复制。',
    );
  }

  Future<void> _revealEntry() async {
    final path = _entry?.entryDocument.trim() ?? '';
    if (_acting || path.isEmpty) return;
    await _runAction(
      () => _pathOpener.revealFile(path),
      success: '已在资源管理器中显示入口。',
    );
  }

  Future<void> _openDocs() async {
    final path = _entry?.docsRoot.trim() ?? '';
    if (_acting || path.isEmpty) return;
    await _runAction(
      () => _pathOpener.openDirectory(path),
      success: '已打开 Agent 资料目录。',
    );
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String success,
  }) async {
    setState(() {
      _acting = true;
      _message = null;
      _error = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = success);
    } on Object catch (error) {
      if (mounted) setState(() => _error = friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    if (_loading && entry == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (entry == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal_rounded, size: 28, color: T.muted),
            const SizedBox(height: T.s8),
            Text(_error ?? 'Agent 入口暂不可用。', style: T.tCaption),
            const SizedBox(height: T.s12),
            ActionButton(
              label: '重试',
              icon: Icons.refresh_rounded,
              onTap: _loading ? null : _load,
            ),
          ],
        ),
      );
    }
    return ToolPanel(
      footer: [
        ActionButton(
          key: const ValueKey('agent-entry-copy'),
          label: '复制入口',
          icon: Icons.content_copy_rounded,
          strong: true,
          onTap: _acting ? null : _copyEntry,
        ),
        ActionButton(
          key: const ValueKey('agent-entry-reveal'),
          label: '显示入口',
          icon: Icons.find_in_page_rounded,
          onTap: _acting ? null : _revealEntry,
        ),
        ActionButton(
          key: const ValueKey('agent-docs-open'),
          label: '打开资料',
          icon: Icons.folder_open_rounded,
          onTap: _acting ? null : _openDocs,
        ),
      ],
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(T.s12),
          decoration: BoxDecoration(
            color: T.skySoft.withValues(alpha: 0.62),
            border: Border.all(color: T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            children: [
              const Icon(Icons.terminal_rounded, size: 20, color: T.sky),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  entry.registered ? 'Agent / CLI 入口已就绪' : 'Agent / CLI 入口未登记',
                  style: T.tBody.copyWith(fontWeight: T.wBold),
                ),
              ),
              Text('v${entry.appVersion}', style: T.tCaption),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: T.s8),
          Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
        ] else if (_message != null) ...[
          const SizedBox(height: T.s8),
          Text(_message!, style: T.tCaption.copyWith(color: T.accentStrong)),
        ],
        const SizedBox(height: T.s16),
        SettingsSection(
          title: '稳定入口',
          children: [
            ReadonlyRow(label: '入口文件', value: entry.entryDocument),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '定位信息', value: entry.entryState),
          ],
        ),
        SettingsSection(
          title: '当前安装',
          children: [
            ReadonlyRow(label: '程序目录', value: entry.installRoot),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '配置目录', value: entry.configRoot),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '资料目录', value: entry.docsRoot),
          ],
        ),
        SettingsSection(
          title: 'CLI 契约',
          divider: false,
          children: [
            ReadonlyRow(
              label: '运行环境',
              value: entry.cliArgvPrefix.isEmpty
                  ? ''
                  : entry.cliArgvPrefix.first,
            ),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '协议版本', value: entry.protocolVersion),
          ],
        ),
      ],
    );
  }
}

String _agentEntryError(Object error) {
  if (error is RpcRemoteException &&
      const {
        'agent_install_not_registered',
        'agent_install_invalid',
        'agent_documents_missing',
        'agent_cli_missing',
      }.contains(error.code)) {
    return '当前运行方式没有可用的安装版 Agent 入口。';
  }
  return friendlySettingsError(error);
}
