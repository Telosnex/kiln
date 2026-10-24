import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'defaults.dart';
import 'manifest.dart' show manifestPath;
import 'pinned_sources.dart';

/// Flatpak architectures of the Linux targets.
const flatpakArches = {'linux-arm64': 'aarch64', 'linux-x64': 'x86_64'};

/// Options of [flatpakSources].
final class FlatpakOptions {
  const FlatpakOptions({
    this.fromSource = false,
    this.cacheDest = 'home/.cache/kiln',
    this.cargoVendorDest = 'cargo/vendor',
    this.cargoHomeDest = 'home/.cargo',
    this.buildRoot = '/run/build/app',
  });

  /// Build every package from source (defaults.json with native_build:
  /// source and host_toolchain: true), with its pinned sources. Otherwise
  /// place the prebuilt files.
  final bool fromSource;

  /// The kiln cache, relative to the module's build directory.
  /// The manifest must set HOME so that the hooks use it
  /// (`home/.cache/kiln` with HOME=<build dir>/home).
  final String cacheDest;

  /// The cache of [tool], next to [cacheDest]. A package that still uses
  /// native_prebuilt, the old name of kiln, reads its files from
  /// `home/.cache/native_prebuilt`.
  String cacheDestFor(String tool) => tool == kilnTool
      ? cacheDest
      : p.posix.join(p.posix.dirname(cacheDest), tool);
  final String cargoVendorDest;
  final String cargoHomeDest;

  /// Absolute path of the module's build directory in the build sandbox
  /// (`/run/build/<module>`): Cargo needs an absolute vendor path.
  final String buildRoot;
}

/// The package name of kiln, and its name before 0.1.0.
const kilnTool = 'kiln';
const legacyTool = 'native_prebuilt';

/// A package of the app with prebuilt files.
final class FlatpakPackage {
  FlatpakPackage(this.name, this.root, {this.tool = kilnTool});
  final String name;
  final Directory root;

  /// The tool that the build hook of the package uses: [kilnTool], or
  /// [legacyTool] for a package that has not moved to kiln. It sets the
  /// cache that the hook reads.
  final String tool;
}

/// The tool in the dependencies of the package at [root].
Future<String> _toolOf(Directory root) async {
  final pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!await pubspec.exists()) return kilnTool;
  final yaml = loadYaml(await pubspec.readAsString());
  final dependencies = yaml is Map ? yaml['dependencies'] : null;
  if (dependencies is Map &&
      !dependencies.containsKey(kilnTool) &&
      dependencies.containsKey(legacyTool)) {
    return legacyTool;
  }
  return kilnTool;
}

/// The packages of the app at [app] that have a prebuilt manifest, from its
/// `.dart_tool/package_config.json` (run `pub get` first).
Future<List<FlatpakPackage>> kilnPackages(Directory app) async {
  final configFile = File(
    p.join(app.path, '.dart_tool', 'package_config.json'),
  );
  final config =
      jsonDecode(await configFile.readAsString()) as Map<String, Object?>;
  final base = Uri.directory(p.join(app.absolute.path, '.dart_tool'));
  return [
    for (final package
        in (config['packages'] as List).cast<Map<String, Object?>>())
      if (Directory.fromUri(base.resolve(package['rootUri'] as String))
          case final root
          when File(p.join(root.path, p.fromUri(manifestPath))).existsSync())
        FlatpakPackage(
          package['name'] as String,
          root,
          tool: await _toolOf(root),
        ),
  ];
}

