import 'dart:convert';
import 'dart:io';

/// Uploads release assets. [GhPublisher] uses the GitHub CLI.
abstract interface class Publisher {
  /// Creates release [tag] with [assets], then publishes it. Fails if a
  /// published release [tag] exists. [latest] marks it as the repository's
  /// latest release on GitHub. Pass true only for a package's own release,
  /// so that side releases (runtime files, GPU packs) never take the label.
  Future<void> publish({
    required String repository,
    required String tag,
    required List<File> assets,
    required String notes,
    required bool latest,
  });

  /// Asset name to SHA-256 of published release [tag], or null if there is
  /// no published release [tag].
  Future<Map<String, String>?> publishedAssetDigests({
    required String repository,
    required String tag,
  });
}

/// [Publisher] with `gh`. In GitHub Actions, set GH_TOKEN.
final class GhPublisher implements Publisher {
  GhPublisher({this.log});

  final void Function(String message)? log;

  Future<ProcessResult> _gh(List<String> args, {bool check = true}) async {
    final result = await Process.run('gh', args, stdoutEncoding: utf8);
    if (check && result.exitCode != 0) {
      throw StateError(
        'gh ${args.take(3).join(' ')} failed (${result.exitCode}): '
        '${result.stderr}',
      );
    }
    return result;
  }

  @override
  Future<void> publish({
    required String repository,
    required String tag,
    required List<File> assets,
    required String notes,
    required bool latest,
  }) async {
    final view = await _gh([
      'release', 'view', tag, '--repo', repository, '--json', 'isDraft', //
    ], check: false);
    if (view.exitCode == 0) {
      final isDraft = (jsonDecode(view.stdout as String) as Map)['isDraft'];
      if (isDraft != true) {
        throw StateError(
          'Release $tag of $repository is published already. Its files are '
          'final (ADR 001 R6). Restore the manifest that refers to it.',
        );
      }
      log?.call('Deleting draft release $tag from an earlier run');
      await _gh([
        'release', 'delete', tag, '--repo', repository, '--yes', //
        '--cleanup-tag',
      ]);
    }
    final commit = Platform.environment['GITHUB_SHA'];
    log?.call('Creating draft release $tag with ${assets.length} assets');
    await _gh([
      'release', 'create', tag, '--repo', repository, '--draft', //
      '--latest=false', '--title', tag, '--notes', notes,
      if (commit != null && commit.isNotEmpty) ...['--target', commit],
      ...assets.map((a) => a.path),
    ]);
    await _gh([
      'release', 'edit', tag, '--repo', repository, '--draft=false', //
      '--latest=$latest',
    ]);
    log?.call('Published release $tag');
  }

  @override
  Future<Map<String, String>?> publishedAssetDigests({
    required String repository,
    required String tag,
  }) async {
    final result = await _gh([
      'api', 'repos/$repository/releases/tags/$tag', //
    ], check: false);
    if (result.exitCode != 0) return null;
    return assetDigestsOf(jsonDecode(result.stdout as String));
  }
}

/// Asset name to SHA-256 from a GitHub release JSON object.
Map<String, String> assetDigestsOf(Object? release) {
  final digests = <String, String>{};
  if (release case {'assets': final List<Object?> assets}) {
    for (final asset in assets) {
      if (asset case {
        'name': final String name,
        'digest': final String digest,
      } when digest.startsWith('sha256:')) {
        digests[name] = digest.substring('sha256:'.length);
      }
    }
  }
  return digests;
}
