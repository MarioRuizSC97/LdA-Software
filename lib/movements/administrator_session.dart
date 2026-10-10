import '../auth/emulator_session.dart';

/// The one "exact administrator session" predicate for administrator reads
/// and writes: both the expected and the current session are administrators
/// without a branch, and they are the same user.
bool isSameExactAdministrator({
  required EmulatorSession expected,
  required EmulatorSession? current,
}) =>
    current != null &&
    expected.role == InventoryRole.administrator &&
    expected.branchId == null &&
    current.role == InventoryRole.administrator &&
    current.branchId == null &&
    current.userId == expected.userId;
