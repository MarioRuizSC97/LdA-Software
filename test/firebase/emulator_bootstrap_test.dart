import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/firebase/emulator_bootstrap.dart';
import 'package:lda_inventory/firebase/emulator_auth_routing_preinit.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/firebase/emulator_seller_profile_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_quote.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';

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
      'uses loopback and iOS-format demo options for the iOS simulator',
      () async {
        final List<String> events = <String>[];
        FirebaseOptions? options;

        await DemoEmulatorBootstrap.start(
          platform: EmulatorClientPlatform.ios,
          initializeApp: (FirebaseOptions value) async {
            events.add('initialize');
            options = value;
          },
          connectAuthEmulator: (String host, int port) async {
            events.add('connect:$host:$port');
          },
          createGateway: () {
            events.add('gateway');
            return _Gateway();
          },
          prepareWebAuth: () async => events.add('web-auth'),
        );

        expect(events, <String>[
          'initialize',
          'connect:127.0.0.1:9099',
          'gateway',
        ]);
        expect(options?.projectId, 'demo-lda-inventory');
        expect(options?.apiKey, emulatorDemoIosOptions.apiKey);
        // Native iOS FirebaseCore rejects any v1 appId whose platform is not
        // `ios` or whose last segment is not hexadecimal.
        expect(options?.appId, matches(RegExp(r'^1:\d+:ios:[0-9a-f]+$')));
      },
    );

    test('Android and web keep the shared demo options', () async {
      final List<FirebaseOptions> received = <FirebaseOptions>[];
      for (final EmulatorClientPlatform platform in <EmulatorClientPlatform>[
        EmulatorClientPlatform.android,
        EmulatorClientPlatform.web,
      ]) {
        await DemoEmulatorBootstrap.start(
          platform: platform,
          initializeApp: (FirebaseOptions value) async => received.add(value),
          connectAuthEmulator: (_, _) async {},
          createGateway: _Gateway.new,
          prepareWebAuth: () async {},
        );
      }

      expect(received, <FirebaseOptions>[
        DemoEmulatorBootstrap.options,
        DemoEmulatorBootstrap.options,
      ]);
    });

    test('product creation uses loopback for the iOS simulator', () async {
      final List<String> endpoints = <String>[];

      await DemoEmulatorBootstrap.startProductCreation<String>(
        platform: EmulatorClientPlatform.ios,
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
        '127.0.0.1:9099',
        '127.0.0.1:8080',
        '127.0.0.1:5001',
      ]);
    });

    test('maps only Android and the iOS simulator to emulator clients', () {
      final Map<TargetPlatform, EmulatorClientPlatform> expected =
          <TargetPlatform, EmulatorClientPlatform>{
            TargetPlatform.android: EmulatorClientPlatform.android,
            TargetPlatform.iOS: EmulatorClientPlatform.ios,
            TargetPlatform.macOS: EmulatorClientPlatform.unsupported,
            TargetPlatform.windows: EmulatorClientPlatform.unsupported,
            TargetPlatform.linux: EmulatorClientPlatform.unsupported,
            TargetPlatform.fuchsia: EmulatorClientPlatform.unsupported,
          };
      for (final MapEntry<TargetPlatform, EmulatorClientPlatform> entry
          in expected.entries) {
        expect(
          DemoEmulatorBootstrap.platformFor(
            isWeb: false,
            target: entry.key,
            isIosSimulator: true,
          ),
          entry.value,
          reason: '${entry.key}',
        );
      }
      expect(
        DemoEmulatorBootstrap.platformFor(
          isWeb: true,
          target: TargetPlatform.iOS,
          isIosSimulator: false,
        ),
        EmulatorClientPlatform.web,
      );
    });

    test('current platform still resolves Android from the target', () {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(
          DemoEmulatorBootstrap.currentPlatform,
          EmulatorClientPlatform.android,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('a physical iOS device fails closed before initialization', () async {
      final EmulatorClientPlatform platform = DemoEmulatorBootstrap.platformFor(
        isWeb: false,
        target: TargetPlatform.iOS,
        isIosSimulator: false,
      );
      expect(platform, EmulatorClientPlatform.unsupported);

      bool initialized = false;
      await expectLater(
        DemoEmulatorBootstrap.start(
          platform: platform,
          initializeApp: (_) async => initialized = true,
          connectAuthEmulator: (_, _) async {},
          createGateway: _Gateway.new,
          prepareWebAuth: () async {},
        ),
        throwsUnsupportedError,
      );
      expect(initialized, isFalse);
    });

    test('iOS demo apiKey satisfies the native Installations format', () {
      final String apiKey = emulatorDemoIosOptions.apiKey;
      // FIRInstallations validateAPIKey: exactly 39 characters, leading `A`,
      // base64 url-safe characters only. Otherwise native init aborts.
      expect(apiKey.length, 39);
      expect(apiKey.startsWith('A'), isTrue);
      expect(apiKey, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(apiKey, contains('demo'));
      expect(emulatorDemoIosOptions.projectId, 'demo-lda-inventory');
      expect(emulatorDemoIosOptions.messagingSenderId, isNotEmpty);
      expect(emulatorDemoIosOptions.appId, isNotEmpty);
    });

    group('trusted app gate', () {
      void verify(
        EmulatorClientPlatform platform, {
        required FirebaseOptions explicit,
        required FirebaseOptions app,
        String appName = emulatorDemoAppName,
      }) => DemoEmulatorBootstrap.verifyTrustedApp(
        platform: platform,
        appName: appName,
        explicitOptions: explicit,
        appOptions: app,
      );

      test('accepts the matching options for iOS and Android', () {
        verify(
          EmulatorClientPlatform.ios,
          explicit: emulatorDemoIosOptions,
          app: emulatorDemoIosOptions,
        );
        verify(
          EmulatorClientPlatform.android,
          explicit: emulatorDemoOptions,
          app: emulatorDemoOptions,
        );
      });

      test('rejects options from another platform', () {
        expect(
          () => verify(
            EmulatorClientPlatform.ios,
            explicit: emulatorDemoOptions,
            app: emulatorDemoOptions,
          ),
          throwsStateError,
        );
        expect(
          () => verify(
            EmulatorClientPlatform.android,
            explicit: emulatorDemoIosOptions,
            app: emulatorDemoIosOptions,
          ),
          throwsStateError,
        );
      });

      test('rejects a mismatched app or app name', () {
        expect(
          () => verify(
            EmulatorClientPlatform.ios,
            explicit: emulatorDemoIosOptions,
            app: emulatorDemoOptions,
          ),
          throwsStateError,
        );
        expect(
          () => verify(
            EmulatorClientPlatform.android,
            explicit: emulatorDemoOptions,
            app: emulatorDemoOptions,
            appName: '[DEFAULT]',
          ),
          throwsStateError,
        );
      });
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

    test(
      'stock intake connects trusted Auth, Firestore, and Functions first',
      () async {
        final List<String> events = <String>[];

        final String result =
            await DemoEmulatorBootstrap.startStockIntake<String>(
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
                events.add('intake');
                return 'intake';
              },
            );

        expect(result, 'intake');
        expect(events, <String>[
          'initialize',
          'auth:127.0.0.1:9099',
          'firestore:127.0.0.1:8080',
          'functions:127.0.0.1:5001',
          'intake',
        ]);
      },
    );

    test(
      'stock intake uses Android host and rejects unsupported platforms',
      () async {
        final List<String> endpoints = <String>[];
        await DemoEmulatorBootstrap.startStockIntake<String>(
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
          createGateway: () => 'intake',
        );
        expect(endpoints, <String>[
          '10.0.2.2:9099',
          '10.0.2.2:8080',
          '10.0.2.2:5001',
        ]);

        var initialized = false;
        await expectLater(
          DemoEmulatorBootstrap.startStockIntake<String>(
            platform: EmulatorClientPlatform.unsupported,
            initializeApp: (_) async => initialized = true,
            connectAuthEmulator: (_, _) async {},
            connectFirestoreEmulator: (_, _) async {},
            connectFunctionsEmulator: (_, _) async {},
            createGateway: () => 'intake',
          ),
          throwsA(isA<UnsupportedError>()),
        );
        expect(initialized, isFalse);
      },
    );

    test('failed stock intake connection never builds the gateway and is retryable', () async {
      var connectionCalls = 0;
      var gatewaysBuilt = 0;
      Future<String> attempt() =>
          DemoEmulatorBootstrap.startStockIntake<String>(
            platform: EmulatorClientPlatform.web,
            initializeApp: (_) async {},
            connectAuthEmulator: (_, _) async {},
            connectFirestoreEmulator: (_, _) async {},
            connectFunctionsEmulator: (_, _) async {
              connectionCalls += 1;
              if (connectionCalls == 1) {
                throw StateError('host unavailable');
              }
            },
            createGateway: () {
              gatewaysBuilt += 1;
              return 'intake';
            },
          );

      await expectLater(attempt(), throwsStateError);
      expect(gatewaysBuilt, 0);
      expect(await attempt(), 'intake');
      expect(gatewaysBuilt, 1);
    });

    test('sale gateway initializer matches the sale loader contract', () {
      const SaleGatewayLoader loader =
          DemoEmulatorBootstrap.initializeSaleGateway;
      expect(loader, same(DemoEmulatorBootstrap.initializeSaleGateway));
    });

    test(
      'sale gateway binds quoteSale to quote and submitSale to submit',
      () async {
        const EmulatorSession seller = EmulatorSession(
          userId: 'seller-1',
          email: 'seller@demo.invalid',
          role: InventoryRole.seller,
          branchId: saleBranchId,
        );
        final List<String> requested = <String>[];
        final List<String> invoked = <String>[];
        final EmulatorSaleGateway gateway =
            DemoEmulatorBootstrap.createSaleGateway(
              session: seller,
              sessionChecker: () async => seller,
              callable: (String name) {
                requested.add(name);
                return (Map<String, Object?> request) async {
                  invoked.add(name);
                  return name == 'quoteSale'
                      ? quoteResponse()
                      : submitResponse();
                };
              },
            );

        expect(requested, unorderedEquals(<String>['quoteSale', 'submitSale']));
        expect(gateway.expectedSession, same(seller));
        expect((await gateway.quote(invoicedCart())).totalCentavos, 3650);
        expect(invoked, <String>['quoteSale']);
        final SaleReceipt receipt = await gateway.submit(
          SaleDraft.fromQuote(
            quote: SaleQuote.fromCallable(
              quoteResponse(),
              cart: invoicedCart(),
            ),
            branchId: saleBranchId,
            paymentMethod: SalePaymentMethod.card,
            createKey: () => saleKey,
          ),
        );
        expect(receipt.folio, 'NTE-3F2A-9C1B');
        expect(invoked, <String>['quoteSale', 'submitSale']);
      },
    );
    test('correction gateway initializer matches the loader contract', () {
      const CorrectionGatewayLoader loader =
          DemoEmulatorBootstrap.initializeCorrectionGateway;
      expect(loader, same(DemoEmulatorBootstrap.initializeCorrectionGateway));
    });

    test('correction gateway binds each callable to its operation', () async {
      const EmulatorSession seller = EmulatorSession(
        userId: 'seller-1',
        email: 'seller@demo.invalid',
        role: InventoryRole.seller,
        branchId: saleBranchId,
      );
      final List<String> requested = <String>[];
      final List<String> invoked = <String>[];
      final Map<String, Object? Function()> responses =
          <String, Object? Function()>{
            'findCorrectableSale': findResponse,
            'listRecentCorrectableSales': () => <String, Object?>{
              'sales': <Object?>[lookupSaleJson()],
            },
            'submitSaleReturn': returnResponse,
            'submitSaleReplacement': replacementResponse,
            'submitSaleExchange': exchangeResponse,
            'previewSaleReturn': returnPreviewJson,
            'previewSaleExchange': exchangePreviewJson,
          };
      final EmulatorCorrectionGateway gateway =
          DemoEmulatorBootstrap.createCorrectionGateway(
            session: seller,
            sessionChecker: () async => seller,
            callable: (String name) {
              requested.add(name);
              return (Map<String, Object?> request) async {
                invoked.add(name);
                return responses[name]!();
              };
            },
          );

      expect(requested, unorderedEquals(responses.keys));
      expect(gateway.expectedSession, same(seller));
      await gateway.find(SaleLookupQuery.bySaleId(saleKey));
      expect(invoked.last, 'findCorrectableSale');
      await gateway.listRecent();
      expect(invoked.last, 'listRecentCorrectableSales');
      await gateway.submitReturn(returnDraft());
      expect(invoked.last, 'submitSaleReturn');
      await gateway.submitReplacement(replacementDraft());
      expect(invoked.last, 'submitSaleReplacement');
      await gateway.submitExchange(exchangeDraft());
      expect(invoked.last, 'submitSaleExchange');
      await gateway.previewReturn(returnPreviewRequest());
      await gateway.previewExchange(exchangePreviewRequest());
      expect(invoked, <String>[
        'findCorrectableSale',
        'listRecentCorrectableSales',
        'submitSaleReturn',
        'submitSaleReplacement',
        'submitSaleExchange',
        'previewSaleReturn',
        'previewSaleExchange',
      ]);
    });
  });

  test(
    'seller profile gateway binds only the setSellerProfile callable',
    () async {
      const EmulatorSession administrator = EmulatorSession(
        userId: 'administrator-1',
        email: 'admin@demo.invalid',
        role: InventoryRole.administrator,
      );
      final List<String> requested = <String>[];
      final EmulatorSellerProfileGateway gateway =
          DemoEmulatorBootstrap.createSellerProfileGateway(
            session: administrator,
            sessionChecker: () async => administrator,
            callable: (String name) {
              requested.add(name);
              return (Map<String, Object?> request) async => <String, Object?>{
                'uid': request['uid'],
                'replayed': false,
              };
            },
          );
      expect(requested, <String>['setSellerProfile']);
      expect(gateway.expectedSession, same(administrator));
      expect(
        (await gateway.setSellerProfile(uid: 'u-1', displayName: 'Ana')).uid,
        'u-1',
      );
    },
  );
}
