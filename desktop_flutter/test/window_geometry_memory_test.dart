import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/current_window_controls.dart';

void main() {
  test('window geometry memory stores role-scoped window bounds', () async {
    final temp = await Directory.systemTemp.createTemp('tvx_window_geometry_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final file = File('${temp.path}${Platform.pathSeparator}geometry.json');
    final memory = WindowGeometryMemory(file);

    await memory.writeBounds(
      AppWindowType.translationSettings,
      const Rect.fromLTWH(120, 140, 860, 620),
    );
    await memory.writeBounds(
      AppWindowType.taskProcessing,
      const Rect.fromLTWH(240, 260, 1180, 780),
    );

    expect(
      await memory.readBounds(AppWindowType.translationSettings),
      const Rect.fromLTWH(120, 140, 860, 620),
    );
    expect(
      await memory.readBounds(AppWindowType.taskProcessing),
      const Rect.fromLTWH(240, 260, 1180, 780),
    );
    expect(await memory.readBounds(AppWindowType.main), isNull);

    final decoded = jsonDecode(await file.readAsString()) as Map;
    final windows = decoded['windows'] as Map;
    expect(windows.keys, contains('tool:translationSettings'));
    expect(windows.keys, contains('workbench:taskProcessing'));
    expect(windows.keys, isNot(contains('taskProcessing:tvx_123')));

    await memory.reset(AppWindowType.translationSettings);
    expect(await memory.readBounds(AppWindowType.translationSettings), isNull);
    expect(
      await memory.readBounds(AppWindowType.taskProcessing),
      const Rect.fromLTWH(240, 260, 1180, 780),
    );

    await memory.reset();
    expect(await file.exists(), isFalse);
  });

  test(
    'remembered window geometry stays visible and respects minimum size',
    () {
      final visibleBounds = const Rect.fromLTWH(0, 0, 1920, 1080);
      final geometry = windowGeometryFor(
        AppWindowArgs(
          type: AppWindowType.asrSettings,
          parentBounds: const Rect.fromLTWH(40, 60, 720, 520),
          visibleBounds: visibleBounds,
        ),
        rememberedBounds: const Rect.fromLTWH(1900, 1000, 120, 100),
      );

      expect(geometry.role, WindowRole.tool);
      expect(geometry.size, const Size(700, 500));
      expect(geometry.position, const Offset(1220, 580));
      expect(geometry.center, isFalse);

      final workbenchGeometry = windowGeometryFor(
        AppWindowArgs(
          type: AppWindowType.taskProcessing,
          parentBounds: const Rect.fromLTWH(40, 60, 720, 520),
          visibleBounds: visibleBounds,
        ),
        rememberedBounds: const Rect.fromLTWH(-240, -200, 1280, 820),
      );

      expect(workbenchGeometry.size, const Size(1280, 820));
      expect(workbenchGeometry.position, Offset.zero);
      expect(workbenchGeometry.maximizable, isTrue);
    },
  );
}
