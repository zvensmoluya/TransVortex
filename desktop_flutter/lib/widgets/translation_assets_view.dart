import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import 'memory_library_dialog.dart';
import 'translation_style_library.dart';

class TranslationAssetsView extends StatelessWidget {
  const TranslationAssetsView({super.key, required this.client});

  final AppServiceClient client;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '术语库'),
              Tab(text: '风格库'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                MemoryLibraryDialog(client: client, embedded: true),
                TranslationStyleLibrary(client: client),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
