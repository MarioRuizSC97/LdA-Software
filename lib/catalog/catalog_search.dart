import 'package:flutter/material.dart';

import 'catalog_product.dart';
import 'catalog_stock.dart';

/// Typed inventory search over the catalog list.
///
/// A query matches the product name and the product internal code, which is
/// also the QR payload (`ProductQr.payloadFor`), so a code read from a printed
/// label or typed by hand finds the same product as its name.
///
/// Matching is forgiving for store use: case-insensitive, accent-insensitive
/// (`cafe` finds `Café Grano`, `te` finds `Té`), whitespace collapsed, and
/// every typed term has to appear in the same product, in either its name or
/// its code. Term order does not matter, so `agua 002` and `002 agua` behave
/// the same.

const ValueKey<String> catalogSearchFieldKey = ValueKey<String>(
  'catalog-search',
);

const ValueKey<String> catalogSearchClearKey = ValueKey<String>(
  'catalog-search-clear',
);

const ValueKey<String> catalogSearchScanKey = ValueKey<String>(
  'catalog-search-scan',
);

/// Label announced for the search input, also used as its visible label.
const String catalogSearchLabel = 'Buscar por nombre o código';

/// Accented letters folded to their base letter, limited to what a Spanish
/// catalog uses, so a query typed without accents still matches.
const Map<String, String> _foldedAccents = <String, String>{
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};

/// Lowercases, folds Spanish accents and collapses internal whitespace.
String normalizeCatalogQuery(String value) {
  final String lowered = value.trim().toLowerCase();
  final StringBuffer folded = StringBuffer();
  for (final int rune in lowered.runes) {
    final String character = String.fromCharCode(rune);
    folded.write(_foldedAccents[character] ?? character);
  }
  return folded.toString().replaceAll(RegExp(r'\s+'), ' ');
}

String _searchableText(CatalogProduct product) =>
    normalizeCatalogQuery('${product.name} ${product.internalCode}');

/// Whether [product] matches [query]. An empty or whitespace-only query
/// matches every product.
bool catalogProductMatchesQuery(CatalogProduct product, String query) {
  final String normalized = normalizeCatalogQuery(query);
  if (normalized.isEmpty) return true;
  final String haystack = _searchableText(product);
  return normalized.split(' ').every((String term) => haystack.contains(term));
}

/// Products matching [query], in their original order. The input list is never
/// modified, and an empty query returns every product.
List<CatalogProduct> filterCatalogProducts(
  List<CatalogProduct> products,
  String query,
) {
  if (normalizeCatalogQuery(query).isEmpty) {
    return List<CatalogProduct>.unmodifiable(products);
  }
  return List<CatalogProduct>.unmodifiable(
    products.where(
      (CatalogProduct product) => catalogProductMatchesQuery(product, query),
    ),
  );
}

/// Same filter over catalog items, so the list keeps the holdings it already
/// showed. The input list is never modified.
List<CatalogItem> filterCatalogItems(List<CatalogItem> items, String query) {
  if (normalizeCatalogQuery(query).isEmpty) {
    return List<CatalogItem>.unmodifiable(items);
  }
  return List<CatalogItem>.unmodifiable(
    items.where(
      (CatalogItem item) => catalogProductMatchesQuery(item.product, query),
    ),
  );
}

/// The search input shown above the product list.
///
/// The owner keeps [controller] and rebuilds on [onChanged], so the clear
/// control appears as soon as there is a query.
class CatalogSearchField extends StatelessWidget {
  const CatalogSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    this.onScan,
    this.focusNode,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// When set, a camera entry point is offered next to the field. The caller
  /// decides that, so a platform without a camera route never shows one.
  final VoidCallback? onScan;

  bool get _hasQuery => controller.text.trim().isNotEmpty;

  /// The clear action and the camera action, side by side when there is
  /// something to clear: a query must not hide the camera, otherwise a seller
  /// who already typed has to clear the field before scanning again.
  Widget? _suffix() {
    final List<Widget> actions = <Widget>[
      if (_hasQuery)
        IconButton(
          key: catalogSearchClearKey,
          icon: const Icon(Icons.close),
          tooltip: 'Limpiar búsqueda',
          onPressed: onClear,
        ),
      if (onScan != null)
        IconButton(
          key: catalogSearchScanKey,
          icon: const Icon(Icons.qr_code_scanner),
          tooltip: 'Escanear código QR',
          onPressed: onScan,
        ),
    ];
    if (actions.isEmpty) return null;
    if (actions.length == 1) return actions.single;
    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: catalogSearchFieldKey,
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      autocorrect: false,
      decoration: InputDecoration(
        isDense: true,
        labelText: catalogSearchLabel,
        hintText: 'Nombre o código',
        prefixIcon: const Icon(Icons.search),
        border: const OutlineInputBorder(),
        suffixIcon: _suffix(),
      ),
    );
  }
}
