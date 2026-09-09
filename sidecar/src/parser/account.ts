/**
 * The signed-in account's name, handle and avatar.
 *
 * Task 22 §7 asks where the top bar's name and picture come from, given that
 * `auth.verify` answers `{state, tileCount}` and nothing else. This is the
 * answer: `/account/account_menu`, the endpoint behind the avatar menu on
 * youtube.com, parsed the same tolerant way as every other renderer in this
 * project — walk for the node, read what is there, `null` for anything that is
 * not (hard invariant 4).
 *
 * A separate endpoint rather than a field lifted off the home feed, because the
 * home response's topbar carries an avatar and an "Account menu" accessibility
 * label but no account *name* — and a name is the half that distinguishes two
 * accounts from each other, which is the entire point of showing it.
 */

import { deepFind, type JsonObject } from './tree.ts';
import { bestImageUrl, text } from './text.ts';

export interface AccountInfo {
  name: string | null;
  handle: string | null;
  avatarUrl: string | null;
}

export const EMPTY_ACCOUNT: AccountInfo = Object.freeze({
  name: null,
  handle: null,
  avatarUrl: null,
});

/**
 * Pull the active account out of a raw `/account/account_menu` response.
 *
 * The node is an `accountItem`, nested about eight renderers deep inside an
 * `openPopupAction`. Found by key rather than by path: the wrapping is menu
 * chrome — a popup action around a multi-page menu around a section list — and
 * every layer of it is a layer that can be renamed without the account itself
 * changing shape. Depth-first for the same reason `parseFeed` is: the *first*
 * `accountItem` in a multi-account response is the signed-in one, and
 * `isSelected` confirms it when present.
 *
 * Never throws. An account menu that cannot be read is `EMPTY_ACCOUNT` and a
 * top bar that falls back to the person glyph — worth strictly less than a
 * name, and worth strictly more than a failed sign-in.
 */
export function parseAccountMenu(raw: unknown): AccountInfo {
  const selected = deepFind(
    raw,
    (node) => isAccountItem(node) && node['isSelected'] === true,
  );
  const item = selected ?? deepFind(raw, isAccountItem);
  if (!item) return EMPTY_ACCOUNT;

  const handle = text(item['channelHandle']);
  return {
    name: text(item['accountName']),
    // A handle is `@name`; anything else is a field that has moved, and
    // rendering it would put whatever moved into the top bar.
    handle: handle !== null && handle.startsWith('@') ? handle : null,
    // Scoped to `accountPhoto` rather than the item: `bestImageUrl` walks for
    // any `thumbnails` below whatever it is handed, and an account item can
    // carry a channel banner or a badge icon alongside the avatar.
    //
    // Passed straight through rather than behind an `isObject` gate. The gate
    // was redundant — `bestImageUrl` walks whatever it is given and answers
    // null for anything with no image in it — and it was the same shape as the
    // `get`-across-an-array bug found on 2026-09-09: a type check in front of a
    // call that already handles the type, which turns "unusual shape" into a
    // silent null instead of an answer. If YouTube ever ships this field as a
    // list, this now reads it; before, it would have returned null and said
    // nothing.
    avatarUrl: bestImageUrl(item['accountPhoto']),
  };
}

function isAccountItem(node: JsonObject): boolean {
  // Keyed on the two fields that make it an account rather than on the
  // container's name: `accountItemRenderer` and a bare `accountItem` wrapper
  // have both been seen, and the payload inside them is identical.
  return 'accountName' in node && ('accountPhoto' in node || 'channelHandle' in node);
}
