import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/comments_source.dart';
import 'package:rill/domain/comment.dart';
import 'package:rill/domain/feed_item.dart' as domain;
import 'package:rill/ui/widgets/comment_composer.dart';
import 'package:rill/ui/widgets/comments_section.dart';

/// A page the widget asked for, held open until the test answers it.
class IssuedPage {
  IssuedPage(this.id, this.continuation);

  final int id;
  final String continuation;
  final completer = Completer<CommentsResult>();
}

/// A [CommentsSource] that answers when told to.
///
/// **A cancelled request's future is never completed by the real transport**
/// (`RpcClient.callCancelable`), but `$cancel` is best-effort: a response the
/// sidecar had already written still arrives. So a cancel here only records the
/// id, and a test that wants "the answer was already on the wire" completes the
/// cancelled request itself — that is the case the generation guard exists for.
class FakeCommentsSource implements CommentsSource {
  final issued = <IssuedPage>[];
  final cancelled = <int>[];
  int _next = 1;

  @override
  CommentsPageRequest page(String continuation) {
    final request = IssuedPage(_next++, continuation);
    issued.add(request);
    return (id: request.id, response: request.completer.future);
  }

  @override
  void cancel(int id) => cancelled.add(id);
}

Comment comment(
  String id, {
  bool isLiked = false,
  bool creatorHearted = false,
  bool isVerified = false,
  bool isUploader = false,
  bool isPinned = false,
  String? likeCount,
  int replyCount = 0,
  String? repliesContinuation,
  String? replyParams,
}) {
  return Comment(
    id: id,
    authorName: 'Author $id',
    authorAvatarUrl: '',
    text: CommentText(content: 'text of $id'),
    replyCount: replyCount,
    isLiked: isLiked,
    creatorHearted: creatorHearted,
    isVerified: isVerified,
    isUploader: isUploader,
    isPinned: isPinned,
    likeCount: likeCount,
    repliesContinuation: repliesContinuation,
    replyParams: replyParams,
  );
}

domain.Chip chip(String label, String token, {bool selected = false}) =>
    domain.Chip(label: label, token: token, selected: selected, scope: 'feed');

/// The two sort chips of a real page, with [selected] the one in force.
List<domain.Chip> sortChips({required String selected}) => [
      chip('Top', 'sort-top', selected: selected == 'Top'),
      chip('Newest', 'sort-newest', selected: selected == 'Newest'),
    ];

Widget section(FakeCommentsSource source, {String videoId = 'A', String initial = 'init-A'}) {
  return ProviderScope(
    overrides: [commentsSourceProvider.overrideWithValue(source)],
    child: MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [CommentsSection(videoId: videoId, initialContinuation: initial)],
        ),
      ),
    ),
  );
}

/// A comment's *body* (`comment(id)` writes `text of $id`). It is a `RichText`,
/// which `find.text` skips unless told otherwise, and matching on the id alone
/// would also hit the author's name.
Finder text(String id) => find.textContaining('text of $id', findRichText: true);

/// Thirty threads, the first of which has replies — tall enough that the first one can
/// be scrolled out of the viewport and its row disposed.
List<Comment> manyThreads({int firstReplies = 3, String? firstToken = 'rep-t0'}) => [
      comment('t0', replyCount: firstReplies, repliesContinuation: firstToken, replyParams: 'RP', likeCount: '1'),
      for (var i = 1; i < 30; i++) comment('t$i'),
    ];

/// The section with [items] already loaded (the first page answered).
Future<FakeCommentsSource> pumpLoaded(WidgetTester tester, List<Comment> items) async {
  final source = FakeCommentsSource();
  await tester.pumpWidget(section(source));
  source.issued.single.completer.complete(CommentsResult(items: items));
  await tester.pump();
  return source;
}

Future<void> scrollTo(WidgetTester tester, {required bool bottom}) async {
  // The list's, which is the outermost: a multi-line TextField (the reply box) brings a Scrollable of its own.
  final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  position.jumpTo(bottom ? position.maxScrollExtent : 0);
  await tester.pump();
}

