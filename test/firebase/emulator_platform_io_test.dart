import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/firebase/emulator_platform_io.dart';

void main() {
  group('isIosSimulatorExecutable', () {
    test('accepts an executable inside a CoreSimulator device container', () {
      expect(
        isIosSimulatorExecutable(
          '/Users/dev/Library/Developer/CoreSimulator/Devices/'
          '9BF59A32-569D-465E-88F7-C1B065C7ED36/data/Containers/Bundle/'
          'Application/ABC/Runner.app/Runner',
        ),
        isTrue,
      );
    });

    test('rejects a physical device bundle path', () {
      expect(
        isIosSimulatorExecutable(
          '/private/var/containers/Bundle/Application/X/Runner.app/Runner',
        ),
        isFalse,
      );
    });

    test('rejects an empty path', () {
      expect(isIosSimulatorExecutable(''), isFalse);
    });
  });
}
