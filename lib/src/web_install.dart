import 'dart:io';

import 'package:path/path.dart' as p;

import 'fetch.dart';
import 'hashing.dart';
import 'locks.dart';
import 'source_key.dart';
import 'web_manifest.dart';

/// The `web_build` user define (ADR 002 D4).
enum WebBuildMode {
  /// Download the generated files of web.json and verify them.
  download,

  /// Copy the generated files from a local build directory.
  local;

  static WebBuildMode parse(Object? value) => switch (value) {
    null || 'download' => WebBuildMode.download,
    'local' => WebBuildMode.local,
    _ => throw FormatException(
      'web_build must be download or local, not "$value".',
    ),
  };
}

/// Directory in the app `web/` directory that holds the package
/// directories (ADR 002 §5).
const webInstallDirectoryName = 'native_prebuilt';

/// Version file that `web install-dev` writes (ADR 002 D13).
const devVersionFileName = '.native_prebuilt_web_version';

/// The web files of one package, ready to install.
final class WebFileSet {
  WebFileSet._(this.files, this.dependencies, this.webVersion);

  /// Installed name to the file to copy.
  final Map<String, File> files;

  /// Files whose change changes [files]: for a hook.
  final List<Uri> dependencies;

  /// webVersion of [files].
  final String webVersion;
}

/// Gets the web files of the package at [packageRoot] (ADR 002 D4).
///
/// In [WebBuildMode.download], the generated files of [manifest] are
/// downloaded into [cacheRoot] and verified. It fails if the manifest
/// source key is not the local source key, or if a hand-written file
/// differs from its entry. In [WebBuildMode.local], every file under
/// [localDirectory] is used, and nothing is verified. Hand-written files
/// come from the package in both modes.
Future<WebFileSet> resolveWebFiles({
  required Uri packageRoot,
  required WebManifest? manifest,
  required WebBuildMode mode,
  required Directory cacheRoot,
  Directory? localDirectory,
  HttpClient? client,
  void Function(String message)? log,
}) async {
  final files = <String, File>{};
  final dependencies = <Uri>[packageRoot.resolve(webManifestPath)];
  for (final entry in manifest?.handWritten ?? const <WebFile>[]) {
    final file = File.fromUri(packageRoot.resolve(entry.source));
    dependencies.add(file.uri);
    if (!await file.exists()) {
      throw StateError('Hand-written web file ${entry.source} is missing.');
    }
    if (mode == WebBuildMode.download &&
        await sha256OfFile(file) != entry.sha256) {
      throw StateError(
        '${entry.source} differs from its entry in $webManifestPath. Run '
        '"dart run prebuilt:web stamp" in the package.',
      );
    }
    files[entry.name] = file;
  }

  switch (mode) {
    case WebBuildMode.download:
      if (manifest == null) {
        throw StateError('The package has no $webManifestPath.');
      }
      final generated = manifest.generated.toList();
      if (generated.isNotEmpty) {
        final sourceKey = await computeSourceKey(
          packageRoot,
          memoDirectory: Directory(p.join(cacheRoot.path, 'source_keys')),
        );
        dependencies.addAll(sourceKey.files.map((f) => f.uri));
        if (sourceKey.key != manifest.sourceKey) {
          throw StateError(
            'The package sources differ from the sources of its web files '
            '(local source key ${sourceKey.short}, $webManifestPath '
            '${manifest.sourceKey!.substring(0, 16)}). Run the native '
            'release workflow, or set web_build: local.',
          );
        }
      }
      final http = client ?? HttpClient();
      try {
        for (final entry in generated) {
          files[entry.name] = await fetchVerified(
            entry.fetchSpec,
            File(p.join(cacheRoot.path, entry.sha256, p.basename(entry.name))),
            client: http,
            archiveCache: cacheRoot,
            log: log,
          );
        }
      } finally {
        if (client == null) http.close(force: true);
      }
    case WebBuildMode.local:
      final directory = localDirectory;
      if (directory == null) {
        throw StateError('web_build is local, but web_build_dir is not set.');
      }
      final local = await listWebDirectory(directory);
      if (local.isEmpty) {
        throw StateError('The web build directory ${directory.path} is empty.');
      }
      for (final MapEntry(key: name, value: file) in local.entries) {
        if (files.containsKey(name)) {
          throw StateError(
            '$name is a hand-written file and is also in ${directory.path}.',
          );
        }
        files[name] = file;
        dependencies.add(file.uri);
      }
  }

  final digests = [
    for (final MapEntry(key: name, value: file) in files.entries)
      (name: name, sha256: await sha256OfFile(file)),
  ];
  return WebFileSet._(files, dependencies, webVersionOf(digests));
}

