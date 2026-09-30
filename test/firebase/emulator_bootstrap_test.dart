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

    test('connects Firestore before constructing the catalog reader', () async {
      final List<String> events = <String>[];

      final String result = await DemoEmulatorBootstrap.startCatalog<String>(
        platform: EmulatorClientPlatform.web,
        initializeApp: (FirebaseOptions value) async {
          expect(value.projectId, 'demo-lda-inventory');
          events.add('initialize');
        },
        connectAuthEmulator: (String host, int port) async {
          events.add('auth:$host:$port');
        },
        connectFirestoreEmulator: (String host, int port) async {
          events.add('firestore:$host:$port');
        },
        createCatalog: () {
          events.add('catalog');
          return 'catalog';
        },
      );

      expect(result, 'catalog');
      expect(events, <String>[
        'initialize',
        'auth:127.0.0.1:9099',
        'firestore:127.0.0.1:8080',
        'catalog',
      ]);
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

    test(
      'reused Firestore connection configures the emulator only once',
      () async {
        var connectionCalls = 0;
        final FirestoreEmulatorConnection connection =
            FirestoreEmulatorConnection((_, _) async => connectionCalls += 1);

        await connection.ensureConnected('127.0.0.1', 8080);
        await connection.ensureConnected('127.0.0.1', 8080);

        expect(connectionCalls, 1);
      },
    );

    test('failed Firestore connection remains retryable', () async {
      var connectionCalls = 0;
      final FirestoreEmulatorConnection connection =
          FirestoreEmulatorConnection((_, _) async {
            connectionCalls += 1;
            if (connectionCalls == 1) throw StateError('host unavailable');
          });

      await expectLater(
        connection.ensureConnected('127.0.0.1', 8080),
        throwsStateError,
      );
      await connection.ensureConnected('127.0.0.1', 8080);

      expect(connectionCalls, 2);
    });

    test('reused Firestore connection rejects an endpoint mismatch', () async {
      final FirestoreEmulatorConnection connection =
          FirestoreEmulatorConnection((_, _) async {});

      await connection.ensureConnected('127.0.0.1', 8080);

      await expectLater(
        connection.ensureConnected('10.0.2.2', 8080),
        throwsStateError,
      );
    });

    test(
      'connects Auth, Firestore, and Functions before callable construction',
      () async {
        final List<String> events = <String>[];

        final String result =
            await DemoEmulatorBootstrap.startProductCreation<String>(
              platform: EmulatorClientPlatform.web,
              initializeApp: (_) async => events.add('initialize'),
              connectAuthEmulator: (String host, int port) async {
                events.add('auth:$host:$port');
              },
              connectFirestoreEmulator: (String host, int port) async {
                events.add('firestore:$host:$port');
              },
              connectFunctionsEmulator: (String host, int port) async {
                events.add('functions:$host:$port');
              },
              createGateway: () {
                events.add('gateway');
                return 'gateway';
              },
            );

        expect(result, 'gateway');
        expect(events, <String>[
          'initialize',
          'auth:127.0.0.1:9099',
          'firestore:127.0.0.1:8080',
          'functions:127.0.0.1:5001',
          'gateway',
        ]);
      },
    );

    test(
      'product creation uses Android host and fails closed when unsupported',
      () async {
        final List<String> endpoints = <String>[];
        await DemoEmulatorBootstrap.startProductCreation<String>(
          platform: EmulatorClientPlatform.android,
          initializeApp: (_) async {},
          connectAuthEmulator: (String host, int port) async {
            endpoints.add('$host:$port');
          },
          connectFirestoreEmulator: (String host, int port) async {
            endpoints.add('$host:$port');
          },
          connectFunctionsEmulator: (String host, int port) async {
            endpoints.add('$host:$port');
          },
          createGateway: () => 'gateway',
        );
        expect(endpoints, <String>[
          '10.0.2.2:9099',
          '10.0.2.2:8080',
          '10.0.2.2:5001',
        ]);

        var initialized = false;
        await expectLater(
          DemoEmulatorBootstrap.startProductCreation<String>(
            platform: EmulatorClientPlatform.unsupported,
            initializeApp: (_) async => initialized = true,
            connectAuthEmulator: (_, _) async {},
            connectFirestoreEmulator: (_, _) async {},
            connectFunctionsEmulator: (_, _) async {},
            createGateway: () => 'gateway',
          ),
          throwsA(isA<UnsupportedError>()),
        );
        expect(initialized, isFalse);
      },
    );

    test(
      'product pricing connects trusted Auth, Firestore, and Functions first',
      () async {
        final List<String> events = <String>[];

        final String result =
            await DemoEmulatorBootstrap.startProductPricing<String>(
              platform: EmulatorClientPlatform.web,
              initializeApp: (_) async => events.add('initialize'),
              connectAuthEmulator: (String host, int port) async {
                events.add('auth:$host:$port');
              },
              connectFirestoreEmulator: (String host, int port) async {
                events.add('firestore:$host:$port');
              },
              connectFunctionsEmulator: (String host, int port) async {
                events.add('functions:$host:$port');
              },
              createGateway: () {
                events.add('pricing');
                return 'pricing';
              },
            );

        expect(result, 'pricing');
        expect(events, <String>[
          'initialize',
          'auth:127.0.0.1:9099',
          'firestore:127.0.0.1:8080',
          'functions:127.0.0.1:5001',
          'pricing',
        ]);
      },
    );

    test(
      'product pricing uses Android host and rejects unsupported platforms',
      () async {
        final List<String> endpoints = <String>[];
        await DemoEmulatorBootstrap.startProductPricing<String>(
          platform: EmulatorClientPlatform.android,
          initializeApp: (_) async {},
          connectAuthEmulator: (String host, int port) async {
            endpoints.add('$host:$port');
          },
          connectFirestoreEmulator: (String host, int port) async {
            endpoints.add('$host:$port');
          },
          connectFunctionsEmulator: (String host, int port) async {
            endpoints.add('$host:$port');
          },
          createGateway: () => 'pricing',
        );
        expect(endpoints, <String>[
          '10.0.2.2:9099',
          '10.0.2.2:8080',
          '10.0.2.2:5001',
        ]);

        var initialized = false;
        await expectLater(
          DemoEmulatorBootstrap.startProductPricing<String>(
            platform: EmulatorClientPlatform.unsupported,
            initializeApp: (_) async => initialized = true,
            connectAuthEmulator: (_, _) async {},
            connectFirestoreEmulator: (_, _) async {},
            connectFunctionsEmulator: (_, _) async {},
            createGateway: () => 'pricing',
          ),
          throwsA(isA<UnsupportedError>()),
        );
        expect(initialized, isFalse);
      },
    );

    test(
      'Functions connection is idempotent, retryable, and rejects mismatch',
      () async {
        var calls = 0;
        final FunctionsEmulatorConnection connection =
            FunctionsEmulatorConnection((_, _) async {
              calls += 1;
              if (calls == 1) throw StateError('host unavailable');
            });

        await expectLater(
          connection.ensureConnected('127.0.0.1', 5001),
          throwsStateError,
        );
        await connection.ensureConnected('127.0.0.1', 5001);
        await connection.ensureConnected('127.0.0.1', 5001);
        expect(calls, 2);
        await expectLater(
          connection.ensureConnected('10.0.2.2', 5001),
          throwsStateError,
        );
      },
    );
  });
}
