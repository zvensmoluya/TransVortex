import 'dart:io';

class PathOpenException implements Exception {
  PathOpenException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PathOpener {
  Future<void> revealFile(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw PathOpenException('path is empty');
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', trimmed]);
      return;
    }
    await openDirectory(File(trimmed).parent.path);
  }

  Future<void> openDirectory(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw PathOpenException('path is empty');
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [trimmed]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [trimmed]);
      return;
    }
    await Process.start('xdg-open', [trimmed]);
  }
}
