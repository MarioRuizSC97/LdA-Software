import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:lda_inventory/firebase/emulator_auth_routing.dart';
import 'package:lda_inventory/firebase/emulator_auth_routing_preinit.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/firebase/emulator_bootstrap.dart';

const appName = 'lda-demo-emulators';
const key = '$appName-firebaseEmulatorOrigin';
const local = AuthEmulatorRoute(appName, 'http', '127.0.0.1', 9099);

class _NoGateway implements EmulatorSessionGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Harness {
  AuthEmulatorRoute? route;
  final storage = <String, String>{
    'unrelated': 'preserved',
    'other-firebaseEmulatorOrigin': 'http://other:9099',
  };
  int calls = 0;
  bool storageFails = false;
  bool connectorFails = false;
  bool falseSuccess = false;
  bool removalFails = false;
  Completer<void>? pause;
  late final guard = WebAuthEmulatorRouting(
    appName: appName,
    inspect: () => route,
    readOrigin: (key) {
      if (storageFails) throw StateError('Storage unavailable');
      return storage[key];
    },
    removeOrigin: (key) {
      if (!removalFails) storage.remove(key);
    },
    connect: (host, port) async {
      calls++;
      if (connectorFails) throw StateError('Connector failed');
      if (storage[key] == 'http://$host:$port' || falseSuccess) return;
      if (pause != null) await pause!.future;
      route = local;
      storage[key] = 'http://$host:$port';
    },
  );
}

