import 'dart:async';

import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:rill/ui/focus_ring.dart' show KeyboardNavigation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/comments_source.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/domain/comment.dart';
import 'package:rill/domain/feed_item.dart' as domain;
import 'package:rill/ui/widgets/comment_composer.dart';
import 'package:rill/ui/widgets/comments_section.dart';
import 'package:rill/ui/widgets/shortcut_tooltip.dart';

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

  // --- Writes ---------------------------------------------------------------

  /// Every write, in order: `('rate', 'BLOB')`, `('delete', 'TOKEN')`, …
  final writes = <(String, String)>[];

  /// The next write of each kind throws this instead of succeeding, so the
  /// revert paths can be driven.
  final failures = <String, Object>{};

  /// What [post] answers. Null makes the caller stand in a local comment.
  Comment? posted;

  Future<void> _record(String kind, String arg) async {
    writes.add((kind, arg));
    final failure = failures.remove(kind);
    if (failure != null) throw failure;
  }

  @override
  Future<Comment?> post(String createParams, String text) async {
    await _record('post', text);
    return posted;
  }

  @override
  Future<void> reply(String replyParams, String text) => _record('reply', text);

  @override
  Future<void> delete(String deleteParams) => _record('delete', deleteParams);

  @override
  Future<void> rate(String params) => _record('rate', params);
}

