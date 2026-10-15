import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';
import 'package:lda_inventory/firebase/emulator_transfer_notice_gateway.dart';

/// A local SDK double: constructing the exception needs no Firebase init.
class _FunctionsException extends FirebaseFunctionsException {
  _FunctionsException({required super.code}) : super(message: 'server detail');
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

void main() {
  gatewayStreamTests();

  test('passes the exact request through to the raw callable', () async {
    final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
    final TransferNoticeReadInvoker invoker = transferNoticeCallableFromInvoker(
      (Map<String, Object?> request) async {
        payloads.add(Map<String, Object?>.of(request));
        return <String, Object?>{
          'transferId': 't-1',
          'branchId': 'branch-north',
          'read': true,
        };
      },
    );

    final Object? response = await invoker(<String, Object?>{
      'transferId': 't-1',
    });

    expect(payloads, <Map<String, Object?>>[
      <String, Object?>{'transferId': 't-1'},
    ]);
    expect(response, isA<Map<Object?, Object?>>());
  });

  test(
    'maps FirebaseFunctionsException codes without parsing messages',
    () async {
      final TransferNoticeReadInvoker invoker =
          transferNoticeCallableFromInvoker(
            (Map<String, Object?> request) async =>
                throw _FunctionsException(code: 'failed-precondition'),
          );

      await expectLater(
        invoker(<String, Object?>{'transferId': 't-1'}),
        throwsA(
          isA<TransferNoticeCallableException>().having(
            (TransferNoticeCallableException error) => error.code,
            'code',
            'failed-precondition',
          ),
        ),
      );
    },
  );

  test('propagates non-SDK failures untouched', () async {
    final TransferNoticeReadInvoker invoker = transferNoticeCallableFromInvoker(
      (Map<String, Object?> request) async => throw StateError('boom'),
    );

    await expectLater(
      invoker(<String, Object?>{'transferId': 't-1'}),
      throwsStateError,
    );
  });
}

/// Records how the production adapter builds each query's stream, without
/// initializing Firebase or issuing any read.
class _RecordingQueryFactory implements TransferNoticeQueryFactory {
  final List<String> built = <String>[];
  final List<bool> metadataFlags = <bool>[];

  @override
  TransferNoticeQueryHandle movementsQuery({required String branchId}) {
    built.add('movements:$branchId');
    return _RecordingHandle(metadataFlags);
  }

  @override
  TransferNoticeQueryHandle markersQuery({
    required String userId,
    required String branchId,
  }) {
    built.add('markers:$userId:$branchId');
    return _RecordingHandle(metadataFlags);
  }
}

class _RecordingHandle implements TransferNoticeQueryHandle {
  _RecordingHandle(this.metadataFlags);

  final List<bool> metadataFlags;

  @override
  Stream<QuerySnapshot<Map<String, Object?>>> snapshots({
    required bool includeMetadataChanges,
  }) {
    metadataFlags.add(includeMetadataChanges);
    return const Stream<QuerySnapshot<Map<String, Object?>>>.empty();
  }
}

void gatewayStreamTests() {
  test('both live queries subscribe with metadata changes for metadata-only confirmations', () {
    final _RecordingQueryFactory factory = _RecordingQueryFactory();
    final FirebaseTransferNoticeStreamSource source =
        FirebaseTransferNoticeStreamSource(_seller, factory);

    source.movements(branchId: 'branch-north').listen((_) {});
    source.markers().listen((_) {});

    expect(factory.built, <String>[
      'movements:branch-north',
      'markers:seller-1:branch-north',
    ]);
    // Server confirmation of a metadata-only change is otherwise not
    // emitted, and the controller would never leave loading.
    expect(factory.metadataFlags, <bool>[true, true]);
  });
}
