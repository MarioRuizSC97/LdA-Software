import 'correction_draft.dart';

// User-visible correction labels, in neutral, professional Spanish.

String correctionReasonLabel(CorrectionReason reason) => switch (reason) {
  CorrectionReason.changeOfMind => 'Cambio de opinión',
  CorrectionReason.wrongProduct => 'Producto equivocado',
  CorrectionReason.factoryDefect => 'Defecto de fábrica',
  CorrectionReason.other => 'Otro',
};

String returnConditionLabel(ReturnCondition condition) => switch (condition) {
  ReturnCondition.good => 'En buen estado',
  ReturnCondition.factoryDefect => 'Defecto de fábrica',
};
