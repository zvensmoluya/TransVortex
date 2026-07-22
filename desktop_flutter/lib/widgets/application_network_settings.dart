import 'dart:async';

import 'package:flutter/material.dart';

import '../model/network_settings.dart';
import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/settings_error.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'network_settings_form.dart';
import 'settings_common.dart';

class ApplicationNetworkSettings extends StatefulWidget {
  const ApplicationNetworkSettings({
    super.key,
    required this.client,
    required this.bridge,
    required this.service,
  });

  final AppServiceClient client;
  final WindowStateBridge bridge;
  final LocalServiceController service;

  @override
  State<ApplicationNetworkSettings> createState() =>
      _ApplicationNetworkSettingsState();
}

class _ApplicationNetworkSettingsState
    extends State<ApplicationNetworkSettings> {
  final TextEditingController _proxyPort = TextEditingController();
  DesktopSnapshot? _snapshot;
  String _mode = 'system';
  String _savedMode = 'system';
  String _savedProxyPort = '';
  bool _loading = false;
  bool _saving = false;
  int _serviceRevision = 0;
  String? _message;
  String? _error;

  bool get _dirty =>
      _snapshot != null &&
      (_mode != _savedMode || _proxyPort.text.trim() != _savedProxyPort);

  @override
  void initState() {
    super.initState();
    final initial = widget.service.snapshot.desktopSnapshot;
    if (initial != null) _applySnapshot(initial);
    widget.service.addListener(_syncFromService);
    unawaited(_load(clearFeedback: initial == null));
  }

  @override
  void didUpdateWidget(covariant ApplicationNetworkSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      oldWidget.service.removeListener(_syncFromService);
      widget.service.addListener(_syncFromService);
      _syncFromService();
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_syncFromService);
    _proxyPort.dispose();
    super.dispose();
  }

  void _applySnapshot(DesktopSnapshot snapshot) {
    final network = snapshot.networkSettings;
    final proxyPort = network.proxyPort > 0 ? '${network.proxyPort}' : '';
    _snapshot = snapshot;
    _mode = network.mode;
    _savedMode = network.mode;
    _savedProxyPort = proxyPort;
    _proxyPort.text = proxyPort;
  }

  void _syncFromService() {
    final next = widget.service.snapshot.desktopSnapshot;
    if (!mounted || next == null || identical(next, _snapshot)) return;
    _serviceRevision += 1;
    final network = next.networkSettings;
    final proxyPort = network.proxyPort > 0 ? '${network.proxyPort}' : '';
    final externalNetworkChanged =
        network.mode != _savedMode || proxyPort != _savedProxyPort;
    if (_dirty) {
      setState(() {
        _snapshot = next;
        _savedMode = network.mode;
        _savedProxyPort = proxyPort;
        _error = null;
        if (externalNetworkChanged) {
          _message = _dirty
              ? '网络设置已在其他窗口更新；当前未保存内容已保留。'
              : '网络设置已自动同步：${networkSettingsLabel(_mode, _proxyPort.text)}。';
        }
      });
      return;
    }
    setState(() {
      _applySnapshot(next);
      _error = null;
    });
  }

  Future<void> _load({bool clearFeedback = true}) async {
    if (!mounted || _loading || _saving) return;
    final serviceRevision = _serviceRevision;
    setState(() {
      _loading = true;
      if (clearFeedback) {
        _message = null;
        _error = null;
      }
    });
    try {
      final snapshot = await widget.client.desktopSnapshot();
      if (!mounted || serviceRevision != _serviceRevision) return;
      setState(() {
        _applySnapshot(snapshot);
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted || serviceRevision != _serviceRevision) return;
      setState(() => _error = friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectMode(String mode) {
    if (_saving || _mode == mode) return;
    setState(() {
      _mode = mode;
      _message = null;
      _error = null;
    });
  }

  void _editProxyPort(String value) {
    if (_saving) return;
    setState(() {
      _message = null;
      _error = null;
    });
  }

  Future<void> _save() async {
    final snapshot = _snapshot;
    if (snapshot == null || _saving || !_dirty) return;
    try {
      resolveNetworkProxyPort(
        mode: _mode,
        proxyPortText: _proxyPort.text,
        fallbackPort: snapshot.networkSettings.proxyPort,
      );
    } on NetworkSettingsValidationException catch (error) {
      setState(() {
        _error = error.message;
        _message = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _message = null;
      _error = null;
    });
    try {
      final saved = await saveNetworkSettingsDraft(
        client: widget.client,
        snapshot: snapshot,
        mode: _mode,
        proxyPortText: _proxyPort.text,
      );
      if (mounted) setState(() => _applySnapshot(saved));
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
      setState(() {
        _message = '网络设置已保存：${networkSettingsLabel(_mode, _proxyPort.text)}。';
      });
    } on Object catch (error) {
      if (isNetworkSettingsConflict(error)) {
        await widget.bridge.refreshServiceSnapshot();
        if (!mounted) return;
        setState(() {
          _message = '网络设置刚刚发生变化；当前修改已保留，请确认后再次保存。';
          _error = null;
        });
      } else if (mounted) {
        setState(() => _error = friendlySettingsError(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (_loading && snapshot == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ToolPanel(
      footer: [
        FeedbackActionButton(
          key: const ValueKey('application-network-save'),
          label: '保存网络设置',
          strong: true,
          busy: _saving,
          onTap: !_loading && !_saving && _dirty ? _save : null,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.public_rounded, size: 18, color: T.sky),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  '这是一项应用全局设置：翻译、远程识别和资源下载会一起使用；本机服务始终直连。',
                  style: T.tCaption.copyWith(color: T.ink),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: T.s16),
        NetworkSettingsForm(
          mode: _mode,
          proxyPortController: _proxyPort,
          onModeChanged: _selectMode,
          onProxyPortChanged: _editProxyPort,
          enabled: !_loading && !_saving && snapshot != null,
        ),
        if (_loading && snapshot != null) ...[
          const SizedBox(height: T.s8),
          Text('正在同步最新网络设置…', style: T.tCaption),
        ],
        if (_error != null) ...[
          const SizedBox(height: T.s12),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              Text(_error!, style: T.tCaption.copyWith(color: T.danger)),
              if (!_loading && !_saving)
                ActionButton(
                  label: '重试同步',
                  onTap: () => _load(clearFeedback: false),
                ),
            ],
          ),
        ] else if (_message != null) ...[
          const SizedBox(height: T.s12),
          Text(_message!, style: T.tCaption.copyWith(color: T.accentStrong)),
        ],
      ],
    );
  }
}
