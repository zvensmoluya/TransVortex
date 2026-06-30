import 'dart:convert';
import 'dart:io';

class SidecarProbeResult {
  const SidecarProbeResult({
    required this.ok,
    required this.lines,
    required this.exitCode,
  });

  final bool ok;
  final List<String> lines;
  final int? exitCode;
}

class SidecarProbe {
  Future<SidecarProbeResult> run() async {
    final lines = <String>[];
    Process? process;
    try {
      final root = _findRepoRoot();
      if (root == null) {
        return const SidecarProbeResult(
          ok: false,
          lines: ['probe_error: could not find repository root for sidecar'],
          exitCode: null,
        );
      }
      process = await Process.start('python', [
        '-m',
        'transvortex.app_service',
        '--root',
        root.path,
      ], workingDirectory: root.path, environment: {
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONPATH': root.path,
      });
      final stdoutLines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      final stderrLines = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      stderrLines.listen((line) => lines.add('stderr: $line'));

      Future<Map<String, dynamic>> send(
        int id,
        String method,
        Map<String, Object?> params,
      ) async {
        process!.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        final line = await stdoutLines.first.timeout(
          const Duration(seconds: 8),
        );
        lines.add(line);
        return jsonDecode(line) as Map<String, dynamic>;
      }

      final snapshot = await send(1, 'desktop.snapshot', const {});
      final error = await send(2, 'transvortex.missingMethodForSpike', const {});
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 3));
      final ok = snapshot.containsKey('result') && error.containsKey('error');
      return SidecarProbeResult(ok: ok, lines: lines, exitCode: exit);
    } on Object catch (exc) {
      lines.add('probe_error: $exc');
      process?.kill();
      return SidecarProbeResult(ok: false, lines: lines, exitCode: null);
    }
  }

  Directory? _findRepoRoot() {
    final candidates = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    for (final start in candidates) {
      var cursor = start;
      while (true) {
        final marker = File(
          '${cursor.path}${Platform.pathSeparator}src'
          '${Platform.pathSeparator}transvortex'
          '${Platform.pathSeparator}app_service.py',
        );
        if (marker.existsSync()) return cursor;
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
    }
    return null;
  }
}
