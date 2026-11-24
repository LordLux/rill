/// The settings page — Task 40 (`todo.md` 69, 16).
///
/// What it promises: it opens from the account menu and Back or Escape leaves it; every
/// moved setting's control writes the provider the app already reads, under the key it
/// was always stored under, so nobody loses a value; the members-only switch (todo 16)
/// filters every list and is remembered; every control is named; and Tab walks it in
/// reading order.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/shelf.dart';
import 'package:rill/domain/update/app_version.dart';
import 'package:rill/domain/update/update_manifest.dart';
import 'package:rill/domain/update/update_state.dart';
import 'package:rill/domain/ytdlp/ytdlp_state.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/captions_controller.dart';
import 'package:rill/ui/feed_controller.dart';
import 'package:rill/ui/focus_ring.dart';
import 'package:rill/ui/members_only_preference.dart';
import 'package:rill/ui/page_wrapper.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/promoted_preference.dart';
import 'package:rill/ui/session_restore.dart';
import 'package:rill/ui/settings/sections/about_section.dart';
import 'package:rill/ui/settings/sections/captions_section.dart';
import 'package:rill/ui/settings/sections/feeds_section.dart';
import 'package:rill/ui/settings/sections/general_section.dart';
import 'package:rill/ui/settings/settings_page.dart';
import 'package:rill/ui/settings/settings_sections.dart';
import 'package:rill/ui/shelf_visibility.dart';
import 'package:rill/ui/update_controller.dart';
import 'package:rill/ui/widgets/feed_view.dart';
import 'package:rill/ui/widgets/shelf_row.dart';
import 'package:rill/ui/ytdlp_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_engine.dart';
import 'settings_harness.dart';

class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);
  final AuthState initial;
  @override
  AuthState build() => initial;
}

/// Parked, with no timers: the real one schedules a check 30 s after it starts.
class _IdleUpdate extends UpdateController {
  @override
  UpdateState build() => const UpdateState(phase: UpdatePhase.idle());
}

/// An update ready to install, so About shows Restart to update and Later.
class _ReadyUpdate extends UpdateController {
  @override
  UpdateState build() => UpdateState(
        currentVersion: const AppVersion(major: 0, minor: 2, patch: 2),
        phase: UpdatePhase.ready(
          installerPath: 'Rill-Setup-x64.exe',
          manifest: UpdateManifest(
            schema: 1,
            version: const AppVersion(major: 0, minor: 3, patch: 0),
            tag: 'v0.3.0',
            notes: const [],
            windowsX64: UpdateAsset(name: 'Rill-Setup-x64.exe', url: Uri.parse('https://example.invalid/x.exe'), sha256: '0' * 64, size: 10),
          ),
        ),
      );

  @override
  Future<void> dismiss() async => state = state.copyWith(dismissedVersion: '0.3.0');
}

class _OnPathYtDlp extends YtDlpController {
  @override
  YtDlpState build() => const YtDlpState(phase: YtDlpPhase.idle(), location: YtDlpLocation.onPath, onPathPath: 'yt-dlp');
}

/// Nothing playing, so the captions controller loads no track.
class _NoPlayback extends PlaybackController {
  @override
  PlaybackState build() => const PlaybackState();
}

class _StubFeed extends FeedController {
  _StubFeed(this.initial);
  final FeedState initial;
  @override
  FeedState build() => initial;
}

const signedIn = AuthState(status: AuthStatus.authenticated, accountName: 'Ada Lovelace', accountHandle: '@ada');

VideoItem _video(String id, {bool members = false}) => VideoItem(
      kind: 'video',
      id: id,
      title: id,
      channelName: 'Channel',
      thumbnailUrl: '',
      isLive: false,
      isMembersOnly: members,
      canWatchLater: false,
      canAddToQueue: false,
    );

List<Override> _overrides({AuthState auth = signedIn, bool updateReady = false}) => [
      authProvider.overrideWith(() => _FixedAuth(auth)),
      if (updateReady) updateControllerProvider.overrideWith(_ReadyUpdate.new) else updateControllerProvider.overrideWith(_IdleUpdate.new),
      updateConfigProvider.overrideWithValue(UpdateConfig.resolve(releaseMode: false, version: '0.2.2')),
      ytDlpControllerProvider.overrideWith(_OnPathYtDlp.new),
      playbackEngineProvider.overrideWithValue(FakeEngine()),
      playbackProvider.overrideWith(_NoPlayback.new),
    ];

