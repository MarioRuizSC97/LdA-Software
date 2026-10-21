import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';

const _code = 'PRD-PALETTE-001';
const _product = CatalogProduct(
  internalCode: _code,
  name: 'Café de prueba',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final brightness in Brightness.values) {
      for (final role in [InventoryRole.seller, InventoryRole.administrator]) {
        testWidgets('$role listed price uses readable neutral ink on '
            '$platform ($brightness)', (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final theme = brightness == Brightness.light
              ? buildInventoryTheme().copyWith(platform: platform)
              : ThemeData(
                  platform: platform,
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.blue,
                    brightness: brightness,
                  ),
                );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: AuthenticatedCatalogPage(
                session: EmulatorSession(
                  userId: 'palette-user',
                  email: 'palette@example.invalid',
                  role: role,
                  branchId: role == InventoryRole.seller
                      ? 'branch-north'
                      : null,
                ),
                catalogLoader: (_) async => CatalogSnapshot([
                  CatalogItem(
                    product: _product,
                    holdings: [
                      CatalogHolding(
                        branchId: 'branch-north',
                        branchName: 'North',
                        quantityScaled: 100,
                      ),
                    ],
                  ),
                ]),
                onLogout: () async {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('product-details-$_code')),
          );
          await tester.pumpAndSettle();
          final sheet = find.byKey(const ValueKey('product-sheet-$_code'));
          final price = tester.widget<Text>(
            find.descendant(
              of: sheet,
              matching: find.text('Precio de lista: 129.00 MXN'),
            ),
          );
          final sheetTheme = Theme.of(tester.element(sheet));
          final scheme = sheetTheme.colorScheme;
          expect(price.style?.color, isNot(scheme.primary));
          expect(
            price.style?.color,
            isIn([scheme.onSurface, scheme.onSurfaceVariant]),
          );
          // Both roles use the same ink, not a role-dependent accent.
          expect(price.style?.color, scheme.onSurface);
          expect(
            price.style?.fontSize,
            sheetTheme.textTheme.titleLarge?.fontSize,
          );
          expect(price.style?.fontWeight, FontWeight.w700);
          final inkLuminance = price.style!.color!.computeLuminance();
          final surfaceLuminance = sheetTheme.canvasColor.computeLuminance();
          final contrast = inkLuminance > surfaceLuminance
              ? (inkLuminance + .05) / (surfaceLuminance + .05)
              : (surfaceLuminance + .05) / (inkLuminance + .05);
          expect(contrast, greaterThanOrEqualTo(4.5));

          final name = tester.widget<Text>(
            find.descendant(of: sheet, matching: find.text(_product.name)),
          );
          expect(
            name.style,
            sheetTheme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          );
          for (final label in ['Detalles del producto', 'Modo de precio:']) {
            final attribute = tester.widget<Text>(
              find.descendant(of: sheet, matching: find.textContaining(label)),
            );
            expect(attribute.style?.color, scheme.onSurfaceVariant);
          }
          final qr = tester.widget<Container>(
            find.byKey(const ValueKey('product-sheet-qr-$_code')),
          );
          expect(
            (qr.decoration! as BoxDecoration).color,
            scheme.surfaceContainerHighest,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
