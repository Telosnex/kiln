/// The `native_build` user define (ADR 001 D2).
enum NativeBuildMode {
  auto,
  download,
  source;

  static NativeBuildMode parse(Object? value) => switch (value) {
    null || 'auto' => NativeBuildMode.auto,
    'download' => NativeBuildMode.download,
    'source' => NativeBuildMode.source,
    _ => throw FormatException(
      'native_build must be auto, download or source, not "$value".',
    ),
  };
}

final _repository = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

/// Parses the `native_release` user define: the GitHub repository
/// (`owner/name`) that hosts the release, or null.
String? parseReleaseRepository(Object? value) {
  if (value == null) return null;
  if (value is String && _repository.hasMatch(value)) return value;
  throw FormatException(
    'native_release must be a GitHub repository such as "Telosnex/fllama", '
    'not "$value".',
  );
}

/// What the hook does.
sealed class BuildDecision {
  const BuildDecision();
}

/// Download and publish the prebuilt files.
final class UsePrebuilt extends BuildDecision {
  const UsePrebuilt();
}

/// Run the source build. [reason] says why prebuilt files are not used.
final class BuildFromSource extends BuildDecision {
  const BuildFromSource(this.reason, {required this.requested});

  final String reason;

  /// Whether `native_build: source` or `native_release` asked for it.
  final bool requested;
}

/// Stop with [message].
final class FailBuild extends BuildDecision {
  const FailBuild(this.message);

  final String message;
}

/// Applies ADR 001 D2.
///
/// [prebuiltProblem] is null if the manifest has files for this target, its
/// source key equals the local key, and the files can serve this build.
/// Otherwise it says why not.
BuildDecision decideBuild({
  required NativeBuildMode mode,
  required String? releaseRepository,
  required String? prebuiltProblem,
}) {
  if (releaseRepository != null) {
    return mode == NativeBuildMode.download
        ? const FailBuild('native_release needs native_build: source or auto.')
        : const BuildFromSource('native_release is set', requested: true);
  }
  return switch (mode) {
    NativeBuildMode.source => const BuildFromSource(
      'native_build is source',
      requested: true,
    ),
    NativeBuildMode.auto when prebuiltProblem == null => const UsePrebuilt(),
    NativeBuildMode.auto => BuildFromSource(prebuiltProblem!, requested: false),
    NativeBuildMode.download when prebuiltProblem == null =>
      const UsePrebuilt(),
    NativeBuildMode.download => FailBuild(
      'native_build is download, but prebuilt files cannot be used: '
      '$prebuiltProblem.',
    ),
  };
}
