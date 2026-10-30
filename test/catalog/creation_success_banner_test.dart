import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';

Future<void> _create(WidgetTester tester, {bool reducedMotion = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: AuthenticatedCatalogPage(
        session: const EmulatorSession(
          userId: 'admin',
          email: 'admin@demo.invalid',
          role: InventoryRole.administrator,
        ),
        catalogLoader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
        onLogout: () async {},
        createProduct: (_) async => const ProductCreationResult(
          productId: 'PRD-SECRET-001',
          internalCode: 'PRD-SECRET-001',
          replayed: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Crear producto'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey<String>('create-product-name')),
    'Cinta',
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('create-product-unit')),
    'piece',
  );
  final Finder precision = find.byKey(
    const ValueKey<String>('create-product-precision'),
  );
  await tester.ensureVisible(precision);
  await tester.tap(precision);
  await tester.pumpAndSettle();
  await tester.tap(find.text('0').last);
  await tester.pumpAndSettle();
  final Finder create = find.widgetWithText(FilledButton, 'Crear');
  await tester.ensureVisible(create);
  await tester.tap(create);
  await tester.pump();
}

void main() {
  final platforms = TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  });
  testWidgets('creation announces success without exposing the internal code', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _create(tester);
    expect(find.text('Producto creado correctamente'), findsOneWidget);
    expect(find.textContaining('PRD-SECRET-001'), findsNothing);
    final Semantics notice = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.text('Producto creado correctamente'),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(notice.properties.liveRegion, isTrue);
    expect(notice.properties.label, 'Producto creado correctamente');
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  }, variant: platforms);

  testWidgets('creation expires with a fade and upward header collapse', (
    tester,
  ) async {
    await _create(tester);
    final Finder banner = find.textContaining('Producto creado');
    await tester.pump(const Duration(seconds: 9));
    expect(banner, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 110));
    expect(banner, findsOneWidget);
    final FadeTransition fade = tester.widget<FadeTransition>(
      find.ancestor(of: banner, matching: find.byType(FadeTransition)).first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    final SizeTransition collapse = tester.widget<SizeTransition>(
      find.ancestor(of: banner, matching: find.byType(SizeTransition)).first,
    );
    expect(collapse.sizeFactor.value, inExclusiveRange(0, 1));
    expect(collapse.alignment, Alignment.topCenter);
    await tester.pump(const Duration(milliseconds: 140));
    expect(banner, findsNothing);
  }, variant: platforms);

  testWidgets(
    'reduced motion removes creation notice immediately at ten seconds',
    (tester) async {
      await _create(tester, reducedMotion: true);
      await tester.pump(const Duration(seconds: 9));
      expect(find.textContaining('Producto creado'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Producto creado'), findsNothing);
    },
    variant: platforms,
  );
}
