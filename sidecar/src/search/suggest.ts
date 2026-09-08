/**
 * Search suggestions — `search.suggest` (`protocol.md` §3.3).
 *
 * **Not an InnerTube endpoint.** Task 20 asked to establish the real shape
 * rather than assume it, and it is a different surface entirely: no
 * `/youtubei/v1/*` POST, no session, no `parse: false` renderer tree to walk.
 * It is a plain unauthenticated `GET` against Google's classic suggest service,
 * answering JSONP —
 *
 *   window.google.ac.h(["lofi hip h",[["lofi hip hop",0,[512,433]], …]])
 *
 * — confirmed live 2026-08-27. youtubei.js has its own wrapper
 * (`Innertube.getSearchSuggestions`), but that method sits outside the
 * session/auth/decipher layer hard invariant 1 restricts youtubei.js to: it is
 * not a renderer parser (nothing here risks F2's silent-drop failure), but
 * fetching and unwrapping five lines of JSONP ourselves keeps this endpoint's
 * shape entirely inside code this project owns, same as every other network
 * boundary in `sidecar/src`.
 *
 * The array's second element holds one triple per suggestion; only the first
 * (the suggestion text) is read — the rest is client-side telemetry hints
 * this project has no use for.
 */

const SUGGEST_URL = 'https://suggestqueries-clients6.youtube.com/complete/search';

export async function getSearchSuggestions(
  query: string,
  signal?: AbortSignal,
): Promise<{ suggestions: string[] }> {
  const url = new URL(SUGGEST_URL);
  url.searchParams.set('client', 'youtube');
  url.searchParams.set('ds', 'yt');
  url.searchParams.set('q', query);

  const response = await fetch(url, { signal });
  if (!response.ok) {
    throw new Error(`suggest endpoint answered HTTP ${response.status}`);
  }
  const text = await response.text();

  // `window.google.ac.h(...)` — strip the JSONP wrapper. Answered with an empty
  // list rather than thrown on anything that does not match: a suggestion
  // dropdown with nothing in it is a fine answer to a shape YouTube changed,
  // and this endpoint is not covered by hard invariant 4's renderer tolerance
  // (there is no renderer here), but the same spirit applies — a suggest
  // hiccup must never surface as a search error.
  const match = /^window\.google\.ac\.h\((.*)\)\s*;?\s*$/s.exec(text.trim());
  const body = match?.[1];
  if (body === undefined) return { suggestions: [] };

  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return { suggestions: [] };
  }

  if (!Array.isArray(parsed) || !Array.isArray(parsed[1])) return { suggestions: [] };

  const suggestions: string[] = parsed[1]
    .map((entry) => (Array.isArray(entry) && typeof entry[0] === 'string' ? (entry[0] as string) : null))
    .filter((entry: string | null): entry is string => entry !== null);

  return { suggestions };
}
