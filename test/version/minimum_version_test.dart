import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/version/minimum_version.dart';

class _FakeSource implements MinimumVersionSource {
  _FakeSource(this._read);

  final Future<Map<String, Object?>?> Function() _read;

  @override
  Future<Map<String, Object?>?> readClientConfig() => _read();
}

Future<VersionGateDecision> _check(
  String installed,
  Future<Map<String, Object?>?> Function() read, {
  Duration timeout = const Duration(seconds: 5),
}) => checkMinimumVersion(
  installedVersion: installed,
  loadSource: () async => _FakeSource(read),
  timeout: timeout,
);

void main() {
  group('AppVersion.tryParse', () {
    test('reads MAJOR.MINOR.PATCH', () {
      final AppVersion? version = AppVersion.tryParse('1.10.3');
      expect(version, isNotNull);
      expect(version.toString(), '1.10.3');
    });

    test('rejects anything that is not exactly three numbers', () {
      for (final String raw in <String>[
        '',
        '1',
        '1.0',
        '1.0.0.0',
        'v1.0.0',
        '1.0.0+1',
        '1.0.-1',
        '1.a.0',
        ' 1.0.0',
      ]) {
        expect(AppVersion.tryParse(raw), isNull, reason: raw);
      }
    });
  });

  group('AppVersion ordering', () {
    bool lower(String a, String b) =>
        AppVersion.tryParse(a)!.compareTo(AppVersion.tryParse(b)!) < 0;

    test('an equal version is not lower', () {
      expect(lower('1.0.0', '1.0.0'), isFalse);
    });

    test('a lower patch is lower', () {
      expect(lower('1.0.0', '1.0.1'), isTrue);
      expect(lower('1.0.1', '1.0.0'), isFalse);
    });

    test('parts compare as numbers, not as text', () {
      expect(lower('1.9.0', '1.10.0'), isTrue);
      expect(lower('1.10.0', '1.9.0'), isFalse);
    });

    test('the major part dominates', () {
      expect(lower('1.99.99', '2.0.0'), isTrue);
    });
  });

  group('checkMinimumVersion', () {
    test('allows an installed version equal to the minimum', () async {
      final VersionGateDecision decision = await _check(
        '1.0.0',
        () async => <String, Object?>{'minimumVersion': '1.0.0'},
      );
      expect(decision, isA<VersionAllowed>());
    });

    test('blocks an installed version below the minimum', () async {
      final VersionGateDecision decision = await _check(
        '1.0.0',
        () async => <String, Object?>{
          'minimumVersion': '1.0.1',
          'androidUpdateUrl': 'https://play.example/app',
          'iosUpdateUrl': 'https://apps.example/app',
        },
      );
      expect(decision, isA<UpdateRequired>());
      final UpdateRequired required = decision as UpdateRequired;
      expect(required.installedVersion, '1.0.0');
      expect(required.minimumVersion, '1.0.1');
      expect(required.androidUpdateUrl, Uri.parse('https://play.example/app'));
      expect(required.iosUpdateUrl, Uri.parse('https://apps.example/app'));
    });

    test('keeps the update URLs optional', () async {
      final VersionGateDecision decision = await _check(
        '1.0.0',
        () async => <String, Object?>{'minimumVersion': '2.0.0'},
      );
      final UpdateRequired required = decision as UpdateRequired;
      expect(required.androidUpdateUrl, isNull);
      expect(required.iosUpdateUrl, isNull);
    });

    test('ignores an update URL that is not http or https', () async {
      final VersionGateDecision decision = await _check(
        '1.0.0',
        () async => <String, Object?>{
          'minimumVersion': '2.0.0',
          'androidUpdateUrl': 'javascript:alert(1)',
          'iosUpdateUrl': 42,
        },
      );
      final UpdateRequired required = decision as UpdateRequired;
      expect(required.androidUpdateUrl, isNull);
      expect(required.iosUpdateUrl, isNull);
    });

    test('fails open when the document is missing', () async {
      expect(await _check('1.0.0', () async => null), isA<VersionAllowed>());
    });

    test('fails open when minimumVersion is absent or malformed', () async {
      for (final Object? value in <Object?>[null, 2, '2', 'v2.0.0', '']) {
        final VersionGateDecision decision = await _check(
          '1.0.0',
          () async => <String, Object?>{'minimumVersion': value},
        );
        expect(decision, isA<VersionAllowed>(), reason: '$value');
      }
    });

    test('fails open when the installed version is malformed', () async {
      final VersionGateDecision decision = await _check(
        'dev',
        () async => <String, Object?>{'minimumVersion': '9.0.0'},
      );
      expect(decision, isA<VersionAllowed>());
    });

    test('fails open when the read throws', () async {
      final VersionGateDecision decision = await _check(
        '1.0.0',
        () async => throw StateError('offline'),
      );
      expect(decision, isA<VersionAllowed>());
    });

    test('fails open when the source cannot be created', () async {
      final VersionGateDecision decision = await checkMinimumVersion(
        installedVersion: '1.0.0',
        loadSource: () async => throw StateError('no Firebase'),
      );
      expect(decision, isA<VersionAllowed>());
    });

    test('fails open when the read is slower than the timeout', () async {
      final Completer<Map<String, Object?>?> never =
          Completer<Map<String, Object?>?>();
      final VersionGateDecision decision = await _check(
        '1.0.0',
        () => never.future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(decision, isA<VersionAllowed>());
    });
  });
}
