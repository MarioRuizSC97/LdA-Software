import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lda_inventory/app/cost_pin_store.dart';

/// Existing workflow tests exercise their original behavior after the curtain.
void setUpCostPin() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CostPinStore().create('1234');
  });
}

Future<void> unlockCostPin(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('cost-pin')), '1234');
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
}

Future<void> revealCost(WidgetTester tester) async {
  await tester.tap(find.text('Ver costo'));
  await unlockCostPin(tester);
}
