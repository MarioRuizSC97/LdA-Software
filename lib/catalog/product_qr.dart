import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'catalog_product.dart';

abstract final class ProductQr {
  static String payloadFor(CatalogProduct product) => product.internalCode;
}

class ProductQrView extends StatelessWidget {
  const ProductQrView({required this.product, super.key});

  final CatalogProduct product;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      image: true,
      label: 'Código QR de ${product.name}. Código ${product.internalCode}',
      child: ExcludeSemantics(
        // Keep the quiet zone light in both themes so black modules scan.
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          child: QrImageView(
            key: ValueKey<String>('product-qr-${product.internalCode}'),
            data: ProductQr.payloadFor(product),
            version: QrVersions.auto,
            size: 136,
          ),
        ),
      ),
    );
  }
}
