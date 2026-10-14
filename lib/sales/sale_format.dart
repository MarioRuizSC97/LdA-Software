/// Shared integer-only display formatting for money and quantities. Values
/// never pass through binary floating point.
library;

import 'sale_cart.dart';

/// Centavos with the currency, for example `12900` → `129.00 MXN`.
String formatMoney(int centavos) => '${formatCentavos(centavos)} MXN';

/// Spanish payment method label.
String salePaymentLabel(SalePaymentMethod method) => switch (method) {
  SalePaymentMethod.cash => 'Efectivo',
  SalePaymentMethod.card => 'Tarjeta',
  SalePaymentMethod.transfer => 'Transferencia',
};

/// Formats integer centavos as `units.cc`, for example `12900` → `129.00`.
String formatCentavos(int centavos) {
  final int absolute = centavos.abs();
  final String sign = centavos < 0 ? '-' : '';
  final String fraction = (absolute % 100).toString().padLeft(2, '0');
  return '$sign${absolute ~/ 100}.$fraction';
}

/// Formats a quantity scaled by 10^precision, padded to the precision, for
/// example `250` at precision 2 → `2.50`.
String formatScaledQuantity(int scaled, int precision) {
  if (precision == 0) return scaled.toString();
  final int absolute = scaled.abs();
  final String sign = scaled < 0 ? '-' : '';
  var divisor = 1;
  for (var index = 0; index < precision; index += 1) {
    divisor *= 10;
  }
  final String fraction = (absolute % divisor).toString().padLeft(
    precision,
    '0',
  );
  return '$sign${absolute ~/ divisor}.$fraction';
}

const List<String> _spanishMonths = <String>[
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

/// Formats a date and time already in the zone to show, in Spanish, for
/// example "8 de octubre de 2026, 19:42" (24-hour clock).
String formatSaleDateTime(DateTime value) {
  final String hour = value.hour.toString().padLeft(2, '0');
  final String minute = value.minute.toString().padLeft(2, '0');
  return '${value.day} de ${_spanishMonths[value.month - 1]} de '
      '${value.year}, $hour:$minute';
}
