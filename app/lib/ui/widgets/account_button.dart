import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/update/update_config.dart';
import '../../domain/update/update_state.dart';
import '../auth_controller.dart';
import '../pages/login_page.dart';
import '../update_controller.dart';
import 'titlebar_button.dart';

/// The titlebar's account surface.
///
/// Signed in: avatar chip that opens an overlay menu with the name, handle,
/// and Sign Out.
/// Anonymous or degraded: person-glyph chip that opens the login flow.
///
/// Uses a bare [OverlayEntry] + [TapRegion] instead of [showMenu]/[PopupRoute].
/// [showMenu] pushes a [ModalRoute] which installs a full-screen
/// [ModalBarrier] — even though transparent, it has its own [MouseRegion]
/// (blocking hover) and a [GestureDetector] (consuming outside clicks so they
/// never reach the content behind).  [TapRegion] fires [onTapOutside] without
/// consuming the event, so clicks and hovers pass through to the content below.
///
/// The two signed-out states are **not** one state with one message. `degraded`
/// says the session expired; `anonymous` says you were never signed in. Task 22
/// §3: they are different messages because they call for different things from
/// the reader.
class AccountButton extends ConsumerStatefulWidget {
  const AccountButton({super.key});

  @override
  ConsumerState<AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends ConsumerState<AccountButton> {
  static const double _avatarRadius = 13.0;

  OverlayEntry? _entry;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _openMenu(AuthState auth) {
    // Toggle: second tap closes.
    if (_entry != null) {
      _dismiss();
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final Size buttonSize = box.size;

    // The OverlayEntry builder's context only has the root InheritedWidget
    // chain — it won't see any Theme widget that wraps just this subtree.
    // Capture the theme here (inside the normal build tree) and inject it.
    final capturedTheme = Theme.of(context);

    _entry = OverlayEntry(
      builder: (_) => Theme(
        data: capturedTheme,
        child: _AccountMenuOverlay(
          auth: auth,
          menuTop: topLeft.dy + buttonSize.height,
          onDismiss: _dismiss,
          onSignOut: () async {
            _dismiss();
            await ref.read(authProvider.notifier).signOut();
          },
        ),
      ),
    );
    overlayState.insert(_entry!);
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final scheme = Theme.of(context).colorScheme;
    // Only where it leads somewhere: signed out, this button opens the login
    // flow, not the menu the update lives in (architecture.md §2.14).
    final updateNotice = auth.isSignedIn && ref.watch(updateControllerProvider.select((s) => s.showsNotice));

    final Widget avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: _avatarRadius,
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundImage: auth.accountAvatarUrl == null //
              ? null
              : NetworkImage(auth.accountAvatarUrl!),
          child: auth.accountAvatarUrl != null //
              ? null
              : Icon(Icons.person, color: scheme.onSurfaceVariant, size: _avatarRadius * 1.25),
        ),
        if (updateNotice)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              key: const ValueKey('update-dot'),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        if (auth.status == AuthStatus.degraded)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: scheme.error,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
      ],
    );