Comment comment(
  String id, {
  String myRating = 'none',
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
    myRating: myRating,
    // Present on every real comment, anonymous ones included — the tile needs
    // them non-null only so a vote has a transition to send.
    likeParams: 'LIKE',
    unlikeParams: 'UNLIKE',
    dislikeParams: 'DISLIKE',
    undislikeParams: 'UNDISLIKE',
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

/// An [AuthController] parked in one state — votes are gated on it, so a test
/// that wants a pressable thumb has to say who is watching.
class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;
}

Widget section(
  FakeCommentsSource source, {
  String videoId = 'A',
  String initial = 'init-A',
  AuthStatus auth = AuthStatus.authenticated,
}) {
  return ProviderScope(
    overrides: [
      commentsSourceProvider.overrideWithValue(source),
      authProvider.overrideWith(() => _FixedAuth(AuthState(status: auth))),
    ],
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
  setUp(KeyboardNavigation.install);

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

  group('CommentsSection — an identity change loads the list again (Task 31 §3)', () {
    // The rows fetched under one identity carry that identity's vote tokens (and
    // its like state), so a sign-in or sign-out starts the list over from page one
    // through the same generation guard a re-sort uses.
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(CommentsSection)));

    testWidgets('signing in drops the rows, asks for the first page again, and shows what it returns', (tester) async {
      // Mutation: remove the `ref.listen(authIdentityProvider)` trigger and the
      // anonymous rows stay, no second page is asked for, and this fails.
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source, auth: AuthStatus.anonymous));
      source.issued.single.completer.complete(
        CommentsResult(items: [comment('anon-1'), comment('anon-2')], continuation: 'more'),
      );
      await tester.pump();
      expect(text('anon-1'), findsOneWidget);

      containerOf(tester).read(authProvider.notifier).adoptVerifiedState('authenticated');
      await tester.pump();

      expect(source.issued, hasLength(2));
      expect(source.issued.last.continuation, 'init-A', reason: 'page one, not the continuation the old rows were on');
      expect(text('anon-'), findsNothing, reason: 'the other identity\'s rows are gone at once');
      expect(find.text('Show more comments'), findsNothing);

      source.issued.last.completer.complete(CommentsResult(items: [comment('acct-1')]));
      await tester.pump();
      expect(text('acct-1'), findsOneWidget);
      expect(text('anon-'), findsNothing);
    });

    testWidgets('a vote on a row that came after the sign-in is live', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source, auth: AuthStatus.anonymous));
      source.issued.single.completer.complete(CommentsResult(items: [comment('anon-1')]));
      await tester.pump();

      containerOf(tester).read(authProvider.notifier).adoptVerifiedState('authenticated');
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('acct-1')]));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
      await tester.pump();

      expect(source.writes, [('rate', 'LIKE')]);
    });

    testWidgets('signing out drops the account\'s rows the same way', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(
        CommentsResult(items: [comment('acct-1', myRating: 'like')]),
      );
      await tester.pump();
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);

      containerOf(tester).read(authProvider.notifier).adoptVerifiedState('anonymous');
      await tester.pump();

      expect(source.issued, hasLength(2));
      expect(text('acct-1'), findsNothing);
      source.issued.last.completer.complete(CommentsResult(items: [comment('anon-1')]));
      await tester.pump();
      expect(find.byIcon(Icons.thumb_up), findsNothing, reason: 'the old account\'s like is not drawn on anonymous rows');
    });

    testWidgets('a page still in flight for the old identity is not merged', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source, auth: AuthStatus.anonymous));
      final stale = source.issued.single;

      containerOf(tester).read(authProvider.notifier).adoptVerifiedState('authenticated');
      await tester.pump();
      stale.completer.complete(CommentsResult(items: [comment('stale-1')]));
      await tester.pump();

      expect(text('stale-1'), findsNothing);
      expect(source.cancelled, contains(stale.id));
    });

    testWidgets('an unchanged identity does not reload', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(CommentsResult(items: [comment('acct-1')]));
      await tester.pump();

      containerOf(tester).read(authProvider.notifier).adoptVerifiedState('authenticated');
      await tester.pump();

      expect(source.issued, hasLength(1));
      expect(text('acct-1'), findsOneWidget);
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

    testWidgets('the replies button is named "Show N replies", and the comment does not carry that name', (tester) async {
      final handle = tester.ensureSemantics();
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(
        CommentsResult(items: [comment('t1', replyCount: 2, repliesContinuation: 'rep-t1')]),
      );
      await tester.pump();

      // The button has the name; before, it was nameless and the name sat on the comment.
      final button = tester.getSemantics(find.bySemanticsLabel('Show 2 replies'));
      expect(button.getSemanticsData().flagsCollection.isButton, isNot(Tristate.isFalse));
      final commentNode = tester.getSemantics(find.bySemanticsLabel(RegExp('^(?!Show 2 replies).*', dotAll: true)).first);
      expect(commentNode.label, isNot(contains('Show 2 replies')));
      expect(find.bySemanticsLabel(RegExp('Show 2 replies')), findsOneWidget, reason: 'said once');
      handle.dispose();
    });

    testWidgets('a thread that goes away while its replies load releases the sidecar', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(
        CommentsResult(items: [comment('t1', replyCount: 2, repliesContinuation: 'rep-t1')]),
      );
      await tester.pump();

      await tester.tap(find.text('2 replies'));
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
      await tester.tap(find.text('$replies replies'));
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
      await tester.tap(find.text('300 replies'));
      await tester.pump();

      expect(text('r1'), findsOneWidget);
      expect(builtTiles(), lessThan(40));
    });

    testWidgets('a re-sort forgets every thread\'s replies: the same thread comes back collapsed', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source));
      source.issued.single.completer.complete(CommentsResult(items: manyThreads(), chips: sortChips(selected: 'Top')));
      await tester.pump();
      await tester.tap(find.text('3 replies'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('r1')]));
      await tester.pump();
      expect(find.text('Hide replies'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Newest'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: manyThreads(), chips: sortChips(selected: 'Newest')));
      await tester.pump();

      expect(find.text('3 replies'), findsOneWidget, reason: 'the same thread, collapsed again');
      expect(text('r1'), findsNothing);
    });

    testWidgets('a different video forgets them too', (tester) async {
      final source = await pumpLoaded(tester, manyThreads());
      await tester.tap(find.text('3 replies'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('r1')]));
      await tester.pump();

      await tester.pumpWidget(section(source, videoId: 'B', initial: 'init-B'));
      source.issued.last.completer.complete(CommentsResult(items: manyThreads()));
      await tester.pump();

      expect(find.text('3 replies'), findsOneWidget);
      expect(text('r1'), findsNothing);
    });
  });

  group('CommentsSection — voting, through the seam', () {
    // The handler these drive had no test until the writes took a seam
    // (`todo.md` 39.5): it went straight to `RpcClient.instance`. A vote is the
    // one write whose failure is least visible — a vote that silently does not
    // stick looks exactly like one that did — so the revert below is the point.

    testWidgets('a vote sends the blob for the transition and flips the thumb at once', (tester) async {
      final source = await pumpLoaded(tester, [comment('c1')]);

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined).first);
      await tester.pump();

      // Optimistic: the thumb is filled before the write has answered.
      expect(source.writes, [('rate', 'LIKE')]);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    });

    testWidgets('a failed vote puts the thumb back', (tester) async {
      final source = await pumpLoaded(tester, [comment('c1')]);
      source.failures['rate'] = Exception('nope');

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined).first);
      await tester.pump();
      await tester.pump();

      expect(find.byIcon(Icons.thumb_up), findsNothing);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
    });

    testWidgets('clearing a vote sends the undo blob, not the set one', (tester) async {
      final source = await pumpLoaded(tester, [comment('c1', myRating: 'like')]);

      await tester.tap(find.byIcon(Icons.thumb_up).first);
      await tester.pump();

      expect(source.writes, [('rate', 'UNLIKE')]);
    });

    testWidgets('switching sides sends the dislike blob', (tester) async {
      final source = await pumpLoaded(tester, [comment('c1', myRating: 'like')]);

      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined).first);
      await tester.pump();

      expect(source.writes, [('rate', 'DISLIKE')]);
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing, reason: 'the like is gone, not kept alongside');
    });

    // The reply branch of `_replaceComment` — a different list from the
    // threads', held by the thread's state rather than by the section's
    // `_threads`. It was the one path with no coverage at all.
    testWidgets('a reply can be voted on, and it is the reply that changes', (tester) async {
      final source = await pumpLoaded(tester, manyThreads(firstReplies: 2));
      await tester.tap(find.text('2 replies'));
      await tester.pump();
      source.issued.last.completer.complete(
        CommentsResult(items: [comment('r1'), comment('r2', myRating: 'like')]),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.thumb_up).first);
      await tester.pump();

      expect(source.writes, [('rate', 'UNLIKE')]);
      expect(find.byIcon(Icons.thumb_up), findsNothing, reason: 'the reply is the one that moved');
    });

    testWidgets('a failed vote on a reply puts that reply back', (tester) async {
      final source = await pumpLoaded(tester, manyThreads(firstReplies: 1));
      await tester.tap(find.text('1 replies'));
      await tester.pump();
      source.issued.last.completer.complete(CommentsResult(items: [comment('r1')]));
      await tester.pump();
      source.failures['rate'] = Exception('nope');

      final before = find.byIcon(Icons.thumb_up_alt_outlined).evaluate().length;
      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined).last);
      await tester.pump();
      await tester.pump();

      expect(find.byIcon(Icons.thumb_up), findsNothing);
      expect(find.byIcon(Icons.thumb_up_alt_outlined).evaluate().length, before);
    });

    testWidgets('a degraded session cannot vote, and the tooltip says why', (tester) async {
      // Not merely "not signed in": `AuthState.isSignedIn` is strictly
      // `== authenticated`, and `degraded` is its own status fed by
      // `auth.verify` — hard invariant 5, since `logged_in` is cookie presence
      // rather than server acceptance.
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source, auth: AuthStatus.degraded));
      source.issued.single.completer.complete(CommentsResult(items: [comment('c1')]));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined).first);
      await tester.pump();
      expect(source.writes, isEmpty);

      final tooltips = tester.widgetList<ShortcutTooltip>(find.byType(ShortcutTooltip)).map((t) => t.label).toList();
      expect(tooltips, contains('Your session expired. Sign in again to vote'));
    });

    testWidgets('an anonymous viewer gets the other reason', (tester) async {
      final source = FakeCommentsSource();
      await tester.pumpWidget(section(source, auth: AuthStatus.anonymous));
      source.issued.single.completer.complete(CommentsResult(items: [comment('c1')]));
      await tester.pump();

      final tooltips = tester.widgetList<ShortcutTooltip>(find.byType(ShortcutTooltip)).map((t) => t.label).toList();
      expect(tooltips, contains('Sign in to vote'));
      expect(tooltips, isNot(contains('Your session expired. Sign in again to vote')));
    });
  });


  group('CommentTile — the hover-revealed copy-link button', () {
    VoidCallback? lastCopy;

    Future<void> pumpTileFor(WidgetTester tester, Comment tile, {bool copyable = true}) {
      lastCopy = null;
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: CommentTile(
                    comment: tile,
                    onReply: () {},
                    onCopyLink: copyable ? () => lastCopy = () {} : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    double opacityOfCopy(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byIcon(Icons.link),
            matching: find.byType(AnimatedOpacity),
          ).first,
        )
        .opacity;

    testWidgets('is transparent until the pointer is over the comment', (tester) async {
      await pumpTileFor(tester, comment('c1'));
      expect(opacityOfCopy(tester), 0);
    });

    testWidgets('fades in on hover and out again on exit', (tester) async {
      await pumpTileFor(tester, comment('c1'));

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(pointer.removePointer);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(find.byType(CommentTile)));
      await tester.pump();

      expect(opacityOfCopy(tester), 1);

      await pointer.moveTo(const Offset(2000, 2000));
      await tester.pump();
      expect(opacityOfCopy(tester), 0);
    });

    testWidgets('cannot be clicked while it is invisible', (tester) async {
      // Transparent and still hit-testable is worse than absent: the pointer
      // finds a button nobody can see.
      await pumpTileFor(tester, comment('c1'));

      final ignoring = tester.widget<IgnorePointer>(
        find.ancestor(
          of: find.byIcon(Icons.link),
          matching: find.byType(IgnorePointer),
        ).first,
      );
      expect(ignoring.ignoring, isTrue);
    });

    testWidgets('asks the section to copy, which is the half that knows the video', (tester) async {
      await pumpTileFor(tester, comment('c1'));
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(pointer.removePointer);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(find.byType(CommentTile)));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.link));
      await tester.pump();

      expect(lastCopy, isNotNull);
    });

    testWidgets('keyboard focus reveals it, so Tab never lands on an invisible button', (tester) async {
      // Measured 2026-09-21: `IgnorePointer(ignoring: true)` drops a subtree
      // from semantics but does *not* stop it taking focus. Hiding on hover
      // alone therefore gave the worst pair — Tab focuses a button nobody can
      // see, and a screen reader is never told it exists.
      await pumpTileFor(tester, comment('c1'));
      expect(opacityOfCopy(tester), 0);

      final button = tester.widget<IconButton>(
        find.ancestor(of: find.byIcon(Icons.link), matching: find.byType(IconButton)).first,
      );
      expect(button.onPressed, isNotNull, reason: 'focusable only if it is a live button');

      // Revealed by keyboard navigation only: a click that focuses it shows nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      Focus.of(tester.element(find.byIcon(Icons.link))).requestFocus();
      await tester.pump();

      expect(opacityOfCopy(tester), 1);
    });

    testWidgets('it is not actionable while hidden, and is once focused', (tester) async {
      // Measured, not assumed: `IgnorePointer` keeps the semantics node (the
      // tooltip text survives) and strips the **tap action**. So while hidden a
      // screen reader can read it but not press it — which is why focus has to
      // reveal it, or Tab lands somewhere invisible and inert.
      final handle = tester.ensureSemantics();
      await pumpTileFor(tester, comment('c1'));

      // The tap action is the part that actually differs; the tooltip text
      // survives either way, and which node it lands on depends on how the
      // tile's semantics merge, so it is not what this asserts.
      expect(
        tester.getSemantics(find.byIcon(Icons.link)).getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
        reason: 'hidden: a screen reader can reach it but not activate it',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      Focus.of(tester.element(find.byIcon(Icons.link))).requestFocus();
      // Settled, not pumped: `Opacity` at exactly 0 drops the subtree from
      // semantics on its own, so the action only comes back once the fade has
      // actually left zero.
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.byIcon(Icons.link)).getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'revealed by focus, so it can actually be activated',
      );
      handle.dispose();
    });

    testWidgets('no button at all when the section offers no link', (tester) async {
      await pumpTileFor(tester, comment('c1'), copyable: false);
      expect(find.byIcon(Icons.link), findsNothing);
    });
  });

  group('CommentTile — the body is selectable', () {
    testWidgets('the comment text sits in a SelectionArea, so it can be selected and copied', (tester) async {
      // Copying the *text* is not a button: it is ordinary text selection —
      // drag, Ctrl+C, or the platform's right-click menu.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 400, child: CommentTile(comment: comment('c1'))),
              ),
            ),
          ),
        ),
      );

      expect(
        find.ancestor(of: text('c1'), matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
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
      await pumpTile(tester, comment('c1', myRating: 'like', likeCount: '737'));

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
      await pumpTile(tester, comment('c1', myRating: 'like', creatorHearted: true));

      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });

    testWidgets('a disliked comment draws a filled thumb-down and an outlined thumb-up', (tester) async {
      // The dislike had no state to draw at all before 2026-09-21: `Comment`
      // carried no dislike field, so this glyph was a hardcoded outline that
      // stayed outlined for a comment the viewer had disliked.
      await pumpTile(tester, comment('c1', myRating: 'dislike'));

      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing);
    });
  });

  group('CommentTile — voting', () {
    Future<List<String>> pumpVotable(WidgetTester tester, Comment tile, {bool enabled = true}) async {
      final asked = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: CommentTile(
                    comment: tile,
                    onRate: enabled ? asked.add : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return asked;
    }

    testWidgets('both thumbs are pressable, and each asks for the right rating', (tester) async {
      // They were bare `Icon`s until 2026-09-21 — drawn, never pressable, on
      // every comment in the app. The same class of dead control as
      // `MediaTile.onMore` (F36).
      final asked = await pumpVotable(tester, comment('c1'));

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
      expect(asked, ['like', 'dislike']);
    });

    testWidgets('pressing the active vote asks to clear it, not to set it again', (tester) async {
      final liked = await pumpVotable(tester, comment('c1', myRating: 'like'));
      await tester.tap(find.byIcon(Icons.thumb_up));
      expect(liked, ['none']);

      final disliked = await pumpVotable(tester, comment('c2', myRating: 'dislike'));
      await tester.tap(find.byIcon(Icons.thumb_down));
      expect(disliked, ['none']);
    });

    testWidgets('switching sides asks for the other rating directly', (tester) async {
      final asked = await pumpVotable(tester, comment('c1', myRating: 'like'));
      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
      expect(asked, ['dislike']);
    });

    testWidgets('a signed-out viewer cannot press either, though the tokens are there', (tester) async {
      // The tokens on this comment are non-null — they are on anonymous pages
      // too — so a tile that enabled its buttons from them would be pressable
      // here. Gating is the caller's job and this proves it is honoured.
      final asked = await pumpVotable(tester, comment('c1'), enabled: false);

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
      expect(asked, isEmpty);
    });

    testWidgets('a vote in flight disables both buttons', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: CommentTile(comment: comment('c1'), onRate: asked.add, rating: true),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
      expect(asked, isEmpty, reason: 'a second press must not race the first');
    });
  });
}
