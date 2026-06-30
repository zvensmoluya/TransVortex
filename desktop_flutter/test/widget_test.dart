import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/spike_state.dart';

void main() {
  testWidgets('main screen renders empty-state subject', (tester) async {
    await tester.pumpWidget(const TransVortexApp());
    // 呼吸动画在 repeat，不能 pumpAndSettle；推进一帧即可。
    await tester.pump(const Duration(milliseconds: 100));

    // 「放入片源」出现两处：主体提示 + 空态禁用 CTA。
    expect(find.text('放入片源'), findsNWidgets(2));
    expect(find.textContaining('拖进来'), findsOneWidget);
    expect(find.text('TransVortex'), findsOneWidget);
    expect(find.textContaining('调试态'), findsOneWidget);
  });

  testWidgets('translation settings window renders IME probe fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TransVortexApp(windowType: SpikeWindowType.translationSettings),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('翻译模型设置'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('模型名'), findsOneWidget);
    expect(find.textContaining('中文备注'), findsOneWidget);
  });
}
