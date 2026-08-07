import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/desktop_app_paths.dart';

class FakeRpcTransport implements AppServiceTransport {
  FakeRpcTransport(this.results);

  final Map<String, Object?> results;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class RecordingRpcTransport implements AppServiceTransport {
  RecordingRpcTransport(this.results);

  final Map<String, Object?> results;
  final List<RecordedRpcCall> calls = [];

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(RecordedRpcCall(method, params));
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class RecordedRpcCall {
  const RecordedRpcCall(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}

bool hasEmbeddedSubtitleSmokeTools() {
  try {
    final ffmpeg = Process.runSync('ffmpeg', const ['-version']);
    final ffprobe = Process.runSync('ffprobe', const ['-version']);
    return ffmpeg.exitCode == 0 && ffprobe.exitCode == 0;
  } on Object {
    return false;
  }
}

Future<File> writeEmbeddedSubtitleVideo(Directory root) async {
  final subtitle = File('${root.path}${Platform.pathSeparator}demo.en.srt');
  subtitle.writeAsStringSync(
    '1\n'
    '00:00:00,000 --> 00:00:00,800\n'
    'Hello from subtitle\n',
    encoding: utf8,
  );
  final video = File('${root.path}${Platform.pathSeparator}demo.mkv');
  final result = await Process.run('ffmpeg', [
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=black:s=160x90:d=1',
    '-f',
    'srt',
    '-i',
    subtitle.path,
    '-map',
    '0:v:0',
    '-map',
    '1:s:0',
    '-c:v',
    'ffv1',
    '-c:s',
    'srt',
    '-metadata:s:s:0',
    'language=eng',
    video.path,
  ]);
  if (result.exitCode != 0) {
    fail('ffmpeg could not create embedded-subtitle fixture: ${result.stderr}');
  }
  return video;
}

Future<File> writeAudioVideo(Directory root) async {
  final video = File('${root.path}${Platform.pathSeparator}demo_audio.mkv');
  final result = await Process.run('ffmpeg', [
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=black:s=160x90:d=1',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:duration=1',
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    '-c:v',
    'ffv1',
    '-c:a',
    'aac',
    '-shortest',
    video.path,
  ]);
  if (result.exitCode != 0) {
    fail('ffmpeg could not create audio-video fixture: ${result.stderr}');
  }
  return video;
}

Future<void> waitForSlowAsrRequestOrFail(
  SlowAsrServer slowAsr, {
  required AppServiceClient client,
  required JsonRpcTransport transport,
  required Directory serviceRoot,
  required String taskId,
  Duration timeout = const Duration(seconds: 45),
}) async {
  try {
    await slowAsr.firstRequest.timeout(timeout);
  } on TimeoutException catch (error) {
    fail(
      'slow ASR server did not receive a request within '
      '${timeout.inSeconds}s: $error\n'
      '${await workerSmokeDiagnostics(client, transport, serviceRoot, taskId)}',
    );
  }
}

Future<String> workerSmokeDiagnostics(
  AppServiceClient client,
  JsonRpcTransport transport,
  Directory serviceRoot,
  String taskId,
) async {
  final lines = <String>[];
  try {
    final health = await client.health();
    lines.add('health=${health.status}; pump=${jsonEncode(health.pump)}');
  } on Object catch (error) {
    lines.add('health_error=$error');
  }
  try {
    final snapshot = await client.desktopSnapshot();
    final task = snapshot.taskById(taskId);
    lines.add(
      'task=${task?.status ?? 'missing'}; checkpoint=${task?.displayStatus ?? 'missing'}; '
      'error=${task?.error ?? ''}; runtime=${jsonEncode(task?.runtime ?? {})}',
    );
    lines.add('runtime=${jsonEncode(snapshot.runtime)}');
  } on Object catch (error) {
    lines.add('snapshot_error=$error');
  }
  try {
    final events = await client.taskEvents(taskId);
    lines.add('events=${eventTypeSummary(events.events)}');
  } on Object catch (error) {
    lines.add('events_error=$error');
  }
  lines.add('transport_diagnostics=${transport.diagnosticLines.join(' | ')}');
  final taskDir = Directory(
    '${serviceRoot.path}${Platform.pathSeparator}artifacts'
    '${Platform.pathSeparator}$taskId',
  );
  for (final relativePath in const [
    'runtime_request.json',
    'worker.json',
    'checkpoint.json',
    'worker/stdout.log',
    'worker/stderr.log',
  ]) {
    final file = File(
      '${taskDir.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    if (file.existsSync()) {
      lines.add('$relativePath=${tailFile(file)}');
    } else {
      lines.add('$relativePath=<missing>');
    }
  }
  return lines.join('\n');
}

String eventTypeSummary(List<Object?> events) {
  if (events.isEmpty) return '<none>';
  return events
      .map((event) {
        if (event is! Map) return '<non-map>';
        final type = event['type'] ?? '?';
        final stage = event['stage'] ?? '';
        final message = event['message'] ?? '';
        return '$type/$stage/$message';
      })
      .join(' | ');
}

String tailFile(File file, {int maxChars = 4000}) {
  try {
    final text = file.readAsStringSync(encoding: utf8);
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  } on Object catch (error) {
    return '<read_error: $error>';
  }
}

class SlowAsrServer {
  SlowAsrServer._(this._server);

  final HttpServer _server;
  final _firstRequest = Completer<void>();
  final _release = Completer<void>();

  int get port => _server.port;
  Future<void> get firstRequest => _firstRequest.future;

  static Future<SlowAsrServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = SlowAsrServer._(server);
    unawaited(instance._serve());
    return instance;
  }

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  Future<void> close() async {
    release();
    await _server.close(force: true);
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      await request.drain<void>();
      if (!_firstRequest.isCompleted) {
        _firstRequest.complete();
      }
      await _release.future.timeout(const Duration(seconds: 20));
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'text': 'hello from slow asr',
          'segments': [
            {'start': 0.0, 'end': 0.8, 'text': 'hello from slow asr'},
          ],
        }),
      );
    } on Object catch (error, stackTrace) {
      if (!_firstRequest.isCompleted) {
        _firstRequest.completeError(error, stackTrace);
      }
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('slow asr error');
    } finally {
      await request.response.close();
    }
  }
}

