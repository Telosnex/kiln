import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'hashing.dart';
import 'locks.dart';

/// Upstream sources of a package's source build, pinned in
/// `native_artifacts/sources.json`:
///
/// ```json
/// {"schema": 1, "sources": [
///   {"name": "zxing-cpp", "git": "https://github.com/zxing-cpp/zxing-cpp.git",
///    "commit": "287c85df6f961c8efbfb5ffd736cd9457b8b890e", "submodules": true},
///   {"name": "onnxruntime", "targets": ["linux-arm64"],
///    "url": "https://.../onnxruntime-linux-aarch64-1.27.0.tgz",
///    "sha256": "..."}
/// ]}
/// ```
///
/// Packagers read the file to place the sources before a build without
/// network (`dart run prebuilt:flatpak`). The hook gets them with
/// `SourceBuild.pinnedSource`: from the cache if present, else fetched.
const sourcesPath = 'native_artifacts/sources.json';

/// One pinned source: a git commit, or a file by SHA-256.
final class PinnedSource {
  const PinnedSource._({
    required this.name,
    this.git,
    this.commit,
    this.submodules = false,
    this.url,
    this.sha256,
    this.targets,
  });

  final String name;
  final String? git;
  final String? commit;
  final bool submodules;
  final String? url;
  final String? sha256;

  /// Target names (`linux-arm64`, ...) that need the source; null: all.
  final List<String>? targets;

  bool get isGit => git != null;

  /// File name of a URL source.
  String get fileName => Uri.parse(url!).pathSegments.last;

  /// Directory in the cache: `sources/<name>-<first 16 of commit or sha256>`.
  /// A git source is checked out there; a URL source is the file
  /// [fileName] in it.
  String get cacheDirectoryName =>
      '$name-${(commit ?? sha256)!.substring(0, 16)}';

  bool appliesTo(String target) => targets == null || targets!.contains(target);

  static final _name = RegExp(r'^[A-Za-z0-9_.+-]+$');
  static final _commit = RegExp(r'^[0-9a-f]{40}$');

  factory PinnedSource.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('a source must be an object');
    }
    final name = json['name'];
    if (name is! String || !_name.hasMatch(name)) {
      throw FormatException('source name "$name" is not a plain name');
    }
    final targets = switch (json['targets']) {
      null => null,
      final List<Object?> list when list.every((t) => t is String) =>
        list.cast<String>(),
      final other => throw FormatException('$name: targets $other'),
    };
    switch (json) {
      case {'git': final String git, 'commit': final String commit}
          when _commit.hasMatch(commit) && json['url'] == null:
        final submodules = json['submodules'] ?? false;
        if (submodules is! bool) throw FormatException('$name: submodules');
        return PinnedSource._(
          name: name,
          git: git,
          commit: commit,
          submodules: submodules,
          targets: targets,
        );
      case {'url': final String url, 'sha256': final String sha}
          when isSha256Hex(sha) && json['git'] == null:
        return PinnedSource._(
          name: name,
          url: url,
          sha256: sha,
          targets: targets,
        );
    }
    throw FormatException(
      '$name: needs "git" and a full "commit", or "url" and "sha256".',
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'git': ?git,
    'commit': ?commit,
    if (submodules) 'submodules': true,
    'url': ?url,
    'sha256': ?sha256,
    'targets': ?targets,
  };
}

/// Reads [sourcesPath] of the package at [packageRoot]; empty if absent.
Future<List<PinnedSource>> loadPinnedSources(Uri packageRoot) async {
  final file = File.fromUri(packageRoot.resolve(sourcesPath));
  if (!await file.exists()) return const [];
  final decoded = jsonDecode(await file.readAsString());
  if (decoded case {'schema': 1, 'sources': final List<Object?> sources}) {
    final parsed = sources.map(PinnedSource.fromJson).toList();
    final names = <String>{};
    for (final s in parsed) {
      if (!names.add(s.name)) {
        throw FormatException('${file.path}: source ${s.name} is listed twice');
      }
    }
    return parsed;
  }
  throw FormatException(
    '${file.path}: expected {"schema": 1, "sources": [...]}',
  );
}

/// Returns the directory of [source] in `<cacheRoot>/sources/`, fetching it
/// first if it is not there. With [offline], a missing source fails with the
/// path where a packager must put it.
Future<Directory> resolvePinnedSource(
  PinnedSource source, {
  required Directory cacheRoot,
  required bool offline,
  HttpClient? client,
  void Function(String message)? log,
}) async {
  final sources = Directory(p.join(cacheRoot.path, 'sources'));
  final dir = Directory(p.join(sources.path, source.cacheDirectoryName));
  return withFileLock(File('${dir.path}.lock'), () async {
    if (await _present(source, dir)) return dir;
    if (offline) {
      throw StateError(
        'Pinned source ${source.name} is not in the cache, and the build '
        'must not download (host_toolchain). Put '
        '${source.isGit ? 'a checkout of ${source.git} at ${source.commit}' : '${source.url} (sha256 ${source.sha256})'} '
        'at ${source.isGit ? dir.path : p.join(dir.path, source.fileName)}.',
      );
    }
    log?.call('Fetching ${source.name}');
    final partial = Directory('${dir.path}.partial');
    if (await partial.exists()) await partial.delete(recursive: true);
    await partial.create(recursive: true);
    if (source.isGit) {
      await _gitFetch(source, partial);
    } else {
      await _download(
        source,
        File(p.join(partial.path, source.fileName)),
        client,
      );
    }
    if (await dir.exists()) await dir.delete(recursive: true);
    await partial.rename(dir.path);
    return dir;
  });
}

Future<bool> _present(PinnedSource source, Directory dir) async {
  if (!await dir.exists()) return false;
  if (!source.isGit) {
    final file = File(p.join(dir.path, source.fileName));
    return await file.exists() && await sha256OfFile(file) == source.sha256;
  }
  // A checkout without .git (a packager's copy) is trusted: its path names
  // the commit. With .git, HEAD must be the commit.
  if (!await Directory(p.join(dir.path, '.git')).exists() &&
      !await File(p.join(dir.path, '.git')).exists()) {
    return (await dir.list().isEmpty) == false;
  }
  final head = await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: dir.path);
  return head.exitCode == 0 && (head.stdout as String).trim() == source.commit;
}

Future<void> _gitFetch(PinnedSource source, Directory dir) async {
  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: dir.path);
    if (r.exitCode != 0) {
      throw StateError('git ${args.join(' ')} (${source.name}): ${r.stderr}');
    }
  }

  await git(['init', '-q']);
  await git(['remote', 'add', 'origin', source.git!]);
  await git(['fetch', '-q', '--depth', '1', 'origin', source.commit!]);
  await git(['checkout', '-q', '--detach', 'FETCH_HEAD']);
  if (source.submodules) {
    await git([
      'submodule',
      'update',
      '-q',
      '--init',
      '--recursive',
      '--depth',
      '1',
    ]);
  }
}

Future<void> _download(PinnedSource source, File to, HttpClient? client) async {
  final http = client ?? HttpClient();
  try {
    for (var attempt = 1; ; attempt++) {
      try {
        final request = await http.getUrl(Uri.parse(source.url!));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
        }
        await response.pipe(to.openWrite());
        final actual = await sha256OfFile(to);
        if (actual != source.sha256) {
          throw StateError(
            '${source.url}: sha256 is $actual, not ${source.sha256}.',
          );
        }
        return;
      } on IOException {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  } finally {
    if (client == null) http.close();
  }
}
