/**
 * A minimal, local type for `jsdom` — deliberately not `@types/jsdom`.
 *
 * `@types/jsdom` triple-slash-references `lib="dom"`, and TypeScript's global
 * scope is program-wide: pulling it in here reintroduced `lib.dom.d.ts`'s
 * `ReadableStream`, which predates async iteration, merged against `@types/bun`'s
 * own `ReadableStream` — and broke `for await (const chunk of response.body!)`
 * in two files with nothing to do with `jsdom` (`probe-playback.ts`,
 * `network.test.ts`). `po-token.ts` only ever touches `new JSDOM(...)` and
 * `dom.window.{document,location,origin,navigator}` as opaque values handed
 * straight to `globalThis`, so that is all this declares.
 */
declare module 'jsdom' {
  export class JSDOM {
    constructor(
      html?: string,
      options?: {
        url?: string;
        referrer?: string;
        resources?: { userAgent?: string } | 'usable';
      },
    );
    readonly window: {
      readonly document: unknown;
      readonly location: unknown;
      readonly origin: string;
      readonly navigator: unknown;
    };
  }
}
