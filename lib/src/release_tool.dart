import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'fetch.dart';
import 'hashing.dart';
import 'manifest.dart';
import 'publisher.dart';
import 'release_names.dart';
import 'runtime_file.dart';
import 'source_key.dart';
import 'targets.dart';

/// Name of the file that `native_prebuilt:build` writes next to the files
/// of one target.
const targetDescriptionName = 'target.json';

/// Path of the Dart file that `native_prebuilt:runtime_release` writes.
const runtimeDartPath = 'lib/src/native_prebuilt.g.dart';

/// Oldest macOS version of release builds.
const defaultMacOSVersion = 12;

/// Oldest iOS version of release builds.
///
/// Flutter 3.47 passes iOS 13 to every build hook, regardless of the app's
/// deployment target. Its `targetIOSVersion` constant is in
/// `flutter_tools/lib/src/isolated/native_assets/ios/native_assets.dart`.
/// See https://github.com/flutter/flutter/issues/145104.
///
/// The app template uses iOS 15, but a release built for 15 cannot serve a
/// hook request for 13. [compatibilityProblem] then selects a source build
/// in mode auto, or fails in mode download. Release builds use 13 so Flutter
/// can use the prebuilt files. `--ios-version` overrides this default for a
/// package that needs a newer OS.
const defaultIOSVersion = 13;

/// Oldest Android API level of release builds.
const defaultAndroidApi = 24;

typedef Log = void Function(String message);

/// The `name` of the pubspec at [packageRoot].
Future<String> readPackageName(Uri packageRoot) async {
  final pubspec = await File.fromUri(
    packageRoot.resolve('pubspec.yaml'),
  ).readAsString();
  final match = RegExp(
    r'^name:\s*([A-Za-z0-9_]+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) throw StateError('No package name in pubspec.yaml.');
  return match.group(1)!;
}

/// `native_prebuilt:build`: runs the hook of the package at [packageRoot]
/// for [target] with `native_build: source` and `native_release`, and copies
/// its files and a [targetDescriptionName] into [out] (ADR 001 D6).
Future<void> buildTarget({
  required Uri packageRoot,
  required TargetName target,
  required Directory out,
  required String repository,
  required String runner,
  String toolchain = '',
  Map<String, Object> userDefines = const {},
  int macOSVersion = defaultMacOSVersion,
  int iOSVersion = defaultIOSVersion,
  int androidApi = defaultAndroidApi,
  String? dartExecutable,
  Log? log,
}) async {
  final packageName = await readPackageName(packageRoot);
  final before = await computeSourceKey(packageRoot);
  log?.call('Source key ${before.key} (${before.files.length} files)');

  final (input, output) = await runHook(
    packageRoot: packageRoot,
    packageName: packageName,
    target: target,
    defines: {
      ...userDefines,
      'native_build': 'source',
      'native_release': repository,
    },
    macOSVersion: macOSVersion,
    iOSVersion: iOSVersion,
    androidApi: androidApi,
    dartExecutable: dartExecutable,
    log: log,
  );
  final os = target.os;

  final sidecarFile = File.fromUri(
    input.outputDirectory.resolve(releaseSidecarName),
  );
  if (!await sidecarFile.exists()) {
    throw StateError(
      'The hook did not write $releaseSidecarName. It must call '
      'NativePrebuilt.run.',
    );
  }
  final sidecar = jsonDecode(await sidecarFile.readAsString()) as Map;
  if (sidecar['sourceKey'] != before.key) {
    throw StateError(
      'The hook computed source key ${sidecar['sourceKey']}, and this '
      'command computed ${before.key}.',
    );
  }
  final after = await computeSourceKey(packageRoot);
  if (after.key != before.key) {
    throw StateError(
      'The source key changed during the build. The hook must not write '
      'into the package.',
    );
  }

  await out.create(recursive: true);
  final files = <Map<String, Object?>>[];
  Future<void> add(File source, Map<String, Object?> fields) async {
    final name = p.basename(source.path);
    if (files.any((f) => f['name'] == name)) {
      throw StateError('Two files of $target are named $name.');
    }
    final copy = await source.copy(p.join(out.path, name));
    files.add({'name': name, 'sha256': await sha256OfFile(copy), ...fields});
  }

  final prefix = 'package:$packageName/';
  for (final asset in output.assets.code) {
    final file = asset.file;
    if (asset.linkMode is! DynamicLoadingBundled || file == null) {
      throw StateError(
        '${asset.id}: prebuilt files must be bundled dynamic libraries.',
      );
    }
    await add(File.fromUri(file), {
      'delivery': Delivery.bundle.name,
      'asset': asset.id.substring(prefix.length),
    });
  }
  for (final runtime in (sidecar['runtimeFiles'] as List).cast<Map>()) {
    await add(File(runtime['file'] as String), {
      'delivery': Delivery.runtime.name,
      if (runtime['pack'] != null) 'pack': runtime['pack'],
    });
  }

  final description = {
    'schema': 1,
    'package': packageName,
    'target': target.name,
    'sourceKey': before.key,
    'runner': runner,
    'toolchain': toolchain,
    'minOSVersion': ?switch (os) {
      OS.macOS => macOSVersion,
      OS.iOS => iOSVersion,
      OS.android => androidApi,
      _ => null,
    },
    'files': files,
  };
  await File(p.join(out.path, targetDescriptionName)).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(description)}\n',
  );
  log?.call('Wrote ${files.length} files of $target to ${out.path}');
}

