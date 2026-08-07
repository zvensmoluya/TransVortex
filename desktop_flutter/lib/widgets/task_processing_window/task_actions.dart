part of '../task_processing_window.dart';

extension _TaskProcessingActions on _TaskProcessingWindowState {
  Future<void> _resumeTask(TaskSummary task) async {
    if (!task.canResume || _resuming) return;
    _setTaskProcessingState(() {
      _resuming = true;
      _message = '正在继续任务…';
      _error = null;
    });
    try {
      final result = await _client.submitResume({
        'request_version': 1,
        'task_id': task.taskId,
      });
      if (!mounted) return;
      _setTaskProcessingState(() {
        _message = result.message.isNotEmpty ? result.message : '任务已重新排队。';
        _resuming = false;
      });
      await _loadTasks();
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _error = '继续任务失败：${_friendlyTaskProcessingError(error)}';
        _resuming = false;
      });
    }
  }

  Future<void> _retranslateTask(TaskSummary task) async {
    if (!task.isDone || _retranslatingTaskId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新翻译当前识别稿'),
        content: const Text('将使用已保存的识别稿和当前翻译设置创建新任务，不会重新运行语音识别。该操作会调用翻译模型。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.translate, size: 16),
            label: const Text('创建翻译任务'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _setTaskProcessingState(() {
      _retranslatingTaskId = task.taskId;
      _message = '正在从已有识别稿创建翻译任务…';
      _error = null;
    });
    try {
      final result = await _client.retranslate(task.taskId);
      if (!mounted) return;
      _selectedTaskId = result.taskId;
      await _loadTasks();
      if (!mounted) return;
      _setTaskProcessingState(() {
        _message = result.message.isNotEmpty ? result.message : '新的翻译任务已排队。';
        _retranslatingTaskId = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _error = '创建翻译任务失败：${_friendlyTaskProcessingError(error)}';
        _message = null;
        _retranslatingTaskId = null;
      });
    }
  }

  Future<void> _cancelTask(TaskSummary task) async {
    if (!task.canCancel || _cancellingTaskId != null) return;
    _setTaskProcessingState(() {
      _cancellingTaskId = task.taskId;
      _message = '正在请求取消任务…';
      _error = null;
    });
    try {
      final cancelled = await _client.cancel(task.taskId);
      if (!mounted) return;
      final message = cancelled.status == 'CANCEL_REQUESTED'
          ? '已请求取消任务。'
          : '任务已更新为${taskStatusLabel(cancelled.status)}。';
      _setTaskProcessingState(() {
        _selectedTaskId = cancelled.taskId.isEmpty
            ? task.taskId
            : cancelled.taskId;
        _cancellingTaskId = null;
      });
      await _loadTasks();
      if (!mounted || _error != null) return;
      _setTaskProcessingState(() {
        _message = message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _error = '取消任务失败：${_friendlyTaskProcessingError(error)}';
        _message = null;
        _cancellingTaskId = null;
      });
    }
  }

  Future<void> _openTaskDirectory(TaskSummary task) async {
    final dir = task.taskDir.trim();
    if (dir.isEmpty) {
      _setTaskProcessingState(() {
        _error = '这个任务没有记录任务目录。';
        _message = null;
      });
      return;
    }
    await _openDirectory(dir, successMessage: '已打开任务目录');
  }

  Future<void> _openOutputDirectory(TaskSummary task) async {
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      _setTaskProcessingState(() {
        _error = '这个任务还没有输出目录。';
        _message = null;
      });
      return;
    }
    await _openDirectory(dir, successMessage: '已打开结果目录');
  }

  Future<void> _checkOutputDirectory(TaskSummary task) async {
    if (_checkingOutputDirectory) return;
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      _setTaskProcessingState(() {
        _error = '这个任务还没有输出目录。';
        _message = null;
      });
      return;
    }
    _setTaskProcessingState(() {
      _checkingOutputDirectory = true;
      _message = '正在检查结果目录…';
      _error = null;
    });
    try {
      final result = await _directoryProbe.checkWritable(dir);
      if (!mounted) return;
      _setTaskProcessingState(() {
        if (result.ok) {
          _message = '结果目录可写，可以重新导出。';
          _error = null;
        } else {
          _message = null;
          _error = '结果目录不可用：${result.message}';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _message = null;
        _error = '检查结果目录失败：$error';
      });
    } finally {
      if (mounted) {
        _setTaskProcessingState(() => _checkingOutputDirectory = false);
      }
    }
  }

  Future<void> _recoverTaskOutput(
    TaskSummary task, {
    required bool chooseDirectory,
  }) async {
    if (_reexportingTaskId != null) return;
    final recovery = taskFailurePresentation(
      error: task.error,
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    if (recovery.target != TaskFailureRecoveryTarget.outputDirectory &&
        recovery.target != TaskFailureRecoveryTarget.reexport) {
      return;
    }

    String? outputDirectory;
    if (chooseDirectory) {
      try {
        outputDirectory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择新的字幕输出目录',
          initialDirectory: _outputDirectoryFor(task),
        );
      } on Object {
        if (!mounted) return;
        _setTaskProcessingState(() {
          _message = null;
          _error = '打开目录选择器失败，请稍后重试。';
        });
        return;
      }
      if (!mounted || outputDirectory == null) return;
    }

    _setTaskProcessingState(() {
      _reexportingTaskId = task.taskId;
      _message = chooseDirectory ? '正在写入新的输出目录…' : '正在重新导出字幕…';
      _error = null;
    });
    try {
      final reexportStyle = _stringMap(
        task.settings['reexport_subtitle_ass_style'],
      );
      final subtitleStyle = reexportStyle.isNotEmpty
          ? reexportStyle
          : _stringMap(task.settings['subtitle_ass_style']);
      final reexportBilingual = _firstDiagnosticBool(task.settings, const [
        'reexport_bilingual',
      ]);
      await _client.resultReexport(
        task.taskId,
        outputFormat: _taskOutputFormat(task),
        outputDir: outputDirectory,
        bilingual: reexportBilingual ?? task.bilingual,
        subtitleBilingualOrder: _stringValue(subtitleStyle['bilingual_order']),
        subtitlePreferSingleLine: _firstDiagnosticBool(subtitleStyle, const [
          'prefer_single_line',
        ]),
      );
      if (!mounted) return;
      await _loadTasks();
      if (!mounted) return;
      _setTaskProcessingState(() {
        _reexportingTaskId = null;
        if (_error == null) {
          _message = chooseDirectory ? '字幕已重新导出到新目录。' : '字幕已重新导出。';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _reexportingTaskId = null;
        _message = null;
        _error = '重新导出失败：${_friendlyTaskProcessingError(error)}';
      });
    }
  }

  Future<void> _openFailureRecoverySettings(TaskSummary task) async {
    final recovery = taskFailurePresentation(
      error: task.error,
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    final type = switch (recovery.target) {
      TaskFailureRecoveryTarget.translationSettings =>
        AppWindowType.translationSettings,
      TaskFailureRecoveryTarget.asrSettings => AppWindowType.asrSettings,
      _ => null,
    };
    if (type == null) return;
    _setTaskProcessingState(() {
      _message = '正在打开${type.title}…';
      _error = null;
    });
    try {
      await widget.bridge.openToolWindow(type);
      if (!mounted) return;
      _setTaskProcessingState(() {
        _message = '已打开${type.title}，修好后可以回来继续任务。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _message = null;
        _error = '打开${type.title}失败：$error';
      });
    }
  }

  Future<void> _openDirectory(
    String path, {
    required String successMessage,
  }) async {
    try {
      await _pathOpener.openDirectory(path);
      if (!mounted) return;
      _setTaskProcessingState(() {
        _message = successMessage;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _error = '打开目录失败：$error';
        _message = null;
      });
    }
  }
}