/// Flatpak sources (flatpak-builder JSON) that let the build hooks of
/// [packages] run without network. Messages for the packager go to [log].
Future<List<Map<String, Object?>>> flatpakSources(
  List<FlatpakPackage> packages,
  FlatpakOptions options, {
  void Function(String message)? log,
}) async {
  final sources = <Map<String, Object?>>[];
  final cargoLocks = <File>[];
  for (final package in packages) {
    if (!options.fromSource) {
      sources.addAll(await _prebuiltSources(package, options));
      continue;
    }
    final pinned = await loadPinnedSources(package.root.uri);
    final cargo = await _cargoLocks(package);
    if (pinned.isEmpty && cargo.isEmpty) {
      log?.call(
        '${package.name}: no $sourcesPath. If its source build fetches '
        'anything, add the sources to the manifest by hand.',
      );
    }
    for (final source in pinned) {
      for (final MapEntry(key: target, value: arch) in flatpakArches.entries) {
        if (!source.appliesTo(target)) continue;
        // One entry for both arches when the source applies to both.
        final all = flatpakArches.keys.every(source.appliesTo);
        if (all && arch != flatpakArches.values.first) continue;
        final dest =
            '${options.cacheDestFor(package.tool)}/sources/'
            '${source.cacheDirectoryName}';
        sources.add({
          if (!all) 'only-arches': [arch],
          if (source.isGit) ...{
            'type': 'git',
            'url': source.git,
            'commit': source.commit,
            if (!source.submodules) 'disable-submodules': true,
          } else ...{
            'type': 'file',
            'url': source.url,
            'sha256': source.sha256,
            'dest-filename': source.fileName,
          },
          'dest': dest,
        });
      }
    }
    cargoLocks.addAll(cargo);
  }
  if (cargoLocks.isNotEmpty) {
    sources.addAll(await cargoVendorSources(cargoLocks, options));
  }
  if (options.fromSource) {
    // One defaults.json in the cache of each tool that a package uses.
    final tools = {for (final package in packages) package.tool};
    if (tools.isEmpty) tools.add(kilnTool);
    for (final tool in tools) {
      sources.add({
        'type': 'inline',
        'dest': options.cacheDestFor(tool),
        'dest-filename': defaultsFileName,
        'contents':
            '${jsonEncode({
              'schema': 1,
              'user_defines': {StandardDefines.nativeBuild: 'source', StandardDefines.hostToolchain: true},
            })}\n',
      });
    }
  }
  return sources;
}

/// `cargo_locks` of the package's sources.json: Cargo.lock files whose
/// crates the source build needs.
Future<List<File>> _cargoLocks(FlatpakPackage package) async {
  final file = File(p.join(package.root.path, p.fromUri(sourcesPath)));
  if (!await file.exists()) return const [];
  final json = jsonDecode(await file.readAsString());
  final locks = json is Map ? json['cargo_locks'] : null;
  if (locks == null) return const [];
  if (locks is! List || locks.any((l) => l is! String)) {
    throw FormatException('${file.path}: cargo_locks must be a list of paths');
  }
  return [
    for (final l in locks.cast<String>()) File(p.join(package.root.path, l)),
  ];
}

Future<List<Map<String, Object?>>> _prebuiltSources(
  FlatpakPackage package,
  FlatpakOptions options,
) async {
  final manifest =
      jsonDecode(
            await File(
              p.join(package.root.path, p.fromUri(manifestPath)),
            ).readAsString(),
          )
          as Map<String, Object?>;
  final targets = manifest['targets'] as Map<String, Object?>;
  final cache = options.cacheDestFor(package.tool);
  final sources = <Map<String, Object?>>[];
  for (final MapEntry(key: target, value: arch) in flatpakArches.entries) {
    final entry = targets[target] as Map<String, Object?>?;
    for (final file
        in ((entry?['files'] as List?) ?? const [])
            .cast<Map<String, Object?>>()) {
      if (file['delivery'] == 'runtime') continue;
      final url = file['url'] as String;
      final download = file['downloadSha256'] as String;
      final lower = Uri.parse(url).path.toLowerCase();
      if (file['archiveEntry'] != null) {
        // The hook extracts the entry from <cache>/<downloadSha256>/<name>.
        sources.add({
          'type': 'file',
          'only-arches': [arch],
          'url': url,
          'sha256': download,
          'dest': '$cache/$download',
        });
      } else if (lower.endsWith('.gz')) {
        final sha = file['sha256'] as String;
        final name = file['name'] as String;
        final staged = '.kiln_downloads/$download.gz';
        sources
          ..add({
            'type': 'file',
            'only-arches': [arch],
            'url': url,
            'sha256': download,
            'dest': '.kiln_downloads',
            'dest-filename': '$download.gz',
          })
          ..add({
            'type': 'shell',
            'only-arches': [arch],
            'commands': [
              'mkdir -p $cache/$sha && '
                  'gunzip -c $staged > $cache/$sha/$name',
            ],
          });
      } else {
        sources.add({
          'type': 'file',
          'only-arches': [arch],
          'url': url,
          'sha256': file['sha256'],
          'dest': '$cache/${file['sha256']}',
          'dest-filename': file['name'],
        });
      }
    }
  }
  return sources;
}

