import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore path of the client configuration the version gate reads before
/// login. Rules allow anonymous single-document reads of exactly this path.
const String clientConfigPath = 'appConfig/client';

/// How long the gate waits for the configuration before letting the app in.
const Duration minimumVersionTimeout = Duration(seconds: 5);

/// A `MAJOR.MINOR.PATCH` version whose parts compare as numbers.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');

  /// Parses exactly three dot-separated numbers; anything else is null.
  static AppVersion? tryParse(String raw) {
    final RegExpMatch? match = _pattern.firstMatch(raw);
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}

/// What the gate decided for the installed build.
sealed class VersionGateDecision {
  const VersionGateDecision();
}

/// The build may continue: it meets the minimum, or the check could not run.
final class VersionAllowed extends VersionGateDecision {
  const VersionAllowed();
}

/// The build is older than the configured minimum.
final class UpdateRequired extends VersionGateDecision {
  const UpdateRequired({
    required this.installedVersion,
    required this.minimumVersion,
    this.androidUpdateUrl,
    this.iosUpdateUrl,
  });

  final String installedVersion;
  final String minimumVersion;
  final Uri? androidUpdateUrl;
  final Uri? iosUpdateUrl;
}

/// Reads the raw client configuration; null when the document is absent.
abstract interface class MinimumVersionSource {
  Future<Map<String, Object?>?> readClientConfig();
}

typedef MinimumVersionSourceLoader = Future<MinimumVersionSource> Function();

class FirestoreMinimumVersionSource implements MinimumVersionSource {
  FirestoreMinimumVersionSource(this._firestore);

  final FirebaseFirestore _firestore;

  @override
  Future<Map<String, Object?>?> readClientConfig() async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await _firestore
        .doc(clientConfigPath)
        .get();
    return snapshot.data();
  }
}

/// Compares [installedVersion] with the configured minimum.
///
/// Fails open: a missing document, a malformed version, a read error or a
/// read slower than [timeout] all allow the app. The gate nudges delivery; it
/// is not a security boundary, and a configuration outage must not stop sales.
Future<VersionGateDecision> checkMinimumVersion({
  required String installedVersion,
  required MinimumVersionSourceLoader loadSource,
  Duration timeout = minimumVersionTimeout,
}) async {
  final AppVersion? installed = AppVersion.tryParse(installedVersion);
  if (installed == null) return const VersionAllowed();
  final Map<String, Object?>? config;
  try {
    config = await Future<Map<String, Object?>?>(() async {
      final MinimumVersionSource source = await loadSource();
      return source.readClientConfig();
    }).timeout(timeout);
  } on Object {
    return const VersionAllowed();
  }
  if (config == null) return const VersionAllowed();
  final Object? rawMinimum = config['minimumVersion'];
  final AppVersion? minimum = rawMinimum is String
      ? AppVersion.tryParse(rawMinimum)
      : null;
  if (minimum == null || installed.compareTo(minimum) >= 0) {
    return const VersionAllowed();
  }
  return UpdateRequired(
    installedVersion: installed.toString(),
    minimumVersion: minimum.toString(),
    androidUpdateUrl: _webUrl(config['androidUpdateUrl']),
    iosUpdateUrl: _webUrl(config['iosUpdateUrl']),
  );
}

Uri? _webUrl(Object? raw) {
  if (raw is! String) return null;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasAuthority) return null;
  return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
}
