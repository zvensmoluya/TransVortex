import 'dart:io';

class DirectoryProbeResult {
  const DirectoryProbeResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

abstract class DirectoryWriteProbe {
  Future<DirectoryProbeResult> checkWritable(String path);
}

class SystemDirectoryWriteProbe implements DirectoryWriteProbe {
  @override
  Future<DirectoryProbeResult> checkWritable(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return const DirectoryProbeResult(ok: false, message: '没有目录记录');
    }
    final dir = Directory(trimmed);
    if (!await dir.exists()) {
      return const DirectoryProbeResult(ok: false, message: '目录不存在');
    }
    final probe = File(
      '${dir.path}${Platform.pathSeparator}.tvx_write_probe_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsString('ok');
      return const DirectoryProbeResult(ok: true, message: '目录可写');
    } on Object catch (error) {
      return DirectoryProbeResult(ok: false, message: '目录不可写：$error');
    } finally {
      try {
        if (await probe.exists()) await probe.delete();
      } on Object {
        // Best effort cleanup only.
      }
    }
  }
}
