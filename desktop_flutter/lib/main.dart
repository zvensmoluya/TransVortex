import 'package:flutter/material.dart';

void main() {
  runApp(const TransVortexDesktopFlutterApp());
}

class TransVortexDesktopFlutterApp extends StatelessWidget {
  const TransVortexDesktopFlutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TransVortex Desktop Flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffef5d8f),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const FrontendValidationPage(),
    );
  }
}

class FrontendValidationPage extends StatelessWidget {
  const FrontendValidationPage({super.key});

  static const _checks = [
    ValidationCheck(
      title: 'Three-window model',
      detail:
          'Main window, translation settings, and ASR settings with explicit state sync.',
    ),
    ValidationCheck(
      title: 'Chinese IME',
      detail:
          'Composition, candidate position, paste, focus switching, and subtitle editing in release builds.',
    ),
    ValidationCheck(
      title: 'Python sidecar',
      detail:
          'Start the existing JSON-RPC service and exchange line-based stdin/stdout messages.',
    ),
    ValidationCheck(
      title: 'Subtitle review load',
      detail:
          'Render and edit 1000 subtitle rows while tracking frame time and memory.',
    ),
    ValidationCheck(
      title: 'Release sanity',
      detail:
          'Build a Windows release and record startup, window opening, and sidecar path behavior.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffff8fb),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TransVortex Desktop Flutter',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff29232d),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This project validates route-setting desktop risks. It is not a product migration.',
                    style: TextStyle(fontSize: 14, color: Color(0xff665b68)),
                  ),
                  const SizedBox(height: 28),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _checks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final check = _checks[index];
                        return ValidationCheckTile(
                          index: index + 1,
                          check: check,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ValidationCheckTile extends StatelessWidget {
  const ValidationCheckTile({
    super.key,
    required this.index,
    required this.check,
  });

  final int index;
  final ValidationCheck check;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffffc8da)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: 34,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xffef5d8f),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    '$index',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    check.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff29232d),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    check.detail,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Color(0xff665b68),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ValidationCheck {
  const ValidationCheck({required this.title, required this.detail});

  final String title;
  final String detail;
}
