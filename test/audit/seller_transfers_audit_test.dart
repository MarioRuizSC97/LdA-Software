import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';
import 'package:lda_inventory/transfers/transfer_notices_view.dart';

import '../support/viewport.dart';

const _transferId = 'aaaaaaaa-0000-0000-0000-000000000001';
const _productId = 'PRD-COFFEE-001';
TransferNoticeState _state(String name) => switch (name) {
  'loading' => const TransferNoticeState(),
  'error' => const TransferNoticeState(phase: TransferNoticePhase.error),
  'empty' => const TransferNoticeState(phase: TransferNoticePhase.ready),
  _ => TransferNoticeState(
    phase: TransferNoticePhase.ready,
    notices: <TransferNotice>[
      TransferNotice(
        transferId: _transferId,
        lines: <TransferNoticeLine>[
          TransferNoticeLine(
            movementId: 'movement-private-123',
            productId: _productId,
            quantityScaled: BigInt.from(125),
            unit: 'kg',
            precision: 2,
            occurredAt: DateTime(2026, 10, 20),
          ),
        ],
      ),
    ],
  ),
};

Future<void> _mount(
  WidgetTester tester,
  String name,
  Brightness brightness, {
  Map<String, String> names = const <String, String>{
    _productId: 'Café de especialidad de origen nacional',
  },
  List<String>? marked,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: TransferNoticesView(
          state: _state(name),
          productNames: names,
          onMarkRead: (id) => marked?.add(id),
          onClose: () {},
          onRetry: () {},
        ),
      ),
    ),
  );
  // Loading has a continuously animated spinner.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  for (final name in <String>['loading', 'error', 'empty', 'ready']) {
    for (final width in <double>[320, 400, 600, 1200]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'notices $name ${width.toInt()}px ${brightness.name} scale 1.3',
          (tester) async {
            useViewport(tester, Size(width, 900), 1.3);
            final marked = <String>[];
            await _mount(tester, name, brightness, marked: marked);
            expect(tester.takeException(), isNull);
            expect(
              marked,
              isEmpty,
              reason: 'opening never acknowledges automatically',
            );
            if (name == 'loading' || name == 'error') {
              expect(
                find.textContaining(
                  RegExp(r'Sin leer: 0|Leídos: 0|Total: 0|^0$'),
                ),
                findsNothing,
              );
              expect(find.text('Sin avisos de traslados'), findsNothing);
            }
            if (name == 'ready') {
              expect(
                find.text('Café de especialidad de origen nacional: +1.25 kg'),
                findsOneWidget,
              );
            }
            final private = RegExp(
              r'costCentavos|Costo de adquisición|purchaseCost',
              caseSensitive: false,
            );
            expect(find.textContaining(private), findsNothing);
            expect(find.bySemanticsLabel(private), findsNothing);
            await expectLater(
              tester,
              meetsGuideline(labeledTapTargetGuideline),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'notice heading and semantics never expose the internal transfer UUID',
    (tester) async {
      await _mount(tester, 'ready', Brightness.light);
      // T22 D2 explicitly asks for no raw ids/codes in seller-facing copy.
      expect(find.textContaining(_transferId), findsNothing);
      expect(find.bySemanticsLabel(RegExp(_transferId)), findsNothing);
    },
  );

  testWidgets(
    'deleted catalog product uses a readable fallback instead of its raw code',
    (tester) async {
      await _mount(
        tester,
        'ready',
        Brightness.light,
        names: const <String, String>{},
      );
      expect(find.text('Producto no disponible: +1.25 kg'), findsOneWidget);
      expect(find.text('código $_productId'), findsOneWidget);
      expect(find.text('$_productId: +1.25 kg'), findsNothing);
      expect(find.textContaining('+1.25 kg'), findsOneWidget);
    },
  );
}
