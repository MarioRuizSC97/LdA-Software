import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lda_inventory/app/cost_pin_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only 4 to 6 ASCII digits are accepted', () async {
    final store = CostPinStore();
    for (final pin in [
      '',
      '123',
      '1234567',
      '12a4',
      ' 1234',
      '1234\n',
      '１２３４',
    ]) {
      await expectLater(store.create(pin), throwsArgumentError);
    }
    expect(await store.isConfigured, isFalse);
    for (final pin in ['1234', '12345', '123456']) {
      SharedPreferences.setMockInitialValues({});
      await CostPinStore().create(pin);
      expect(await CostPinStore().verify(pin), isTrue);
    }
  });

  test(
    'persists salt and digest only and verifies across store instances',
    () async {
      final store = CostPinStore();
      await store.create('852963');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {CostPinStore.preferenceKey});
      final stored = prefs.getString(CostPinStore.preferenceKey)!;
      expect(prefs.getKeys().map(prefs.get), isNot(contains('852963')));
      expect(stored.split(':'), hasLength(2));
      expect(base64Decode(stored.split(':').first), hasLength(32));
      expect(
        stored.split(':').last,
        sha256
            .convert(utf8.encode('${stored.split(':').first}852963'))
            .toString(),
      );
      expect(await CostPinStore().isConfigured, isTrue);
      expect(await CostPinStore().verify('852963'), isTrue);
      expect(await store.verify('852964'), isFalse);
      expect(await store.verify('bad'), isFalse);
      await expectLater(store.create('4321'), throwsStateError);
    },
  );

  test('changing requires current PIN and validates the replacement', () async {
    final store = CostPinStore();
    await store.create('1234');
    expect(await store.change('9999', '5678'), isFalse);
    expect(await store.verify('1234'), isTrue);
    await expectLater(store.change('1234', 'abc'), throwsArgumentError);
    expect(await store.change('1234', '5678'), isTrue);
    expect(await store.verify('1234'), isFalse);
    expect(await store.verify('5678'), isTrue);
  });

  test(
    'malformed persisted records fail closed and cannot be recreated',
    () async {
      for (final value in ['broken', 'salt:hash', 42]) {
        SharedPreferences.setMockInitialValues({
          CostPinStore.preferenceKey: value,
        });
        final store = CostPinStore();
        expect(await store.isConfigured, isTrue);
        expect(await store.verify('1234'), isFalse);
        await expectLater(store.create('1234'), throwsStateError);
      }
    },
  );

  test('fresh device stores receive different random salts', () async {
    await CostPinStore().create('1234');
    final first = (await SharedPreferences.getInstance()).getString(
      CostPinStore.preferenceKey,
    )!;
    SharedPreferences.setMockInitialValues({});
    await CostPinStore().create('1234');
    final second = (await SharedPreferences.getInstance()).getString(
      CostPinStore.preferenceKey,
    )!;
    expect(first.split(':').first, isNot(second.split(':').first));
  });
}
