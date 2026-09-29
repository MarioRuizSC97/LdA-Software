import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/firebase/emulator_bootstrap.dart';

class _Gateway implements EmulatorSessionGateway {
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

void main() {
  group('DemoEmulatorBootstrap', () {
    test(
      'uses explicit demo options and Android emulator host in order',
      () async {
        final List<String> events = <String>[];
        FirebaseOptions? options;
        final _Gateway gateway = _Gateway();

        final EmulatorSessionGateway result = await DemoEmulatorBootstrap.start(
          platform: EmulatorClientPlatform.android,
          initializeApp: (FirebaseOptions value) async {
            events.add('initialize');
            options = value;
          },
          connectAuthEmulator: (String host, int port) async {
            events.add('connect:$host:$port');
          },
          createGateway: () {
            events.add('gateway');
            return gateway;
          },
        );

        expect(result, same(gateway));
        expect(options?.projectId, 'demo-lda-inventory');
        expect(options?.projectId, isNot('lda-inventory-dev-mx'));
        expect(events, <String>[
          'initialize',
          'connect:10.0.2.2:9099',
          'gateway',
        ]);
      },
    );

    test('uses loopback for web', () async {
      final List<String> connections = <String>[];

      await DemoEmulatorBootstrap.start(
        platform: EmulatorClientPlatform.web,
        initializeApp: (_) async {},
        connectAuthEmulator: (String host, int port) async {
          connections.add('$host:$port');
        },
        createGateway: _Gateway.new,
      );

      expect(connections, <String>['127.0.0.1:9099']);
    });

    test(
      'fails closed before initialization on unsupported platforms',
      () async {
        var initialized = false;

        await expectLater(
          DemoEmulatorBootstrap.start(
            platform: EmulatorClientPlatform.unsupported,
            initializeApp: (_) async => initialized = true,
            connectAuthEmulator: (_, _) async {},
            createGateway: _Gateway.new,
          ),
          throwsA(isA<UnsupportedError>()),
        );
        expect(initialized, isFalse);
      },
    );

    test('reused Auth connection configures the emulator only once', () async {
      var connectionCalls = 0;
      final AuthEmulatorConnection connection = AuthEmulatorConnection(
        (_, _) async => connectionCalls += 1,
      );

      await connection.ensureConnected('127.0.0.1', 9099);
      await connection.ensureConnected('127.0.0.1', 9099);

      expect(connectionCalls, 1);
    });

    test('failed Auth connection remains retryable', () async {
      var connectionCalls = 0;
      final AuthEmulatorConnection connection = AuthEmulatorConnection((
        _,
        _,
      ) async {
        connectionCalls += 1;
        if (connectionCalls == 1) throw StateError('host unavailable');
      });

      await expectLater(
        connection.ensureConnected('127.0.0.1', 9099),
        throwsStateError,
      );
      await connection.ensureConnected('127.0.0.1', 9099);

      expect(connectionCalls, 2);
    });

    test(
      'does not create auth gateway when emulator connection fails',
      () async {
        var gatewayCreated = false;

        await expectLater(
          DemoEmulatorBootstrap.start(
            platform: EmulatorClientPlatform.web,
            initializeApp: (_) async {},
            connectAuthEmulator: (_, _) async {
              throw StateError('host unavailable');
            },
            createGateway: () {
              gatewayCreated = true;
              return _Gateway();
            },
          ),
          throwsStateError,
        );
        expect(gatewayCreated, isFalse);
      },
    );
  });
}
