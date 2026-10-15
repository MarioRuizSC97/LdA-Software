import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/firebase/emulator_bootstrap.dart';
import 'package:lda_inventory/firebase/emulator_transfer_gateway.dart';
import 'package:lda_inventory/main.dart';

class _UnauthenticatedGateway implements EmulatorSessionGateway {
  @override
  Future<EmulatorSession?> restoreSession() async => null;

  @override
  Stream<EmulatorSession?> sessionChanges() => const Stream.empty();

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<void> logout() async {}
}

Future<EmulatorSessionGateway> _loadGateway() async =>
    _UnauthenticatedGateway();

/// Fails the test the moment a bootstrap path initializes Functions eagerly.
Future<EmulatorTransferGateway> _unexpectedTransferLoad(
  EmulatorSession session,
) => throw StateError('transfers must stay lazy until an admin submits');

void main() {
  test('the transfer initializer matches the shell loader contract', () {
    const TransferGatewayLoader loader =
        DemoEmulatorBootstrap.initializeTransferGateway;
    expect(loader, same(DemoEmulatorBootstrap.initializeTransferGateway));
  });

  testWidgets(
    'local-emulator bootstrap hands the transfer loader to the shell',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const LdaInventoryBootstrap(
          demoEnabled: false,
          localEmulatorsEnabled: true,
          emulatorLoader: _loadGateway,
          emulatorTransferLoader: _unexpectedTransferLoad,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Inicio de sesión en el emulador local'),
        findsOneWidget,
      );
      final EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
        find.byType(EmulatorLoginShell),
      );
      expect(shell.transferGatewayLoader, same(_unexpectedTransferLoad));
    },
  );

  testWidgets('local-emulator bootstrap defaults to the live loader', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        localEmulatorsEnabled: true,
        emulatorLoader: _loadGateway,
      ),
    );
    await tester.pumpAndSettle();

    final EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
      find.byType(EmulatorLoginShell),
    );
    expect(
      shell.transferGatewayLoader,
      same(DemoEmulatorBootstrap.initializeTransferGateway),
    );
  });

  testWidgets('fixture mode never threads or initializes transfers', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: true,
        localEmulatorsEnabled: true,
        emulatorLoader: _loadGateway,
        emulatorTransferLoader: _unexpectedTransferLoad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Datos de demostración · Sin conexión'), findsOneWidget);
    expect(find.byType(EmulatorLoginShell), findsNothing);
  });
}
