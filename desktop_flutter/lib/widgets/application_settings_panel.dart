import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/settings_service_transport.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'asr_resource_management.dart';

class ApplicationSettingsPanel extends StatefulWidget {
  const ApplicationSettingsPanel({
    super.key,
    required this.bridge,
    required this.service,
    required this.onClose,
    this.pathOpener,
  });

  final WindowStateBridge bridge;
  final LocalServiceController service;
  final VoidCallback onClose;
  final PathOpener? pathOpener;

  @override
  State<ApplicationSettingsPanel> createState() =>
      _ApplicationSettingsPanelState();
}

class _ApplicationSettingsPanelState extends State<ApplicationSettingsPanel> {
  late final AppServiceClient _client = AppServiceClient(
    SettingsServiceTransport(bridge: widget.bridge, service: widget.service),
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('application-settings-panel'),
      color: T.bg,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: T.bg,
          border: Border(
            left: BorderSide(color: T.line),
            top: BorderSide(color: T.line),
            right: BorderSide(color: T.line),
            bottom: BorderSide(color: T.line),
          ),
        ),
        child: Column(
          children: [
            _ApplicationSettingsHeader(onClose: widget.onClose),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('存储与资源', style: T.tSection),
                    const SizedBox(height: T.s4),
                    Text('查看和精简应用下载到本机的资源。这里不改变翻译连接或识别方案。', style: T.tCaption),
                    const SizedBox(height: T.s16),
                    Expanded(
                      child: AsrResourceManagement(
                        client: _client,
                        bridge: widget.bridge,
                        pathOpener: widget.pathOpener,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplicationSettingsHeader extends StatelessWidget {
  const _ApplicationSettingsHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.fromLTRB(T.s12, 0, 0, 0),
      decoration: BoxDecoration(
        color: T.surface.withValues(alpha: 0.9),
        border: const Border(bottom: BorderSide(color: T.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              key: const ValueKey('application-settings-drag-area'),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: T.accentSoft,
                      border: Border.all(
                        color: T.accent.withValues(alpha: 0.48),
                      ),
                      borderRadius: BorderRadius.circular(T.rSm),
                    ),
                    child: const Icon(
                      Icons.tune_rounded,
                      size: 16,
                      color: T.accentStrong,
                    ),
                  ),
                  const SizedBox(width: T.s8),
                  Text('应用设置', style: T.tSection),
                  const SizedBox(width: T.s8),
                  Container(width: 1, height: 14, color: T.line),
                  const SizedBox(width: T.s8),
                  Flexible(
                    child: Text(
                      '本机资源',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('application-settings-close'),
            tooltip: '收起应用设置',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
            color: T.muted,
            hoverColor: T.accentSoft,
          ),
        ],
      ),
    );
  }
}
