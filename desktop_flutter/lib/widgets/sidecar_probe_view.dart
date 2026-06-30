import 'package:flutter/material.dart';

import '../services/sidecar_probe.dart';
import '../theme/tokens.dart';

class SidecarProbeView extends StatefulWidget {
  const SidecarProbeView({super.key});

  @override
  State<SidecarProbeView> createState() => _SidecarProbeViewState();
}

class _SidecarProbeViewState extends State<SidecarProbeView> {
  bool _running = false;
  SidecarProbeResult? _result;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
    });
    final result = await SidecarProbe().run();
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Python sidecar 探针', style: T.tSection),
            const Spacer(),
            _ProbeButton(running: _running, onTap: _running ? null : _run),
          ],
        ),
        const SizedBox(height: T.s12),
        Text(
          result == null
              ? '等待运行'
              : result.ok
              ? '通过 · exit=${result.exitCode}'
              : '未通过 · exit=${result.exitCode ?? 'unknown'}',
          style: T.tBody.copyWith(
            color: result == null
                ? T.muted
                : result.ok
                ? T.ok
                : T.danger,
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
              children: [
                for (final line in result?.lines ?? const <String>[])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(
                      line,
                      style: T.tCaption.copyWith(fontFamily: 'Consolas'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
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
            widget.running ? '运行中' : '运行',
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
