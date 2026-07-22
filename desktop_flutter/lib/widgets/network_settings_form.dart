import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'settings_common.dart';

class NetworkSettingsForm extends StatelessWidget {
  const NetworkSettingsForm({
    super.key,
    required this.mode,
    required this.proxyPortController,
    required this.onModeChanged,
    required this.onProxyPortChanged,
    this.enabled = true,
  });

  final String mode;
  final TextEditingController proxyPortController;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<String> onProxyPortChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return SettingsSection(
      title: '连接方式',
      divider: false,
      children: [
        IgnorePointer(
          ignoring: !enabled,
          child: Opacity(
            opacity: enabled ? 1 : 0.62,
            child: Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                ChoicePill(
                  label: '跟随系统',
                  selected: mode == 'system',
                  onTap: () => onModeChanged('system'),
                  showCheck: true,
                ),
                ChoicePill(
                  label: '直连',
                  selected: mode == 'direct',
                  onTap: () => onModeChanged('direct'),
                  showCheck: true,
                ),
                ChoicePill(
                  label: '本地代理',
                  selected: mode == 'local_proxy',
                  onTap: () => onModeChanged('local_proxy'),
                  showCheck: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: T.s12),
        AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: Text(
            _modeDescription(mode),
            key: ValueKey('network-mode-description-$mode'),
            style: T.tCaption,
          ),
        ),
        AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => ClipRect(
            child: SizeTransition(
              sizeFactor: animation,
              alignment: Alignment.topCenter,
              child: FadeTransition(opacity: animation, child: child),
            ),
          ),
          child: mode == 'local_proxy'
              ? Padding(
                  key: const ValueKey('local-proxy-fields'),
                  padding: const EdgeInsets.only(top: T.s16),
                  child: IgnorePointer(
                    ignoring: !enabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Input(
                            label: '本地代理端口（HTTP / Mixed）',
                            controller: proxyPortController,
                            hintText: '例如 7890',
                            keyboardType: TextInputType.number,
                            onChanged: onProxyPortChanged,
                          ),
                        ),
                        const SizedBox(height: T.s8),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: proxyPortController,
                          builder: (context, value, child) {
                            final port = value.text.trim();
                            return Text(
                              port.isEmpty
                                  ? '代理地址将使用 127.0.0.1。'
                                  : '代理地址：http://127.0.0.1:$port',
                              style: T.tCaption,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(
                  key: ValueKey('local-proxy-fields-hidden'),
                ),
        ),
      ],
    );
  }
}

String _modeDescription(String mode) => switch (mode) {
  'direct' => '忽略 Windows 系统代理和代理环境变量，直接连接远程服务。',
  'local_proxy' => '连接本机代理软件提供的 HTTP 或 Mixed 端口。',
  _ => '使用 Windows 系统代理；没有系统代理时自动直连。',
};
