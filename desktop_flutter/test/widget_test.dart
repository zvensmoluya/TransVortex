import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';

void main() {
  testWidgets('renders frontend validation checklist', (tester) async {
    await tester.pumpWidget(const TransVortexDesktopFlutterApp());

    expect(find.text('TransVortex Desktop Flutter'), findsOneWidget);
    expect(find.text('Three-window model'), findsOneWidget);
    expect(find.text('Chinese IME'), findsOneWidget);
    expect(find.text('Python sidecar'), findsOneWidget);
    expect(find.text('Subtitle review load'), findsOneWidget);

    await tester.drag(find.byType(Scrollable), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(find.text('Release sanity'), findsOneWidget);
  });
}
