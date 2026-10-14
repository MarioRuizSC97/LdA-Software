import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_format.dart';

void main() {
  group('formatScaledQuantity', () {
    test('positive scaled values include whole and fraction digits', () {
      expect(formatScaledQuantity(250, 2), '2.50');
      expect(formatScaledQuantity(5, 1), '0.5');
    });

    test('zero values format without a sign at any precision', () {
      expect(formatScaledQuantity(0, 0), '0');
      expect(formatScaledQuantity(0, 3), '0.000');
    });

    test('precision zero returns the plain integer', () {
      expect(formatScaledQuantity(7, 0), '7');
      expect(formatScaledQuantity(-5, 0), '-5');
    });

    test('negative values keep a single leading minus sign', () {
      expect(formatScaledQuantity(-250, 2), '-2.50');
      expect(formatScaledQuantity(-5, 1), '-0.5');
      expect(formatScaledQuantity(-1200, 2), '-12.00');
      expect(formatScaledQuantity(-1250, 3), '-1.250');
      expect(formatScaledQuantity(-50, 2), '-0.50');
      expect(formatScaledQuantity(-12345, 2), '-123.45');
    });

    test('negative outputs mirror positive digits without a plus sign', () {
      const List<(int, int)> magnitudes = <(int, int)>[
        (5, 1),
        (250, 2),
        (1250, 3),
        (50, 2),
        (12345, 2),
      ];
      for (final (int scaled, int precision) in magnitudes) {
        final String positive = formatScaledQuantity(scaled, precision);
        expect(formatScaledQuantity(-scaled, precision), '-$positive');
        expect(positive, isNot(startsWith('-')));
        expect(positive, isNot(contains('+')));
      }
    });
  });
}