void _bigWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The home page with the real top bar, so the account menu is the real one.
Future<void> pumpHome(WidgetTester tester, {AuthState auth = signedIn}) async {
  _bigWindow(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    settingsTestApp(
      overrides: _overrides(auth: auth),
      home: const PageWrapper(title: Text('Rill'), body: SizedBox(key: ValueKey('home-body'))),
    ),
  );
  await tester.pump();
}

/// The settings page alone, at [section].
Future<ProviderContainer> pumpSettings(WidgetTester tester, {String section = 'general', bool updateReady = false}) async {
  _bigWindow(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(settingsTestApp(overrides: _overrides(updateReady: updateReady), home: const SettingsPage()));
  await tester.pump();
  final container = ProviderScope.containerOf(tester.element(find.byType(SettingsPage)));
  if (section != 'general') {
    await tester.tap(find.byKey(settingsSectionTabKey(section)));
    await tester.pumpAndSettle();
  }
  return container;
}

Future<void> openAccountMenu(WidgetTester tester, {String tooltip = 'Ada Lovelace'}) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

/// What has keyboard focus, by the nearest string key or semantics label above it.
String focusedName() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return 'none';
  String? name;
  bool visit(Widget widget) {
    if (widget.key is ValueKey<String>) {
      name = (widget.key! as ValueKey<String>).value;
    } else if (widget is Semantics && (widget.properties.label ?? '').isNotEmpty) {
      name = widget.properties.label;
    }
    return name == null;
  }

  if (visit(context.widget)) {
    context.visitAncestorElements((element) => visit(element.widget));
  }
  return name ?? 'unnamed';
}

