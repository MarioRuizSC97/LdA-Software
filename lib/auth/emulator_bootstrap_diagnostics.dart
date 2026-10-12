import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart' show debugPrint, immutable;

/// Fixed failure families for the emulator session gateway bootstrap. Never
/// derived from a runtime type name, a message, or any SDK-controlled value.
enum EmulatorBootstrapDiagnosticCategory {
  /// The host platform cannot reach the local emulators.
  unsupportedPlatform('unsupported-platform'),

  /// A Firebase SDK failure while initializing or connecting.
  firebase('firebase'),

  /// A trust or connection guard rejected the app or emulator.
  state('state'),

  /// Nothing above matched. Deliberately tells the reader no more.
  other('other');

  const EmulatorBootstrapDiagnosticCategory(this.token);

  final String token;
}

/// Emitted when an error carries no Firebase code to classify.
const String emulatorBootstrapCodeNone = 'none';

/// Emitted when a Firebase code exists but is not on the finite allowlist.
const String emulatorBootstrapCodeOther = 'other';

/// Finite codes that are safe to print verbatim.
const Set<String> _allowlistedCodes = <String>{
  'duplicate-app',
  'internal',
  'invalid-api-key',
  'network-request-failed',
  'no-app',
  'not-initialized',
  'unavailable',
  'unknown',
};

/// One sanitized bootstrap failure: fixed values and nothing else.
@immutable
final class EmulatorBootstrapDiagnostic {
  const EmulatorBootstrapDiagnostic({
    required this.category,
    required this.code,
  });

  final EmulatorBootstrapDiagnosticCategory category;
  final String code;

  String render() =>
      '[emulator-bootstrap] stage=gateway category=${category.token} '
      'code=$code';

  @override
  String toString() => render();
}

/// Sink seam so tests can capture diagnostics instead of printing them.
typedef EmulatorBootstrapDiagnosticReporter = void Function(
  EmulatorBootstrapDiagnostic diagnostic,
);

/// The injectable diagnostic sink. Reporting is best-effort: a failing sink is
/// swallowed so that diagnostics can never change the login shell behaviour.
abstract final class EmulatorBootstrapDiagnostics {
  /// Injectable sink. Tests replace it; production keeps the console printer.
  static EmulatorBootstrapDiagnosticReporter reporter = _printDiagnostic;

  static void restoreDefaultReporter() => reporter = _printDiagnostic;

  static void report(EmulatorBootstrapDiagnostic diagnostic) {
    try {
      reporter(diagnostic);
    } catch (_) {
      // A broken diagnostic sink must not alter a fail-closed bootstrap.
    }
  }
}

void _printDiagnostic(EmulatorBootstrapDiagnostic diagnostic) {
  // debugPrint reaches the browser console; developer.log alone often does not.
  debugPrint(diagnostic.render());
}

/// Classifies [error] into fixed tokens. [error] is never rendered.
EmulatorBootstrapDiagnostic emulatorBootstrapDiagnosticFor(Object error) {
  if (error is FirebaseException) {
    return EmulatorBootstrapDiagnostic(
      category: EmulatorBootstrapDiagnosticCategory.firebase,
      code: _allowlistedCodes.contains(error.code)
          ? error.code
          : emulatorBootstrapCodeOther,
    );
  }
  return EmulatorBootstrapDiagnostic(
    category: switch (error) {
      // UnimplementedError extends UnsupportedError but is not a platform gap.
      UnimplementedError() => EmulatorBootstrapDiagnosticCategory.other,
      UnsupportedError() =>
        EmulatorBootstrapDiagnosticCategory.unsupportedPlatform,
      StateError() => EmulatorBootstrapDiagnosticCategory.state,
      _ => EmulatorBootstrapDiagnosticCategory.other,
    },
    code: emulatorBootstrapCodeNone,
  );
}

/// Reports one session gateway bootstrap failure, best-effort.
void reportEmulatorBootstrapFailure(Object error) {
  try {
    EmulatorBootstrapDiagnostics.report(emulatorBootstrapDiagnosticFor(error));
  } catch (_) {
    // Classification must never escape into the login shell either.
  }
}
