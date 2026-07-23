import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/settings_service_transport.dart';
import '../services/window_state_bridge.dart';
import '../services/workspace_data_manager.dart';
import '../theme/tokens.dart';
import 'application_network_settings.dart';
import 'asr_resource_management.dart';
import 'settings_common.dart';
import 'title_bar.dart';
import 'workspace_data_management.dart';

enum _ApplicationSettingsSection { network, workspace, resources }

const _applicationSettingsTabs = [
  SettingsTabOption(value: _ApplicationSettingsSection.network, label: '网络'),
  SettingsTabOption(
    value: _ApplicationSettingsSection.workspace,
    label: '工作数据',
  ),
  SettingsTabOption(
    value: _ApplicationSettingsSection.resources,
    label: '识别资源',
  ),
];

class ApplicationSettingsPanel extends StatefulWidget {
  const ApplicationSettingsPanel({
    super.key,
    required this.bridge,
    required this.service,
    required this.onClose,
    this.pathOpener,
    this.entranceAnimation,
    this.overlay = false,
    this.workspaceOperations,
    this.directoryPicker,
    this.onWorkspaceBusyChanged,
  });

  final WindowStateBridge bridge;
  final LocalServiceController service;
  final VoidCallback onClose;
  final PathOpener? pathOpener;
  final Animation<double>? entranceAnimation;
  final bool overlay;
  final WorkspaceDataOperations? workspaceOperations;
  final WorkspaceDirectoryPicker? directoryPicker;
  final ValueChanged<bool>? onWorkspaceBusyChanged;

  @override
  State<ApplicationSettingsPanel> createState() =>
      _ApplicationSettingsPanelState();
}

class _ApplicationSettingsPanelState extends State<ApplicationSettingsPanel> {
  late final AppServiceClient _client = AppServiceClient(
    SettingsServiceTransport(bridge: widget.bridge, service: widget.service),
  );
  _ApplicationSettingsSection _section = _ApplicationSettingsSection.network;
  int _navigationDirection = 1;

  void _selectSection(_ApplicationSettingsSection next) {
    if (next == _section) return;
    setState(() {
      _navigationDirection = next.index > _section.index ? 1 : -1;
      _section = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        _ApplicationSettingsHeader(onClose: widget.onClose),
        Padding(
          padding: const EdgeInsets.fromLTRB(T.s16, T.s12, T.s16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SettingsTabs<_ApplicationSettingsSection>(
              key: const ValueKey('application-settings-tabs'),
              options: _applicationSettingsTabs,
              selected: _section,
              onPick: _selectSection,
              tabWidth: 112,
            ),
          ),
        ),
        const SizedBox(height: T.s12),
        const Divider(height: 1, color: T.line),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(T.s16, T.s16, T.s16, T.s16),
            child: _buildSectionTransition(context),
          ),
        ),
      ],
    );
    return Material(
      key: const ValueKey('application-settings-panel'),
      color: T.bg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: T.bg,
          border: widget.overlay
              ? const Border(left: BorderSide(color: T.line))
              : const Border(
                  top: BorderSide(color: T.line),
                  right: BorderSide(color: T.line),
                  bottom: BorderSide(color: T.line),
                ),
        ),
        child: _buildEntranceTransition(context, content),
      ),
    );
  }

  Widget _buildEntranceTransition(BuildContext context, Widget child) {
    final animation = widget.entranceAnimation;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (animation == null || reduceMotion) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final curve = animation.status == AnimationStatus.reverse
            ? Curves.easeInCubic
            : Curves.easeOutCubic;
        final progress = curve.transform(animation.value);
        return IgnorePointer(
          ignoring: animation.status != AnimationStatus.completed,
          child: Opacity(
            key: const ValueKey('application-settings-transition'),
            opacity: progress,
            child: Transform.translate(
              offset: Offset((1 - progress) * 20, 0),
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionTransition(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 190);
    final currentKey = ValueKey(_section);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: duration,
        reverseDuration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, ?currentChild],
        ),
        transitionBuilder: (child, animation) {
          final incoming = child.key == currentKey;
          final offset = incoming
              ? 0.035 * _navigationDirection
              : -0.02 * _navigationDirection;
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(offset, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: SizedBox.expand(
          key: currentKey,
          child: switch (_section) {
            _ApplicationSettingsSection.network => ApplicationNetworkSettings(
              client: _client,
              bridge: widget.bridge,
              service: widget.service,
            ),
            _ApplicationSettingsSection.workspace => Align(
              alignment: Alignment.topCenter,
              child: WorkspaceDataManagement(
                client: _client,
                service: widget.service,
                operations: widget.workspaceOperations,
                pathOpener: widget.pathOpener,
                directoryPicker: widget.directoryPicker,
                onBusyChanged: widget.onWorkspaceBusyChanged,
                onWorkspaceChanged: widget.bridge.refreshServiceSnapshot,
              ),
            ),
            _ApplicationSettingsSection.resources => AsrResourceManagement(
              client: _client,
              bridge: widget.bridge,
              service: widget.service,
              pathOpener: widget.pathOpener,
              directoryPicker: widget.directoryPicker,
              showHeader: false,
            ),
          },
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
      decoration: BoxDecoration(
        color: T.surface.withValues(alpha: 0.76),
        border: const Border(bottom: BorderSide(color: T.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: WindowDragArea(
              key: const ValueKey('application-settings-drag-area'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: T.s16),
                child: Row(
                  children: [
                    const BrandSeal(),
                    const SizedBox(width: T.s8),
                    Text(
                      '应用设置',
                      style: T.tBrand.copyWith(
                        color: T.ink.withValues(alpha: 0.86),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TitleBarCloseButton(
            key: const ValueKey('application-settings-close'),
            tooltip: '收起应用设置',
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}