Future<TaskSummary> waitForTerminalTask(
  AppServiceClient client,
  String taskId, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  TaskSummary? latest;
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await client.desktopSnapshot();
    latest = snapshot.taskById(taskId);
    if (latest?.isTerminal == true) {
      return latest!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  final status = latest == null
      ? 'not found in desktop snapshot'
      : '${latest.status}: ${latest.error ?? ''}';
  fail('task $taskId did not reach a terminal state: $status');
}

Future<void> deleteDirectoryWithRetries(Directory directory) async {
  Object? lastError;
  StackTrace? lastStackTrace;
  for (var attempt = 0; attempt < 10; attempt += 1) {
    if (!await directory.exists()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on Object catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
  if (lastError != null) {
    Error.throwWithStackTrace(lastError, lastStackTrace ?? StackTrace.current);
  }
}

DesktopAppPaths desktopPathsFixture(Directory appDataRoot) {
  final workspaceRoot = Directory(
    '${appDataRoot.path}${Platform.pathSeparator}Workspace',
  );
  return DesktopAppPaths(
    appDataRoot: appDataRoot,
    configRoot: Directory('${appDataRoot.path}${Platform.pathSeparator}Config'),
    workspaceRoot: workspaceRoot,
    tasksRoot: Directory('${workspaceRoot.path}${Platform.pathSeparator}Tasks'),
    cacheRoot: Directory('${workspaceRoot.path}${Platform.pathSeparator}Cache'),
  );
}

class FakeProcess implements Process {
  final _exit = Completer<int>();
  bool killed = false;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 12345;

  @override
  IOSink get stdin => FakeSink();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) {
      _exit.complete(0);
    }
    return true;
  }
}

class FakeSink implements IOSink {
  final writes = <Object?>[];
  bool closed = false;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => writes.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => writes.add(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    writes.add(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) => writes.add(charCode);

  @override
  void writeln([Object? object = '']) => writes.add('$object\n');
}

class ControlledFlushSink implements IOSink {
  final writes = <Object?>[];
  final firstFlushStarted = Completer<void>();
  final secondFlushStarted = Completer<void>();
  Completer<void>? _activeFlush;
  int _flushCount = 0;
  bool closed = false;

  @override
  Encoding encoding = utf8;

  void _checkWritable() {
    final active = _activeFlush;
    if (active != null && !active.isCompleted) {
      throw StateError('StreamSink is bound to a stream');
    }
  }

  void releaseFlush() {
    final active = _activeFlush;
    if (active != null && !active.isCompleted) active.complete();
  }

  @override
  void add(List<int> data) {
    _checkWritable();
    writes.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    _checkWritable();
    await for (final data in stream) {
      writes.add(data);
    }
  }

  @override
  Future<void> close() async {
    releaseFlush();
    closed = true;
  }

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() {
    _checkWritable();
    final completer = Completer<void>();
    _activeFlush = completer;
    _flushCount += 1;
    if (_flushCount == 1) firstFlushStarted.complete();
    if (_flushCount == 2) secondFlushStarted.complete();
    return completer.future.whenComplete(() {
      if (identical(_activeFlush, completer)) _activeFlush = null;
    });
  }

  @override
  void write(Object? object) {
    _checkWritable();
    writes.add(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _checkWritable();
    writes.add(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    _checkWritable();
    writes.add(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    _checkWritable();
    writes.add('$object\n');
  }
}
