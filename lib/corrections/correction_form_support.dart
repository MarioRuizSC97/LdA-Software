import '../catalog/catalog_product.dart';
import '../sales/sale_cart.dart';
import 'correction_draft.dart';
import 'correction_sale.dart';
import 'sale_corrections.dart';

// Shared seller copy and validation for the correction forms. User-visible
// text is neutral, professional Spanish; identifiers stay in English.

const String correctionSessionMessage =
    'Tu sesión cambió. Inicia sesión de nuevo para continuar.';

/// A newer attempt settled this submission first and nothing is stored.
const String correctionStaleMessage =
    'La solicitud quedó desactualizada. Intenta de nuevo.';

/// Another correction may have committed and must be retried first.
const String correctionUnresolvedMessage =
    'Hay otra corrección sin confirmar. Reinténtala antes de registrar una '
    'nueva.';

/// A correction committed, but the seller has not yet seen its receipt.
const String correctionUnacknowledgedMessage =
    'Hay una corrección registrada pendiente de revisar. Abre su comprobante '
    'para continuar.';

const String correctionWindowMessage =
    'La venta ya está fuera del plazo de $correctionWindowDays días para '
    'correcciones.';

/// Why a new correction cannot begin now, or null when it can: an unresolved
/// draft must be retried, and a committed one must have its receipt seen.
/// A form that reopens its own stored draft locks to it before asking.
String? correctionBlockedMessage(SaleCorrections corrections) {
  if (corrections.unresolvedDraft() != null) {
    return correctionUnresolvedMessage;
  }
  if (corrections.unacknowledged() != null) {
    return correctionUnacknowledgedMessage;
  }
  return null;
}

String? correctionNoteError(String text) {
  try {
    normalizeCorrectionNote(text);
    return null;
  } on CorrectionValidationException {
    return 'La nota admite como máximo $correctionNoteMaxLength caracteres.';
  }
}

/// Validates one selected sale line at its precision with BigInt against
/// its remaining quantity; [verb] names the action in the over-limit copy
/// ("devolver", "reemplazar").
String? correctionLineError(
  String text,
  CorrectableSaleLine line, {
  required String verb,
}) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return 'Escribe una cantidad.';
  final String over =
      'No puedes $verb más de lo restante '
      '(${line.remainingDecimal} ${line.quantitySpec.unit}).';
  final int scaled;
  try {
    scaled = scaleCorrectionQuantity(
      trimmed,
      line.quantitySpec,
      productId: line.productId,
    );
  } on CorrectionValidationException catch (error) {
    return switch (error.reason) {
      CorrectionValidationReason.tooPrecise => _precisionError(
        line.quantitySpec.precision,
      ),
      CorrectionValidationReason.notPositive =>
        'La cantidad debe ser mayor que cero.',
      CorrectionValidationReason.tooLarge => over,
      _ => _malformedError,
    };
  }
  return scaled > line.remainingScaled ? over : null;
}

/// Validates a new item quantity at the product precision with BigInt.
String? newItemQuantityError(String text, QuantitySpec spec, String id) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return 'Escribe una cantidad.';
  try {
    SaleCartLine(
      productId: id,
      name: id,
      quantitySpec: spec,
      quantity: trimmed,
    );
    return null;
  } on SaleValidationException catch (error) {
    return switch (error.reason) {
      SaleValidationReason.tooPrecise => _precisionError(spec.precision),
      SaleValidationReason.notPositive =>
        'La cantidad debe ser mayor que cero.',
      SaleValidationReason.tooLarge => 'La cantidad es demasiado grande.',
      _ => _malformedError,
    };
  }
}

const String _malformedError =
    'Escribe una cantidad válida, por ejemplo 2 o 1.5.';

String _precisionError(int precision) => precision == 0
    ? 'Este producto solo admite cantidades enteras.'
    : 'Usa como máximo $precision '
          '${precision == 1 ? 'decimal' : 'decimales'}.';
