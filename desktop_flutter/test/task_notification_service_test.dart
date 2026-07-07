import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:transvortex_desktop_flutter/model/main_window_controller.dart';
import 'package:transvortex_desktop_flutter/model/session.dart';
import 'package:transvortex_desktop_flutter/services/task_notification_service.dart';

void main() {
  test('observer notifies only task terminal transitions', () {
    final service = _RecordingTaskNotificationService();
    final observer = TaskNotificationObserver(service);

    observer.handle(_view(MainState.empty));
    observer.handle(_view(MainState.failed));
    observer.handle(_view(MainState.running));
    observer.handle(_view(MainState.running));
    observer.handle(_view(MainState.completed));
    observer.handle(_view(MainState.completed));

    expect(service.completed, ['movie.mp4']);
    expect(service.failed, isEmpty);

    observer.handle(_view(MainState.running));
    observer.handle(_view(MainState.failed, failureReason: '翻译服务连不上'));
    observer.handle(_view(MainState.failed, failureReason: '翻译服务连不上'));

    expect(service.completed, ['movie.mp4']);
    expect(service.failed, ['翻译服务连不上']);
  });

  test('observer resets notification guard when source changes', () {
    final service = _RecordingTaskNotificationService();
    final observer = TaskNotificationObserver(service);

    observer.handle(_view(MainState.running, path: r'D:\a.mp4', name: 'a.mp4'));
    observer.handle(
      _view(MainState.completed, path: r'D:\a.mp4', name: 'a.mp4'),
    );
    observer.handle(_view(MainState.running, path: r'D:\b.mp4', name: 'b.mp4'));
    observer.handle(
      _view(MainState.completed, path: r'D:\b.mp4', name: 'b.mp4'),
    );

    expect(service.completed, ['a.mp4', 'b.mp4']);
  });

  test('observer resets notification guard when task id changes', () {
    final service = _RecordingTaskNotificationService();
    final observer = TaskNotificationObserver(service);

    observer.handle(_view(MainState.running, taskId: 'tvx_1'));
    observer.handle(_view(MainState.completed, taskId: 'tvx_1'));
    observer.handle(_view(MainState.running, taskId: 'tvx_2'));
    observer.handle(_view(MainState.completed, taskId: 'tvx_2'));

    expect(service.completed, ['movie.mp4', 'movie.mp4']);
  });

  test('windows notification service respects foreground gate', () async {
    final sink = _RecordingWindowsNotificationSink();
    final service = WindowsTaskNotificationService(
      sink: sink,
      shouldNotify: (_) => false,
    );

    await service.notifyCompleted(_view(MainState.completed));

    expect(sink.shown, isEmpty);
  });

  test(
    'windows notification service shows terminal toasts and handles activation',
    () async {
      final sink = _RecordingWindowsNotificationSink();
      final activations = <String?>[];
      final service = WindowsTaskNotificationService(
        sink: sink,
        shouldNotify: (_) => true,
        onActivated: activations.add,
      );

      await service.notifyCompleted(_view(MainState.completed));
      await service.notifyFailed(
        _view(MainState.failed, failureReason: '翻译服务连不上'),
      );
      service.handleActivation('task:tvx_1:completed');

      expect(sink.shown.map((item) => item.title), ['字幕已生成', '制作失败']);
      expect(sink.shown.first.payload, 'task:tvx_1:completed');
      expect(sink.shown.last.body, '翻译服务连不上');
      expect(activations, ['task:tvx_1:completed']);
    },
  );

  test(
    'windows notification payload avoids leaking local source paths',
    () async {
      final sink = _RecordingWindowsNotificationSink();
      final service = WindowsTaskNotificationService(
        sink: sink,
        shouldNotify: (_) => true,
      );

      await service.notifyCompleted(_view(MainState.completed, taskId: null));

      expect(sink.shown.single.payload, startsWith('task:local-'));
      expect(sink.shown.single.payload, endsWith(':completed'));
      expect(sink.shown.single.payload, isNot(contains(r'D:\movie.mp4')));
    },
  );
}

MainWindowViewModel _view(
  MainState state, {
  String path = r'D:\movie.mp4',
  String name = 'movie.mp4',
  String? taskId = 'tvx_1',
  String? failureReason,
}) {
  return MainWindowViewModel(
    state: state,
    statusLine: '',
    taskId: taskId,
    source: MainSourceDraft(name: name, path: path, kind: SourceKind.video),
    translationLabel: 'RealProvider · real-model',
    translationConfigured: true,
    asrLabel: '本机 · large-v3',
    asrConfigured: true,
    translationOptions: const [],
    asrOptions: const [],
    bilingual: true,
    formats: const ['SRT', 'ASS'],
    termsEnabled: true,
    runningText: null,
    progress: state == MainState.completed ? 1 : 0,
    canceling: false,
    outputPaths: const {},
    outputDirectory: null,
    failure: failureReason == null
        ? null
        : MainFailureView(
            reason: failureReason,
            actionLabel: '重试',
            target: MainRecoveryTarget.retry,
          ),
    homeTaskReminder: null,
    submitting: false,
  );
}

class _RecordingTaskNotificationService implements TaskNotificationService {
  final completed = <String>[];
  final failed = <String>[];

  @override
  Future<void> notifyCompleted(MainWindowViewModel view) async {
    completed.add(view.source?.name ?? '');
  }

  @override
  Future<void> notifyFailed(MainWindowViewModel view) async {
    failed.add(view.failure?.reason ?? '');
  }
}

class _RecordingWindowsNotificationSink implements WindowsNotificationSink {
  final shown = <_ShownNotification>[];

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required WindowsNotificationDetails notificationDetails,
  }) async {
    shown.add(_ShownNotification(id, title, body, payload));
  }
}

class _ShownNotification {
  const _ShownNotification(this.id, this.title, this.body, this.payload);

  final int id;
  final String title;
  final String body;
  final String payload;
}