/// Runs `hook/build.dart` of the package at [packageRoot] for [target], as a
/// Flutter build does, and checks its output.
Future<(BuildInput, BuildOutput)> runHook({
  required Uri packageRoot,
  required String packageName,
  required TargetName target,
  Map<String, Object> defines = const {},
  int macOSVersion = defaultMacOSVersion,
  int iOSVersion = defaultIOSVersion,
  int androidApi = defaultAndroidApi,
  String? dartExecutable,
  Log? log,
}) async {
  final work = await Directory.systemTemp.createTemp('native_prebuilt_hook_');
  final outShared = work.uri.resolve('out_shared/');
  await Directory.fromUri(outShared).create();
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: packageRoot,
      packageName: packageName,
      outputFile: work.uri.resolve('output.json'),
      outputDirectoryShared: outShared,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: defines,
          basePath: packageRoot,
        ),
      ),
    )
    ..setupBuildInput()
    ..config.setupBuild(linkingEnabled: false);
  final os = target.os;
  final extension = CodeAssetExtension(
    linkModePreference: LinkModePreference.dynamic,
    targetArchitecture: target.architecture,
    targetOS: os,
    macOS: os == OS.macOS ? MacOSCodeConfig(targetVersion: macOSVersion) : null,
    iOS: os == OS.iOS
        ? IOSCodeConfig(targetSdk: target.iosSdk!, targetVersion: iOSVersion)
        : null,
    android: os == OS.android
        ? AndroidCodeConfig(targetNdkApi: androidApi)
        : null,
  );
  try {
    // hooks 2.2 and later: the runner must set a logger first.
    // ignore: avoid_dynamic_calls
    (extension as dynamic).setupLogger(Logger('native_prebuilt'));
  } on NoSuchMethodError {
    // hooks before 2.2 has no setupLogger.
  }
  extension.setupBuildInput(builder);
  final input = builder.build();
  final inputFile = File.fromUri(work.uri.resolve('input.json'));
  await inputFile.writeAsString(jsonEncode(input.json));

  // Like hooks_runner: compile to kernel, then run it. `dart run` would
  // first run the hooks of the package itself and bundle their output.
  final dart = dartExecutable ?? Platform.resolvedExecutable;
  final packageConfig = packageRoot.resolve('.dart_tool/package_config.json');
  if (!await File.fromUri(packageConfig).exists()) {
    throw StateError('Run "dart pub get" or "flutter pub get" in the package.');
  }
  final packages = '--packages=${packageConfig.toFilePath()}';
  final kernel = work.uri.resolve('hook.dill').toFilePath();
  Future<void> step(String what, List<String> arguments) async {
    final process = await Process.start(
      dart,
      arguments,
      workingDirectory: Directory.fromUri(packageRoot).path,
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;
    if (exitCode != 0)
      throw StateError('$what failed with exit code $exitCode.');
  }

  log?.call('Compiling hook/build.dart');
  await step('Compiling the hook', [
    'compile', 'kernel', packages, '--output=$kernel', //
    packageRoot.resolve('hook/build.dart').toFilePath(),
  ]);
  log?.call('Running hook/build.dart for $target');
  await step('The hook', [packages, kernel, '--config=${inputFile.path}']);
  final output = BuildOutput(
    jsonDecode(await File.fromUri(input.outputFile).readAsString())
        as Map<String, Object?>,
  );
  final errors = [
    ...await ProtocolBase.validateBuildOutput(input, output),
    ...await extension.validateBuildOutput(input, output),
  ];
  if (errors.isNotEmpty) {
    throw StateError('The hook output is not valid:\n${errors.join('\n')}');
  }
  return (input, output);
}

