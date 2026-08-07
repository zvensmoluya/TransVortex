part of '../settings_window.dart';

extension _DiagnosticsSettingsSurface on _SettingsWindowState {
  Widget _diagnosticsBody() {
    final snapshot = _snapshot;
    final checks = _diagnosticChecks(snapshot);
    final report = _diagnosticReport(snapshot);
    final selected = _selectedDiagnostic(checks);
    final selectedName = selected == null ? null : _diagnosticId(selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DefaultBar(
          text: _diagnosticHeader(snapshot),
          busy: _loading,
          error: _error,
          message: _message,
        ),
        const SizedBox(height: T.s16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 230,
                child: _DiagnosticSummaryList(
                  checks: checks,
                  selectedName: selectedName,
                  onPick: _pickDiagnosticCheck,
                ),
              ),
              const SizedBox(width: T.s32),
              Expanded(
                child: _DiagnosticDetails(
                  snapshot: snapshot,
                  tasks: _diagnosticTasks,
                  selectedTaskId: _selectedDiagnosticTaskId,
                  result: _diagnosticResult,
                  outputDirectoryResults: _diagnosticOutputDirectoryResults,
                  checkingOutputDirectoryTaskIds:
                      _checkingDiagnosticOutputDirectoryTaskIds,
                  report: report,
                  checks: checks,
                  highlighted: selected,
                  onRefresh: _loading ? null : _loadConfig,
                  onRefreshTasks: _loadingDiagnosticTasks
                      ? null
                      : _loadDiagnosticTasks,
                  onOpenResult: _loadingDiagnosticResult
                      ? null
                      : _openDiagnosticResult,
                  onOpenTask: _openDiagnosticTask,
                  onOpenTaskId: _openDiagnosticTaskId,
                  onCheckOutputDirectory: _checkDiagnosticOutputDirectory,
                  onOpenTool: _openDiagnosticTool,
                  onOpenPath: _openDiagnosticPath,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Map<String, Object?> _diagnosticReport(DesktopSnapshot? snapshot) {
    return _stringMap(snapshot?.environment);
  }

  List<Map<String, Object?>> _diagnosticChecks(DesktopSnapshot? snapshot) {
    return _objectList(
      _diagnosticReport(snapshot)['checks'],
    ).map(_stringMap).where((check) => check.isNotEmpty).toList();
  }

  String _diagnosticStatus(DesktopSnapshot? snapshot) {
    final status = _stringValue(_diagnosticReport(snapshot)['status']);
    return status == null || status.isEmpty ? 'UNKNOWN' : status;
  }

  String _diagnosticHeader(DesktopSnapshot? snapshot) {
    if (snapshot == null) return '诊断：等待服务';
    final checks = _diagnosticChecks(snapshot);
    final fail = _diagnosticCount(checks, 'FAIL');
    final warn = _diagnosticCount(checks, 'WARN');
    final pass = _diagnosticCount(checks, 'PASS');
    return '诊断：${_diagnosticStatusLabel(_diagnosticStatus(snapshot))} · 通过 $pass / 警告 $warn / 失败 $fail';
  }

  String? _defaultDiagnosticSelection(DesktopSnapshot snapshot) {
    final checks = _diagnosticChecks(snapshot);
    if (checks.isEmpty) return null;
    final current = _selectedDiagnosticCheck;
    if (current != null &&
        checks.any((check) => _diagnosticId(check) == current)) {
      return current;
    }
    for (final check in checks) {
      final status = _diagnosticCheckStatus(check);
      if (status == 'FAIL' || status == 'WARN') {
        return _diagnosticId(check);
      }
    }
    return _diagnosticId(checks.first);
  }

  Map<String, Object?>? _selectedDiagnostic(List<Map<String, Object?>> checks) {
    if (checks.isEmpty) return null;
    final selectedName = _selectedDiagnosticCheck;
    if (selectedName != null) {
      for (final check in checks) {
        if (_diagnosticId(check) == selectedName) return check;
      }
    }
    return checks.first;
  }

  void _pickDiagnosticCheck(String name) {
    _setSettingsState(() {
      _selectedDiagnosticCheck = name;
      _message = null;
      _error = null;
    });
  }

  Future<void> _openDiagnosticTool(AppWindowType type, {String? taskId}) async {
    try {
      await widget.bridge.openToolWindow(type, taskId: taskId);
      if (!mounted) return;
      _setSettingsState(() {
        _message = '已打开${type.title}';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() {
        _message = null;
        _error = '打开${type.title}失败：${_friendlySettingsError(error)}';
      });
    }
  }

  Future<void> _loadDiagnosticTasks() async {
    _setSettingsState(() {
      _loadingDiagnosticTasks = true;
      _message = null;
      _error = null;
    });
    try {
      final tasks = await _client.taskList();
      if (!mounted) return;
      _setSettingsState(() {
        _diagnosticTasks = tasks;
        final ids = tasks.map((task) => task.taskId).toSet();
        _diagnosticOutputDirectoryResults.removeWhere(
          (taskId, _) => !ids.contains(taskId),
        );
        _message = '已读取 ${tasks.length} 个最近任务。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _loadingDiagnosticTasks = false);
    }
  }

  Future<void> _openDiagnosticResult(TaskSummary task) async {
    if (!task.isDone) return;
    _setSettingsState(() {
      _loadingDiagnosticResult = true;
      _selectedDiagnosticTaskId = task.taskId;
      _diagnosticResult = null;
      _message = null;
      _error = null;
    });
    try {
      final result = await _client.openTaskResult(task.taskId);
      if (!mounted) return;
      _setSettingsState(() {
        _diagnosticResult = result;
        _message = '已读取结果摘要。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _loadingDiagnosticResult = false);
    }
  }

  Future<void> _openDiagnosticTask(TaskSummary task) {
    return _openDiagnosticTool(
      AppWindowType.taskProcessing,
      taskId: task.taskId,
    );
  }

  Future<void> _openDiagnosticTaskId(String taskId) {
    return _openDiagnosticTool(AppWindowType.taskProcessing, taskId: taskId);
  }

  Future<void> _checkDiagnosticOutputDirectory(TaskSummary task) async {
    final dir = _diagnosticOutputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      _setSettingsState(() {
        _selectedDiagnosticTaskId = task.taskId;
        _message = null;
        _error = '这个任务没有结果目录记录。';
      });
      return;
    }
    _setSettingsState(() {
      _selectedDiagnosticTaskId = task.taskId;
      _checkingDiagnosticOutputDirectoryTaskIds.add(task.taskId);
      _message = null;
      _error = null;
    });
    try {
      final result = await _directoryProbe.checkWritable(dir);
      if (!mounted) return;
      _setSettingsState(() {
        _diagnosticOutputDirectoryResults[task.taskId] = result;
        _message = result.ok ? '结果目录可写：$dir' : '结果目录不可写：${result.message}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) {
        _setSettingsState(() {
          _checkingDiagnosticOutputDirectoryTaskIds.remove(task.taskId);
        });
      }
    }
  }

  Future<Map<String, Object?>> _diagnosticSmokeOutputDirectoryCheck(
    DesktopSnapshot? snapshot,
  ) async {
    final task = _diagnosticLatestTask(snapshot);
    if (task == null) {
      return const {
        'diagnostic_output_dir_checked': false,
        'diagnostic_output_dir_writable': false,
        'diagnostic_output_dir_task_id': '',
        'diagnostic_output_dir_path': '',
        'diagnostic_output_dir_message': '没有任务记录',
      };
    }
    final dir = _diagnosticOutputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      return {
        'diagnostic_output_dir_checked': false,
        'diagnostic_output_dir_writable': false,
        'diagnostic_output_dir_task_id': task.taskId,
        'diagnostic_output_dir_path': '',
        'diagnostic_output_dir_message': '没有结果目录记录',
      };
    }
    final result = await _directoryProbe.checkWritable(dir);
    return {
      'diagnostic_output_dir_checked': true,
      'diagnostic_output_dir_writable': result.ok,
      'diagnostic_output_dir_task_id': task.taskId,
      'diagnostic_output_dir_path': dir,
      'diagnostic_output_dir_message': result.message,
    };
  }

  Future<void> _openDiagnosticPath(_DiagnosticPathAction action) async {
    try {
      await _pathOpener.openDirectory(action.path);
      if (!mounted) return;
      _setSettingsState(() {
        _message = action.successMessage;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() {
        _message = null;
        _error = '打开目录失败：${_friendlySettingsError(error)}';
      });
    }
  }
}
