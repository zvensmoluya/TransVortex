import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

Future<Map<String, Object?>> captureSmokeRender({
  required GlobalKey boundaryKey,
  required String? path,
}) async {
  final targetPath = path?.trim();
  if (targetPath == null || targetPath.isEmpty) {
    return const <String, Object?>{};
  }

  await WidgetsBinding.instance.endOfFrame;
  final renderObject = boundaryKey.currentContext?.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) {
    return <String, Object?>{
      'render_capture_ok': false,
      'render_screenshot_path': targetPath,
      'render_screenshot_error': 'Render boundary is not available.',
    };
  }

  final image = await renderObject.toImage(pixelRatio: 1);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final width = image.width;
  final height = image.height;
  image.dispose();
  if (byteData == null) {
    return <String, Object?>{
      'render_capture_ok': false,
      'render_screenshot_path': targetPath,
      'render_screenshot_error': 'Render boundary did not produce PNG bytes.',
    };
  }

  final file = File(targetPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
  return <String, Object?>{
    'render_capture_ok': true,
    'render_screenshot_path': file.path,
    'render_screenshot_width': width,
    'render_screenshot_height': height,
    'render_screenshot_error': '',
  };
}
