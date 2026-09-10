import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth_controller.dart';
import '../pages/login_page.dart';

/// The top bar's account surface — Task 22 §7, and no more than §7.
///
/// Signed in: the avatar and, in the menu, the name, the handle and Sign Out.
/// Anonymous or degraded: the person glyph the placeholder used to be, and a
/// Log In that now works. The full settings page is a later task and nothing
/// here anticipates it.
///
/// The two signed-out states are **not** one state with one message. `degraded`
/// says the session expired; `anonymous` says you were never signed in. Task 22
/// §3: they are different messages because they call for different things from
/// the reader.
class AccountButton extends ConsumerWidget {
  const AccountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final scheme = Theme.of(context).colorScheme;

    if (auth.isSignedIn) return _SignedInMenu(auth: auth);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Tooltip(
        message: auth.status == AuthStatus.degraded
            ? 'Your session expired. Please sign in again'
            : 'Log in',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: auth.isBusy ? null : () => _signIn(context, ref),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: scheme.surfaceContainerHighest,
                child: Icon(Icons.person, color: scheme.onSurfaceVariant, size: 20),
              ),
              // A degraded session is the one signed-out state worth marking:
              // nothing else on screen distinguishes it from anonymous, and the
              // user's own feed silently going empty is exactly F7's shape.
              if (auth.status == AuthStatus.degraded)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: scheme.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedInMenu extends ConsumerWidget {
  const _SignedInMenu({required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = auth.accountAvatarUrl;

    return PopupMenuButton<_AccountAction>(
      tooltip: auth.displayName,
      offset: const Offset(0, 40),
      borderRadius: BorderRadius.circular(16),
      onSelected: (action) async {
        switch (action) {
          case _AccountAction.signOut:
            await ref.read(authProvider.notifier).signOut();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<_AccountAction>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _Avatar(url: avatar, radius: 20),
            title: Text(auth.displayName),
            subtitle: auth.accountHandle == null ? null : Text(auth.accountHandle!),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.signOut,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
      child: auth.isBusy
          ? SizedBox(
              width: 32,
              height: 32,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSurfaceVariant),
              ),
            )
          : _Avatar(url: avatar, radius: 16),
    );
  }
}

enum _AccountAction { signOut }

/// The avatar, falling back to the person glyph.
///
/// The fallback is not decoration: `auth.status` answers `accountAvatarUrl:
/// null` whenever the account menu could not be read, which is a state the
/// sidecar deliberately reports rather than failing on — a name and a face are
/// decoration, and the *state* is what matters.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.radius});

  final String? url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.surfaceContainerHighest,
      foregroundImage: url == null ? null : NetworkImage(url!),
      child: url != null
          ? null
          : Icon(Icons.person, color: scheme.onSurfaceVariant, size: radius * 1.25),
    );
  }
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

