import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import 'cache.dart';
import 'fetch.dart';
import 'manifest.dart';
import 'defaults.dart';
import 'mode.dart';
import 'pinned_sources.dart';
import 'release_names.dart';
import 'source_key.dart';
import 'targets.dart';
import 'web_install.dart';
import 'web_manifest.dart';

/// Information for a source build that makes release files
/// (`native_release`, ADR 001 D7).
final class PrebuiltRelease {
  PrebuiltRelease._({
    required this.repository,
    required this.sourceKey,
    required this.target,
  });

  /// GitHub repository, `owner/name`.
  final String repository;
  final String sourceKey;
  final TargetName target;
  final List<Map<String, Object?>> _runtimeFiles = [];

  String get tag => nativeReleaseTag(sourceKey);

  /// The URL that file [fileName] of this target will have. A library can
  /// contain the URLs of its runtime files (fllama ADR 004 D13).
  String assetUrl(String fileName) =>
      githubAssetUrl(repository, tag, nativeAssetName(target.name, fileName));

  /// Adds a file that apps download after install. The hook must not also
  /// publish it as a code asset.
  void addRuntimeFile(Uri file, {String? pack}) =>
      _runtimeFiles.add({'file': file.toFilePath(), 'pack': ?pack});
}

/// What a source build gets from [Prebuilt.run].
final class SourceBuild {
  SourceBuild._({
    required this.sourceKey,
    required this.reason,
    required this.release,
    required Object? Function(String name) define,
    required List<PinnedSource> pinnedSources,
    required String target,
    required Future<Directory> Function(PinnedSource source) resolve,
  }) : _define = define,
       _pinned = pinnedSources,
       _target = target,
       _resolve = resolve;

  final Object? Function(String name) _define;
  final List<PinnedSource> _pinned;
  final String _target;
  final Future<Directory> Function(PinnedSource source) _resolve;

  /// The user define [name] of the package, else its default from
  /// `<cache root>/defaults.json`.
  Object? define(String name) => _define(name);

  /// User define `host_toolchain`: use the tools on PATH, download nothing.
  bool get hostToolchain => define(StandardDefines.hostToolchain) == true;

  /// The pinned sources of `native_artifacts/sources.json` for this target.
  List<PinnedSource> get pinnedSources => [
    for (final s in _pinned)
      if (s.appliesTo(_target)) s,
  ];

  /// The directory of pinned source [name]: a checkout of a git source, or
  /// the directory that holds the file of a URL source. From
  /// `<cache root>/sources/` if a packager put it there; otherwise fetched,
  /// unless [hostToolchain] is set.
  Future<Directory> pinnedSource(String name) {
    final source = pinnedSources.where((s) => s.name == name).firstOrNull;
    if (source == null) {
      throw StateError(
        'No pinned source "$name" for $_target in $sourcesPath.',
      );
    }
    return _resolve(source);
  }

  /// The source key of the package. A local build cache can use it in its
  /// own key (ADR 001 D4).
  final SourceKey sourceKey;

  /// Why the hook builds from source.
  final String reason;

  /// Non-null when the build makes release files (`native_release`).
  final PrebuiltRelease? release;
}

/// Runs ADR 001 D2 in a build hook: publish prebuilt files, or run the
/// package's source build. For a web build, [installWeb] installs the web
/// runtime files of the package (ADR 002).
///
/// ```dart
/// await build(args, (input, output) async {
///   final prebuilt = Prebuilt(input: input, output: output);
///   if (!input.config.buildCodeAssets) return prebuilt.installWeb();
///   await prebuilt.run((source) => buildFromSource(input, output, source));
/// });
/// ```
final class Prebuilt {
  Prebuilt({
    required this.input,
    required this.output,
    this.log,
    Directory? cacheRoot,
    this.httpClient,
  }) : cacheRoot =
           cacheRoot ??
           switch (input.userDefines.path('prebuilt_cache')) {
             final Uri path => Directory.fromUri(path),
             null => defaultCacheRoot(),
           };

  final BuildInput input;
  final BuildOutputBuilder output;

  final void Function(String message)? log;

  /// The shared cache (ADR 001 D9). The user define `prebuilt_cache`
  /// (a path relative to the pubspec) changes it.
  final Directory cacheRoot;
  final HttpClient? httpClient;

