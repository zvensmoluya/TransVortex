import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/directory_probe.dart';

void main() {
  test(
    'system directory probe reports writable directory and cleans up',
    () async {
      final temp = await Directory.systemTemp.createTemp('tvx_probe_test_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      final result = await SystemDirectoryWriteProbe().checkWritable(temp.path);

      expect(result.ok, isTrue);
      expect(result.message, '目录可写');
      final leftovers = await temp
          .list()
          .where((entity) => entity.path.contains('.tvx_write_probe_'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );

  test('system directory probe reports missing directory', () async {
    final temp = await Directory.systemTemp.createTemp('tvx_probe_test_');
    final missing = Directory('${temp.path}${Platform.pathSeparator}missing');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final result = await SystemDirectoryWriteProbe().checkWritable(
      missing.path,
    );

    expect(result.ok, isFalse);
    expect(result.message, '目录不存在');
  });
}
