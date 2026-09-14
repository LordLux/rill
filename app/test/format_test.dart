/// Compact count formatting, as arithmetic.
///
/// The interesting property is the rounding direction: YouTube **truncates**,
/// and a formatter that rounds up would have this app claim milestones a video
/// has not reached — 999,999 showing as "1M" being the case anyone would
/// notice.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/format.dart';

void main() {
  group('below a thousand, exact and pluralised', () {
    test('singular', () => expect(formatCompactViews(1), '1 view'));
    test('zero', () => expect(formatCompactViews(0), '0 views'));
    test('plural', () => expect(formatCompactViews(2), '2 views'));
    test('just under the first unit', () => expect(formatCompactViews(999), '999 views'));
  });

  group('thousands', () {
    test('1,234 -> 1.2K', () => expect(formatCompactViews(1234), '1.2K views'));
    test('1,000 drops a pointless .0', () => expect(formatCompactViews(1000), '1K views'));
    test('12,345 -> 12K, no decimal past ten', () => expect(formatCompactViews(12345), '12K views'));
    test('313,095 -> 313K', () => expect(formatCompactViews(313095), '313K views'));
    test('999,999 stays under the next unit', () => expect(formatCompactViews(999999), '999K views'));
  });

  group('millions and billions', () {
    test('4,642,098 -> 4.6M', () => expect(formatCompactViews(4642098), '4.6M views'));
    test('57,253,345 -> 57M', () => expect(formatCompactViews(57253345), '57M views'));
    test('1,815,347,797 -> 1.8B', () => expect(formatCompactViews(1815347797), '1.8B views'));
    test('exactly 1M', () => expect(formatCompactViews(1000000), '1M views'));
  });

  group('truncates rather than rounds', () {
    // The property, stated three ways. Each of these rounds *up* to the next
    // display value under `toStringAsFixed`, which is the trap.
    test('1,999 -> 1.9K, never 2K', () => expect(formatCompactViews(1999), '1.9K views'));
    test('1,990,000 -> 1.9M, never 2M', () => expect(formatCompactViews(1990000), '1.9M views'));
    test('9,990 -> 9.9K, never 10K', () => expect(formatCompactViews(9990), '9.9K views'));
  });

  group('the number alone', () {
    test('no unit word', () => expect(formatCompactCount(4642098), '4.6M'));
    test('small values are bare', () => expect(formatCompactCount(1), '1'));
  });

  test('a negative count is not rendered as one', () {
    // Not reachable from a real response; this is here so a future caller that
    // passes a sentinel gets an empty string rather than "-1 views".
    expect(formatCompactViews(-1), '');
    expect(formatCompactCount(-1), '');
  });
}
