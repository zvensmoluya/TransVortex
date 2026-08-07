part of '../task_processing_window.dart';

extension _TaskProcessingData on _TaskProcessingWindowState {
  Future<void> _loadTasks() async {
    _setTaskProcessingState(() {
      _loadingTasks = true;
      _message = null;
      _error = null;
    });
    try {
      final tasks = await _client.taskList();
      if (!mounted) return;
      final selected = _selectedTask(
        _visibleTasksFor(tasks, _taskFilter, _taskSearchController.text),
      );
      final previousTaskId = _selectedTaskId;
      _setTaskProcessingState(() {
        _tasks = tasks;
        _selectedTaskId = selected?.taskId;
        if (previousTaskId != selected?.taskId) {
          _setEventSearchTextSilently('');
        }
        _loadingTasks = false;
        _message = tasks.isEmpty ? '还没有任务记录。' : '已读取 ${tasks.length} 个任务。';
      });
      if (selected != null) {
        if (widget.smoke != null) {
          await _loadEvents(selected.taskId);
        } else {
          unawaited(_loadEvents(selected.taskId));
        }
      }
      if (widget.smoke != null) {
        var reportTasks = tasks;
        var reportSelected = selected;
        if (selected != null) {
          await _runSmokeScenario(selected);
          if (_smokeScenario == 'review') {
            reportSelected = _selectedTask(
              _visibleTasksFor(
                reportTasks,
                _taskFilter,
                _taskSearchController.text,
              ),
            );
          } else if (_smokeScenario == 'edit') {
            reportTasks = await _client.taskList();
            reportSelected = _selectedTask(reportTasks);
            if (mounted && reportSelected != null) {
              _setTaskProcessingState(() {
                _tasks = reportTasks;
                _selectedTaskId = reportSelected?.taskId;
                _editingTaskId = null;
              });
              await WidgetsBinding.instance.endOfFrame;
              if (mounted) {
                _setTaskProcessingState(
                  () => _editingTaskId = reportSelected?.taskId,
                );
                await Future<void>.delayed(const Duration(milliseconds: 300));
                if (mounted) await WidgetsBinding.instance.endOfFrame;
              }
            }
          } else if (_smokeScenario == 'resume' || _smokeScenario == 'cancel') {
            reportTasks = await _client.taskList();
            reportSelected = _selectedTask(reportTasks);
            if (mounted) {
              _setTaskProcessingState(() {
                _tasks = reportTasks;
                _selectedTaskId = reportSelected?.taskId;
              });
            }
          }
        }
        await _writeSmokeReport(tasks: reportTasks, selected: reportSelected);
      }
    } on Object catch (error) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _error = _friendlyTaskProcessingError(error);
        _loadingTasks = false;
      });
      if (widget.smoke != null) {
        await _writeSmokeReport(tasks: const [], error: error);
      }
    }
  }

  Future<void> _retarget(AppWindowArgs args) async {
    if (args.type != AppWindowType.taskProcessing) return;
    final taskId = args.taskId?.trim();
    if (taskId != null && taskId.isNotEmpty) {
      if (taskId != _editingTaskId && !await _leaveResultEditor()) return;
      _setTaskSearchTextSilently('');
      _setEventSearchTextSilently('');
      _selectedTaskId = taskId;
      _editingTaskId = taskId;
      _resultEditorDirty = false;
      _taskFilter = _TaskFilter.all;
    }
    await _loadTasks();
  }

  List<TaskSummary> _visibleTasksFor(
    List<TaskSummary> tasks,
    _TaskFilter filter,
    String searchQuery,
  ) {
    return tasks
        .where(
          (task) =>
              _taskMatchesFilter(task, filter) &&
              _taskMatchesSearch(task, searchQuery),
        )
        .toList(growable: false);
  }

  Map<_TaskFilter, int> _taskFilterCounts(
    List<TaskSummary> tasks,
    String searchQuery,
  ) {
    return {
      for (final filter in _TaskFilter.values)
        filter: tasks
            .where(
              (task) =>
                  _taskMatchesFilter(task, filter) &&
                  _taskMatchesSearch(task, searchQuery),
            )
            .length,
    };
  }

  TaskSummary? _selectedTask(List<TaskSummary> tasks) {
    if (tasks.isEmpty) return null;
    final selectedId = _selectedTaskId?.trim();
    if (selectedId != null && selectedId.isNotEmpty) {
      for (final task in tasks) {
        if (task.taskId == selectedId) return task;
      }
    }
    return tasks.first;
  }

  Future<void> _setTaskFilter(_TaskFilter filter) async {
    if (_taskFilter == filter) return;
    if (!await _leaveResultEditor()) return;
    final visibleTasks = _visibleTasksFor(
      _tasks,
      filter,
      _taskSearchController.text,
    );
    final selected = _selectedTask(visibleTasks);
    final previousTaskId = _selectedTaskId;
    _setTaskProcessingState(() {
      _taskFilter = filter;
      _selectedTaskId = selected?.taskId;
      _editingTaskId = null;
      _resultEditorDirty = false;
      if (previousTaskId != selected?.taskId) {
        _setEventSearchTextSilently('');
      }
      _message = null;
      _error = null;
    });
    if (selected != null) {
      await _loadEvents(selected.taskId);
    }
  }

  void _handleTaskSearchChanged() {
    if (!mounted) return;
    if (_resultEditorDirty) return;
    final visibleTasks = _visibleTasksFor(
      _tasks,
      _taskFilter,
      _taskSearchController.text,
    );
    final selected = _selectedTask(visibleTasks);
    final previousTaskId = _selectedTaskId;
    final nextTaskId = selected?.taskId;
    _setTaskProcessingState(() {
      _selectedTaskId = nextTaskId;
      if (previousTaskId != nextTaskId) {
        _editingTaskId = null;
        _setEventSearchTextSilently('');
      }
      _message = null;
      _error = null;
    });
    if (selected != null && previousTaskId != nextTaskId) {
      unawaited(_loadEvents(selected.taskId));
    }
  }

  void _setTaskSearchTextSilently(String text) {
    _taskSearchController.removeListener(_handleTaskSearchChanged);
    _taskSearchController.text = text;
    _taskSearchController.addListener(_handleTaskSearchChanged);
  }

  void _handleEventSearchChanged() {
    if (mounted) _setTaskProcessingState(() {});
  }

  void _setEventSearchTextSilently(String text) {
    _eventSearchController.removeListener(_handleEventSearchChanged);
    _eventSearchController.text = text;
    _eventSearchController.addListener(_handleEventSearchChanged);
  }

  Future<void> _selectTask(TaskSummary task) async {
    if (_selectedTaskId == task.taskId && _eventsPage?.taskId == task.taskId) {
      return;
    }
    if (!await _leaveResultEditor()) return;
    _setTaskProcessingState(() {
      _selectedTaskId = task.taskId;
      _editingTaskId = null;
      _resultEditorDirty = false;
      _setEventSearchTextSilently('');
      _message = null;
      _error = null;
    });
    await _loadEvents(task.taskId);
  }

  Future<void> _loadEvents(String taskId) async {
    _setTaskProcessingState(() {
      _loadingEvents = true;
      _loadingMoreEvents = false;
    });
    try {
      final events = await _client.taskEvents(taskId, limit: 40);
      if (!mounted) return;
      _setTaskProcessingState(() {
        _eventsPage = events;
        _loadingEvents = false;
        _loadingMoreEvents = false;
      });
    } on Object catch (_) {
      if (!mounted) return;
      _setTaskProcessingState(() {
        _eventsPage = null;
        _loadingEvents = false;
        _loadingMoreEvents = false;
      });
    }
  }

  Future<void> _loadMoreEvents(String taskId) async {
    final current = _eventsPage;
    if (current == null || !current.hasMore || _loadingMoreEvents) return;
    _setTaskProcessingState(() {
      _loadingMoreEvents = true;
      _error = null;
    });
    try {
      final next = await _client.taskEvents(
        taskId,
        cursor: current.nextCursor,
        limit: 40,
      );
      if (!mounted || _selectedTaskId != taskId) return;
      _setTaskProcessingState(() {
        _eventsPage = TaskEventsPage(
          taskId: next.taskId.isEmpty ? taskId : next.taskId,
          events: [...current.events, ...next.events],
          cursor: current.cursor,
          nextCursor: next.nextCursor,
          hasMore: next.hasMore,
        );
        _loadingMoreEvents = false;
      });
    } on Object catch (error) {
      if (!mounted || _selectedTaskId != taskId) return;
      _setTaskProcessingState(() {
        _error = '读取更多事件失败：${_friendlyTaskProcessingError(error)}';
        _loadingMoreEvents = false;
      });
    }
  }
}
