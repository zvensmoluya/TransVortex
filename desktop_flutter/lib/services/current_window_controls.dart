import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../model/spike_state.dart';

Future<void> configureCurrentWindow(SpikeWindowType type) async {
  await windowManager.ensureInitialized();

  final size = switch (type) {
    SpikeWindowType.main => const Size(720, 520),
    SpikeWindowType.translationSettings => const Size(780, 560),
    SpikeWindowType.asrSettings => const Size(700, 540),
  };

  final options = WindowOptions(
    size: size,
    center: true,
    backgroundColor: const Color(0xFFFFF7F1),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.show();
    await windowManager.focus();
  });
}

Future<void> registerCurrentWindowControls() async {
  try {
    final current = await WindowController.fromCurrentEngine();
    await current.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'window_focus':
          await windowManager.show();
          await windowManager.focus();
          return null;
        case 'window_close':
          await windowManager.close();
          return null;
        default:
          throw MissingPluginException('No handler for ${call.method}');
      }
    });
  } on Object {
    // Widget tests and unsupported hosts still render the Flutter tree.
  }
}
