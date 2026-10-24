import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cache.dart';
import 'hashing.dart';
import 'source_key.dart';
import 'web_install.dart';
import 'web_manifest.dart';

typedef _Log = void Function(String message);

/// `web stamp` (ADR 002 D6): updates the hand-written entries of web.json
/// from the package files, adds [add] and removes [remove], then writes
/// web.json and [webRuntimeDartPath]. Creates web.json if needed.
///
/// [add] maps an installed name to a package path.
Future<WebManifest> stampWeb({
  required Uri packageRoot,
  Map<String, String> add = const {},
  Set<String> remove = const {},
  _Log? log,
}) async {
  final previous = await WebManifest.load(packageRoot, checkVersion: false);
  final known = {for (final f in previous?.files ?? <WebFile>[]) f.name: f};
  for (final name in remove) {
    if (known.remove(name) == null) {
      throw StateError('web.json has no file $name.');
    }
  }
  for (final MapEntry(key: name, value: path) in add.entries) {
    validateWebName(name);
    validateWebName(path);
    if (known[name]?.isGenerated ?? false) {
      throw StateError('$name is a generated file.');
    }
    known[name] = WebFile(name: name, sha256: '0' * 64, bytes: 0, source: path);
  }
  final files = [
    for (final file in known.values)
      file.isGenerated
          ? file
          : await handWrittenWebFile(packageRoot, file.name, file.source),
  ];
  final hasGenerated = files.any((f) => f.isGenerated);
  final manifest = WebManifest(
    files: files,
    sourceKey: hasGenerated ? previous?.sourceKey : null,
    release: hasGenerated ? previous?.release : null,
    runner: hasGenerated ? previous?.runner : null,
    toolchain: hasGenerated ? previous?.toolchain : null,
  );
  await manifest.save(packageRoot);
  log?.call(
    'Wrote $webManifestPath (${files.length} files, webVersion '
    '${manifest.webVersion}) and $webRuntimeDartPath',
  );
  return manifest;
}

