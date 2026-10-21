import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';

import '../sales/sale_ui_fixtures.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets('catalog header follows each scroll step (reduced: $reduced)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: AuthenticatedCatalogPage(
            session: const EmulatorSession(
              userId: 'seller-north',
              email: 'seller@demo.invalid',
              role: InventoryRole.seller,
              branchId: 'branch-north',
            ),
            catalogLoader: (_) async => sellerSaleSnapshot(),
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AppBar));
      final scheme = Theme.of(context).colorScheme;
      Color surface() => tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('catalog-app-bar-surface')),
          )
          .color;
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(surface(), scheme.surface);
      final colors = <Color>[surface()];
      for (var offset = 6.0; offset <= 36; offset += 6) {
        scroll.jumpTo(offset);
        // Notifications are delivered after layout; the surface paints next frame.
        await tester.pump();
        await tester.pump();
        expect(
          surface(),
          Color.lerp(scheme.surface, scheme.surfaceContainerLow, offset / 36),
        );
        colors.add(surface());
      }
      expect(colors.toSet().length, colors.length);
      expect(colors.last, scheme.surfaceContainerLow);
      for (var i = 1; i < colors.length; i++) {
        expect((colors[i].r - colors[i - 1].r).abs(), lessThan(.02));
        expect((colors[i].g - colors[i - 1].g).abs(), lessThan(.02));
        expect((colors[i].b - colors[i - 1].b).abs(), lessThan(.02));
      }
      scroll.jumpTo(100);
      await tester.pumpAndSettle();
      expect(surface(), colors.last);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(surface(), colors.first);
    });
  }
}
