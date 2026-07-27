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
  AgentClientInfo? _agentClient;
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
      final results = await Future.wait<Object>([
        widget.client.agentEntry(),
        widget.client.agentClient(),
      ]);
      if (!mounted) return;
      setState(() {
        _entry = results[0] as AgentEntryInfo;
        _agentClient = results[1] as AgentClientInfo;
      });
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
      success: '交接信息已复制，可交给 Agent。',
    );
  }

  Future<void> _revealEntry() async {
    final path = _entry?.entryDocument.trim() ?? '';
    if (_acting || path.isEmpty) return;
    await _runAction(() => _pathOpener.revealFile(path), success: '已定位稳定入口文件。');
  }

  Future<void> _openDocs() async {
    final path = _entry?.docsRoot.trim() ?? '';
    if (_acting || path.isEmpty) return;
    await _runAction(
      () => _pathOpener.openDirectory(path),
      success: '已打开当前版本的 Agent 文档。',
    );
  }

  Future<void> _openClient() async {
    if (_acting || _agentClient?.ready != true) return;
    await _runAction(() async {
      final result = await widget.client.openAgentClient();
      if (!result.launched) throw StateError('Codex CLI did not launch');
    }, success: 'Codex CLI 已打开，尚未发送任务。');
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
    final agentClient = _agentClient;
    if (_loading && (entry == null || agentClient == null)) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (entry == null || agentClient == null) {
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
          key: const ValueKey('agent-client-open'),
          label: '打开 Codex',
          icon: Icons.terminal_rounded,
          strong: true,
          onTap: _acting || !agentClient.ready ? null : _openClient,
        ),
        ActionButton(
          key: const ValueKey('agent-entry-copy'),
          label: '复制交接信息',
          icon: Icons.content_copy_rounded,
          onTap: _acting ? null : _copyEntry,
        ),
        ActionButton(
          key: const ValueKey('agent-entry-reveal'),
          label: '定位稳定入口',
          icon: Icons.find_in_page_rounded,
          onTap: _acting ? null : _revealEntry,
        ),
        ActionButton(
          key: const ValueKey('agent-docs-open'),
          label: '打开版本文档',
          icon: Icons.folder_open_rounded,
          onTap: _acting ? null : _openDocs,
        ),
      ],
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(T.s12),
          decoration: BoxDecoration(
            color: agentClient.ready
                ? T.skySoft.withValues(alpha: 0.62)
                : T.warn.withValues(alpha: 0.10),
            border: Border.all(color: T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            children: [
              Icon(
                agentClient.ready
                    ? Icons.terminal_rounded
                    : Icons.error_outline_rounded,
                size: 20,
                color: agentClient.ready ? T.sky : T.warn,
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  _agentClientStatusLabel(agentClient),
                  style: T.tBody.copyWith(fontWeight: T.wBold),
                ),
              ),
              if (agentClient.version.isNotEmpty)
                Text('v${agentClient.version}', style: T.tCaption),
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
          title: 'Agent 客户端',
          children: [
            const ReadonlyRow(label: '默认接收', value: 'Codex CLI'),
            const SizedBox(height: T.s8),
            ReadonlyRow(
              label: '检测状态',
              value: agentClient.ready
                  ? '可用'
                  : _agentClientUnavailableLabel(agentClient),
            ),
            const SizedBox(height: T.s8),
            ReadonlyRow(
              label: '客户端版本',
              value: agentClient.versionLabel.isEmpty
                  ? '未知'
                  : agentClient.versionLabel,
            ),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '执行程序', value: agentClient.executable),
            const SizedBox(height: T.s12),
            ActionButton(
              key: const ValueKey('agent-client-refresh'),
              label: '重新检测',
              icon: Icons.refresh_rounded,
              onTap: _acting || _loading ? null : _load,
            ),
          ],
        ),
        SettingsSection(
          title: 'TransVortex Agent 接口',
          divider: false,
          children: [
            ReadonlyRow(label: '接口状态', value: entry.registered ? '已登记' : '未登记'),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '应用版本', value: 'v${entry.appVersion}'),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '稳定入口', value: entry.entryDocument),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '能力定位', value: entry.entryState),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '版本文档', value: entry.docsRoot),
            const SizedBox(height: T.s8),
            ReadonlyRow(label: '协议版本', value: entry.protocolVersion),
          ],
        ),
      ],
    );
  }
}

String _agentClientStatusLabel(AgentClientInfo client) {
  if (client.ready) return 'Codex CLI 已就绪';
  if (!client.detected) return '未检测到 Codex CLI';
  return 'Codex CLI 暂不可用';
}

String _agentClientUnavailableLabel(AgentClientInfo client) {
  switch (client.statusCode) {
    case 'codex_cli_not_found':
      return '未检测到';
    case 'codex_cli_terminal_unsupported':
      return '当前系统不支持启动';
    default:
      return '运行异常';
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
  if (error is RpcRemoteException) {
    switch (error.code) {
      case 'codex_cli_not_found':
        return '没有检测到 Codex CLI，请确认安装后可从 PATH 启动。';
      case 'codex_cli_probe_failed':
        return 'Codex CLI 已找到，但当前无法运行。';
      case 'codex_cli_terminal_unsupported':
        return '当前系统暂不支持从 TransVortex 打开 Codex CLI。';
      case 'codex_cli_launch_failed':
        return 'Codex CLI 启动失败，请在终端中检查 codex 是否可用。';
    }
  }
  return friendlySettingsError(error);
}
