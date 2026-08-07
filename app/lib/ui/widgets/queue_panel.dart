import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../queue_controller.dart';

/// Open the queue. Reachable from the mini-player and the watch page (task §5).
Future<void> showQueuePanel(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const QueuePanel(),
  );
}

class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final queue = ref.watch(queueProvider);
    final controller = ref.read(queueProvider.notifier);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
            child: Row(
              children: [
                Text(
                  'Queue',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  queue.items.isEmpty ? 'empty' : '${queue.items.length} videos',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
                const Spacer(),
                if (queue.items.isNotEmpty)
                  TextButton(
                    onPressed: controller.clear,
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: queue.items.isEmpty
                ? Center(
                    child: Text(
                      'Nothing queued.\nUse the queue button on a tile to add something.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: queue.items.length,
                    // `onReorderItem`, not the deprecated `onReorder`: it hands
                    // over the destination already adjusted for the row having
                    // been lifted out, which is the plain remove-then-insert the
                    // queue models. `onReorder` reports it one too far on a
                    // downward drag, and every caller has to know that.
                    onReorderItem: controller.reorder,
                    itemBuilder: (context, index) {
                      final item = queue.items[index];
                      final isCurrent = index == queue.currentIndex;
                      return ListTile(
                        key: ValueKey('${item.id}-$index'),
                        selected: isCurrent,
                        mouseCursor: SystemMouseCursors.click,
                        leading: SizedBox(
                          width: 72,
                          height: 40,
                          child: Image.network(
                            item.thumbnailUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                Container(color: scheme.surfaceContainerHighest),
                          ),
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: isCurrent ? scheme.primary : scheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          item.channelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Remove',
                              mouseCursor: SystemMouseCursors.click,
                              icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
                              onPressed: () => controller.removeAt(index),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                        onTap: () => controller.jumpTo(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