    // Center loosens the SizedBox's tight constraints so CircleAvatar honours
    // its own radius instead of being forced to fill the whole button area.
    final Widget inner = Center(
      child: auth.isBusy
          ? SizedBox(
              width: _avatarRadius * 2,
              height: _avatarRadius * 2,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSurfaceVariant),
            )
          : avatar,
    );

    return TapRegion(
      groupId: 'account_menu',
      child: TitleBarWidgetButton(
        tooltip: auth.isSignedIn
            ? auth.displayName
            : (auth.status == AuthStatus.degraded ? 'Your session expired. Please sign in again' : 'Log in'),
        onTap: auth.isBusy
            ? null
            : auth.isSignedIn
            ? () => _openMenu(auth)
            : () => showLoginFlow(context),
        child: inner,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Account menu pages
// ─────────────────────────────────────────────────────────────────────────────

/// Which page the overlay is currently showing.
enum _AccountMenuPage { root, appearance, language, restrictedMode, location, updates }

// ─────────────────────────────────────────────────────────────────────────────
// Account menu overlay — no ModalBarrier, pointer events pass through
// ─────────────────────────────────────────────────────────────────────────────

/// The floating menu shown when the account button is tapped.
///
/// Inserted as a bare [OverlayEntry] (no route, no [ModalBarrier]).
/// [TapRegion] detects taps outside and calls [onDismiss], but does **not**
/// consume those events — so the click still reaches whatever is behind.
///
/// Inner navigation follows the same [AnimatedSize] + [AnimatedSwitcher]
/// pattern as [PlayerSettingsMenu]: the panel morphs to the natural height of
/// the incoming page, the old page fades + slides out, the new one fades + slides
/// in. Direction is derived in [build] the same way [PlayerSettingsMenu] does it.
class _AccountMenuOverlay extends StatefulWidget {
  const _AccountMenuOverlay({
    required this.auth,
    required this.menuTop,
    required this.onDismiss,
    required this.onSignOut,
  });

  final AuthState auth;
  final double menuTop;
  final VoidCallback onDismiss;
  final VoidCallback onSignOut;

  @override
  State<_AccountMenuOverlay> createState() => _AccountMenuOverlayState();
}

class _AccountMenuOverlayState extends State<_AccountMenuOverlay> {
  _AccountMenuPage _current = _AccountMenuPage.root;

  /// The page this widget last drew — lets [build] know the *direction* of the
  /// change before the transition starts. Pattern lifted from [PlayerSettingsMenu].
  _AccountMenuPage _shown = _AccountMenuPage.root;
  double _direction = 0;

  static const double _travel = 0.25;
  static const Duration _morph = Duration(milliseconds: 180);

  /// The Updates page's card needs its two buttons side by side; everything
  /// else fits the menu's usual width. [AnimatedSize] morphs between the two.
  static double _widthOf(_AccountMenuPage p) => p == _AccountMenuPage.updates ? 300 : 260;
  static const double _widestPage = 300;

  /// Root is depth 0; every subpage is depth 1.
  static int _depthOf(_AccountMenuPage p) => p == _AccountMenuPage.root ? 0 : 1;

  void _go(_AccountMenuPage page) => setState(() => _current = page);
  void _back() => _go(_AccountMenuPage.root);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Derived before drawing — the same pattern as [_PlayerSettingsMenuState].
    if (_current != _shown) {
      _direction = (_depthOf(_current) - _depthOf(_shown)).toDouble();
      _shown = _current;
    }

    final scheme = Theme.of(context).colorScheme;
    // Respect the app's popup theme; fall back to surfaceContainer which reads
    // as elevated without being too dark.
    final popupColor = PopupMenuTheme.of(context).color ?? scheme.surfaceContainer;

    final Widget page = KeyedSubtree(
      key: ValueKey(_shown.name),
      child: _buildPage(_shown),
    );

    return Positioned(
      top: widget.menuTop,
      right: 12.0,
      child: TapRegion(
        groupId: 'account_menu',
        // Does NOT consume the outside click — it passes through to whatever is
        // behind the overlay. See AccountButton's class-level doc.
        onTapOutside: (_) => widget.onDismiss(),
        child: Material(
          elevation: 8,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          color: popupColor,
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: _widthOf(_shown),
              maxWidth: _widthOf(_shown),
              // Cap the height to the distance from the button to the bottom of the screen,
              // minus a 12px margin so it doesn't touch the exact edge of the window.
              maxHeight: (MediaQuery.sizeOf(context).height - widget.menuTop - 12).clamp(0.0, double.infinity),
            ),
            child: AnimatedSize(
              duration: _morph,
              curve: Curves.easeOutCubic,
              // Anchored top-right: growing a taller page pushes the bottom
              // edge down and leaves the top-right corner where it was.
              alignment: Alignment.topRight,
              child: AnimatedSwitcher(
                duration: _morph,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                // The box follows the INCOMING page's size; the outgoing page
                // is positioned so it doesn't compete for layout space.
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The outgoing page keeps a width it fits in: the box has
                    // already taken the incoming page's, which may be narrower.
                    for (final prev in previousChildren)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: UnconstrainedBox(
                          alignment: Alignment.topRight,
                          constrainedAxis: Axis.vertical,
                          clipBehavior: Clip.hardEdge,
                          child: SizedBox(width: _widestPage, child: prev),
                        ),
                      ),
                    ?currentChild,
                  ],
                ),
                transitionBuilder: (child, animation) {
                  // [transitionBuilder] is called for both directions and is not
                  // told which, so the child's key distinguishes them — same
                  // reasoning as [_PlayerSettingsMenuState.build].
                  final entering = child.key == ValueKey(_shown.name);
                  final from = (entering ? _direction : -_direction) * _travel;
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(from, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: page,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPage(_AccountMenuPage page) => switch (page) {
    _AccountMenuPage.root => _AccountRootPage(
      auth: widget.auth,
      onSignOut: widget.onSignOut,
      onGo: _go,
    ),
    _AccountMenuPage.appearance => _AccountSubPage(
      title: 'Appearance',
      onBack: _back,
      children: [
        _AccountMenuItem(icon: Icons.check, label: 'Use device theme', onTap: () {}),
        _AccountMenuItem(icon: Icons.light_mode, label: 'Light', onTap: () {}),
        _AccountMenuItem(icon: Icons.dark_mode, label: 'Dark', onTap: () {}),
      ],
    ),
    _AccountMenuPage.language => _AccountSubPage(
      title: 'Display language',
      onBack: _back,
      children: [
        _AccountMenuItem(icon: Icons.check, label: 'English', onTap: () {}),
      ],
    ),
    _AccountMenuPage.restrictedMode => _AccountSubPage(
      title: 'Restricted Mode',
      onBack: _back,
      children: [
        _AccountMenuItem(icon: Icons.check, label: 'Off', onTap: () {}),
        _AccountMenuItem(icon: Icons.do_not_disturb_on, label: 'On', onTap: () {}),
      ],
    ),
    _AccountMenuPage.location => _AccountSubPage(
      title: 'Location',
      onBack: _back,
      children: [
        _AccountMenuItem(icon: Icons.check, label: 'Worldwide', onTap: () {}),
      ],
    ),
    _AccountMenuPage.updates => _AccountMenuBody(
      header: _AccountMenuPageHeader(title: 'Updates', onBack: _back, trailing: const _UpdateRefreshButton()),
      children: [_UpdatesPanel(onDone: _back)],
    ),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Pages
// ─────────────────────────────────────────────────────────────────────────────

class _AccountRootPage extends StatelessWidget {
  const _AccountRootPage({
    required this.auth,
    required this.onSignOut,
    required this.onGo,
  });

  final AuthState auth;
  final VoidCallback onSignOut;
  final void Function(_AccountMenuPage) onGo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return _AccountMenuBody(
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Avatar + name + handle ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.surfaceContainerHighest,
                  foregroundImage: auth.accountAvatarUrl == null ? null : NetworkImage(auth.accountAvatarUrl!),
                  child: auth.accountAvatarUrl != null ? null : Icon(Icons.person, color: scheme.onSurfaceVariant, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        auth.displayName,
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (auth.accountHandle != null)
                        Text(
                          auth.accountHandle!,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ── "View your channel" link ────────────────────────────────────
          InkWell(
            onTap: () {},
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                'View your channel',
                style: textTheme.bodySmall?.copyWith(color: scheme.primary),
              ),
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
      children: [
        // ── Account ────────────────────────────────────────────────────────
        _AccountMenuItem(icon: Icons.manage_accounts, label: 'Google Account', onTap: () {}),
        _AccountMenuItem(icon: Icons.switch_account, label: 'Switch account', onTap: () {}),
        _AccountMenuItem(icon: Icons.logout, label: 'Sign out', onTap: onSignOut),
        // ── Preferences ────────────────────────────────────────────────────
        const _AccountMenuDivider(),
        _AccountMenuNavItem(
          icon: Icons.brightness_4,
          label: 'Appearance',
          value: 'Dark',
          onTap: () => onGo(_AccountMenuPage.appearance),
        ),
        _AccountMenuNavItem(
          icon: Icons.language,
          label: 'Display language',
          value: 'English',
          onTap: () => onGo(_AccountMenuPage.language),
        ),
        _AccountMenuNavItem(
          icon: Icons.do_not_disturb_on,
          label: 'Restricted Mode',
          value: 'Off',
          onTap: () => onGo(_AccountMenuPage.restrictedMode),
        ),
        _AccountMenuNavItem(
          icon: Icons.public,
          label: 'Location',
          onTap: () => onGo(_AccountMenuPage.location),
        ),
        _AccountMenuItem(icon: Icons.keyboard, label: 'Keyboard shortcuts', onTap: () {}),
        // ── Settings ───────────────────────────────────────────────────────
        const _AccountMenuDivider(),
        _AccountMenuItem(icon: Icons.settings, label: 'Settings', onTap: () {}),
        _UpdateMenuItem(onOpen: () => onGo(_AccountMenuPage.updates)),
        // ── Help ───────────────────────────────────────────────────────────
        const _AccountMenuDivider(),
        _AccountMenuItem(icon: Icons.help_outline, label: 'Help', onTap: () {}),
        _AccountMenuItem(icon: Icons.feedback, label: 'Send feedback', onTap: () {}),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _AccountSubPage extends StatelessWidget {
  const _AccountSubPage({
    required this.title,
    required this.onBack,
    required this.children,
  });

  final String title;
  final VoidCallback onBack;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => _AccountMenuBody(
    header: _AccountMenuPageHeader(title: title, onBack: onBack),
    children: [...children, const SizedBox(height: 4)],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared layout primitives
// ─────────────────────────────────────────────────────────────────────────────

/// The shape every page has: optional sticky header above a scrollable list.
class _AccountMenuBody extends StatelessWidget {
  const _AccountMenuBody({this.header, required this.children});

  final Widget? header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sticky — outside the scroll view so it cannot scroll away.
        ?header,
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}

/// The back-button header for subpages, with a divider underneath.
class _AccountMenuPageHeader extends StatelessWidget {
  const _AccountMenuPageHeader({required this.title, this.onBack, this.trailing});

  final String title;
  final VoidCallback? onBack;

  /// An action at the right end of the header, outside the back tap target.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget row = Padding(
      padding: EdgeInsets.fromLTRB(onBack != null ? 8 : 16, 12, 16, 12),
      child: Row(
        children: [
          if (onBack != null) ...[
            Icon(Icons.chevron_left, size: 20, color: scheme.onSurface),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              title,
              style: textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (onBack != null) row = InkWell(onTap: onBack, child: row);
    if (trailing != null) {
      row = Row(
        children: [
          Expanded(child: row),
          Padding(padding: const EdgeInsets.only(right: 8), child: trailing),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }
}

/// A standard icon + label row.
class _AccountMenuItem extends StatelessWidget {
  const _AccountMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.leading,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Replaces the icon — a spinner while something is running.
  final Widget? leading;

  /// Icon and label colour when the row needs attention; `onSurface` otherwise.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            leading ?? Icon(icon, size: 20, color: color ?? scheme.onSurface),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: textTheme.bodySmall?.copyWith(color: color ?? scheme.onSurface),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// An [_AccountMenuItem] that navigates to a subpage: shows [value] + chevron.
class _AccountMenuNavItem extends StatelessWidget {
  const _AccountMenuNavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return _AccountMenuItem(
      icon: icon,
      label: label,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null) ...[
            Text(
              value!,
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 4),
          ],
          Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// A thin section-separator divider.
class _AccountMenuDivider extends StatelessWidget {
  const _AccountMenuDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 9,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

/// Open the login flow.
///
/// Task 22 §6.8's refresh is not here: `AuthController.signIn` bumps
/// [authRefreshProvider] on success, so every auth-sensitive surface reloads
/// whatever route reached the flow — and a cancelled flow, which never reaches
/// `signIn`, reloads nothing.
Future<void> _signIn(BuildContext context, WidgetRef ref) => showLoginFlow(context);

/// The public entry point. Same body; named so other surfaces can call it.
Future<void> openLoginFlow(BuildContext context, WidgetRef ref) => _signIn(context, ref);

// ─────────────────────────────────────────────────────────────────────────────
// Updates (architecture.md §2.14)
// ─────────────────────────────────────────────────────────────────────────────

/// The root page's update row. Idle, it checks and then opens [_UpdatesPanel]
/// with the result; while a check or download runs it says so; with an update
/// on offer it is highlighted and opens the panel directly.
class _UpdateMenuItem extends ConsumerWidget {
  const _UpdateMenuItem({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final spinner = SizedBox(
      width: 20,
      height: 20,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSurfaceVariant),
      ),
    );

    Future<void> checkThenOpen() async {
      await ref.read(updateControllerProvider.notifier).checkNow();
      if (context.mounted) onOpen();
    }

    return switch (state.phase) {
      UpdateChecking() => _AccountMenuItem(
        icon: Icons.system_update_alt,
        label: 'Checking for updates…',
        leading: spinner,
        onTap: null,
      ),
      UpdateDownloading(:final received, :final total) => _AccountMenuItem(
        icon: Icons.downloading,
        label: 'Downloading update · ${_percent(received, total)}%',
        onTap: onOpen,
      ),
      UpdateReady() => _AccountMenuItem(
        icon: Icons.restart_alt,
        label: 'Restart to update',
        color: scheme.primary,
        onTap: onOpen,
      ),
      UpdateAvailable(:final manifest) => _AccountMenuItem(
        icon: Icons.system_update_alt,
        label: 'Update ${manifest.version} available',
        color: scheme.primary,
        onTap: onOpen,
      ),
      UpdateInstalling() => _AccountMenuItem(
        icon: Icons.restart_alt,
        label: 'Restarting to update…',
        leading: spinner,
        onTap: null,
      ),
      _ => _AccountMenuItem(
        icon: Icons.system_update_alt,
        label: 'Check for updates',
        onTap: ref.read(updateConfigProvider).enabled ? checkThenOpen : onOpen,
      ),
    };
  }
}

/// The Updates page: a card for whatever the updater has to say — the update
/// on offer with its notes and actions, a download in progress, a failure, or
/// that all is well — then the running version, the last check, and the
/// automatic-update switch. Lives in the account menu because there is no
/// settings page yet (architecture.md §2.14).
class _UpdatesPanel extends ConsumerWidget {
  const _UpdatesPanel({required this.onDone});

  /// Back to the root page; "Later" goes there after dismissing.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final config = ref.watch(updateConfigProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lastChecked = state.lastChecked;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (config.overridden)
            Container(
              key: const ValueKey('update-test-marker'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: const BorderRadius.all(Radius.circular(6)),
              ),
              child: Text(
                'TEST FEED · ${config.activeOverrides.join('/')}',
                style: textTheme.labelSmall?.copyWith(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700),
              ),
            ),
          _UpdateCard(state: state, enabled: config.enabled, onLater: () async {
            await controller.dismiss();
            onDone();
          }),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _UpdateInfoRow(label: 'Version', value: state.currentVersion?.toString() ?? 'Development build'),
                _UpdateInfoRow(label: 'Last checked', value: lastChecked == null ? 'Never' : _ago(lastChecked)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: Text('Download updates automatically', style: textTheme.bodySmall)),
                    Switch(
                      value: state.autoUpdate,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: config.enabled ? controller.setAutoUpdate : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The header's refresh action: a manual check, a spinner while one runs.
class _UpdateRefreshButton extends ConsumerWidget {
  const _UpdateRefreshButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(updateControllerProvider.select((s) => s.phase));
    final enabled = ref.watch(updateConfigProvider).enabled;
    final scheme = Theme.of(context).colorScheme;
    if (phase is UpdateChecking) {
      return SizedBox.square(
        dimension: 32,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
      );
    }
    return IconButton(
      tooltip: 'Check for updates',
      icon: const Icon(Icons.refresh, size: 20),
      color: scheme.primary,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      onPressed: enabled && canStartCheck(phase) ? () => ref.read(updateControllerProvider.notifier).checkNow() : null,
    );
  }
}

/// The card at the top of the Updates page. Accent-coloured when there is an
/// update to act on, error-coloured for a failure, neutral otherwise.
class _UpdateCard extends ConsumerWidget {
  const _UpdateCard({required this.state, required this.enabled, required this.onLater});

  final UpdateState state;
  final bool enabled;
  final VoidCallback onLater;

  static const _maxNotes = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(updateControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final phase = state.phase;
    final manifest = phase.manifest;
    final version = manifest?.version.toString() ?? '';

    final (Color background, Color foreground) = switch (phase) {
      _ when !enabled => (scheme.surfaceContainerHighest, scheme.onSurface),
      UpdateError() => (scheme.errorContainer, scheme.onErrorContainer),
      UpdateAvailable() || UpdateDownloading() || UpdateReady() || UpdateInstalling() =>
        (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    final muted = foreground.withValues(alpha: 0.72);

    final String headline = !enabled
        ? 'Updates are off'
        : switch (phase) {
            UpdateIdle() => 'Not checked yet',
            UpdateChecking() => 'Checking for updates…',
            UpdateUpToDate() => 'Rill is up to date',
            UpdateAvailable() => 'Rill $version is available!',
            UpdateDownloading() => 'Downloading Rill $version',
            UpdateReady() => 'Rill $version is ready!',
            UpdateInstalling() => 'Restarting to update…',
            UpdateError(:final kind) => _errorHeadline(kind),
          };

    final String? detail = !enabled
        ? 'This is a development build, which has no version to compare with a release.'
        : switch (phase) {
            UpdateDownloading(:final received, :final total) =>
              '${_percent(received, total)}% of ${(total / (1024 * 1024)).toStringAsFixed(1)} MB',
            UpdateError(:final message) => message,
            _ => null,
          };

    final offersNotes = enabled && manifest != null && phase is! UpdateError && manifest.notes.isNotEmpty;
    final canLater = !state.isMandatory && state.dismissedVersion != version;

    final Widget? actions = !enabled
        ? null
        : switch (phase) {
            UpdateReady() => _UpdateActions(
              primary: FilledButton(onPressed: controller.install, child: const Text('Restart to update')),
              later: canLater ? onLater : null,
            ),
            UpdateAvailable() => _UpdateActions(
              primary: FilledButton(onPressed: controller.download, child: const Text('Download')),
              later: canLater ? onLater : null,
            ),
            UpdateError() => Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: foreground),
                onPressed: () => controller.checkNow(),
                child: const Text('Try again'),
              ),
            ),
            _ => null,
          };

    return Container(
      key: const ValueKey('update-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: background, borderRadius: const BorderRadius.all(Radius.circular(16))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(headline, style: textTheme.titleMedium?.copyWith(color: foreground, fontWeight: FontWeight.w700)),
          if (state.isMandatory) ...[
            const SizedBox(height: 2),
            Text('This update is required.', style: textTheme.bodySmall?.copyWith(color: foreground, fontWeight: FontWeight.w600)),
          ],
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail, style: textTheme.bodySmall?.copyWith(color: muted)),
          ],
          if (phase case UpdateDownloading(:final received, :final total)) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: total == 0 ? null : received / total),
          ] else if (phase is UpdateChecking) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
          if (offersNotes) ...[
            const SizedBox(height: 8),
            Text(
              "WHAT'S NEW",
              style: textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w700, letterSpacing: 0.8),
            ),
            const SizedBox(height: 6),
            for (final note in manifest.notes.take(_maxNotes))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: textTheme.bodySmall?.copyWith(color: foreground)),
                    Expanded(child: Text(note, style: textTheme.bodySmall?.copyWith(color: foreground))),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(4)),
                onTap: () => unawaited(
                  launchUrl(Uri.parse('${UpdateConfig.releasePageBase}${manifest.tag}'), mode: LaunchMode.externalApplication),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Full release notes', style: textTheme.bodySmall?.copyWith(color: scheme.primary)),
                      const SizedBox(width: 4),
                      Icon(Icons.north_east, size: 14, color: scheme.primary),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (actions != null) ...[const SizedBox(height: 12), actions],
        ],
      ),
    );
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({required this.primary, this.later});

  final Widget primary;
  final VoidCallback? later;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      primary,
      if (later != null) TextButton(onPressed: later, child: const Text('Later')),
    ],
  );
}

class _UpdateInfoRow extends StatelessWidget {
  const _UpdateInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style?.copyWith(color: scheme.onSurfaceVariant))),
          Text(value, style: style),
        ],
      ),
    );
  }
}

int _percent(int received, int total) => total <= 0 ? 0 : (received * 100 ~/ total).clamp(0, 100);

String _errorHeadline(UpdateErrorKind kind) => switch (kind) {
  UpdateErrorKind.network => "Couldn't reach the update server",
  UpdateErrorKind.signature => 'The update failed verification',
  UpdateErrorKind.manifest => 'The update information was invalid',
  UpdateErrorKind.integrity => 'The download was corrupted',
  UpdateErrorKind.disk => "Couldn't save the update",
  UpdateErrorKind.install => "Couldn't start the installer",
};

String _ago(DateTime time) {
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 1) return 'Just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
  return elapsed.inDays == 1 ? 'Yesterday' : '${elapsed.inDays} days ago';
}
