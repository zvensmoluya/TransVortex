part of '../task_processing_window.dart';

extension _TaskProcessingSmoke on _TaskProcessingWindowState {
  Future<void> _runSmokeScenario(TaskSummary selected) async {
    _smokeScenario = _normalizedSmokeScenario(
      widget.smoke?.taskProcessingScenario,
    );
    if (_smokeScenario == 'edit') {
      await _runSmokeEditFlow(selected);
    } else if (_smokeScenario == 'review') {
      TaskSummary? reviewTask;
      for (final task in _tasks) {
        if (task.needsReview) {
          reviewTask = task;
          break;
        }
      }
      if (reviewTask != null && mounted) {
        _setTaskProcessingState(() {
          _taskFilter = _TaskFilter.review;
          _selectedTaskId = reviewTask?.taskId;
          _editingTaskId = null;
        });
      }
    } else if (_smokeScenario == 'failure' ||
        _smokeScenario == 'outputFailure') {
      return;
    } else if (_smokeScenario == 'resume') {
      await _runSmokeResumeFlow(selected);
    } else if (_smokeScenario == 'cancel') {
      await _runSmokeCancelFlow(selected);
    } else {
      await _runSmokeOutputDirectoryCheck(selected);
    }
  }

  Future<void> _runSmokeEditFlow(TaskSummary task) async {
    if (!task.isDone) return;
    await _runSmokeOutputDirectoryCheck(task);
    final result = await _client.openTaskResult(task.taskId);
    _smokeResultSegmentCount = result.segments.length;
    _smokeResultIssueCount = result.issueCount;
    if (result.segments.isEmpty) return;
    final first = result.segments.first;
    _smokeEditedText = '已校对的字幕译文';
    _smokeEditedStart = 0.1;
    _smokeEditedEnd = 1.3;
    final payload = result.segments
        .map(
          (segment) => <String, Object?>{
            ...segment.raw,
            'id': segment.id,
            'start': segment.id == first.id ? _smokeEditedStart : segment.start,
            'end': segment.id == first.id ? _smokeEditedEnd : segment.end,
            'text_src': segment.sourceText,
            'text_tgt': segment.id == first.id
                ? _smokeEditedText
                : segment.targetText,
          },
        )
        .toList();
    final saved = await _client.resultSegmentsSave(task.taskId, payload);
    _smokeTimingSaved = saved.segments.any(
      (segment) =>
          segment.id == first.id &&
          (segment.start - _smokeEditedStart).abs() < 0.0005 &&
          (segment.end - _smokeEditedEnd).abs() < 0.0005,
    );
    _smokeEditSaved =
        _smokeTimingSaved &&
        saved.segments.any((segment) => segment.targetText == _smokeEditedText);
    _smokeResultSegmentCount = saved.segments.length;
    _smokeResultIssueCount = saved.issueCount;
    _smokeReexportFormat = 'ass';
    _smokeReexportBilingual = true;
    _smokeReexportBilingualOrder = 'source_target';
    _smokeReexportPreferSingleLine = false;
    final reexported = await _client.resultReexport(
      task.taskId,
      outputFormat: _smokeReexportFormat,
      bilingual: _smokeReexportBilingual ?? true,
      subtitleBilingualOrder: _smokeReexportBilingualOrder,
      subtitlePreferSingleLine: _smokeReexportPreferSingleLine,
    );
    _smokeReexported = reexported.isNotEmpty;
    _smokeReexportStyleApplied =
        _stringValue(reexported['subtitle_bilingual_order']) ==
            _smokeReexportBilingualOrder &&
        reexported['subtitle_prefer_single_line'] ==
            _smokeReexportPreferSingleLine;
    final outputPaths = _stringMap(reexported['output_paths']);
    final outputPath =
        _stringValue(outputPaths['ass']) ??
        _stringValue(outputPaths['srt']) ??
        _stringValue(outputPaths['vtt']) ??
        _stringValue(outputPaths['lrc']);
    if (outputPath != null && outputPath.isNotEmpty) {
      final output = File(outputPath);
      if (await output.exists()) {
        final text = await output.readAsString(encoding: utf8);
        _smokeOutputContainsEdit = text.contains(_smokeEditedText);
        _smokeOutputUsesRequestedTiming = text.contains(
          'Dialogue: 1,0:00:00.10,0:00:01.30,Target',
        );
        final sourceIndex = text.indexOf(first.sourceText);
        final targetIndex = text.indexOf(_smokeEditedText);
        _smokeReexportOutputUsesRequestedOrder =
            sourceIndex >= 0 && targetIndex >= 0 && sourceIndex < targetIndex;
      }
    }
  }

  Future<void> _runSmokeResumeFlow(TaskSummary task) async {
    if (!task.canResume) return;
    _smokeResumeAttempted = true;
    final result = await _client.submitResume({
      'request_version': 1,
      'task_id': task.taskId,
    });
    _smokeResumeOk = result.taskId == task.taskId && result.status == 'QUEUED';
    _smokeResumeStatus = result.status;
  }

