import 'package:flutter/material.dart';

import '../services/local_service_controller.dart';
import '../theme/tokens.dart';

class SidecarProbeView extends StatefulWidget {
  const SidecarProbeView({super.key, required this.controller});

  final LocalServiceController controller;

  @override
  State<SidecarProbeView> createState() => _SidecarProbeViewState();
}

class _SidecarProbeViewState extends State<SidecarProbeView> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _reload() async {
    setState(() {
      _refreshing = true;
    });
    await widget.controller.refresh();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.controller.snapshot;
    final info = snapshot.info;
    final health = snapshot.health;
    final desktopSnapshot = snapshot.desktopSnapshot;
    final config = desktopSnapshot?.configReadiness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Local Service 诊断', style: T.tSection),
            const Spacer(),
            _ProbeButton(
              running:
                  _refreshing ||
                  snapshot.status == LocalServiceConnectionStatus.starting,
              onTap: _refreshing ? null : _reload,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        Text(
          snapshot.status.zh,
          style: T.tBody.copyWith(
            color: switch (snapshot.status) {
              LocalServiceConnectionStatus.ready => T.ok,
              LocalServiceConnectionStatus.degraded => T.warn,
              LocalServiceConnectionStatus.unavailable => T.danger,
              LocalServiceConnectionStatus.stopped => T.muted,
              _ => T.muted,
            },
            fontWeight: T.wMedium,
          ),
        ),
        const SizedBox(height: T.s12),
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: T.line)),
            ),
            child: ListView(
              padding: const EdgeInsets.only(top: T.s12),
              children: [
                _FactRow(label: 'service', value: info?.service ?? 'unknown'),
                _FactRow(
                  label: 'protocol',
                  value: '${info?.protocolVersion ?? '-'}',
                ),
                _FactRow(
                  label: 'app version',
                  value: info?.appVersion ?? 'unknown',
                ),
                _FactRow(label: 'health', value: health?.status ?? 'unknown'),
                _FactRow(label: 'pump', value: health?.pumpLabel ?? 'unknown'),
                if (health?.pump['last_error'] != null)
                  _FactRow(
                    label: 'pump error',
                    value: '${health!.pump['last_error']}',
                  ),
                _FactRow(
                  label: 'active',
                  value: health?.activeTaskLabel ?? 'unknown',
                ),
                _FactRow(
                  label: 'translation',
                  value: config == null
                      ? 'unknown'
                      : '${config.translationLabel} · ${config.translationConfigured ? 'ready' : 'needs config'}',
                ),
                _FactRow(
                  label: 'asr',
                  value: config == null
                      ? 'unknown'
                      : '${config.asrLabel} · ${config.asrConfigured ? 'ready' : 'needs config'}',
                ),
                _FactRow(
                  label: 'tasks',
                  value: '${desktopSnapshot?.tasks.length ?? 0}',
                ),
                if (snapshot.lastError != null)
                  _FactRow(label: 'last error', value: snapshot.lastError!),
                if (health?.error != null)
                  _FactRow(label: 'health error', value: health!.error!),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: T.tCaption.copyWith(fontFamily: 'Consolas'),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: T.tCaption.copyWith(color: T.ink, fontFamily: 'Consolas'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProbeButton extends StatefulWidget {
  const _ProbeButton({required this.running, required this.onTap});

  final bool running;
  final VoidCallback? onTap;

  @override
  State<_ProbeButton> createState() => _ProbeButtonState();
}

class _ProbeButtonState extends State<_ProbeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover && widget.onTap != null ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: T.accent, width: 1.2),
          ),
          child: Text(
            widget.running ? '刷新中' : '刷新',
            style: T.tBody.copyWith(
              color: T.accentStrong,
              fontWeight: T.wMedium,
            ),
          ),
        ),
      ),
    );
  }
}
