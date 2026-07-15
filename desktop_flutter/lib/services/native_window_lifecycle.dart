import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('transvortex/window_lifecycle');

Future<void> Function()? _closeHandler;

void registerNativeWindowCloseHandler(Future<void> Function()? handler) {
  _closeHandler = handler;
  _channel.setMethodCallHandler(
    handler == null
        ? null
        : (call) async {
            if (call.method != 'onClose') {
              throw MissingPluginException('No handler for ${call.method}');
            }
            await handler();
            return null;
          },
  );
}

@visibleForTesting
Future<void> dispatchNativeWindowCloseForTesting() async {
  await _closeHandler?.call();
}