/// `native_prebuilt:release`: uploads the targets that `build` wrote under
/// [targetDirectories], and writes the manifest (ADR 001 D6). Without a
/// [publisher], nothing is uploaded.
Future<PrebuiltManifest> releaseTargets({
  required Uri packageRoot,
  required List<Directory> targetDirectories,
  required String repository,
  required Directory staging,
  Publisher? publisher,
  String Function(String tag, String assetName)? assetUrl,
  Log? log,
}) async {
  final packageName = await readPackageName(packageRoot);
  final sourceKey = await computeSourceKey(packageRoot);
  final tag = nativeReleaseTag(sourceKey.key);
  final urlOf =
      assetUrl ?? (tag, asset) => githubAssetUrl(repository, tag, asset);

  final descriptions = <File>[
    for (final directory in targetDirectories)
      ...await directory
          .list(recursive: true)
          .where(
            (e) => e is File && p.basename(e.path) == targetDescriptionName,
          )
          .cast<File>()
          .toList(),
  ];
  if (descriptions.isEmpty) {
    throw StateError('No $targetDescriptionName under $targetDirectories.');
  }

  await staging.create(recursive: true);
  final assets = <File>[];
  final targets = <String, PrebuiltTarget>{};
  for (final descriptionFile in descriptions) {
    final d = jsonDecode(await descriptionFile.readAsString()) as Map;
    final target = TargetName.parse(d['target'] as String).name;
    if (d['package'] != packageName) {
      throw StateError('$descriptionFile is for package ${d['package']}.');
    }
    if (d['sourceKey'] != sourceKey.key) {
      throw StateError(
        '$target was built from source key ${d['sourceKey']}. The package '
        'here has ${sourceKey.key}.',
      );
    }
    if (targets.containsKey(target)) {
      throw StateError('Two builds of $target.');
    }
    final files = <PrebuiltFile>[];
    for (final f in (d['files'] as List).cast<Map>()) {
      final name = f['name'] as String;
      final source = File(p.join(descriptionFile.parent.path, name));
      if (await sha256OfFile(source) != f['sha256']) {
        throw StateError('${source.path} changed after the build.');
      }
      final assetName = nativeAssetName(target, name);
      final gz = File(p.join(staging.path, assetName));
      await source
          .openRead()
          .transform(GZipCodec(level: 9).encoder)
          .pipe(gz.openWrite());
      assets.add(gz);
      files.add(
        PrebuiltFile(
          name: name,
          sha256: f['sha256'] as String,
          url: urlOf(tag, assetName),
          downloadSha256: await sha256OfFile(gz),
          delivery: Delivery.values.byName(f['delivery'] as String),
          asset: f['asset'] as String?,
          pack: f['pack'] as String?,
        ),
      );
    }
    targets[target] = PrebuiltTarget(
      runner: d['runner'] as String,
      toolchain: d['toolchain'] as String,
      minOSVersion: d['minOSVersion'] as int?,
      files: files,
    );
  }

  if (publisher != null) {
    await publisher.publish(
      repository: repository,
      tag: tag,
      assets: assets,
      latest: true,
      notes:
          'Prebuilt native files of $packageName for source key '
          '${sourceKey.key}. Targets: ${(targets.keys.toList()..sort()).join(', ')}.',
    );
  } else {
    log?.call('Dry run: assets are in ${staging.path}');
  }

  final previous = await PrebuiltManifest.load(packageRoot);
  final manifest = PrebuiltManifest(
    sourceKey: sourceKey.key,
    release: githubReleaseUrl(repository, tag),
    targets: targets,
    runtimeFiles: previous?.runtimeFiles,
  );
  await manifest.save(packageRoot);
  log?.call('Wrote $manifestPath for ${targets.length} targets');
  return manifest;
}

final _githubAsset = RegExp(
  r'^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$',
);

