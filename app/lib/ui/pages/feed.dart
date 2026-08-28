import 'package:flutter/material.dart';

import '../page_wrapper.dart';
import '../debug_player.dart';
import '../feed_controller.dart';
import '../widgets/accent_debug_button.dart';
import '../widgets/feed_view.dart';

class FeedPage extends StatelessWidget {
  const FeedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageWrapper(
      title: Text(
        'Rill',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 23,
        ),
      ),
      actions: [
        const AccentDebugButton(),
        IconButton(
          icon: const Icon(Icons.bug_report),
          tooltip: 'Debug Player',
          onPressed: () async {
            final config = HarnessConfig.fromEnvironment();
            final source = await StreamSource.load(config);
            if (context.mounted) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => HarnessPage(config: config, source: source),
                ),
              );
            }
          },
        ),
      ],
      body: FeedView(provider: feedProvider),
    );
  }
}
