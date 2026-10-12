import 'dart:async' show TimeoutException;

import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter/foundation.dart' show debugPrint, immutable;

import 'catalog_repository.dart' show CatalogRepositoryUnavailable;

/// The only two catalog load boundaries that may report a failure.
enum CatalogDiagnosticStage {
  /// The Firestore read pipeline rejected a prepared request.
  repository,

  /// Emulator bootstrap failed before or while creating the repository.
  bootstrap,
}

/// Fixed failure families. Never derived from a runtime type name, a message,
/// or any other value that an SDK or document can control.
enum CatalogDiagnosticCategory {
  /// Authentication, session authority, or an access denial.
  session,

  /// The read itself failed: transport, timeout, or a missing document.
  read,

  /// A document or path did not match the catalog contract.
  parse,

  /// Nothing above matched. Deliberately tells the reader no more.
  unknown,
}

/// Emitted when an error carries no Firebase code to classify.
const String catalogDiagnosticCodeNone = 'none';

/// Emitted when a Firebase code exists but is not on the finite allowlist.
const String catalogDiagnosticCodeOther = 'other';

/// The single session-authority rejection used by the Firestore repository.
/// Identity, not text, is what lets the repository boundary log it once.
const FormatException catalogSessionInactiveFailure = FormatException(
  'catalog session is no longer active',
);

/// Finite codes that are safe to print verbatim. Anything else becomes
/// [catalogDiagnosticCodeOther]; plugins are never printed at all.
const Set<String> _allowlistedCodes = <String>{
  'aborted',
  'cancelled',
  'data-loss',
  'deadline-exceeded',
  'failed-precondition',
  'internal',
  'invalid-api-key',
  'invalid-credential',
  'missing-identifier',
  'network-request-failed',
  'not-found',
  'operation-not-allowed',
  'out-of-range',
  'permission-denied',
  'resource-exhausted',
  'too-many-requests',
  'unauthenticated',
  'unavailable',
  'unknown',
  'user-disabled',
  'user-not-found',
};

const Set<String> _firestorePlugins = <String>{'cloud_firestore'};
const Set<String> _authPlugins = <String>{'firebase_auth', 'firebase_core'};

/// One sanitized catalog load failure: three fixed values and nothing else.
@immutable
final class CatalogLoadDiagnostic {
  const CatalogLoadDiagnostic({
    required this.stage,
    required this.category,
    required this.code,
  });

  final CatalogDiagnosticStage stage;
  final CatalogDiagnosticCategory category;
  final String code;

  String render() =>
      '[catalog-load] stage=${stage.name} category=${category.name} code=$code';

  @override
  String toString() => render();
}

/// Sink seam so tests can capture diagnostics instead of printing them.
typedef CatalogDiagnosticReporter = void Function(
  CatalogLoadDiagnostic diagnostic,
);

/// The injectable diagnostic sink. Reporting is best-effort: a failing sink is
/// swallowed so that diagnostics can never change catalog behaviour.
abstract final class CatalogLoadDiagnostics {
  /// Injectable sink. Tests replace it; production keeps the console printer.
  static CatalogDiagnosticReporter reporter = _printDiagnostic;

  static void restoreDefaultReporter() => reporter = _printDiagnostic;

  static void report(CatalogLoadDiagnostic diagnostic) {
    try {
      reporter(diagnostic);
    } catch (_) {
      // A broken diagnostic sink must not alter a fail-closed catalog read.
    }
  }
}

void _printDiagnostic(CatalogLoadDiagnostic diagnostic) {
  // debugPrint reaches the browser console; developer.log alone often does not.
  debugPrint(diagnostic.render());
}

/// Keys the generic wrapper that the repository boundary is about to throw, so
/// the application loader boundary does not report the same failure again.
final Expando<Object> _reportedFailures = Expando<Object>('catalog-load');

/// Reports a prepared failure leaving the repository boundary. [error] is only
/// inspected for fixed categories and allowlisted codes; it is never passed on.
void reportCatalogRepositoryFailure({
  required Object error,
  required CatalogRepositoryUnavailable failure,
}) {
  _reportedFailures[failure] = true;
  if (identical(error, catalogSessionInactiveFailure)) {
    // Already reported at the authority check with its precise category.
    return;
  }
  CatalogLoadDiagnostics.report(
    _diagnosticFor(CatalogDiagnosticStage.repository, error),
  );
}

/// Reports a bootstrap failure, unless it is a repository failure that the
/// repository boundary already sanitized.
void reportCatalogBootstrapFailure(Object error) {
  if (error is CatalogRepositoryUnavailable &&
      _reportedFailures[error] == true) {
    return;
  }
  CatalogLoadDiagnostics.report(
    _diagnosticFor(CatalogDiagnosticStage.bootstrap, error),
  );
}

/// Runs one application-level catalog load and reports only failures that the
/// repository boundary could not have seen. The original failure is rethrown.
Future<T> guardCatalogBootstrap<T>(Future<T> Function() load) async {
  try {
    return await load();
  } catch (error) {
    reportCatalogBootstrapFailure(error);
    rethrow;
  }
}

void reportCatalogSessionFence() {
  CatalogLoadDiagnostics.report(
    const CatalogLoadDiagnostic(
      stage: CatalogDiagnosticStage.repository,
      category: CatalogDiagnosticCategory.session,
      code: catalogDiagnosticCodeNone,
    ),
  );
}

CatalogLoadDiagnostic _diagnosticFor(
  CatalogDiagnosticStage stage,
  Object error,
) {
  if (error is FirebaseException) {
    final String code = _allowlistedCodes.contains(error.code)
        ? error.code
        : catalogDiagnosticCodeOther;
    final bool denied =
        error.code == 'permission-denied' || error.code == 'unauthenticated';
    final CatalogDiagnosticCategory category =
        denied || _authPlugins.contains(error.plugin)
        ? CatalogDiagnosticCategory.session
        : _firestorePlugins.contains(error.plugin)
        ? CatalogDiagnosticCategory.read
        : CatalogDiagnosticCategory.unknown;
    return CatalogLoadDiagnostic(stage: stage, category: category, code: code);
  }
  return CatalogLoadDiagnostic(
    stage: stage,
    category: switch (error) {
      TimeoutException() => CatalogDiagnosticCategory.read,
      StateError() => CatalogDiagnosticCategory.read,
      FormatException() => CatalogDiagnosticCategory.parse,
      _ => CatalogDiagnosticCategory.unknown,
    },
    code: catalogDiagnosticCodeNone,
  );
}