/// Every file under [directory], by its path relative to [directory], with
/// `/`.
Future<Map<String, File>> listWebDirectory(Directory directory) async {
  if (!await directory.exists()) {
    throw StateError('Directory ${directory.path} does not exist.');
  }
  final files = <String, File>{};
  await for (final entity in directory.list(
    recursive: true,
    followLinks: true,
  )) {
    if (entity is! File) continue;
    final name = p
        .relative(entity.path, from: directory.path)
        .replaceAll(r'\', '/');
    validateWebName(name);
    files[name] = entity;
  }
  return files;
}

/// The app directory for a hook run (ADR 002 D2): the parent of the
/// `.dart_tool` directory that holds [outputDirectoryShared].
Directory findAppRoot(Uri outputDirectoryShared) {
  final segments = outputDirectoryShared.pathSegments;
  final index = segments.lastIndexOf('.dart_tool');
  if (index < 0) {
    throw StateError(
      'Cannot find the app: ${outputDirectoryShared.toFilePath()} is not '
      'in a .dart_tool directory. Set the user define web_root.',
    );
  }
  return Directory.fromUri(
    outputDirectoryShared.replace(pathSegments: [...segments.take(index), '']),
  );
}

/// The install directory of [packageName] in the app at [appRoot].
Directory appWebDirectory(Directory appRoot, String packageName) {
  final web = Directory(p.join(appRoot.path, 'web'));
  if (!web.existsSync()) {
    throw StateError(
      '${appRoot.path} has no web/ directory. In a pub workspace, set the '
      'user define web_root to the app directory.',
    );
  }
  return Directory(p.join(web.path, webInstallDirectoryName, packageName));
}

var _unique = 0;

/// Makes [destination] hold exactly [files] (ADR 002 D1, D2), and returns
/// the installed files.
///
/// If [destination] already holds them, nothing is written. Otherwise the
/// files go into a new directory beside it, which then replaces it. The
/// parent gets a `.gitignore` with `*`.
Future<List<File>> installWebDirectory(
  Directory destination,
  Map<String, File> files, {
  required Directory lockDirectory,
  void Function(String message)? log,
}) async {
  final parent = destination.parent;
  await parent.create(recursive: true);
  final gitignore = File(p.join(parent.path, '.gitignore'));
  if (!await gitignore.exists() || await gitignore.readAsString() != '*\n') {
    await gitignore.writeAsString('*\n');
  }
  final installed = [
    for (final name in files.keys.toList()..sort())
      File(p.join(destination.path, p.fromUri(name))),
  ];
  final lock = File(
    p.join(
      lockDirectory.path,
      'web-${sha256OfString(destination.absolute.path).substring(0, 16)}.lock',
    ),
  );
  await withFileLock(lock, () async {
    if (await _holds(destination, files)) {
      log?.call('${destination.path} is up to date');
      return;
    }
    final unique = '$pid.${_unique++}';
    final temporary = Directory('${destination.path}.$unique.tmp');
    final old = Directory('${destination.path}.$unique.old');
    try {
      for (final MapEntry(key: name, value: file) in files.entries) {
        final target = File(p.join(temporary.path, p.fromUri(name)));
        await target.parent.create(recursive: true);
        await file.copy(target.path);
      }
      if (await destination.exists()) await destination.rename(old.path);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      if (await old.exists()) await old.delete(recursive: true);
    }
    log?.call('Installed ${files.length} web files in ${destination.path}');
  });
  return installed;
}

/// Whether [directory] holds exactly [files], with equal contents.
Future<bool> _holds(Directory directory, Map<String, File> files) async {
  if (!await directory.exists()) return false;
  final present = await listWebDirectory(directory);
  if (present.length != files.length) return false;
  for (final MapEntry(key: name, value: file) in files.entries) {
    final installed = present[name];
    if (installed == null ||
        await installed.length() != await file.length() ||
        await sha256OfFile(installed) != await sha256OfFile(file)) {
      return false;
    }
  }
  return true;
}

const _gitignoreStart =
    '# native_prebuilt web install-dev: generated, do not edit.';
const _gitignoreEnd = '# End of native_prebuilt web install-dev.';

/// `web install-dev` (ADR 002 D13): copies [set] into the `lib/web/`
/// directory of the package at [packageRoot], for the package tests.
///
/// Files that are already at their place (hand-written files in `lib/web/`)
/// stay. The other names go into a block in `lib/web/.gitignore`. Names of
/// an earlier install that [set] does not have are deleted. Writes
/// [devVersionFileName] with the webVersion of [set].
Future<void> installDevWebFiles(
  Uri packageRoot,
  WebFileSet set, {
  void Function(String message)? log,
}) async {
  final libWeb = Directory.fromUri(packageRoot.resolve('lib/web/'));
  await libWeb.create(recursive: true);
  final gitignore = File(p.join(libWeb.path, '.gitignore'));
  final lines = await gitignore.exists()
      ? await gitignore.readAsLines()
      : <String>[];
  final start = lines.indexOf(_gitignoreStart);
  final end = lines.indexOf(_gitignoreEnd);
  final hasBlock = start >= 0 && end > start;
  final previous = hasBlock
      ? lines.sublist(start + 1, end).map((l) => l.substring(1)).toSet()
      : <String>{};
  final kept = hasBlock
      ? [...lines.take(start), ...lines.skip(end + 1)]
      : lines;

  final ignored = <String>{devVersionFileName};
  for (final MapEntry(key: name, value: file) in set.files.entries) {
    final target = File(p.join(libWeb.path, p.fromUri(name)));
    if (p.equals(target.absolute.path, file.absolute.path)) continue;
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    ignored.add(name);
  }
  for (final name in previous.difference(ignored)) {
    final stale = File(p.join(libWeb.path, p.fromUri(name)));
    if (await stale.exists()) await stale.delete();
  }
  await File(
    p.join(libWeb.path, devVersionFileName),
  ).writeAsString('${set.webVersion}\n');

  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  await gitignore.writeAsString(
    [
      ...kept,
      if (kept.isNotEmpty) '',
      _gitignoreStart,
      for (final name in ignored.toList()..sort()) '/$name',
      _gitignoreEnd,
      '',
    ].join('\n'),
  );
  log?.call(
    'Installed ${ignored.length - 1} web files in ${libWeb.path} '
    '(webVersion ${set.webVersion})',
  );
}
