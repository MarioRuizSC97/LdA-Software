import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';
import 'package:lda_inventory/transfers/transfer_notices_view.dart';

import '../support/viewport.dart';

TransferNoticeLine _line(String id) => TransferNoticeLine(
  movementId: id,
  productId: 'PRD-COFFEE-001',
  quantityScaled: BigInt.from(500),
  unit: 'kg',
  precision: 2,
  occurredAt: DateTime.fromMillisecondsSinceEpoch(1767225600000),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pump(WidgetTester tester, Size size) async {
  useViewport(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TransferNoticesView(
          state: TransferNoticeState(
            phase: TransferNoticePhase.ready,
            notices: <TransferNotice>[
              TransferNotice(
                transferId: 'tr-a',
                lines: <TransferNoticeLine>[_line('m1')],
              ),
              TransferNotice(
                transferId: 'tr-b',
                lines: <TransferNoticeLine>[_line('m2')],
              ),
            ],
            readTransferIds: const <String>{'tr-b'},
          ),
          productNames: const <String, String>{'PRD-COFFEE-001': 'Café'},
          onMarkRead: (_) {},
          onClose: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('narrow: no context and the inbox keeps its geometry', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(400, 800));

    expect(_key('notices-context'), findsNothing);
    expect(tester.getSize(_key('notices-close')).width, greaterThan(0));
    expect(tester.getTopLeft(find.text('Avisos de traslados')).dx, 16);
  });

  testWidgets('wide: context to the right with unread and read counts', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(1200, 800));

    expect(_key('notices-context'), findsOneWidget);
    expect(
      tester.getRect(_key('notices-context')).left,
      greaterThanOrEqualTo(tester.getRect(_key('notices-close')).right),
    );
    expect(
      tester.getRect(find.text('Avisos de traslados')).width,
      lessThanOrEqualTo(600),
    );
    final Finder inContext = find.descendant(
      of: _key('notices-context'),
      matching: find.text('Sin leer: 1'),
    );
    expect(inContext, findsOneWidget);
    expect(
      find.descendant(
        of: _key('notices-context'),
        matching: find.text('Leídos: 1'),
      ),
      findsOneWidget,
    );
  });
}