int builtTiles() => find.byType(CommentTile).evaluate().length;

void main() {
  group('CommentsSection — a re-sort supersedes the page in flight', () {
    /// Page 1 of the "Top" sort is in, and "Show more comments" has been
    /// tapped: `more-top` is out. Returns it.
    Future<IssuedPage> loadMoreInFlight(WidgetTester tester, FakeCommentsSource source) async {
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(
        CommentsResult(
          items: [comment('old-1'), comment('old-2')],
          continuation: 'more-top',
          chips: sortChips(selected: 'Top'),
          commentCount: '4 Comments',
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Show more comments'));
      await tester.pump();
      expect(source.issued.last.continuation, 'more-top');
      return source.issued.last;
    }

    testWidgets('cancels it, asks for the new sort, and never merges the old answer', (tester) async {
      final source = FakeCommentsSource();
      final loadMore = await loadMoreInFlight(tester, source);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Newest'));
      await tester.pump();

      // The click was not dropped: the page in flight is released and the new
      // sort's first page is asked for.
      expect(source.cancelled, [loadMore.id]);
      expect(source.issued.last.continuation, 'sort-newest');
      expect(text('old-1'), findsNothing, reason: 'a re-sort discards the list at once');

      // The cancelled page's answer was already on the wire.
      loadMore.completer.complete(
        CommentsResult(items: [comment('old-3')], continuation: 'more-top-2'),
      );
      await tester.pump();
      expect(text('old-3'), findsNothing, reason: 'the old sort\'s page must not be merged in');

      source.issued.last.completer.complete(
        CommentsResult(items: [comment('new-1')], chips: sortChips(selected: 'Newest')),
      );
      await tester.pump();

      expect(text('new-1'), findsOneWidget);
      expect(text('old-'), findsNothing);
      // Had the stale page landed, its continuation would have replaced the new
      // sort's own (there is none) and this button would be here.
      expect(find.text('Show more comments'), findsNothing);
    });

    testWidgets('a re-sort that fails retries the sort, not the list it replaced', (tester) async {
      final source = FakeCommentsSource();
      await loadMoreInFlight(tester, source);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Newest'));
      await tester.pump();
      source.issued.last.completer.completeError(Exception('offline'));
      await tester.pump();

      await tester.tap(find.text('Tap to retry'));
      await tester.pump();

      expect(source.issued.last.continuation, 'sort-newest');
    });

  });

  group('CommentsSection — leaving', () {
    testWidgets('a section that goes away mid-load releases the sidecar', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      final request = source.issued.single;

      await tester.pumpWidget(const SizedBox());

      expect(source.cancelled, [request.id]);
    });

    testWidgets('a section whose load finished has nothing left to cancel', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(CommentsResult(items: [comment('c1')]));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());

      expect(source.cancelled, isEmpty);
    });

    testWidgets('a thread that goes away while its replies load releases the sidecar', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(
        CommentsResult(items: [comment('t1', replyCount: 2, repliesContinuation: 'rep-t1')]),
      );
      await tester.pump();

      await tester.tap(find.text('Show 2 replies'));
      await tester.pump();
      final replies = source.issued.last;
      expect(replies.continuation, 'rep-t1');

      await tester.pumpWidget(const SizedBox());

      expect(source.cancelled, [replies.id]);
    });
  });

  group('CommentsSection — a different video', () {
    // The watch page swaps the video in place on a queue jump, and a video it
    // has already loaded hands over its cached detail on the first frame — so
    // this widget is updated with new props rather than rebuilt. Left alone it
    // keeps the old video's threads and, worse, the old video's comment-box
    // token, which encodes that video's id.
    testWidgets('drops the old video\'s threads, count and comment box, and loads the new one', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(
        CommentsResult(items: [comment('a-1')], commentCount: '1 Comment', createParams: 'CREATE-A'),
      );
      await tester.pump();
      expect(text('a-1'), findsOneWidget);
      expect(find.byType(CommentComposer), findsOneWidget);
      expect(find.text('1 Comment'), findsOneWidget);

      await tester.pumpWidget(section(source, videoId: 'B', initial: 'init-B'));

      expect(source.issued.last.continuation, 'init-B');
      expect(text('a-1'), findsNothing);
      expect(find.text('1 Comment'), findsNothing);
      expect(
        find.byType(CommentComposer),
        findsNothing,
        reason: 'A\'s token would post to A from B\'s page',
      );

      source.issued.last.completer.complete(
        CommentsResult(items: [comment('b-1')], createParams: 'CREATE-B'),
      );
      await tester.pump();

      expect(text('b-1'), findsOneWidget);
      expect(text('a-1'), findsNothing);
      expect(find.byType(CommentComposer), findsOneWidget);
    });

    testWidgets('a load still out for the old video is cancelled', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      final first = source.issued.single;

      await tester.pumpWidget(section(source, videoId: 'B', initial: 'init-B'));

      expect(source.cancelled, [first.id]);
      expect(source.issued.last.continuation, 'init-B');
    });

    testWidgets('a page of the old video that lands late is not shown under the new one', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      final late = source.issued.single;

      await tester.pumpWidget(section(source, videoId: 'B', initial: 'init-B'));
      late.completer.complete(CommentsResult(items: [comment('a-late')], createParams: 'CREATE-A'));
      await tester.pump();

      expect(text('a-late'), findsNothing);
      expect(find.byType(CommentComposer), findsNothing);
    });

    testWidgets('the same video re-pumped is left alone', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(CommentsResult(items: [comment('a-1')]));
      await tester.pump();

      await tester.pumpWidget(section(source));

      expect(source.issued, hasLength(1), reason: 'no reload for an unchanged video');
      expect(text('a-1'), findsOneWidget);
    });
  });

  group('the reply list is lazy, and a thread keeps its state when it scrolls away', () {
    // A thread's replies used to be a plain `Column` inside the thread's row, so all
    // of them were built the moment it was expanded (345 ms to re-expand 500,
    // `architecture.md` F34), and a `SliverList` disposes a row that leaves the
    // viewport, taking the expansion, the loaded replies and a half-typed reply with
    // it. The replies are rows of the same list now, and their state is the
    // section's.
    Future<FakeCommentsSource> expandFirst(WidgetTester tester, {int replies = 3, String? next}) async {
      final source = await pumpLoaded(tester, manyThreads(firstReplies: replies));
      await tester.tap(find.text('Show $replies replies'));
      await tester.pump();
      source.issued.last.completer.complete(
        CommentsResult(items: [for (var i = 1; i <= replies; i++) comment('r$i')], continuation: next),
      );
      await tester.pump();
      return source;
    }

    testWidgets('an expanded thread is still expanded, with its replies and its load-more, after scrolling away and back', (tester) async {
      final source = await expandFirst(tester, next: 'rep-t0-2');
      expect(text('r3'), findsOneWidget);

      await scrollTo(tester, bottom: true);
      expect(text('r3'), findsNothing, reason: 'the thread is off screen, and its row is gone');
      await scrollTo(tester, bottom: false);

      expect(find.text('Hide replies'), findsOneWidget);
      expect([text('r1'), text('r2'), text('r3')].map((f) => f.evaluate().length), [1, 1, 1]);
      expect(find.text('Show more replies'), findsOneWidget);

      // ...and the next page continues from where it stopped, not from the start.
      await tester.tap(find.text('Show more replies'));
      await tester.pump();
      expect(source.issued.last.continuation, 'rep-t0-2');
    });

    testWidgets('a half-typed reply is still in the box after scrolling away and back', (tester) async {
      final source = await pumpLoaded(tester, manyThreads());
      await tester.tap(find.text('Reply').first);
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('r1')]));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'half typed');

      await scrollTo(tester, bottom: true);
      expect(find.byType(TextField), findsNothing);
      await scrollTo(tester, bottom: false);

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'half typed');
    });

    testWidgets("'Read more' stays open after scrolling away and back", (tester) async {
      final long = List.filled(40, 'a very long comment line').join(' ');
      await pumpLoaded(tester, [
        Comment(id: 'long', authorName: 'A', authorAvatarUrl: '', text: CommentText(content: long), replyCount: 0),
        for (var i = 1; i < 30; i++) comment('t$i'),
      ]);
      await tester.tap(find.text('Read more'));
      await tester.pump();
      expect(find.text('Read less'), findsOneWidget);

      await scrollTo(tester, bottom: true);
      await scrollTo(tester, bottom: false);

      expect(find.text('Read less'), findsOneWidget);
    });

    testWidgets('300 loaded replies build a screenful, not 300', (tester) async {
      await expandFirst(tester, replies: 300);

      expect(text('r1'), findsOneWidget, reason: 'the top of the list is built');
      expect(text('r300'), findsNothing, reason: 'the bottom is not');
      expect(builtTiles(), lessThan(40));
    });

    testWidgets('collapsing and expanding a thread that holds 300 replies again builds a screenful too', (tester) async {
      await expandFirst(tester, replies: 300);

      await tester.tap(find.text('Hide replies'));
      await tester.pump();
      expect(builtTiles(), lessThan(40));

      // The list is complete, so the count is the loaded one, and nothing is refetched.
      await tester.tap(find.text('Show 300 replies'));
      await tester.pump();

      expect(text('r1'), findsOneWidget);
      expect(builtTiles(), lessThan(40));
    });

    testWidgets('a re-sort forgets every thread\'s replies: the same thread comes back collapsed', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(CommentsResult(items: manyThreads(), chips: sortChips(selected: 'Top')));
      await tester.pump();
      await tester.tap(find.text('Show 3 replies'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('r1')]));
      await tester.pump();
      expect(find.text('Hide replies'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Newest'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: manyThreads(), chips: sortChips(selected: 'Newest')));
      await tester.pump();

      expect(find.text('Show 3 replies'), findsOneWidget, reason: 'the same thread, collapsed again');
      expect(text('r1'), findsNothing);
    });

    testWidgets('a different video forgets them too', (tester) async {
      final source = await pumpLoaded(tester, manyThreads());
      await tester.tap(find.text('Show 3 replies'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('r1')]));
      await tester.pump();

      await tester.pumpWidget(section(source, videoId: 'B', initial: 'init-B'));
      source.issued.last.completer.complete(CommentsResult(items: manyThreads()));
      await tester.pump();

      expect(find.text('Show 3 replies'), findsOneWidget);
      expect(text('r1'), findsNothing);
    });
  });

  group('CommentTile — the viewer\'s like and the creator\'s heart', () {
    Future<void> pumpTile(WidgetTester tester, Comment tile) {
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 400, child: CommentTile(comment: tile)),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a comment the viewer liked draws a filled thumb, with its count', (tester) async {
      await pumpTile(tester, comment('c1', isLiked: true, likeCount: '737'));

      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsNothing);
      expect(find.text('737'), findsOneWidget);
    });

    testWidgets('a comment the viewer did not like draws an outlined one', (tester) async {
      await pumpTile(tester, comment('c1', likeCount: '736'));

      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing);
    });

    testWidgets('a hearted comment shows the creator\'s heart, and only that one does', (tester) async {
      await pumpTile(tester, comment('c1', creatorHearted: true));
      expect(find.byIcon(Icons.favorite), findsOneWidget);

      await pumpTile(tester, comment('c2'));
      expect(find.byIcon(Icons.favorite), findsNothing);
    });

    testWidgets('a comment can be liked and hearted at once', (tester) async {
      await pumpTile(tester, comment('c1', isLiked: true, creatorHearted: true));

      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });
  });
}
