import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/update/update_state.dart';
import '../../domain/ytdlp/ytdlp_state.dart';
import '../auth_controller.dart';
import '../focus_ring.dart';
import '../pages/login_page.dart';
import '../settings/sections/about_section.dart' show aboutSettingsSectionId, updatePercent;
import '../settings/settings_page.dart';
import '../update_controller.dart';
import '../ytdlp_controller.dart';
import 'titlebar_button.dart';

/// The titlebar's account surface.
///
/// Signed in: avatar chip that opens an overlay menu with the name, handle,
/// and Sign Out.
/// Anonymous or degraded: person-glyph chip that opens a short menu whose first
/// action is Sign in, so the rows that need no account (updates) stay reachable.
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

  /// The button's own focus, so closing the menu can hand it back.
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'account button');

  /// The open menu's scope: Tab cycles inside it and cannot reach the page
  /// behind, which a bare `OverlayEntry` otherwise lets it do.
  final FocusScopeNode _menuScope = FocusScopeNode(debugLabel: 'account menu');

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    _buttonFocus.dispose();
    _menuScope.dispose();
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
          scope: _menuScope,
          auth: auth,
          menuTop: topLeft.dy + buttonSize.height,
          onDismiss: _dismiss,
          onSignIn: () {
            _dismiss();
            showLoginFlow(context);
          },
          onSignOut: () async {
            _dismiss();
            await ref.read(authProvider.notifier).signOut();
          },
          onOpenSettings: (section) {
            _dismiss();
            openSettingsPage(ref, section: section);
          },
        ),
      ),
    );
    overlayState.insert(_entry!);
  }

  /// Closes the menu, and gives focus back to the button **only if the menu had
  /// it.** An outside click dismisses through the same path, and the click
  /// already moved focus to whatever was clicked — taking it back would undo that.
  void _dismiss() {
    final hadFocus = _menuScope.hasFocus;
    _entry?.remove();
    _entry = null;
    if (hadFocus && mounted) _buttonFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final scheme = Theme.of(context).colorScheme;
    final updateNotice = ref.watch(updateControllerProvider.select((s) => s.showsNotice));
    // The bottom-right dot means "needs attention" for either reason
    // (todo.md 49): an expired session, or a yt-dlp download that failed.
    // yt-dlp's ordinary absence (declined, undecided, still downloading) is
    // not urgent enough to earn the dot — only YtDlpRowSeverity.problem is.
    final needsAttention =
        auth.status == AuthStatus.degraded || ref.watch(ytDlpControllerProvider.select((s) => s.severity == YtDlpRowSeverity.problem));

    final Widget avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: _avatarRadius,
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundImage:
              auth.accountAvatarUrl ==
                  null //
              ? null
              : NetworkImage(auth.accountAvatarUrl!),
          child:
              auth.accountAvatarUrl !=
                  null //
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
        if (needsAttention)
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
        focusNode: _buttonFocus,
        tooltip: auth.isSignedIn
            ? (needsAttention ? '${auth.displayName} — needs attention' : auth.displayName)
            : (auth.status == AuthStatus.degraded
                  ? 'Your session expired. Please sign in again'
                  : (needsAttention ? 'Needs attention. Log in' : 'Log in')),
        // Signed out too: the menu is where updates live, so it has to open
        // for everyone; signed out, its first action is Sign in (§2.14).
        onTap: auth.isBusy ? null : () => _openMenu(auth),
        child: inner,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Account menu pages
// ─────────────────────────────────────────────────────────────────────────────

/// Which page the overlay is currently showing.
enum _AccountMenuPage { root, appearance, language, restrictedMode, location }

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
    required this.scope,
    required this.auth,
    required this.menuTop,
    required this.onDismiss,
    required this.onSignIn,
    required this.onSignOut,
    required this.onOpenSettings,
  });

  final FocusScopeNode scope;
  final AuthState auth;
  final double menuTop;
  final VoidCallback onDismiss;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  /// Closes the menu and opens the settings page, at a section when one is named.
  final void Function(String? section) onOpenSettings;

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

  /// Every page is the menu's one width; the wide Updates page moved to the settings page.
  static double _widthOf(_AccountMenuPage p) => 260;
  static const double _widestPage = 260;

  /// Root is depth 0; every subpage is depth 1.
  static int _depthOf(_AccountMenuPage p) => p == _AccountMenuPage.root ? 0 : 1;

  void _go(_AccountMenuPage page) => setState(() => _current = page);
  void _back() => _go(_AccountMenuPage.root);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    // Explicit rather than `FocusScope(autofocus: true)`, which does nothing
    // while the button that opened this still holds the parent scope's focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.scope.requestFocus();
    });
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
        child: FocusRingShape(
          inflate: -1, // rows fill the panel edge to edge
          child: FocusScope(
          node: widget.scope,
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
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
          ),
          ),
      ),
    );
  }

  Widget _buildPage(_AccountMenuPage page) => switch (page) {
    _AccountMenuPage.root when !widget.auth.isSignedIn => _SignedOutRootPage(
      auth: widget.auth,
      onSignIn: widget.onSignIn,
      onOpenSettings: widget.onOpenSettings,
    ),
    _AccountMenuPage.root => _AccountRootPage(
      auth: widget.auth,
      onSignOut: widget.onSignOut,
      onGo: _go,
      onOpenSettings: widget.onOpenSettings,
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
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Pages
// ─────────────────────────────────────────────────────────────────────────────

/// The root page when nobody is signed in: why, a way to sign in, and the
/// rows that matter without an account — updates, for one (architecture.md §2.14).
class _SignedOutRootPage extends StatelessWidget {
  const _SignedOutRootPage({required this.auth, required this.onSignIn, required this.onOpenSettings});

  final AuthState auth;
  final VoidCallback onSignIn;
  final void Function(String? section) onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final expired = auth.status == AuthStatus.degraded;

    return _AccountMenuBody(
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Task 22 §3: the two signed-out states say different things.
                Text(
                  expired ? 'Your session expired' : "You're not signed in",
                  style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  expired
                      ? 'Sign in again to see your subscriptions and history.'
                      : 'Sign in to see your subscriptions, history and recommendations.',
                  style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onSignIn,
                  icon: const Icon(Icons.login, size: 18),
                  label: Text(expired ? 'Sign in again' : 'Sign in'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
      children: [
        // The settings page needs no account, so it is here too.
        _AccountMenuItem(icon: Icons.settings, label: 'Settings', onTap: () => onOpenSettings(null)),
        _UpdateMenuItem(onOpen: () => onOpenSettings(aboutSettingsSectionId)),
        _YtDlpMenuItem(onOpen: () => onOpenSettings(aboutSettingsSectionId)),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _AccountRootPage extends StatelessWidget {
  const _AccountRootPage({
    required this.auth,
    required this.onSignOut,
    required this.onGo,
    required this.onOpenSettings,
  });

  final AuthState auth;
  final VoidCallback onSignOut;
  final void Function(_AccountMenuPage) onGo;
  final void Function(String? section) onOpenSettings;

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
        _AccountMenuItem(icon: Icons.settings, label: 'Settings', onTap: () => onOpenSettings(null)),
        // Status rows: what they report lives on Settings › About, and they open it there.
        _UpdateMenuItem(onOpen: () => onOpenSettings(aboutSettingsSectionId)),
        _YtDlpMenuItem(onOpen: () => onOpenSettings(aboutSettingsSectionId)),
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
  const _AccountMenuPageHeader({required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [row, Divider(height: 1, color: scheme.outlineVariant)],
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

/// The root page's update row. Idle, it starts a check and opens Settings › About,
/// where the result lands; while a check or download runs it says so; with an
/// update on offer it is highlighted and opens About directly.
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

    void checkThenOpen() {
      unawaited(ref.read(updateControllerProvider.notifier).checkNow());
      onOpen();
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


// ─────────────────────────────────────────────────────────────────────────────
// yt-dlp (todo.md 49)
// ─────────────────────────────────────────────────────────────────────────────

/// The root pages' yt-dlp row — always there while [YtDlpRowSeverity] is not
/// [YtDlpRowSeverity.none], the same "always present, label and colour follow
/// the state" shape as [_UpdateMenuItem]. yt-dlp is optional, so its ordinary
/// absence (declined, undecided, or a download under way) reads in a calm
/// tertiary colour; only [YtDlpRowSeverity.problem] — an attempted download
/// that failed — turns it the same red as an actual error (revised 2026-09-28
/// after live testing: the first version called every missing case "a
/// problem" and showed a red warning for all of them, which overstated an
/// absence most videos never notice).
class _YtDlpMenuItem extends ConsumerWidget {
  const _YtDlpMenuItem({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ytDlpControllerProvider);
    if (state.severity == YtDlpRowSeverity.none) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final color = state.severity == YtDlpRowSeverity.problem ? scheme.error : scheme.tertiary;
    final spinner = SizedBox(
      width: 20,
      height: 20,
      child: Padding(padding: const EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2, color: color)),
    );

    return switch (state.phase) {
      YtDlpChecking() => _AccountMenuItem(icon: Icons.warning_amber_rounded, label: 'Checking yt-dlp…', leading: spinner, color: color, onTap: null),
      YtDlpDownloading() => _AccountMenuItem(icon: Icons.warning_amber_rounded, label: 'Downloading yt-dlp…', leading: spinner, color: color, onTap: onOpen),
      YtDlpPhaseError() => _AccountMenuItem(icon: Icons.warning_amber_rounded, label: 'yt-dlp download failed', color: color, onTap: onOpen),
      _ => _AccountMenuItem(icon: Icons.warning_amber_rounded, label: 'yt-dlp not installed', color: color, onTap: onOpen),
    };
  }
}

int _percent(int received, int total) => updatePercent(received, total);
