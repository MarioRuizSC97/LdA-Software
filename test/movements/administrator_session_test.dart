import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/movements/administrator_session.dart';

import 'movement_fixtures.dart';

void main() {
  const EmulatorSession scopedAdministrator = EmulatorSession(
    userId: 'administrator-1',
    email: 'admin@demo.invalid',
    role: InventoryRole.administrator,
    branchId: 'branch-north',
  );
  const EmulatorSession otherAdministrator = EmulatorSession(
    userId: 'administrator-2',
    email: 'other@demo.invalid',
    role: InventoryRole.administrator,
  );

  test('only the same branchless administrator on both sides passes', () {
    expect(
      isSameExactAdministrator(
        expected: movementsAdministrator,
        current: movementsAdministrator,
      ),
      isTrue,
    );
    for (final (EmulatorSession expected, EmulatorSession? current)
        in <(EmulatorSession, EmulatorSession?)>[
          (movementsAdministrator, null),
          (movementsAdministrator, otherAdministrator),
          (movementsAdministrator, movementsSeller),
          (movementsAdministrator, scopedAdministrator),
          (scopedAdministrator, movementsAdministrator),
          (scopedAdministrator, scopedAdministrator),
          (movementsSeller, movementsSeller),
        ]) {
      expect(
        isSameExactAdministrator(expected: expected, current: current),
        isFalse,
        reason: '${expected.userId} vs ${current?.userId}',
      );
    }
  });
}
