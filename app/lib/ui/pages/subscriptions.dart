import 'package:flutter/material.dart';

import '../feed_controller.dart';
import '../page_wrapper.dart';
import '../player_shell.dart' show rootNavigatorKey;
import '../widgets/feed_view.dart';
import 'all_subscriptions.dart';

const String subscriptionsRouteName = 'subscriptions';

/// The second surface Task 20 §1 asks for — deliberately the cheapest one.
/// No chips, and empty-with-no-auth is a real, expected state rather than an
/// error (`FeedView`'s anonymous branch, driven by `checkAuthOnEmpty`).
class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageWrapper(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          Text(
            'Subscriptions',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8.0, top: 4.0, bottom: 4.0),
            child: TextButton.icon(
              onPressed: () {
                rootNavigatorKey.currentState?.push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: allSubscriptionsRouteName),
                    builder: (_) => const AllSubscriptionsPage(),
                  ),
                );
              },
              icon: const Icon(Icons.people_outline, size: 18),
              label: const Text('Show all channels'),
            ),
          ),
          Expanded(
            child: FeedView(
              provider: subscriptionsProvider,
              anonymousTitle: 'No subscriptions to show.',
              anonymousMessage: 'Log in to see videos from channels you subscribe to.',
              emptyMessage: 'Nothing new from your subscriptions.',
            ),
          ),
        ],
      ),
    );
  }
}
