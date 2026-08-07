import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'app_service_test_support.dart';

void main() {
  test('JsonRpcTransport matches responses by id', () async {
    final stdout = StreamController<List<int>>();
    final stdin = FakeSink();
    final exit = Completer<int>();
    final transport = JsonRpcTransport(
      stdout: stdout.stream,
      stdin: stdin,
      exitCode: exit.future,
      defaultTimeout: const Duration(seconds: 1),
    );

    final first = transport.call('service.info');
    final second = transport.call('service.health');
    stdout.add(
      utf8.encode('{"jsonrpc":"2.0","id":2,"result":{"status":"healthy"}}\n'),
    );
    stdout.add(
      utf8.encode(
        '{"jsonrpc":"2.0","id":1,"result":{"service":"transvortex.app_service"}}\n',
      ),
    );

    expect(await first, {'service': 'transvortex.app_service'});
    expect(await second, {'status': 'healthy'});
    await transport.close();
    await stdout.close();
  });

  test('JsonRpcTransport serializes writes across sink flushes', () async {
    final stdout = StreamController<List<int>>();
    final stdin = ControlledFlushSink();
    final exit = Completer<int>();
    final transport = JsonRpcTransport(
      stdout: stdout.stream,
      stdin: stdin,
      exitCode: exit.future,
      defaultTimeout: const Duration(seconds: 1),
    );

    final first = transport.call('service.info');
    final second = transport.call('service.health');

    await stdin.firstFlushStarted.future;
    expect(stdin.writes, hasLength(1));
    expect(stdin.secondFlushStarted.isCompleted, isFalse);

    stdin.releaseFlush();
    await stdin.secondFlushStarted.future;
    expect(stdin.writes, hasLength(2));
    stdin.releaseFlush();

    stdout.add(
      utf8.encode('{"jsonrpc":"2.0","id":1,"result":{"service":"ready"}}\n'),
    );
    stdout.add(
      utf8.encode('{"jsonrpc":"2.0","id":2,"result":{"status":"healthy"}}\n'),
    );

    expect(await first, {'service': 'ready'});
    expect(await second, {'status': 'healthy'});
    await transport.close();
    await stdout.close();
  });

  test(
    'JsonRpcTransport surfaces RPC errors and ignores non JSON diagnostics',
    () async {
      final stdout = StreamController<List<int>>();
      final stdin = FakeSink();
      final exit = Completer<int>();
      final transport = JsonRpcTransport(
        stdout: stdout.stream,
        stdin: stdin,
        exitCode: exit.future,
        defaultTimeout: const Duration(seconds: 1),
      );

      final call = transport.call('missing.method');
      stdout.add(utf8.encode('not-json\n'));
      stdout.add(utf8.encode('\n'));
      stdout.add(
        utf8.encode(
          '{"jsonrpc":"2.0","id":1,"error":{"code":"method_not_found","message":"missing"}}\n',
        ),
      );

      await expectLater(call, throwsA(isA<RpcRemoteException>()));
      expect(transport.diagnosticLines, contains('not-json'));
      expect(transport.diagnosticLines, isNot(contains('')));
      await transport.close();
      await stdout.close();
    },
  );

  test('JsonRpcTransport timeout leaves connection open', () async {
    final stdout = StreamController<List<int>>();
    final stdin = FakeSink();
    final exit = Completer<int>();
    final transport = JsonRpcTransport(
      stdout: stdout.stream,
      stdin: stdin,
      exitCode: exit.future,
      defaultTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      transport.call('service.health'),
      throwsA(isA<RpcTimeoutException>()),
    );

    expect(transport.isClosed, isFalse);
    expect(stdin.closed, isFalse);
    await transport.close();
    await stdout.close();
  });

  test(
    'LocalServiceSession kills a service that misses the exit budget',
    () async {
      final process = FakeProcess();
      final transport = JsonRpcTransport(
        stdout: process.stdout,
        stdin: process.stdin,
        stderr: process.stderr,
        exitCode: process.exitCode,
        defaultTimeout: const Duration(seconds: 1),
      );
      final session = LocalServiceSession(
        process: process,
        transport: transport,
        client: AppServiceClient(transport),
      );

      await session.shutdown(
        rpcTimeout: const Duration(milliseconds: 10),
        exitTimeout: const Duration(milliseconds: 10),
      );

      expect(process.killed, isTrue);
    },
  );
}
