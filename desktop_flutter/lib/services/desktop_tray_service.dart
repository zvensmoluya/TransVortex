import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart' as tray;

enum DesktopTrayAction { showMain, openTasks, exitApp }

@immutable
class DesktopTrayPresentation {
  const DesktopTrayPresentation({
    required this.statusLabel,
    required this.toolTip,
  });

  final String statusLabel;
  final String toolTip;

  @override
  bool operator ==(Object other) {
    return other is DesktopTrayPresentation &&
        other.statusLabel == statusLabel &&
        other.toolTip == toolTip;
  }

  @override
  int get hashCode => Object.hash(statusLabel, toolTip);
}

abstract class DesktopTrayService {
  Stream<DesktopTrayAction> get actions;

  Future<bool> initialize(DesktopTrayPresentation presentation);

  Future<void> update(DesktopTrayPresentation presentation);

  Future<void> dispose();
}

class SystemDesktopTrayService
    with tray.TrayListener
    implements DesktopTrayService {
  static const String iconAsset = 'assets/ui/app_icon.ico';
  static const String _showMainKey = 'show_main';
  static const String _openTasksKey = 'open_tasks';
  static const String _exitAppKey = 'exit_app';

  final StreamController<DesktopTrayAction> _actions =
      StreamController<DesktopTrayAction>.broadcast(sync: true);
  bool _initialized = false;
  bool _disposed = false;
  DesktopTrayPresentation? _presentation;

  @override
  Stream<DesktopTrayAction> get actions => _actions.stream;

  @override
  Future<bool> initialize(DesktopTrayPresentation presentation) async {
    if (_disposed || !Platform.isWindows) return false;
    if (_initialized) {
      await update(presentation);
      return true;
    }
    tray.trayManager.addListener(this);
    try {
      await tray.trayManager.setIcon(iconAsset);
      _initialized = true;
      await update(presentation);
      return true;
    } on Object {
      tray.trayManager.removeListener(this);
      try {
        await tray.trayManager.destroy();
      } on Object {
        // The icon may not have been created before initialization failed.
      }
      _initialized = false;
      return false;
    }
  }

  @override
  Future<void> update(DesktopTrayPresentation presentation) async {
    if (!_initialized || _disposed || presentation == _presentation) return;
    await tray.trayManager.setToolTip(presentation.toolTip);
    await tray.trayManager.setContextMenu(
      tray.Menu(
        items: [
          tray.MenuItem(key: _showMainKey, label: '打开 TransVortex'),
          tray.MenuItem(key: _openTasksKey, label: '工作台'),
          tray.MenuItem.separator(),
          tray.MenuItem(label: presentation.statusLabel, disabled: true),
          tray.MenuItem.separator(),
          tray.MenuItem(key: _exitAppKey, label: '退出 TransVortex'),
        ],
      ),
    );
    _presentation = presentation;
  }

  @override
  void onTrayIconMouseDown() {
    _emit(DesktopTrayAction.showMain);
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(tray.trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    switch (menuItem.key) {
      case _showMainKey:
        _emit(DesktopTrayAction.showMain);
        return;
      case _openTasksKey:
        _emit(DesktopTrayAction.openTasks);
        return;
      case _exitAppKey:
        _emit(DesktopTrayAction.exitApp);
        return;
    }
  }

  void _emit(DesktopTrayAction action) {
    if (!_disposed) _actions.add(action);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_initialized) {
      tray.trayManager.removeListener(this);
      try {
        await tray.trayManager.destroy();
      } on Object {
        // The native tray may already be gone while the process is exiting.
      }
    }
    _initialized = false;
    await _actions.close();
  }
}
