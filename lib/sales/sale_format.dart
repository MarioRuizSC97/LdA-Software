/// Shared integer-only display formatting for money and quantities. Values
/// never pass through binary floating point.
library;

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
  var divisor = 1;
  for (var index = 0; index < precision; index += 1) {
    divisor *= 10;
  }
  final String fraction = (scaled % divisor).toString().padLeft(precision, '0');
  return '${scaled ~/ divisor}.$fraction';
}