/// Vendored crates of [locks] and a Cargo config that uses them, as
/// `cargo vendor` would make them. Registry crates come from crates.io by
/// checksum; git dependencies are checked out at their locked commit (a
/// crate at the repository root only).
Future<List<Map<String, Object?>>> cargoVendorSources(
  List<File> locks,
  FlatpakOptions options,
) async {
  final crates = <String, CargoPackage>{};
  for (final lock in locks) {
    for (final pkg in parseCargoLock(await lock.readAsString())) {
      if (pkg.source != null)
        crates['${pkg.name}-${pkg.version}-${pkg.source}'] = pkg;
    }
  }
  final vendor = options.cargoVendorDest;
  final sources = <Map<String, Object?>>[];
  final gitSections = <String, String>{};
  for (final pkg in crates.values) {
    if (pkg.source == 'registry+https://github.com/rust-lang/crates.io-index') {
      final dir = '$vendor/${pkg.name}-${pkg.version}';
      sources
        ..add({
          'type': 'archive',
          'archive-type': 'tar-gzip',
          'url':
              'https://static.crates.io/crates/${pkg.name}/${pkg.name}-${pkg.version}.crate',
          'sha256': pkg.checksum,
          'dest': dir,
        })
        ..add({
          'type': 'inline',
          'dest': dir,
          'dest-filename': '.cargo-checksum.json',
          'contents': jsonEncode({'package': pkg.checksum, 'files': {}}),
        });
    } else if (pkg.source!.startsWith('git+')) {
      final uri = Uri.parse(pkg.source!.substring(4));
      final commit = uri.fragment;
      final repo = pkg.source!.substring(4).split('#').first.split('?').first;
      final checkout = 'cargo/git/${pkg.name}-${commit.substring(0, 12)}';
      final dir = '$vendor/${pkg.name}-${pkg.version}';
      sources
        ..add({'type': 'git', 'url': repo, 'commit': commit, 'dest': checkout})
        ..add({
          'type': 'shell',
          'commands': [
            'mkdir -p $dir && cp -a $checkout/. $dir/ && rm -rf $dir/.git',
          ],
        })
        ..add({
          'type': 'inline',
          'dest': dir,
          'dest-filename': '.cargo-checksum.json',
          'contents': jsonEncode({'package': null, 'files': {}}),
        });
      final keys = [
        for (final MapEntry(:key, :value) in uri.queryParameters.entries)
          if (const {'branch', 'tag', 'rev'}.contains(key))
            '$key = ${jsonEncode(value)}',
      ];
      gitSections[repo + uri.query] = [
        '[source.${jsonEncode('$repo${uri.query.isEmpty ? '' : '?${uri.query}'}')}]',
        'git = ${jsonEncode(repo)}',
        ...keys,
        'replace-with = "vendored-sources"',
      ].join('\n');
    } else {
      throw FormatException(
        'Cargo source ${pkg.source} of ${pkg.name} is not supported',
      );
    }
  }
  sources.add({
    'type': 'inline',
    'dest': options.cargoHomeDest,
    'dest-filename': 'config.toml',
    'contents': [
      '[source.vendored-sources]',
      'directory = ${jsonEncode('${options.buildRoot}/$vendor')}',
      '',
      '[source.crates-io]',
      'replace-with = "vendored-sources"',
      for (final section in gitSections.values) ...['', section],
      '',
    ].join('\n'),
  });
  return sources;
}

/// A `[[package]]` of a Cargo.lock.
final class CargoPackage {
  CargoPackage(this.name, this.version, this.source, this.checksum);
  final String name;
  final String version;
  final String? source;
  final String? checksum;
}

/// The packages of a Cargo.lock (version 3 or 4). Only the keys used here.
List<CargoPackage> parseCargoLock(String text) {
  final packages = <CargoPackage>[];
  Map<String, String>? current;
  void flush() {
    if (current case final c?) {
      packages.add(
        CargoPackage(c['name']!, c['version']!, c['source'], c['checksum']),
      );
    }
  }

  final keyValue = RegExp(r'^(name|version|source|checksum) = "([^"]*)"$');
  for (final line in const LineSplitter().convert(text)) {
    if (line == '[[package]]') {
      flush();
      current = {};
    } else if (line.startsWith('[')) {
      flush();
      current = null;
    } else if (current != null) {
      if (keyValue.firstMatch(line) case final m?) current[m[1]!] = m[2]!;
    }
  }
  flush();
  return packages;
}