Future<List<String>> tabWalk(WidgetTester tester, int count) async {
  final seen = <String>[];
  for (var i = 0; i < count; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    seen.add(focusedName());
  }
  return seen;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('opening and leaving', () {
    testWidgets('the account menu opens it, and the back arrow returns to the page it was opened over', (tester) async {
      await pumpHome(tester);
      await openAccountMenu(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('Sign out'), findsNothing, reason: 'the menu closed');
      // The top bar and its window controls are still there, over the page (the login
      // page once hid them).
      expect(find.byTooltip('Toggle menu'), findsOneWidget);
      for (final section in settingsSections) {
        expect(find.byKey(settingsSectionTabKey(section.id)), findsOneWidget);
      }

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byKey(const ValueKey('home-body')), findsOneWidget);
    });

    testWidgets('Escape leaves it', (tester) async {
      await pumpHome(tester);
      await openAccountMenu(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Feeds'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
    });

    testWidgets("Escape in the top bar's search box does not leave it", (tester) async {
      await pumpHome(tester);
      await openAccountMenu(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget, reason: 'Escape belongs to the field');
    });

    testWidgets('signed out, the menu has Settings too', (tester) async {
      await pumpHome(tester, auth: const AuthState(status: AuthStatus.anonymous));
      await openAccountMenu(tester, tooltip: 'Log in');
      expect(find.text('Home page rows'), findsNothing, reason: 'moved to Settings › Feeds');
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('the sidebar shows one section at a time', (tester) async {
      await pumpSettings(tester);
      expect(find.byKey(restoreSessionSwitchKey), findsOneWidget);
      expect(find.byKey(promotedSwitchKey), findsNothing);

      await tester.tap(find.byKey(settingsSectionTabKey('feeds')));
      await tester.pumpAndSettle();
      expect(find.byKey(promotedSwitchKey), findsOneWidget);
      expect(find.byKey(restoreSessionSwitchKey), findsNothing);
    });
  });

  group('each moved setting writes the provider the app reads, under its old key', () {
    testWidgets('General: reopen where I left off, and the accent', (tester) async {
      final container = await pumpSettings(tester);
      await tester.tap(find.byKey(restoreSessionSwitchKey));
      await tester.pumpAndSettle();
      expect(container.read(restoreSessionProvider), isTrue);

      const blue = Color(0xFF2979FF);
      await tester.tap(find.bySemanticsLabel('Accent colour: Blue'));
      await tester.pumpAndSettle();
      expect(container.read(accentProvider), blue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('restore_session'), isTrue);
      expect(prefs.getInt('accent_seed_argb'), blue.toARGB32());
    });

    testWidgets('Feeds: the home rows, promoted and members-only', (tester) async {
      final container = await pumpSettings(tester, section: 'feeds');
      await tester.tap(find.byKey(shelfSwitchKey(ShelfCategory.shorts)));
      await tester.tap(find.byKey(promotedSwitchKey));
      await tester.tap(find.byKey(membersOnlySwitchKey));
      await tester.pumpAndSettle();
      expect(container.read(shelfVisibilityProvider)[ShelfCategory.shorts], isTrue);
      expect(container.read(promotedVisibleProvider), isTrue);
      expect(container.read(membersOnlyVisibleProvider), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('shelf_visible_shorts'), isTrue);
      expect(prefs.getBool('promoted_visible'), isTrue);
      expect(prefs.getBool('members_only_visible'), isFalse);
    });

    testWidgets('Captions: remember the style, and the editor works only while it is on', (tester) async {
      final container = await pumpSettings(tester, section: 'captions');
      await tester.pumpAndSettle();

      // Off: the chips are there but do nothing.
      await tester.tap(find.bySemanticsLabel('Font: Georgia'));
      await tester.pumpAndSettle();
      expect(container.read(captionsProvider).style.fontFamily, isNull);

      await tester.tap(find.byKey(keepCaptionStyleSwitchKey));
      await tester.pumpAndSettle();
      expect(container.read(keepCaptionStyleProvider), isTrue);

      await tester.tap(find.bySemanticsLabel('Font: Georgia'));
      await tester.pumpAndSettle();
      expect(container.read(captionsProvider).style.fontFamily, 'Georgia');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('keep_caption_style'), isTrue);
      expect(prefs.getString('caption_style_json'), contains('Georgia'));
    });

    testWidgets('About: download updates automatically', (tester) async {
      final container = await pumpSettings(tester, section: 'about');
      expect(tester.widget<Switch>(find.byKey(autoUpdateSwitchKey)).value, isTrue);
      await tester.tap(find.byKey(autoUpdateSwitchKey));
      await tester.pumpAndSettle();
      expect(container.read(updateControllerProvider).autoUpdate, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('update_auto'), isFalse);
    });
  });

  group('a value set on the page survives a restart', () {
    testWidgets('read back through the same store by a fresh start', (tester) async {
      await pumpSettings(tester, section: 'feeds');
      await tester.tap(find.byKey(shelfSwitchKey(ShelfCategory.posts)));
      await tester.tap(find.byKey(promotedSwitchKey));
      await tester.tap(find.byKey(membersOnlySwitchKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(settingsSectionTabKey('general')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(restoreSessionSwitchKey));
      await tester.tap(find.bySemanticsLabel('Accent colour: Teal'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(settingsSectionTabKey('captions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(keepCaptionStyleSwitchKey));
      await tester.pumpAndSettle();

      // What `main` reads before `runApp`, as it does on a launch.
      expect((await readShelfVisibility())[ShelfCategory.posts], isTrue);
      expect(await readPromotedVisible(), isTrue);
      expect(await readMembersOnlyVisible(), isFalse);
      expect(await readRestoreSession(), isTrue);

      // And the two that restore themselves in `build`, from a fresh container.
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      fresh.read(accentProvider);
      fresh.read(keepCaptionStyleProvider);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(fresh.read(accentProvider), const Color(0xFF00BFA5));
      expect(fresh.read(keepCaptionStyleProvider), isTrue);
    });
  });

  group('members-only videos (todo 16)', () {
    testWidgets('the switch takes them out of a feed and a home row, and is remembered', (tester) async {
      _bigWindow(tester);
      final feed = FeedState(
        surface: FeedController.surface,
        isLoading: false,
        items: [_video('open-grid'), _video('members-grid', members: true)],
      );
      await tester.pumpWidget(
        settingsTestApp(
          overrides: [..._overrides(), feedProvider.overrideWith(() => _StubFeed(feed))],
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: 520, child: SingleChildScrollView(child: Builder(builder: (context) => feedsSection.builder(context)))),
                Expanded(
                  child: Column(
                    children: [
                      SizedBox(
                        height: 420,
                        child: ShelfRow(
                          shelf: Shelf(
                            category: ShelfCategory.other,
                            title: 'A row',
                            index: 0,
                            items: [ShelfTile(_video('open-row')), ShelfTile(_video('members-row', members: true))],
                          ),
                        ),
                      ),
                      Expanded(child: FeedView(provider: feedProvider)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('members-grid'), findsOneWidget);
      expect(find.text('members-row'), findsOneWidget);

      await tester.tap(find.byKey(membersOnlySwitchKey));
      await tester.pump();
      expect(find.text('members-grid'), findsNothing);
      expect(find.text('members-row'), findsNothing);
      expect(find.text('open-grid'), findsOneWidget);
      expect(find.text('open-row'), findsOneWidget);
      expect(await readMembersOnlyVisible(), isFalse, reason: 'the choice was not saved');
    });
  });

  group('Narrator and the keyboard', () {
    for (final section in settingsSections) {
      testWidgets('every tap target in ${section.title} has a label', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpSettings(tester, section: section.id);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }

    testWidgets('a switch is one node that says its label and its state', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSettings(tester, section: 'feeds');
      final node = tester.getSemantics(find.byKey(membersOnlySwitchKey));
      expect(node.label, startsWith('Members-only videos'));
      expect(node, isSemantics(hasToggledState: true, isToggled: true));
      handle.dispose();
    });

    testWidgets('Tab walks the sidebar, then the section, in reading order', (tester) async {
      await pumpSettings(tester);
      Focus.of(tester.element(find.text('General').first)).requestFocus();
      await tester.pump();
      expect(focusedName(), 'General');

      final walk = await tabWalk(tester, 10);
      expect(walk, [
        'Feeds',
        'Captions',
        'About',
        restoreSessionSwitchKey.value,
        for (final preset in kAccentPresets) 'Accent colour: ${preset.name}',
      ]);
    });

    group('a control pressed from the keyboard keeps focus', () {
      setUp(KeyboardNavigation.install);

      Future<FocusNode> focusOn(WidgetTester tester, Finder finder) async {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab); // keyboard navigation on
        await tester.pump();
        Focus.of(tester.element(finder)).requestFocus();
        await tester.pump();
        return FocusManager.instance.primaryFocus!;
      }

      testWidgets('the size stepper at the end of its range', (tester) async {
        final container = await pumpSettings(tester, section: 'captions');
        await tester.tap(find.byKey(keepCaptionStyleSwitchKey));
        await tester.pumpAndSettle();
        final node = await focusOn(
          tester,
          find.byWidgetPredicate((w) => w is Icon && (w.semanticLabel ?? '').startsWith('Decrease caption size')),
        );
        for (var i = 0; i < 8; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
        }
        expect(container.read(captionsProvider).style.fontSizePercent, 50);
        expect(FocusManager.instance.primaryFocus, same(node), reason: 'focus left the stepper at 50%');
      });

      testWidgets('Reset caption style, with nothing left to reset', (tester) async {
        await pumpSettings(tester, section: 'captions');
        await tester.tap(find.byKey(keepCaptionStyleSwitchKey));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('Font: Georgia'));
        await tester.pumpAndSettle();
        final node = await focusOn(tester, find.text('Reset caption style'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus, same(node));
      });

      testWidgets("Later, which removes itself, hands focus to the card's main button", (tester) async {
        await pumpSettings(tester, section: 'about', updateReady: true);
        await focusOn(tester, find.text('Later'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextButton, 'Later'), findsNothing);
        final focused = FocusManager.instance.primaryFocus?.context;
        expect(focused, isNotNull);
        expect(
          focused!.findAncestorWidgetOfExactType<FilledButton>(),
          isNotNull,
          reason: 'focus went to ${focused.widget}, not Restart to update',
        );
      });
    });

    testWidgets('on Feeds: the rows top to bottom, then every list', (tester) async {
      await pumpSettings(tester, section: 'feeds');
      Focus.of(tester.element(find.text('About').first)).requestFocus();
      await tester.pump();

      final walk = await tabWalk(tester, 6);
      expect(walk, [
        for (final category in [ShelfCategory.members, ShelfCategory.shorts, ShelfCategory.posts, ShelfCategory.other])
          shelfSwitchKey(category).value,
        membersOnlySwitchKey.value,
        promotedSwitchKey.value,
      ]);
    });
  });
}