/// The name for `web stamp --add <spec>`: `name=path`, or a path. A path
/// in `lib/web/` keeps its path below `lib/web/` as name. Other paths use
/// their base name.
MapEntry<String, String> parseWebAdd(String spec) {
  final i = spec.indexOf('=');
  if (i > 0) return MapEntry(spec.substring(0, i), spec.substring(i + 1));
  final path = p.posix.normalize(spec.replaceAll(r'\', '/'));
  return MapEntry(
    path.startsWith('lib/web/')
        ? path.substring('lib/web/'.length)
        : p.posix.basename(path),
    path,
  );
}

/// Gzips the files under [directory] into [staging] as release assets of
/// [tag] (ADR 002 D3), and returns them with the web.json that they make.
/// Hand-written entries of the current web.json are stamped again.
Future<(List<File>, WebManifest)> prepareWebRelease({
  required Uri packageRoot,
  required Directory directory,
  required Directory staging,
  required String sourceKey,
  required String tag,
  required String release,
  required String runner,
  required String toolchain,
  required String Function(String tag, String assetName) assetUrl,
}) async {
  final previous = await WebManifest.load(packageRoot);
  final handWritten = [
    for (final file in previous?.handWritten ?? const <WebFile>[])
      await handWrittenWebFile(packageRoot, file.name, file.source),
  ];
  final generated = await listWebDirectory(directory);
  if (generated.isEmpty) {
    throw StateError('The web directory ${directory.path} is empty.');
  }
  await staging.create(recursive: true);
  final assets = <File>[];
  final entries = <WebFile>[];
  for (final name in generated.keys.toList()..sort()) {
    if (handWritten.any((f) => f.name == name)) {
      throw StateError(
        '$name is a hand-written file and is also in ${directory.path}.',
      );
    }
    final source = generated[name]!;
    final gz = File(p.join(staging.path, webAssetName(name)));
    await source
        .openRead()
        .transform(GZipCodec(level: 9).encoder)
        .pipe(gz.openWrite());
    assets.add(gz);
    entries.add(
      WebFile(
        name: name,
        sha256: await sha256OfFile(source),
        bytes: await source.length(),
        source: webReleaseSource,
        url: assetUrl(tag, webAssetName(name)),
        downloadSha256: await sha256OfFile(gz),
      ),
    );
  }
  return (
    assets,
    WebManifest(
      files: [...handWritten, ...entries],
      sourceKey: sourceKey,
      release: release,
      runner: runner,
      toolchain: toolchain,
    ),
  );
}

/// The local problems of web.json for `kiln:check` (ADR 002
/// I1): the source key, the hand-written files, and the Dart file. Null if
/// the package has no web.json.
Future<List<String>?> checkWebLocal(Uri packageRoot, SourceKey key) async {
  final WebManifest? manifest;
  try {
    manifest = await WebManifest.load(packageRoot);
  } on FormatException catch (error) {
    return [error.message];
  }
  if (manifest == null) return null;
  final problems = <String>[];
  if (manifest.generated.isNotEmpty && manifest.sourceKey != key.key) {
    problems.add(
      'Source key ${key.key} differs from the $webManifestPath key '
      '${manifest.sourceKey}. Run the native release workflow.',
    );
  }
  for (final file in manifest.handWritten) {
    final local = File.fromUri(packageRoot.resolve(file.source));
    if (!await local.exists()) {
      problems.add('web: ${file.source} is missing.');
    } else if (await sha256OfFile(local) != file.sha256) {
      problems.add(
        'web: ${file.source} differs from its entry. Run "dart run '
        'kiln:web stamp".',
      );
    }
  }
  final dart = File.fromUri(packageRoot.resolve(webRuntimeDartPath));
  if (!await dart.exists() ||
      await dart.readAsString() != webRuntimeDart(manifest.webVersion)) {
    problems.add(
      'web: $webRuntimeDartPath does not have webVersion '
      '${manifest.webVersion}. Run "dart run kiln:web stamp".',
    );
  }
  return problems;
}

/// `web install-dev` (ADR 002 D13).
Future<WebFileSet> installDev({
  required Uri packageRoot,
  Directory? from,
  Directory? cacheRoot,
  HttpClient? client,
  _Log? log,
}) async {
  final set = await resolveWebFiles(
    packageRoot: packageRoot,
    manifest: await WebManifest.load(packageRoot),
    mode: from == null ? WebBuildMode.download : WebBuildMode.local,
    localDirectory: from,
    cacheRoot: cacheRoot ?? defaultCacheRoot(),
    client: client,
    log: log,
  );
  await installDevWebFiles(packageRoot, set, log: log);
  return set;
}

/// `web_install` (ADR 002 D9): installs the web files of each dependency
/// of the app at [appRoot] that has web.json, as the hook does. [local]
/// maps a package name to a local build directory. Returns the installed
/// package names.
Future<List<String>> webInstallApp({
  required Directory appRoot,
  Map<String, Directory> local = const {},
  Directory? cacheRoot,
  HttpClient? client,
  _Log? log,
}) async {
  final config = _findPackageConfig(appRoot);
  final json = jsonDecode(await config.readAsString());
  final packages = switch (json) {
    {'packages': final List<Object?> list} => list,
    _ => throw FormatException('${config.path}: no "packages" list.'),
  };
  final cache = cacheRoot ?? defaultCacheRoot();
  final installed = <String>[];
  final unknown = local.keys.toSet();
  for (final package in packages) {
    if (package case {
      'name': final String name,
      'rootUri': final String rootUri,
    }) {
      final root = config.uri.resolve(
        rootUri.endsWith('/') ? rootUri : '$rootUri/',
      );
      final mode = local.containsKey(name)
          ? WebBuildMode.local
          : WebBuildMode.download;
      unknown.remove(name);
      final manifestFile = File.fromUri(root.resolve(webManifestPath));
      if (mode == WebBuildMode.download && !await manifestFile.exists()) {
        continue;
      }
      final set = await resolveWebFiles(
        packageRoot: root,
        manifest: await WebManifest.load(root),
        mode: mode,
        localDirectory: local[name],
        cacheRoot: cache,
        client: client,
        log: log,
      );
      await installWebDirectory(
        appWebDirectory(appRoot, name),
        set.files,
        lockDirectory: Directory(p.join(cache.path, 'locks')),
        log: log,
      );
      installed.add(name);
    }
  }
  if (unknown.isNotEmpty) {
    throw StateError('Not a dependency of the app: ${unknown.join(', ')}.');
  }
  return installed;
}

/// `.dart_tool/package_config.json` of [appRoot] or of the nearest parent
/// that has one (a pub workspace).
File _findPackageConfig(Directory appRoot) {
  var directory = appRoot.absolute;
  while (true) {
    final file = File(
      p.join(directory.path, '.dart_tool', 'package_config.json'),
    );
    if (file.existsSync()) return file;
    if (directory.parent.path == directory.path) {
      throw StateError(
        'No .dart_tool/package_config.json at or above ${appRoot.path}. '
        'Run "flutter pub get".',
      );
    }
    directory = directory.parent;
  }
}
