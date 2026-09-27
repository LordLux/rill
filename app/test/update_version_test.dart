import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/update/app_version.dart';
import 'package:rill/domain/update/update_state.dart';

void main() {
  test('AppVersion tryParse', () {
    expect(AppVersion.tryParse('1.2.3'), const AppVersion(major: 1, minor: 2, patch: 3));
    expect(AppVersion.tryParse('0.10.0'), const AppVersion(major: 0, minor: 10, patch: 0));
    expect(AppVersion.tryParse('0.0.0'), const AppVersion(major: 0, minor: 0, patch: 0));
    
    expect(AppVersion.tryParse(null), isNull);
    expect(AppVersion.tryParse(''), isNull);
    expect(AppVersion.tryParse('1.2'), isNull);
    expect(AppVersion.tryParse('01.2.3'), isNull);
    expect(AppVersion.tryParse('1.2.3-beta'), isNull);
    expect(AppVersion.tryParse(' 1.2.3'), isNull);
    expect(AppVersion.tryParse('v1.2.3'), isNull);
    expect(AppVersion.tryParse('1.2.3\n'), isNull);
  });

  test('AppVersion ordering and equality', () {
    const v090 = AppVersion(major: 0, minor: 9, patch: 0);
    const v0100 = AppVersion(major: 0, minor: 10, patch: 0);
    const v100 = AppVersion(major: 1, minor: 0, patch: 0);
    const v09999 = AppVersion(major: 0, minor: 99, patch: 99);
    
    expect(v0100 > v090, isTrue);
    expect(v090 < v0100, isTrue);
    expect(v100 > v09999, isTrue);
    expect(v0100 >= v0100, isTrue);
    expect(v090 <= v0100, isTrue);
    
    expect(const AppVersion(major: 1, minor: 2, patch: 3) == const AppVersion(major: 1, minor: 2, patch: 3), isTrue);
    expect(const AppVersion(major: 1, minor: 2, patch: 3).hashCode == const AppVersion(major: 1, minor: 2, patch: 3).hashCode, isTrue);
  });

  test('UpdateState copyWith clears nullable fields (invariant 10)', () {
    final state = UpdateState(
      phase: const UpdatePhase.idle(),
      dismissedVersion: '1.0.0',
      lastChecked: DateTime(2026),
    );
    
    final cleared = state.copyWith(dismissedVersion: null, lastChecked: null);
    expect(cleared.dismissedVersion, isNull);
    expect(cleared.lastChecked, isNull);
  });
}