/// `native_prebuilt:check` (ADR 001 D10, I4): returns the problems found.
///
/// Checks that the local source key equals the manifest key, and that each
/// URL returns its file. GitHub release assets are checked by the SHA-256
/// that GitHub reports. With [download], every file is downloaded and
/// checked.
Future<List<String>> checkPackage({
  required Uri packageRoot,
  bool download = false,
  HttpClient? client,
  Log? log,
}) async {
  final manifest = await PrebuiltManifest.load(packageRoot);
  if (manifest == null) return ['The package has no $manifestPath.'];
  final problems = <String>[];
  final sourceKey = await computeSourceKey(packageRoot);
  if (sourceKey.key != manifest.sourceKey) {
    problems.add(
      'Source key ${sourceKey.key} differs from the manifest key '
      '${manifest.sourceKey}. Run the native release workflow.',
    );
  }

  final specs = <String, (FetchSpec, String?)>{};
  for (final MapEntry(key: target, value: files) in manifest.targets.entries) {
    for (final file in files.files) {
      specs['$target/${file.name}'] = (file.fetchSpec, file.downloadSha256);
    }
  }
  for (final file in manifest.runtimeFiles?.files ?? const <RuntimeFile>[]) {
    specs['runtime/${file.name}'] = (
      FetchSpec(
        url: file.url,
        sha256: file.sha256,
        downloadSha256: file.downloadSha256,
        archiveEntry: file.archiveEntry,
      ),
      file.downloadSha256,
    );
  }

  final http = client ?? HttpClient();
  final releases = <String, Map<String, String>?>{};
  try {
    for (final MapEntry(key: label, value: (spec, downloadSha256))
        in specs.entries) {
      if (_githubAsset.firstMatch(spec.url) case final match?) {
        final repo = match.group(1)!, tag = match.group(2)!;
        final asset = Uri.decodeComponent(match.group(3)!);
        final digests = releases['$repo/$tag'] ??= await _githubDigests(
          http,
          repo,
          tag,
        );
        final digest = digests?[asset];
        if (digests == null) {
          problems.add('$label: release $tag of $repo is not published.');
        } else if (digest == null) {
          problems.add('$label: release $tag has no asset $asset.');
        } else if (downloadSha256 != null && digest != downloadSha256) {
          problems.add(
            '$label: $asset has SHA-256 $digest, not $downloadSha256.',
          );
        }
      } else {
        final status = await _headStatus(http, spec.url);
        if (status != HttpStatus.ok) {
          problems.add('$label: ${spec.url} returned HTTP $status.');
        }
      }
    }
    if (download) {
      final temporary = await Directory.systemTemp.createTemp('native_check_');
      try {
        var i = 0;
        for (final MapEntry(key: label, value: (spec, _)) in specs.entries) {
          log?.call('Downloading $label');
          try {
            await fetchVerified(
              spec,
              File(p.join(temporary.path, '${i++}')),
              client: http,
            );
          } on Object catch (error) {
            problems.add('$label: $error');
          }
        }
      } finally {
        await temporary.delete(recursive: true);
      }
    }
  } finally {
    if (client == null) http.close(force: true);
  }
  return problems;
}

Future<Map<String, String>?> _githubDigests(
  HttpClient http,
  String repository,
  String tag,
) async {
  final request = await http.getUrl(
    Uri.https('api.github.com', '/repos/$repository/releases/tags/$tag'),
  );
  request.headers
    ..set(HttpHeaders.userAgentHeader, 'native_prebuilt/1')
    ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  final token =
      Platform.environment['GITHUB_TOKEN'] ?? Platform.environment['GH_TOKEN'];
  if (token != null && token.isNotEmpty) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode == HttpStatus.notFound) return null;
  if (response.statusCode != HttpStatus.ok) {
    throw StateError(
      'GitHub API returned HTTP ${response.statusCode} for $repository '
      'release $tag: $body',
    );
  }
  final release = jsonDecode(body);
  if (release case {'draft': true}) return null;
  return assetDigestsOf(release);
}

