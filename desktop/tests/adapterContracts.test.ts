import assert from "node:assert/strict";
import { test } from "node:test";
import { resultWorkspaceToSegments, segmentsToSavePayload } from "../src/adapters/resultWorkspaceAdapter";
import { taskRecordToTask } from "../src/adapters/taskRecordAdapter";
import { taskToPresentation } from "../src/adapters/taskPresentationAdapter";
import { normalizeWorkerEvents, workerEventToTimelineEvent } from "../src/adapters/workerEventAdapter";

test("task record adapter maps the CLI task payload contract", () => {
  const task = taskRecordToTask({
    task_id: "task-20260527-001",
    status: "DONE",
    input_file: "D:\\media\\sample.srt",
    source_lang: "en",
    target_lang: "zh-CN",
    output_paths: {
      srt: "D:\\openai\\TransVortex\\artifacts\\task-20260527-001\\output\\sample.zh-CN.srt",
      ass: "D:\\openai\\TransVortex\\artifacts\\task-20260527-001\\output\\sample.zh-CN.ass",
    },
    task_dir: "D:\\openai\\TransVortex\\artifacts\\task-20260527-001",
    progress_detail: { stage: "EXPORT" },
    created_at: "2026-05-27T01:00:00Z",
    updated_at: "2026-05-27T01:05:00Z",
    settings: { input_type: "srt_translate" },
  });

  assert.equal(task.id, "task-20260527-001");
  assert.equal(task.status, "completed");
  assert.equal(task.input.kind, "subtitle");
  assert.equal(task.input.path, "D:\\media\\sample.srt");
  assert.equal(task.input.displayName, "sample.srt");
  assert.equal(task.taskDirectory, "D:\\openai\\TransVortex\\artifacts\\task-20260527-001");
  assert.deepEqual(task.outputs.map((file) => file.format), ["srt", "ass"]);
  assert.equal(task.recoverability.canResume, false);
});

test("task record adapter only marks failed or cancelled records resumable", () => {
  assert.equal(taskRecordToTask({ task_id: "running", status: "RUNNING" }).recoverability.canResume, false);
  assert.equal(taskRecordToTask({ task_id: "failed", status: "FAILED" }).recoverability.canResume, true);
  assert.equal(taskRecordToTask({ task_id: "cancelled", status: "CANCELLED" }).recoverability.canResume, true);
});

test("worker event adapter maps task store events and progress consistently", () => {
  const event = workerEventToTimelineEvent({
    type: "stage",
    task_id: "task-20260527-001",
    created_at: "2026-05-27T01:02:00Z",
    stage: "TRANSLATE",
    progress: 0.5234,
    message: "Translating chunk 2",
  });

  assert.equal(event.taskId, "task-20260527-001");
  assert.equal(event.at, "2026-05-27T01:02:00Z");
  assert.equal(event.phase, "translation");
  assert.equal(event.progressPercent, 52.34);

  const run = normalizeWorkerEvents("task-20260527-001", {
    events: [
      { type: "stage", task_id: "task-20260527-001", created_at: "2026-05-27T01:01:00Z", stage: "INGEST", progress: 0.2 },
      { type: "done", task_id: "task-20260527-001", created_at: "2026-05-27T01:05:00Z", stage: "DONE", progress: 1 },
    ],
  });

  assert.equal(run.taskId, "task-20260527-001");
  assert.equal(run.phase, "completed");
  assert.equal(run.progress.percent, 100);
  assert.equal(run.timeline.length, 2);
  assert.equal(run.canCancel, false);

  const running = normalizeWorkerEvents("task-20260527-002", {
    events: [{ type: "stage", task_id: "task-20260527-002", created_at: "2026-05-27T01:01:00Z", stage: "TRANSLATE", progress: 0.4 }],
  });
  assert.equal(running.canCancel, true);

  const cancelled = normalizeWorkerEvents("task-20260527-003", {
    events: [{ type: "cancelled", task_id: "task-20260527-003", created_at: "2026-05-27T01:01:00Z", stage: "CANCELLED" }],
  });
  assert.equal(cancelled.phase, "failed");
  assert.equal(cancelled.canCancel, false);
});

test("result workspace adapter preserves numeric segment ids through edit save payloads", () => {
  const segments = resultWorkspaceToSegments({
    segments: [
      {
        id: 7,
        index: 7,
        start: 12.3,
        end: 15,
        text_src: "hello",
        text_tgt: "你好",
        quality_issues: [{ code: "line_too_long", level: "warning", message: "Line is long" }],
      },
    ],
  });

  assert.equal(segments.length, 1);
  assert.equal(segments[0].id, "7");
  assert.equal(segments[0].startMs, 12300);
  assert.equal(segments[0].issues[0].title, "单行过长");

  const payload = segmentsToSavePayload([{ ...segments[0], translatedText: "你好。" }]);
  assert.deepEqual(payload, [
    {
      id: 7,
      start: 12.3,
      end: 15,
      text_src: "hello",
      text_tgt: "你好。",
    },
  ]);
});