  /// Publishes the prebuilt files, or calls [sourceBuild].
  ///
  /// [sourceBuild] adds the code assets of the package to [output].
  Future<void> run(
    Future<void> Function(SourceBuild source) sourceBuild,
  ) async {
    final code = input.config.code;
    final target = TargetName.of(code);
    final stopwatch = Stopwatch()..start();
    final sourceKey = await computeSourceKey(
      input.packageRoot,
      memoDirectory: Directory(p.join(cacheRoot.path, 'source_keys')),
    );
    output.dependencies.addAll(sourceKey.files.map((f) => f.uri));
    final manifestFile = File.fromUri(input.packageRoot.resolve(manifestPath));
    if (await manifestFile.exists()) output.dependencies.add(manifestFile.uri);
    log?.call(
      'Source key ${sourceKey.short} (${sourceKey.files.length} files, '
      '${stopwatch.elapsedMilliseconds}ms)',
    );

    final defaults = await UserDefineDefaults.load(cacheRoot);
    if (defaults.file case final file?) output.dependencies.add(file.uri);
    Object? define(String name) =>
        input.userDefines[name] ?? defaults.values[name];
    final mode = NativeBuildMode.parse(define(StandardDefines.nativeBuild));
    final repository = parseReleaseRepository(
      input.userDefines['native_release'],
    );
    final manifest = await PrebuiltManifest.load(input.packageRoot);
    final prebuilt = manifest?.targets[target.name];
    final problem = switch (manifest) {
      null => 'the package has no $manifestPath',
      _ when manifest.sourceKey != sourceKey.key =>
        'the package sources differ from the sources of the prebuilt files '
            '(local source key ${sourceKey.short}, manifest '
            '${manifest.sourceKey.substring(0, 16)})',
      _ when prebuilt == null => 'the manifest has no files for $target',
      _ => compatibilityProblem(code, prebuilt.minOSVersion),
    };

    switch (decideBuild(
      mode: mode,
      releaseRepository: repository,
      prebuiltProblem: problem,
    )) {
      case FailBuild(:final message):
        throw StateError('${input.packageName}: $message');
      case UsePrebuilt():
        await _publishPrebuilt(prebuilt!);
      case BuildFromSource(:final reason, :final requested):
        log?.call('Building from source: $reason');
        final release = repository == null
            ? null
            : PrebuiltRelease._(
                repository: repository,
                sourceKey: sourceKey.key,
                target: target,
              );
        try {
          await sourceBuild(
            SourceBuild._(
              sourceKey: sourceKey,
              reason: reason,
              release: release,
              define: define,
              pinnedSources: await loadPinnedSources(input.packageRoot),
              target: target.name,
              resolve: (source) => resolvePinnedSource(
                source,
                cacheRoot: cacheRoot,
                offline: define(StandardDefines.hostToolchain) == true,
                client: httpClient,
                log: log,
              ),
            ),
          );
        } on Object {
          if (!requested) {
            log?.call(
              'The source build failed. Prebuilt files were not used because '
              '$reason. To get prebuilt files for these sources, run the '
              'native release workflow of ${input.packageName}.',
            );
          }
          rethrow;
        }
        if (release != null) await _writeSidecar(release);
    }
  }

  /// Installs the web runtime files of the package into
  /// `<app>/web/prebuilt/<package>/` (ADR 002 D1, D2, D4).
  ///
  /// Does nothing if the build requests code assets, or if the package has
  /// no web.json and the user define web_build is not local. The user
  /// defines web_build, web_build_dir and web_root control it.
  Future<void> installWeb() async {
    if (input.config.buildCodeAssets) return;
    final mode = WebBuildMode.parse(input.userDefines['web_build']);
    final manifestFile = File.fromUri(
      input.packageRoot.resolve(webManifestPath),
    );
    if (mode == WebBuildMode.download && !await manifestFile.exists()) {
      return;
    }
    final localPath = input.userDefines.path('web_build_dir');
    final set = await resolveWebFiles(
      packageRoot: input.packageRoot,
      manifest: await WebManifest.load(input.packageRoot),
      mode: mode,
      cacheRoot: cacheRoot,
      localDirectory: localPath == null ? null : Directory.fromUri(localPath),
      client: httpClient,
      log: log,
    );
    final appRoot = switch (input.userDefines.path('web_root')) {
      final Uri path => Directory.fromUri(path),
      null => findAppRoot(input.outputDirectoryShared),
    };
    final installed = await installWebDirectory(
      appWebDirectory(appRoot, input.packageName),
      set.files,
      lockDirectory: Directory(p.join(cacheRoot.path, 'locks')),
      log: log,
    );
    output.dependencies
      ..addAll(set.dependencies)
      ..addAll(installed.map((f) => f.uri));
  }

  Future<void> _publishPrebuilt(PrebuiltTarget prebuilt) async {
    final outputDirectory = Directory.fromUri(input.outputDirectory);
    await outputDirectory.create(recursive: true);
    final http = httpClient ?? HttpClient();
    try {
      for (final file in prebuilt.files) {
        if (file.delivery == Delivery.runtime) continue;
        final cached = await _cached(file, http);
        final published = File(p.join(outputDirectory.path, file.name));
        await cached.copy(published.path);
        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: file.asset!,
            linkMode: DynamicLoadingBundled(),
            file: published.uri,
          ),
        );
        log?.call('Published prebuilt ${file.name}');
      }
    } finally {
      if (httpClient == null) http.close(force: true);
    }
  }

  /// Returns the cache entry for [file], after a check of its SHA-256
  /// (ADR 001 D9, I1).
  Future<File> _cached(PrebuiltFile file, HttpClient http) => fetchVerified(
    file.fetchSpec,
    File(p.join(cacheRoot.path, file.sha256, file.name)),
    client: http,
    archiveCache: cacheRoot,
    log: log,
  );

  Future<void> _writeSidecar(PrebuiltRelease release) async {
    final sidecar = File.fromUri(
      input.outputDirectory.resolve(releaseSidecarName),
    );
    await sidecar.writeAsString(
      jsonEncode({
        'schema': 1,
        'repository': release.repository,
        'sourceKey': release.sourceKey,
        'target': release.target.name,
        'runtimeFiles': release._runtimeFiles,
      }),
    );
  }
}
