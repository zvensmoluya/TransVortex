import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/app_service_client.dart';

typedef AsrOperationTerminalHandler =
    Future<void> Function(AsrOperationStatus operation);
typedef AsrOperationErrorHandler = void Function(Object error);

/// Owns the lifecycle of a Local Service ASR resource operation.
///
/// The operation itself remains authoritative in the Local Service. This
/// controller only reconnects the settings surface to that state, polls while
/// the operation is active, and reports terminal/error transitions back to the
/// window. It intentionally has no dependency on widgets or window plugins.
class AsrOperationController extends ChangeNotifier {
  AsrOperationController(
    this._client, {
    required this.onTerminal,
    required this.onError,
  });

  final AppServiceClient _client;
  final AsrOperationTerminalHandler onTerminal;
  final AsrOperationErrorHandler onError;

  AsrOperationStatus? _operation;
  Timer? _pollTimer;
  Timer? _dismissTimer;
  bool _disposed = false;

  AsrOperationStatus? get operation => _operation;

  void attach(AsrOperationStatus? operation, {bool poll = false}) {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _replace(operation);
    if (poll && operation?.active == true) startPolling();
  }

  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_poll()),
    );
  }

  Future<AsrOperationStatus?> cancel() async {
    final operationId = _operation?.id;
    if (operationId == null || operationId.isEmpty) return null;
    final operation = await _client.asrOperationCancel(operationId);
    if (_disposed || _operation?.id != operationId) return null;
    _replace(operation);
    return operation;
  }

  void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _replace(null);
  }

  Future<void> _poll() async {
    final operationId = _operation?.id;
    if (operationId == null || operationId.isEmpty) return;
    try {
      final operation = await _client.asrOperation(operationId);
      if (_disposed || _operation?.id != operationId) return;
      _replace(operation);
      if (operation.active) return;

      _stopPolling();
      await onTerminal(operation);
      if (_disposed) return;
      final currentId = _operation?.id;
      if (currentId != null && currentId != operation.id) return;
      _replace(operation);
      _scheduleDismiss(operation);
    } on Object catch (error) {
      _stopPolling();
      if (!_disposed) onError(error);
    }
  }

  void _scheduleDismiss(AsrOperationStatus operation) {
    _dismissTimer?.cancel();
    if (operation.active || operation.state != 'completed') return;
    _dismissTimer = Timer(const Duration(milliseconds: 2200), () {
      if (_disposed || _operation?.id != operation.id) return;
      _replace(null);
    });
  }

  void _replace(AsrOperationStatus? operation) {
    _operation = operation;
    if (!_disposed) notifyListeners();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _dismissTimer?.cancel();
    _dismissTimer = null;
    super.dispose();
  }
}
