import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';
import 'package:lda_inventory/transfers/transfer_notices_view.dart';

const String _transferA = 'aaaaaaaa-0000-0000-0000-000000000001';
const String _transferB = 'aaaaaaaa-0000-0000-0000-000000000002';

TransferNoticeLine _line(
  String movementId, {
  String productId = 'PRD-COFFEE-001',
  int quantityScaled = 500,
  String unit = 'kg',
  int precision = 2,
}) => TransferNoticeLine(
  movementId: movementId,
  productId: productId,
  quantityScaled: BigInt.from(quantityScaled),
  unit: unit,
  precision: precision,
  occurredAt: DateTime.fromMillisecondsSinceEpoch(1767225600000),
);

void main() {
  group('ready state', () {
    testWidgets('lists notices with lines and marks read on tap', (
      WidgetTester tester,
    ) async {
      final List<String> marked = <String>[];
      final TransferNoticeState state = TransferNoticeState(
        phase: TransferNoticePhase.ready,
        notices: <TransferNotice>[
          TransferNotice(
            transferId: _transferA,
            lines: <TransferNoticeLine>[
              _line('m1'),
              _line(
                'm2',
                productId: 'PRD-SUGAR-002',
                quantityScaled: 2500,
                unit: 'g',
                precision: 0,
              ),
            ],
          ),
          TransferNotice(
            transferId: _transferB,
            lines: <TransferNoticeLine>[_line('m3')],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferNoticesView(
              state: state,
              productNames: const <String, String>{
                'PRD-COFFEE-001': 'Café',
                'PRD-SUGAR-002': 'Azúcar',
              },
              onMarkRead: marked.add,
              onClose: () {},
            ),
          ),
        ),
      );

      expect(find.text('Café: +5.00 kg'), findsNWidgets(2));
      expect(find.text('Azúcar: +2500 g'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(marked, isEmpty);

      await tester.tap(find.byKey(ValueKey<String>('notice-read-$_transferA')));
      expect(marked, <String>[_transferA]);
    });

    testWidgets('keeps read notices in history without a mark button', (
      WidgetTester tester,
    ) async {
      final List<String> marked = <String>[];
      final TransferNoticeState state = TransferNoticeState(
        phase: TransferNoticePhase.ready,
        notices: <TransferNotice>[
          TransferNotice(
            transferId: _transferA,
            lines: <TransferNoticeLine>[_line('m1')],
          ),
        ],
        readTransferIds: <String>{_transferA},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferNoticesView(
              state: state,
              productNames: const <String, String>{},
              onMarkRead: marked.add,
              onClose: () {},
            ),
          ),
        ),
      );

      expect(find.text('Leído'), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('notice-read-$_transferA')),
        findsNothing,
      );
      // The notice stays visible (retained history), just marked read.
      expect(find.textContaining('Traslado del '), findsOneWidget);
      expect(find.textContaining(_transferA), findsNothing);
      expect(marked, isEmpty);
    });

    testWidgets('shows the pending state while an ack is in flight', (
      WidgetTester tester,
    ) async {
      final TransferNoticeState state = TransferNoticeState(
        phase: TransferNoticePhase.ready,
        notices: <TransferNotice>[
          TransferNotice(
            transferId: _transferA,
            lines: <TransferNoticeLine>[_line('m1')],
          ),
        ],
        pendingAckTransferIds: <String>{_transferA},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferNoticesView(
              state: state,
              productNames: const <String, String>{},
              onMarkRead: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );

      final Finder button = find.byKey(
        ValueKey<String>('notice-read-$_transferA'),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('Marcando…'), findsOneWidget);
    });

    testWidgets('shows a confirmed empty tray without implying unread', (
      WidgetTester tester,
    ) async {
      final TransferNoticeState state = TransferNoticeState(
        phase: TransferNoticePhase.ready,
        notices: const <TransferNotice>[],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferNoticesView(
              state: state,
              productNames: const <String, String>{},
              onMarkRead: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );

      expect(find.text('Sin avisos de traslados'), findsOneWidget);
      expect(
        find.text('Cuando te envíen un traslado, aparecerá aquí.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('loading state says the information is being fetched', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferNoticesView(
            state: const TransferNoticeState(),
            productNames: const <String, String>{},
            onMarkRead: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );

    expect(find.text('Cargando avisos de traslados…'), findsOneWidget);
  });

  testWidgets('error state never claims zero unread and offers retry', (
    WidgetTester tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferNoticesView(
            state: const TransferNoticeState(phase: TransferNoticePhase.error),
            productNames: const <String, String>{},
            onMarkRead: (_) {},
            onClose: () {},
            onRetry: () => retries += 1,
          ),
        ),
      ),
    );

    expect(
      find.text('No se pudieron cargar los avisos de traslados.'),
      findsOneWidget,
    );
    expect(
      find.text('No es posible confirmar si hay avisos sin leer.'),
      findsOneWidget,
    );
    expect(find.text('0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('notices-retry')));
    expect(retries, 1);
  });

  testWidgets('inbox has no duplicate close control', (
    WidgetTester tester,
  ) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferNoticesView(
            state: const TransferNoticeState(),
            productNames: const <String, String>{},
            onMarkRead: (_) {},
            onClose: () => closed = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey<String>('notices-close')), findsNothing);
    expect(find.byTooltip('Cerrar bandeja de avisos'), findsNothing);
    expect(closed, isFalse);
  });

  testWidgets('exposes accessible labels without overflowing at 320 px', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final SemanticsHandle semantics = tester.ensureSemantics();

    final TransferNoticeState state = TransferNoticeState(
      phase: TransferNoticePhase.ready,
      notices: <TransferNotice>[
        TransferNotice(
          transferId: _transferA,
          lines: <TransferNoticeLine>[_line('m1')],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferNoticesView(
            state: state,
            productNames: const <String, String>{'PRD-COFFEE-001': 'Café'},
            onMarkRead: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Avisos de traslados'), findsOneWidget);
    expect(find.byTooltip('Cerrar bandeja de avisos'), findsNothing);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