test("task presentation maps completed task review and output actions", () => {
  const task = taskRecordToTask({
    task_id: "task-20260527-001",
    status: "DONE",
    input_file: "D:\\media\\sample.srt",
    source_lang: "en",
    target_lang: "zh-CN",
    output_paths: {
      srt: "D:\\openai\\TransVortex\\artifacts\\task-20260527-001\\output\\sample.zh-CN.srt",
    },
    task_dir: "D:\\openai\\TransVortex\\artifacts\\task-20260527-001",
    created_at: "2026-05-27T01:00:00Z",
    updated_at: "2026-05-27T01:05:00Z",
  });
  const presentation = taskToPresentation({ task });

  assert.equal(presentation.title, "sample.srt");
  assert.equal(presentation.statusLabel, "已完成");
  assert.equal(presentation.stage.label, "任务已完成");
  assert.equal(presentation.actions.reviewResult.enabled, true);
  assert.equal(presentation.actions.openPrimaryOutput.enabled, true);
  assert.equal(presentation.actions.cancel.visible, false);
  assert.equal(presentation.delivery.files[0].statusLabel, "已导出");
});

test("task presentation centralizes running cancellation and recovery actions", () => {
  const runningTask = taskRecordToTask({
    task_id: "task-20260527-002",
    status: "RUNNING",
    input_file: "D:\\media\\movie.mp4",
    source_lang: "en",
    target_lang: "zh-CN",
    created_at: "2026-05-27T01:00:00Z",
    updated_at: "2026-05-27T01:02:00Z",
  });
  const runningRun = normalizeWorkerEvents("task-20260527-002", {
    events: [{ type: "stage", task_id: "task-20260527-002", created_at: "2026-05-27T01:01:00Z", stage: "TRANSLATE", progress: 0.4 }],
  });
  const running = taskToPresentation({ task: runningTask, taskRun: runningRun });

  assert.equal(running.stage.phase, "translation");
  assert.equal(running.actions.cancel.visible, true);
  assert.equal(running.actions.cancel.enabled, true);
  assert.equal(running.actions.resume.visible, false);
  assert.equal(running.actions.resume.enabled, false);
  assert.equal(running.actions.reviewResult.enabled, false);

  const cancelledTask = taskRecordToTask({
    task_id: "task-20260527-003",
    status: "CANCELLED",
    input_file: "D:\\media\\movie.mp4",
    created_at: "2026-05-27T01:00:00Z",
    updated_at: "2026-05-27T01:02:00Z",
  });
  const cancelled = taskToPresentation({ task: cancelledTask });
  assert.equal(cancelled.actions.resume.visible, true);
  assert.equal(cancelled.actions.resume.enabled, true);
  assert.equal(cancelled.actions.cancel.visible, false);
});

test("task presentation maps saved result workspace to pending reexport semantics", () => {
  const task = taskRecordToTask({
    task_id: "task-20260527-004",
    status: "DONE",
    input_file: "D:\\media\\sample.srt",
    output_paths: {
      srt: "D:\\openai\\TransVortex\\artifacts\\task-20260527-004\\output\\sample.zh-CN.srt",
    },
    created_at: "2026-05-27T01:00:00Z",
    updated_at: "2026-05-27T01:05:00Z",
  });
  const [segment] = resultWorkspaceToSegments({
    segments: [{ id: 1, start: 0, end: 2, text_src: "hello", text_tgt: "你好" }],
  });
  const presentation = taskToPresentation({
    task,
    workspace: {
      segments: [{ ...segment, translatedText: "你好。", dirtyState: "savedPendingExport" }],
      saveState: "savedPendingExport",
      exportJob: {
        id: "export-idle",
        taskId: task.id,
        formats: [],
        status: "idle",
      },
    },
  });

  assert.equal(presentation.workspace?.saveStateLabel, "已保存，待重新导出");
  assert.equal(presentation.workspace?.outputStateLabel, "待重新导出");
  assert.equal(presentation.delivery.files[0].statusLabel, "待重新导出");
  assert.deepEqual(presentation.delivery.formatsForReexport, ["srt"]);
  assert.equal(presentation.actions.saveResult.enabled, false);
  assert.equal(presentation.actions.reexport.enabled, true);
});