Future<int> _headStatus(HttpClient http, String url) async {
  final request = await http.headUrl(Uri.parse(url));
  request.headers.set(HttpHeaders.userAgentHeader, 'native_prebuilt/1');
  final response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

/// `native_prebuilt:runtime_release` (ADR 001 D12): uploads [files] as the
/// complete set of runtime files, then writes the `runtimeFiles` section and
/// [runtimeDartPath]. A published release of the same set is reused.
Future<RuntimeFileSet> runtimeRelease({
  required Uri packageRoot,
  required List<File> files,
  required String repository,
  required Directory staging,
  Publisher? publisher,
  String Function(String tag, String assetName)? assetUrl,
  Log? log,
}) async {
  final entries = <(File, String, int)>[];
  for (final file in files) {
    validateFileName(p.basename(file.path));
    entries.add((file, await sha256OfFile(file), await file.length()));
  }
  entries.sort(
    (a, b) => p.basename(a.$1.path).compareTo(p.basename(b.$1.path)),
  );
  final names = entries.map((e) => p.basename(e.$1.path)).toList();
  if (names.toSet().length != names.length) {
    throw StateError('Runtime file names must be unique: $names');
  }
  final setKey = sha256OfString(
    [
      for (final (file, digest, _) in entries)
        '${p.basename(file.path)}\t$digest\n',
    ].join(),
  );
  final tag = runtimeReleaseTag(setKey);
  final urlOf =
      assetUrl ?? (tag, asset) => githubAssetUrl(repository, tag, asset);

  final published = await publisher?.publishedAssetDigests(
    repository: repository,
    tag: tag,
  );
  final downloadDigests = <String, String>{};
  if (published != null) {
    log?.call('Release $tag exists; reusing its assets');
    for (final name in names) {
      downloadDigests[name] =
          published['$name.gz'] ??
          (throw StateError('Release $tag has no asset $name.gz.'));
    }
  } else {
    await staging.create(recursive: true);
    final assets = <File>[];
    for (final (file, _, _) in entries) {
      final name = p.basename(file.path);
      final gz = File(p.join(staging.path, '$name.gz'));
      await file
          .openRead()
          .transform(GZipCodec(level: 9).encoder)
          .pipe(gz.openWrite());
      assets.add(gz);
      downloadDigests[name] = await sha256OfFile(gz);
    }
    if (publisher != null) {
      await publisher.publish(
        repository: repository,
        tag: tag,
        assets: assets,
        latest: false,
        notes: 'Runtime files: ${names.join(', ')}.',
      );
    } else {
      log?.call('Dry run: assets are in ${staging.path}');
    }
  }

  final set = RuntimeFileSet(
    release: githubReleaseUrl(repository, tag),
    files: [
      for (final (file, digest, bytes) in entries)
        RuntimeFile(
          name: p.basename(file.path),
          sha256: digest,
          bytes: bytes,
          url: urlOf(tag, '${p.basename(file.path)}.gz'),
          downloadSha256: downloadDigests[p.basename(file.path)],
        ),
    ],
  );
  final previous = await PrebuiltManifest.load(packageRoot);
  await PrebuiltManifest(
    sourceKey: previous?.sourceKey ?? (await computeSourceKey(packageRoot)).key,
    release: previous?.release,
    targets: previous?.targets ?? const {},
    runtimeFiles: set,
  ).save(packageRoot);
  final dart = File.fromUri(packageRoot.resolve(runtimeDartPath));
  await dart.parent.create(recursive: true);
  await dart.writeAsString(runtimeFilesDart(set));
  log?.call(
    'Wrote runtimeFiles and $runtimeDartPath for ${names.length} files',
  );
  return set;
}

/// The Dart source of [runtimeDartPath].
String runtimeFilesDart(RuntimeFileSet set) {
  String literal(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";
  final buffer = StringBuffer()
    ..writeln('// Generated by native_prebuilt:runtime_release. Do not edit.')
    ..writeln('// Release: ${set.release}')
    ..writeln()
    ..writeln("import 'package:native_prebuilt/runtime.dart';")
    ..writeln()
    ..writeln('/// Runtime files of this package, by file name.')
    ..writeln('const nativePrebuiltRuntimeFiles = <String, RuntimeFile>{');
  for (final file in set.files) {
    buffer
      ..writeln('  ${literal(file.name)}: RuntimeFile(')
      ..writeln('    name: ${literal(file.name)},')
      ..writeln('    sha256: ${literal(file.sha256)},')
      ..writeln('    bytes: ${file.bytes},')
      ..writeln('    url: ${literal(file.url)},');
    if (file.downloadSha256 != null) {
      buffer.writeln('    downloadSha256: ${literal(file.downloadSha256!)},');
    }
    buffer.writeln('  ),');
  }
  buffer.writeln('};');
  return buffer.toString();
}
