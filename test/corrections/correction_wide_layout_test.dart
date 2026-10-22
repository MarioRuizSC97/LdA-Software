import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_exchange_form.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/correction_replacement_form.dart';
import 'package:lda_inventory/corrections/correction_return_form.dart';
import 'package:lda_inventory/corrections/correction_sale_detail.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

const Key _context = ValueKey<String>('corrections-context');

/// One corrections view and the key of its existing root widget (empty for
/// the keyless lookup list, whose root is its only ListView).
class _View {
  const _View(this.name, this.rootKey, this.build);

  final String name;
  final String rootKey;
  final Widget Function(FakeCorrections backend) build;
}

final List<_View> _views = <_View>[
  _View(
    'lookup',
    '',
    (FakeCorrections backend) => CorrectionLookupView(
      corrections: backend.corrections,
      productNames: catalogNames,
      onClose: () {},
    ),
  ),
  _View(
    'sale detail',
    'correction-detail',
    (FakeCorrections backend) => CorrectionSaleDetail(
      sale: lookupSale(),
      productNames: catalogNames,
      onBack: () {},
      onReturn: () {},
      onReplace: () {},
      onExchange: () {},
    ),
  ),
  _View(
    'return form',
    'return-form',
    (FakeCorrections backend) => CorrectionReturnForm(
      sale: lookupSale(),
      corrections: backend.corrections,
      productNames: catalogNames,
      onBack: () {},
      onCompleted: (_) {},
    ),
  ),
  _View(
    'replacement form',
    'replacement-form',
    (FakeCorrections backend) => CorrectionReplacementForm(
      sale: lookupSale(),
      corrections: backend.corrections,
      productNames: catalogNames,
      onBack: () {},
      onCompleted: (_) {},
    ),
  ),
  _View(
    'exchange form',
    'exchange-form',
    (FakeCorrections backend) => CorrectionExchangeForm(
      sale: lookupSale(),
      corrections: backend.corrections,
      products: exchangeCatalog,
      productNames: catalogNames,
      onBack: () {},
      onCompleted: (_) {},
    ),
  ),
];

Future<void> _pump(WidgetTester tester, _View view, double width) async {
  useViewport(tester, Size(width, 900));
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: view.build(FakeCorrections()))),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final _View view in _views) {
    final Finder root = view.rootKey.isEmpty
        ? find.byType(ListView)
        : find.byKey(ValueKey<String>(view.rootKey));

    testWidgets('${view.name} stays single-column at 400 px', (
      WidgetTester tester,
    ) async {
      await _pump(tester, view, 400);
      expect(find.byKey(_context), findsNothing);
      expect(tester.getTopLeft(root).dx, 0);
      expect(tester.getSize(root).width, 400);
    });

    testWidgets('${view.name} adds a context column at 1200 px', (
      WidgetTester tester,
    ) async {
      await _pump(tester, view, 1200);
      expect(find.byKey(_context), findsOneWidget);
      expect(tester.getSize(root).width, lessThanOrEqualTo(600));
      expect(
        tester.getTopLeft(find.byKey(_context)).dx,
        greaterThanOrEqualTo(tester.getTopRight(root).dx),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('forms and detail show the selected sale in the context', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _views[2], 1200);
    expect(
      find.descendant(
        of: find.byKey(_context),
        matching: find.textContaining('Folio:'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('corrections-context-line-0')),
      findsOneWidget,
    );
  });

  testWidgets('the lookup context is honest help, not sale data', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _views[0], 1200);
    expect(
      find.descendant(
        of: find.byKey(_context),
        matching: find.text('Cómo corregir una venta'),
      ),
      findsOneWidget,
    );
  });
}