void main() {
  test(
    'stored-user restoration must not run before local Auth connection',
    () async {
      final events = <String>[];
      var connected = false;
      late Future<void> persistence;
      final preinit = AuthEmulatorPreinitializer(
        loadModules: () async {
          events.add('SDKmodules');
        },
        prepareApp: () {},
        initializeAuth: () {
          events.add('namedAuthinit');
          // SDK _initializeWithPersistence queues restoration, not synchronous IO.
          persistence = Future<void>.microtask(() {
            events.add(connected ? 'local-lookup' : 'cloud-lookup');
          });
        },
        connect: () {
          connected = true;
          events.add('connect');
        },
        verify: () {
          expect(connected, isTrue);
          events.add('verify');
        },
      );
      await DemoEmulatorBootstrap.start(
        platform: EmulatorClientPlatform.web,
        prepareWebAuth: preinit.prepare,
        initializeApp: (_) async {
          events.add('Flutterinitialize');
          await persistence;
          events.add('persistenceawait');
        },
        connectAuthEmulator: (_, _) async {
          expect(connected, isTrue);
        },
        createGateway: _NoGateway.new,
      );
      expect(events.take(4), [
        'SDKmodules',
        'namedAuthinit',
        'connect',
        'verify',
      ]);
      expect(events, isNot(contains('cloud-lookup')));
      expect(
        events.indexOf('verify'),
        lessThan(events.indexOf('Flutterinitialize')),
      );
    },
  );
  test('SDK version and exact demo app/options validation reject mismatches before Auth', () async {
    var calls = 0;
    final rejected = <void Function()>[
      () => validateDemoAuthSdkVersion(null),
      () => validateDemoAuthSdkVersion('12.18.0'),
      () => validateDemoAuthApp('other', emulatorDemoOptions),
      () => validateDemoAuthApp(
        emulatorDemoAppName,
        const FirebaseOptions(
          apiKey: 'different-fake-key',
          appId: '1:1234567890:web:demo-lda-inventory',
          messagingSenderId: '1234567890',
          projectId: 'demo-lda-inventory',
          authDomain: 'demo-lda-inventory.firebaseapp.com',
        ),
      ),
    ];
    for (final validate in rejected) {
      final preinit = AuthEmulatorPreinitializer(
        loadModules: () async {
          validate();
        },
        prepareApp: () {},
        initializeAuth: () {
          calls++;
        },
        connect: () {},
        verify: () {},
      );
      await expectLater(preinit.prepare(), throwsStateError);
    }
    expect(calls, 0);
    validateDemoAuthSdkVersion('12.19.0');
    validateDemoAuthApp(emulatorDemoAppName, emulatorDemoOptions);
  });
  test('module/global or stored-origin preparation failure initializes no Auth and retries', () async {
    var loads = 0;
    var authCalls = 0;
    var failModules = true;
    var failStorage = true;
    final preinit = AuthEmulatorPreinitializer(
      loadModules: () async {
        loads++;
        if (failModules) throw StateError('module/global failure');
      },
      prepareApp: () {
        if (failStorage) throw StateError('storage/options failure');
      },
      initializeAuth: () {
        authCalls++;
      },
      connect: () {},
      verify: () {},
    );
    await expectLater(preinit.prepare(), throwsStateError);
    expect(authCalls, 0);
    failModules = false;
    await expectLater(preinit.prepare(), throwsStateError);
    expect(authCalls, 0);
    failStorage = false;
    await preinit.prepare();
    expect(loads, 3);
    expect(authCalls, 1);
  });
  test('preexisting unowned or mismatched app is rejected before Auth initialization', () async {
    var authCalls = 0;
    final preinit = AuthEmulatorPreinitializer(
      loadModules: () async {},
      prepareApp: () =>
          throw StateError('existing unowned app/options conflict'),
      initializeAuth: () {
        authCalls++;
      },
      connect: () {},
      verify: () {},
    );
    await expectLater(preinit.prepare(), throwsStateError);
    expect(authCalls, 0);
  });
  for (final failAt in ['initializeAuth', 'connect', 'verify']) {
    test(
      'unverified initialization at $failAt never starts another Auth queue',
      () async {
        var authCalls = 0;
        final preinit = AuthEmulatorPreinitializer(
          loadModules: () async {},
          prepareApp: () {},
          initializeAuth: () {
            authCalls++;
            if (failAt == 'initializeAuth') {
              throw StateError('already initializing');
            }
          },
          connect: () {
            if (failAt == 'connect') throw StateError('connector failure');
          },
          verify: () {
            if (failAt == 'verify') throw StateError('config mismatch');
          },
        );
        await expectLater(preinit.prepare(), throwsStateError);
        await expectLater(preinit.prepare(), throwsStateError);
        expect(authCalls, 1);
      },
    );
  }
  test('preinitialization is concurrent/idempotent and lost config fails without reconnect', () async {
    final loaded = Completer<void>();
    var initializations = 0;
    var connects = 0;
    var verified = true;
    final preinit = AuthEmulatorPreinitializer(
      loadModules: () => loaded.future,
      prepareApp: () {},
      initializeAuth: () {
        initializations++;
      },
      connect: () {
        connects++;
      },
      verify: () {
        if (!verified) throw StateError('lost configuration');
      },
    );
    final first = preinit.prepare();
    final second = preinit.prepare();
    loaded.complete();
    await Future.wait([first, second]);
    await preinit.prepare();
    verified = false;
    await expectLater(preinit.prepare(), throwsStateError);
    expect(initializations, 1);
    expect(connects, 1);
  });
  test(
    'failed web preinitialization blocks Flutter initialization and consumers',
    () async {
      var called = false;
      await expectLater(
        DemoEmulatorBootstrap.startCatalog<String>(
          platform: EmulatorClientPlatform.web,
          prepareWebAuth: () async =>
              throw StateError('preinitialization failed'),
          initializeApp: (_) async {
            called = true;
          },
          connectAuthEmulator: (_, _) async {
            called = true;
          },
          connectFirestoreEmulator: (_, _) async {
            called = true;
          },
          createCatalog: () {
            called = true;
            return 'catalog';
          },
        ),
        throwsStateError,
      );
      expect(called, isFalse);
    },
  );
  test('all callable bootstraps reject preinitialization failure before Flutter or consumers', () async {
    var calls = 0;
    Future<void> initialize(FirebaseOptions _) async {
      calls++;
    }

    Future<void> connect(String _, int port) async {
      calls++;
    }

    Future<void> reject() async =>
        throw StateError('preinitialization failure');
    String gateway() {
      calls++;
      return 'gateway';
    }

    final attempts = <Future<String> Function()>[
      () => DemoEmulatorBootstrap.startProductCreation<String>(
        platform: EmulatorClientPlatform.web,
        prepareWebAuth: reject,
        initializeApp: initialize,
        connectAuthEmulator: connect,
        connectFirestoreEmulator: connect,
        connectFunctionsEmulator: connect,
        createGateway: gateway,
      ),
      () => DemoEmulatorBootstrap.startProductPricing<String>(
        platform: EmulatorClientPlatform.web,
        prepareWebAuth: reject,
        initializeApp: initialize,
        connectAuthEmulator: connect,
        connectFirestoreEmulator: connect,
        connectFunctionsEmulator: connect,
        createGateway: gateway,
      ),
      () => DemoEmulatorBootstrap.startStockIntake<String>(
        platform: EmulatorClientPlatform.web,
        prepareWebAuth: reject,
        initializeApp: initialize,
        connectAuthEmulator: connect,
        connectFirestoreEmulator: connect,
        connectFunctionsEmulator: connect,
        createGateway: gateway,
      ),
    ];
    for (final attempt in attempts) {
      await expectLater(attempt(), throwsStateError);
    }
    expect(calls, 0);
  });
  test(
    'module await cannot begin Flutter initialization or a login gateway',
    () async {
      final loaded = Completer<void>();
      var called = false;
      final pending = DemoEmulatorBootstrap.start(
        platform: EmulatorClientPlatform.web,
        prepareWebAuth: () => loaded.future,
        initializeApp: (_) async {
          called = true;
        },
        connectAuthEmulator: (_, _) async {},
        createGateway: _NoGateway.new,
      );
      await Future<void>.delayed(Duration.zero);
      expect(called, isFalse);
      loaded.complete();
      await pending;
      expect(called, isTrue);
    },
  );
  test('Android never invokes web preinitialization', () async {
    var prepared = false;
    await DemoEmulatorBootstrap.start(
      platform: EmulatorClientPlatform.android,
      prepareWebAuth: () async {
        prepared = true;
      },
      initializeApp: (_) async {},
      connectAuthEmulator: (host, port) async {
        expect(host, '10.0.2.2');
      },
      createGateway: _NoGateway.new,
    );
    expect(prepared, isFalse);
  });
  for (final stale in [false, true]) {
    test('fresh JS Auth connects with persisted origin: $stale', () async {
      final h = Harness();
      if (stale) h.storage[key] = 'http://127.0.0.1:9099';
      await h.guard.ensureConnected('127.0.0.1', 9099);
      await h.guard.ensureConnected('127.0.0.1', 9099);
      expect(h.calls, 1);
      expect(h.route, same(local));
      expect(h.storage['unrelated'], 'preserved');
      expect(h.storage['other-firebaseEmulatorOrigin'], 'http://other:9099');
    });
  }
  test(
    'reload shares bookkeeping but creates and verifies a fresh JS route',
    () async {
      final first = Harness();
      await first.guard.ensureConnected('127.0.0.1', 9099);
      final reloaded = Harness()..storage.addAll(first.storage);
      expect(reloaded.route, isNull);
      await reloaded.guard.ensureConnected('127.0.0.1', 9099);
      expect(reloaded.calls, 1);
      expect(reloaded.route, same(local));
    },
  );
  test(
    'Auth connection keeps endpoint mismatch and concurrent idempotence',
    () async {
      final h = Harness()..pause = Completer<void>();
      final connection = AuthEmulatorConnection(
        h.guard.ensureConnected,
        verify: h.guard.verify,
      );
      final first = connection.ensureConnected('127.0.0.1', 9099);
      final second = connection.ensureConnected('127.0.0.1', 9099);
      h.pause!.complete();
      await Future.wait([first, second]);
      expect(h.calls, 1);
      await expectLater(
        connection.ensureConnected('10.0.2.2', 9099),
        throwsStateError,
      );
    },
  );
  test(
    'already correct JS route does not touch storage or reconnect',
    () async {
      final h = Harness()
        ..route = local
        ..storageFails = true;
      await h.guard.ensureConnected('127.0.0.1', 9099);
      expect(h.calls, 0);
    },
  );
  for (final badRoute in [
    const AuthEmulatorRoute('other', 'http', '127.0.0.1', 9099),
    const AuthEmulatorRoute(appName, 'https', '127.0.0.1', 9099),
    const AuthEmulatorRoute(appName, 'http', 'localhost', 9099),
    const AuthEmulatorRoute(appName, 'http', '127.0.0.1', null),
  ]) {
    test(
      'mismatched actual config fails closed: ${badRoute.appName}/${badRoute.protocol}/${badRoute.host}/${badRoute.port}',
      () async {
        final h = Harness()..route = badRoute;
        await expectLater(
          h.guard.ensureConnected('127.0.0.1', 9099),
          throwsStateError,
        );
        expect(h.calls, 0);
      },
    );
  }
  test(
    'stored wrong origin remains untouched and fails before connector',
    () async {
      final h = Harness()..storage[key] = 'http://localhost:9099';
      await expectLater(
        h.guard.ensureConnected('127.0.0.1', 9099),
        throwsStateError,
      );
      expect(h.calls, 0);
      expect(h.storage[key], 'http://localhost:9099');
    },
  );
  test(
    'storage failure and unsuccessful exact-key removal fail closed',
    () async {
      final h = Harness()..storageFails = true;
      await expectLater(
        h.guard.ensureConnected('127.0.0.1', 9099),
        throwsStateError,
      );
      h.storageFails = false;
      h.storage[key] = 'http://127.0.0.1:9099';
      h.removalFails = true;
      await expectLater(
        h.guard.ensureConnected('127.0.0.1', 9099),
        throwsStateError,
      );
      expect(h.calls, 0);
    },
  );
  test('connector failure remains retryable', () async {
    final h = Harness()..connectorFails = true;
    final connection = AuthEmulatorConnection(
      h.guard.ensureConnected,
      verify: h.guard.verify,
    );
    await expectLater(
      connection.ensureConnected('127.0.0.1', 9099),
      throwsStateError,
    );
    h.connectorFails = false;
    await connection.ensureConnected('127.0.0.1', 9099);
    expect(h.calls, 2);
  });
  test(
    'false connector success and lost cached route never build consumers',
    () async {
      final h = Harness()..falseSuccess = true;
      final connection = AuthEmulatorConnection(
        h.guard.ensureConnected,
        verify: h.guard.verify,
      );
      var built = false;
      Future<String> start() => DemoEmulatorBootstrap.startStockIntake<String>(
        platform: EmulatorClientPlatform.web,
        initializeApp: (_) async {},
        connectAuthEmulator: connection.ensureConnected,
        connectFirestoreEmulator: (_, _) async {
          built = true;
        },
        connectFunctionsEmulator: (_, _) async {
          built = true;
        },
        createGateway: () {
          built = true;
          return 'gateway';
        },
      );
      await expectLater(start(), throwsStateError);
      expect(built, isFalse);
      h.falseSuccess = false;
      await start();
      built = false;
      h.route = null;
      await expectLater(start(), throwsStateError);
      expect(built, isFalse);
    },
  );
  test('no consumer executes before guarded connector completes', () async {
    final h = Harness()..pause = Completer<void>();
    var built = false;
    final pending = DemoEmulatorBootstrap.startCatalog<String>(
      platform: EmulatorClientPlatform.web,
      initializeApp: (_) async {},
      connectAuthEmulator: h.guard.ensureConnected,
      connectFirestoreEmulator: (_, _) async {
        built = true;
      },
      createCatalog: () => 'catalog',
    );
    await Future<void>.delayed(Duration.zero);
    expect(built, isFalse);
    h.pause!.complete();
    expect(await pending, 'catalog');
    expect(built, isTrue);
  });
  test('inspection failure does not connect or bypass failure', () async {
    var calls = 0;
    final guard = WebAuthEmulatorRouting(
      appName: appName,
      inspect: () => throw StateError('JS unavailable'),
      readOrigin: (_) => null,
      removeOrigin: (_) {},
      connect: (_, _) async {
        calls++;
      },
    );
    await expectLater(
      guard.ensureConnected('127.0.0.1', 9099),
      throwsStateError,
    );
    expect(calls, 0);
  });
  test('web endpoint mismatch rejected before all callbacks', () async {
    final h = Harness();
    await expectLater(
      h.guard.ensureConnected('10.0.2.2', 9099),
      throwsStateError,
    );
    expect(h.calls, 0);
  });
  test('persisted same origin with fresh JS Auth must not cache false success', () async {
    var storedOrigin = 'http://127.0.0.1:9099';
    var actuallyConnected = false;
    var calls = 0;
    final connection = AuthEmulatorConnection(
      (host, port) async {
        calls++;
        // firebase_auth_web 6.3.0 returns without JS connection on 127 reload.
        if (storedOrigin == 'http://$host:$port') return;
        actuallyConnected = true;
      },
      verify: (_, _) {
        if (!actuallyConnected) {
          throw StateError('No actual local JS connection');
        }
      },
    );
    await expectLater(
      connection.ensureConnected('127.0.0.1', 9099),
      throwsStateError,
    );
    expect(actuallyConnected, isFalse);
    storedOrigin = '';
    await connection.ensureConnected('127.0.0.1', 9099);
    expect(calls, 2);
    expect(actuallyConnected, isTrue);
  });
}
