part of '../task_processing_window.dart';

extension _TaskProcessingEditorLifecycle on _TaskProcessingWindowState {
  Future<void> _openResult(TaskSummary task) async {
    if (!task.isDone) return;
    _setTaskProcessingState(() {
      _editingTaskId = task.taskId;
      _resultEditorDirty = false;
      _message = '正在处理字幕结果。';
      _error = null;
    });
  }

  Future<bool> _leaveResultEditor() async {
    if (_editingTaskId == null) return true;
    if (!await _confirmDiscardResultEdits() || !mounted) return false;
    _setTaskProcessingState(() {
      _editingTaskId = null;
      _resultEditorDirty = false;
    });
    return true;
  }

  Future<bool> _confirmDiscardResultEdits({bool closingWindow = false}) async {
    if (!_resultEditorDirty) return true;
    if (closingWindow) {
      unawaited(_focusWindowForClosePrompt());
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        surfaceTintColor: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rMd),
          side: const BorderSide(color: T.line),
        ),
        title: Row(
          children: [
            const Icon(Icons.edit_note_rounded, color: T.accentStrong),
            const SizedBox(width: T.s8),
            Text('放弃未保存修改？', style: T.tSection),
          ],
        ),
        content: Text(
          closingWindow ? '字幕修改尚未保存，关闭任务处理后这些修改会丢失。' : '字幕修改尚未保存，离开后这些修改会丢失。',
          style: T.tBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(closingWindow ? '继续校对' : '继续编辑'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(closingWindow ? '放弃并关闭' : '放弃修改'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _focusWindowForClosePrompt() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // The dialog still protects the edit if native focus is unavailable.
    }
  }

  Future<bool> _approveWindowCloseRequest() {
    if (_windowCloseAllowed) return Future<bool>.value(true);
    final pending = _windowCloseApproval;
    if (pending != null) return pending;
    late final Future<bool> approval;
    approval = _resolveWindowCloseRequest().whenComplete(() {
      if (identical(_windowCloseApproval, approval)) {
        _windowCloseApproval = null;
      }
    });
    _windowCloseApproval = approval;
    return approval;
  }

  Future<bool> _resolveWindowCloseRequest() async {
    if (_smokeRejectWindowClose) return false;
    final approved = await _confirmDiscardResultEdits(closingWindow: true);
    if (approved) _windowCloseAllowed = true;
    return approved;
  }

  Future<Object?> _handleWindowCommand(MethodCall call) async {
    if (call.method != 'window_smoke_set_close_refusal') {
      throw MissingPluginException('No handler for ${call.method}');
    }
    final arguments = call.arguments;
    final enabled =
        arguments == true || (arguments is Map && arguments['enabled'] == true);
    _smokeRejectWindowClose = enabled;
    return {'ok': true, 'enabled': enabled};
  }

  Future<void> _installWindowCloseGuard() async {
    try {
      await windowManager.setPreventClose(true);
    } on Object {
      // Unsupported test hosts still use the in-window close button guard.
    }
  }

  Future<void> _handleNativeWindowClose() async {
    if (_windowCloseAllowed) return;
    await _requestWindowClose();
  }

  Future<void> _requestWindowClose() async {
    if (_windowCloseRequestInProgress) return;
    _windowCloseRequestInProgress = true;
    try {
      if (!await _approveWindowCloseRequest()) return;
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object catch (error) {
      _windowCloseAllowed = false;
      if (mounted) {
        _setTaskProcessingState(() => _error = '关闭任务处理失败：$error');
      }
    } finally {
      _windowCloseRequestInProgress = false;
    }
  }

  void _handleResultDirtyChanged(bool dirty) {
    if (!mounted || _resultEditorDirty == dirty) return;
    _setTaskProcessingState(() => _resultEditorDirty = dirty);
  }
}
