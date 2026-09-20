import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth_controller.dart';
import '../pages/login_page.dart';
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

    final Widget avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: _avatarRadius,
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundImage: auth.accountAvatarUrl == null
              ? null
              : NetworkImage(auth.accountAvatarUrl!),
          child: auth.accountAvatarUrl != null
              ? null
              : Icon(Icons.person, color: scheme.onSurfaceVariant, size: _avatarRadius * 1.25),
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
            : (auth.status == AuthStatus.degraded
                ? 'Your session expired. Please sign in again'
                : 'Log in'),
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

  /// Root is depth 0; every subpage is depth 1.
  static int _depthOf(_AccountMenuPage p) =>
      p == _AccountMenuPage.root ? 0 : 1;

  void _go(_AccountMenuPage page) => setState(() => _current = page);
  void _back() => _go(_AccountMenuPage.root);

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
              minWidth: 260,
              maxWidth: 260,
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
                    for (final prev in previousChildren)
                      Positioned(top: 0, left: 0, right: 0, child: prev),
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
                  foregroundImage: auth.accountAvatarUrl == null
                      ? null
                      : NetworkImage(auth.accountAvatarUrl!),
                  child: auth.accountAvatarUrl != null
                      ? null
                      : Icon(Icons.person, color: scheme.onSurfaceVariant, size: 28),
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
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

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
            Icon(icon, size: 20, color: scheme.onSurface),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurface),
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
