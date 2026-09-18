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

  group('CommentThreadWidget — the viewer\'s like and the creator\'s heart', () {
    Future<void> pumpThread(WidgetTester tester, Comment thread) {
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 400, child: CommentThreadWidget(thread: thread, videoId: 'A')),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a comment the viewer liked draws a filled thumb, with its count', (tester) async {
      await pumpThread(tester, comment('c1', isLiked: true, likeCount: '737'));

      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsNothing);
      expect(find.text('737'), findsOneWidget);
    });

    testWidgets('a comment the viewer did not like draws an outlined one', (tester) async {
      await pumpThread(tester, comment('c1', likeCount: '736'));

      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing);
    });

    testWidgets('a hearted comment shows the creator\'s heart, and only that one does', (tester) async {
      await pumpThread(tester, comment('c1', creatorHearted: true));
      expect(find.byIcon(Icons.favorite), findsOneWidget);

      await pumpThread(tester, comment('c2'));
      expect(find.byIcon(Icons.favorite), findsNothing);
    });

    testWidgets('a comment can be liked and hearted at once', (tester) async {
      await pumpThread(tester, comment('c1', isLiked: true, creatorHearted: true));

      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });
  });
}