  Future<void> _runSmokeCancelFlow(TaskSummary task) async {
    if (!task.canCancel) return;
    _smokeCancelAttempted = true;
    final result = await _client.cancel(task.taskId);
    _smokeCancelOk =
        result.taskId == task.taskId &&
        (result.status == 'CANCEL_REQUESTED' || result.status == 'CANCELLED');
    _smokeCancelStatus = result.status;
  }

  Future<void> _runSmokeOutputDirectoryCheck(TaskSummary task) async {
    final dir = _outputDirectoryFor(task);
    if (dir == null || dir.isEmpty) return;
    _smokeOutputDirectoryChecked = true;
    _smokeOutputDirectoryPath = dir;
    final result = await _directoryProbe.checkWritable(dir);
    _smokeOutputDirectoryWritable = result.ok;
    _smokeOutputDirectoryMessage = result.message;
  }

  Future<void> _writeSmokeReport({
    required List<TaskSummary> tasks,
    TaskSummary? selected,
    Object? error,
  }) async {
    final smoke = widget.smoke;
    if (smoke == null) return;
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    final payload = <String, Object?>{
      'ok': error == null && tasks.isNotEmpty,
      'status': error == null ? 'ready' : 'error',
      'window_type': AppWindowType.taskProcessing.id,
      'title': AppWindowType.taskProcessing.title,
      'task_processing_scenario': _smokeScenario,
      'task_processing_task_count': tasks.length,
      'task_processing_selected_task_id': selected?.taskId ?? '',
      'task_processing_selected_status': selected?.status ?? '',
      'task_processing_review_task_count': tasks
          .where((task) => task.needsReview)
          .length,
      'task_processing_selected_needs_review': selected?.needsReview ?? false,
      'task_processing_selected_review_issue_count':
          selected?.reviewIssueCount ?? 0,
      'task_processing_selected_quality_status': selected?.qualityStatus ?? '',
      'task_processing_selected_delivery_status':
          selected?.deliveryStatus ?? '',
      'task_processing_editor_visible':
          selected?.isDone == true && _editingTaskId == selected?.taskId,
      'task_processing_model_request_count': selected?.modelRequestCount ?? 0,
      'task_processing_model_request_counts':
          selected?.modelRequestCounts ?? const <String, int>{},
      'task_processing_result_segment_count': _smokeResultSegmentCount,
      'task_processing_result_issue_count': _smokeResultIssueCount,
      'task_processing_edit_saved': _smokeEditSaved,
      'task_processing_reexported': _smokeReexported,
      'task_processing_reexport_output_contains_edit': _smokeOutputContainsEdit,
      'task_processing_edited_text': _smokeEditedText,
      'task_processing_edited_start': _smokeEditedStart,
      'task_processing_edited_end': _smokeEditedEnd,
      'task_processing_timing_saved': _smokeTimingSaved,
      'task_processing_reexport_output_uses_requested_timing':
          _smokeOutputUsesRequestedTiming,
      'task_processing_reexport_format': _smokeReexportFormat,
      'task_processing_reexport_bilingual': _smokeReexportBilingual,
      'task_processing_reexport_bilingual_order': _smokeReexportBilingualOrder,
      'task_processing_reexport_prefer_single_line':
          _smokeReexportPreferSingleLine,
      'task_processing_reexport_style_applied': _smokeReexportStyleApplied,
      'task_processing_reexport_output_uses_requested_order':
          _smokeReexportOutputUsesRequestedOrder,
      'task_processing_resume_attempted': _smokeResumeAttempted,
      'task_processing_resume_ok': _smokeResumeOk,
      'task_processing_resume_status': _smokeResumeStatus,
      'task_processing_cancel_attempted': _smokeCancelAttempted,
      'task_processing_cancel_ok': _smokeCancelOk,
      'task_processing_cancel_status': _smokeCancelStatus,
      'task_processing_output_dir_checked': _smokeOutputDirectoryChecked,
      'task_processing_output_dir_writable': _smokeOutputDirectoryWritable,
      'task_processing_output_dir_path': _smokeOutputDirectoryPath,
      'task_processing_output_dir_message': _smokeOutputDirectoryMessage,
      'error': error == null ? '' : '$error',
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };
    payload.addAll(_taskDiagnosticSmokeFields(selected));
    payload.addAll(
      await captureSmokeRender(
        boundaryKey: _renderKey,
        path: smoke.screenshotPath,
      ),
    );
    if (smoke.screenshotPath != null) {
      payload['ok'] =
          payload['ok'] == true && payload['render_capture_ok'] == true;
    }
    await reportFile.writeAsString(jsonEncode(payload), encoding: utf8);
    final hold = smoke.postReportVisibleDuration;
    if (hold > Duration.zero) {
      await Future<void>.delayed(hold);
    }
    if (!mounted) return;
    try {
      await _smokeService?.shutdown();
      await windowManager.close();
    } on Object {
      exit(0);
    }
  }
}
