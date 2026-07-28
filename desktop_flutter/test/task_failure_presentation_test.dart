import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/task_failure_presentation.dart';

void main() {
  group('task failure presentation', () {
    test('routes translation credentials without exposing storage details', () {
      final presentation = taskFailurePresentation(
        error: 'missing environment variable OPENAI_API_KEY',
        errorInfo: const {
          'code': 'missing_env',
          'stage': 'TRANSLATE',
          'hint_zh': '请在 .env 或 env_key 中配置。',
        },
      );

      expect(
        presentation.target,
        TaskFailureRecoveryTarget.translationSettings,
      );
      expect(presentation.actionLabel, '检查翻译设置');
      expect(presentation.reason, contains('翻译模型凭据'));
      expect(presentation.reason, isNot(contains('.env')));
      expect(presentation.reason, isNot(contains('env_key')));
    });

    test('uses the failed stage to distinguish ASR credentials', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {'code': 'missing_env', 'stage': 'ASR'},
      );

      expect(presentation.target, TaskFailureRecoveryTarget.asrSettings);
      expect(presentation.actionLabel, '检查识别设置');
      expect(presentation.reason, contains('语音识别凭据'));
    });

    test('explains missing OpenRouter subtitle timestamps', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {
          'code': 'openrouter_asr_timestamps_missing',
          'stage': 'ASR',
        },
      );

      expect(presentation.target, TaskFailureRecoveryTarget.asrSettings);
      expect(presentation.actionLabel, '检查识别设置');
      expect(presentation.reason, contains('分段或词级时间轴'));
      expect(presentation.reason, contains('可以重试'));
      expect(presentation.reason, contains('OpenRouter'));
    });

    test('routes OpenRouter account errors back to ASR settings', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {
          'code': 'provider_payment_required',
          'stage': 'ASR',
          'retryable': false,
        },
      );

      expect(presentation.target, TaskFailureRecoveryTarget.asrSettings);
      expect(presentation.actionLabel, '检查识别设置');
      expect(presentation.reason, contains('余额不足'));
    });

    test('resumes transient provider failures from an existing checkpoint', () {
      final presentation = taskFailurePresentation(
        canResume: true,
        errorInfo: const {
          'code': 'provider_gateway_timeout',
          'stage': 'TRANSLATE',
          'hint_zh': 'Provider 网关暂时超时，可以继续。',
          'retryable': true,
        },
      );

      expect(presentation.target, TaskFailureRecoveryTarget.resume);
      expect(presentation.actionLabel, '继续任务');
      expect(presentation.reason, isNot(contains('Provider')));
      expect(presentation.reason, contains('翻译服务'));
    });

    test('retries transient provider failures without a checkpoint', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {'code': 'provider_timeout', 'retryable': true},
      );

      expect(presentation.target, TaskFailureRecoveryTarget.retry);
      expect(presentation.actionLabel, '重试');
    });

    test('does not pretend resume can repair a missing executable', () {
      final presentation = taskFailurePresentation(
        canResume: true,
        errorInfo: const {
          'code': 'missing_executable',
          'stage': 'ASR',
          'retryable': false,
        },
      );

      expect(presentation.target, TaskFailureRecoveryTarget.taskDetails);
      expect(presentation.actionLabel, '查看失败线索');
      expect(presentation.reason, contains('重新安装 TransVortex'));
    });

    test('prefers output repair over a generic result retry', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {
          'code': 'result_output_not_writable',
          'hint_zh': '输出目录不可写。',
        },
      );

      expect(presentation.target, TaskFailureRecoveryTarget.outputDirectory);
      expect(presentation.actionLabel, '选择输出目录');
    });

    test('routes missing results to re-export', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {'code': 'result_missing'},
      );

      expect(presentation.target, TaskFailureRecoveryTarget.reexport);
      expect(presentation.actionLabel, '重新导出');
    });

    test('cancelled tasks do not advertise another recovery action', () {
      final presentation = taskFailurePresentation(
        errorInfo: const {'code': 'task_cancelled'},
      );

      expect(presentation.target, TaskFailureRecoveryTarget.none);
      expect(presentation.actionLabel, isEmpty);
      expect(presentation.reason, '任务已取消。');
    });

    test('hides raw English and diagnostic implementation details', () {
      final presentation = taskFailurePresentation(
        error: 'read events.json and stderr for task_id=tvx_secret',
      );

      expect(presentation.target, TaskFailureRecoveryTarget.retry);
      expect(presentation.reason, '制作在这里停住了，可以重试一次。');
      expect(presentation.reason, isNot(contains('events.json')));
      expect(presentation.reason, isNot(contains('task_id')));
    });
  });
}
