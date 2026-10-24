import 'dart:convert';
import 'dart:io';

import 'fetch.dart';
import 'hashing.dart';
import 'runtime_file.dart';

/// Path of the web manifest, relative to the package root (ADR 002 D6).
const webManifestPath = 'native_artifacts/web.json';

/// Path of the generated Dart file with [WebManifest.webVersion] (ADR 002
/// D7).
const webRuntimeDartPath = 'lib/src/web_runtime.g.dart';

/// The `source` value of a generated file.
const webReleaseSource = 'release';

/// Release asset name of the generated web file [name] (ADR 002 §5).
String webAssetName(String name) => 'web-${name.replaceAll('/', '__')}.gz';

/// Throws if [name] is not a relative path with `/` and plain segments.
void validateWebName(String name) {
  final segments = name.split('/');
  if (name.isEmpty ||
      name.contains(r'\') ||
      segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw FormatException('"$name" is not a relative path of plain names.');
  }
}

/// One file in web.json.
final class WebFile {
  const WebFile({
    required this.name,
    required this.sha256,
    required this.bytes,
    required this.source,
    this.url,
    this.downloadSha256,
  });

  factory WebFile.fromJson(Object? json, String where) {
    if (json is! Map<String, Object?>) {
      throw FormatException('$where must be an object.');
    }
    String text(String key) => switch (json[key]) {
      final String value => value,
      _ => throw FormatException('$where: "$key" must be a string.'),
    };
    String? optional(String key) => switch (json[key]) {
      null => null,
      final String value => value,
      _ => throw FormatException('$where: "$key" must be a string.'),
    };
    final file = WebFile(
      name: text('name'),
      sha256: text('sha256'),
      bytes: switch (json['bytes']) {
        final int value when value >= 0 => value,
        _ => throw FormatException('$where: "bytes" must be an int >= 0.'),
      },
      source: text('source'),
      url: optional('url'),
      downloadSha256: optional('downloadSha256'),
    );
    file._validate(where);
    return file;
  }

  /// Path under `web/kiln/<package>/`, with `/`.
  final String name;

  /// SHA-256 of the installed file.
  final String sha256;
  final int bytes;

  /// [webReleaseSource] for a generated file, or the path of a hand-written
  /// file in the package, with `/`.
  final String source;

  /// Download URL of a generated file: a gzip file.
  final String? url;

  /// SHA-256 of the bytes at [url].
  final String? downloadSha256;

  bool get isGenerated => source == webReleaseSource;

  FetchSpec get fetchSpec =>
      FetchSpec(url: url!, sha256: sha256, downloadSha256: downloadSha256);

  void _validate(String where) {
    try {
      validateWebName(name);
      if (!isGenerated) validateWebName(source);
    } on FormatException catch (error) {
      throw FormatException('$where: ${error.message}');
    }
    if (!isSha256Hex(sha256)) {
      throw FormatException('$where: sha256 must be a SHA-256 hex digest.');
    }
    if (isGenerated) {
      final download = downloadSha256;
      if (url == null || !isAllowedUrl(url!)) {
        throw FormatException('$where: a generated file needs an https url.');
      }
      if (download == null || !isSha256Hex(download)) {
        throw FormatException('$where: a generated file needs downloadSha256.');
      }
    } else if (url != null || downloadSha256 != null) {
      throw FormatException(
        '$where: a hand-written file has no url and no downloadSha256.',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'bytes': bytes,
    'source': source,
    if (url != null) 'url': url,
    if (downloadSha256 != null) 'downloadSha256': downloadSha256,
  };
}

/// The webVersion of files with these names and SHA-256 values (ADR 002
/// §5).
String webVersionOf(Iterable<({String name, String sha256})> files) {
  final sorted = files.toList()..sort((a, b) => a.name.compareTo(b.name));
  return sha256OfString(
    sorted.map((f) => '${f.name}\t${f.sha256}\n').join(),
  ).substring(0, 16);
}

/// `native_artifacts/web.json` (ADR 002 §5).
///
/// [sourceKey], [release], [runner] and [toolchain] are set if and only if
/// a file is generated. Before the first web release, web.json can list
/// hand-written files only.
final class WebManifest {
  WebManifest({
    required List<WebFile> files,
    this.sourceKey,
    this.release,
    this.runner,
    this.toolchain,
  }) : files = List.unmodifiable(
         files.toList()..sort((a, b) => a.name.compareTo(b.name)),
       ) {
    final names = this.files.map((f) => f.name).toSet();
    if (names.length != this.files.length) {
      throw const FormatException('web.json: file names must be unique.');
    }
    for (final name in names) {
      if (names.any((other) => other.startsWith('$name/'))) {
        throw FormatException('web.json: "$name" is a file and a directory.');
      }
    }
    final key = sourceKey;
    if (key != null && !isSha256Hex(key)) {
      throw const FormatException('web.json: sourceKey must be a SHA-256.');
    }
    final hasGenerated = this.files.any((f) => f.isGenerated);
    final hasRelease = [
      sourceKey,
      release,
      runner,
      toolchain,
    ].every((v) => v != null);
    final hasNone = [
      sourceKey,
      release,
      runner,
      toolchain,
    ].every((v) => v == null);
    if (hasGenerated ? !hasRelease : !hasNone) {
      throw const FormatException(
        'web.json: sourceKey, release, runner and toolchain are required '
        'with generated files, and only then.',
      );
    }
  }

  /// With [checkVersion] false, a stale webVersion is accepted: for
  /// `web stamp`, which writes it again.
  factory WebManifest.fromJson(Object? json, {bool checkVersion = true}) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('web.json must be a JSON object.');
    }
    if (json['schema'] != 1) {
      throw FormatException('Unsupported web.json schema: ${json['schema']}.');
    }
    String? optional(String key) => switch (json[key]) {
      null => null,
      final String value => value,
      _ => throw FormatException('web.json: "$key" must be a string.'),
    };
    final files = json['files'];
    if (files is! List<Object?>) {
      throw const FormatException('web.json: "files" must be a list.');
    }
    final manifest = WebManifest(
      sourceKey: optional('sourceKey'),
      release: optional('release'),
      runner: optional('runner'),
      toolchain: optional('toolchain'),
      files: [
        for (var i = 0; i < files.length; i++)
          WebFile.fromJson(files[i], 'web.json files[$i]'),
      ],
    );
    if (checkVersion && json['webVersion'] != manifest.webVersion) {
      throw FormatException(
        'web.json: webVersion ${json['webVersion']} does not match its '
        'files (${manifest.webVersion}). Run "dart run kiln:web '
        'stamp".',
      );
    }
    return manifest;
  }

  /// Reads the web manifest of the package at [packageRoot], or null if the
  /// package has none.
  static Future<WebManifest?> load(
    Uri packageRoot, {
    bool checkVersion = true,
  }) async {
    final file = File.fromUri(packageRoot.resolve(webManifestPath));
    if (!await file.exists()) return null;
    try {
      return WebManifest.fromJson(
        jsonDecode(await file.readAsString()),
        checkVersion: checkVersion,
      );
    } on FormatException catch (error) {
      throw FormatException('${file.path}: ${error.message}');
    }
  }

  final String? sourceKey;

  /// URL of the GitHub release page.
  final String? release;
  final String? runner;
  final String? toolchain;

  /// Sorted by name.
  final List<WebFile> files;

  Iterable<WebFile> get generated => files.where((f) => f.isGenerated);
  Iterable<WebFile> get handWritten => files.where((f) => !f.isGenerated);

  String get webVersion =>
      webVersionOf(files.map((f) => (name: f.name, sha256: f.sha256)));

  Map<String, Object?> toJson() => {
    'schema': 1,
    if (sourceKey != null) 'sourceKey': sourceKey,
    if (release != null) 'release': release,
    if (runner != null) 'runner': runner,
    if (toolchain != null) 'toolchain': toolchain,
    'webVersion': webVersion,
    'files': [for (final file in files) file.toJson()],
  };

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Writes web.json and [webRuntimeDartPath].
  Future<void> save(Uri packageRoot) async {
    final file = File.fromUri(packageRoot.resolve(webManifestPath));
    await file.parent.create(recursive: true);
    await file.writeAsString(encode());
    final dart = File.fromUri(packageRoot.resolve(webRuntimeDartPath));
    await dart.parent.create(recursive: true);
    await dart.writeAsString(webRuntimeDart(webVersion));
  }
}

/// The Dart source of [webRuntimeDartPath].
String webRuntimeDart(String webVersion) =>
    '''
// Generated by kiln from $webManifestPath. Do not edit.

/// Version of the web runtime files of this package (kiln
/// ADR 002 D7). Load each file with the query `?v=\$webRuntimeVersion`.
const webRuntimeVersion = '$webVersion';
''';

/// The hand-written entry for the package file at [path], named [name].
Future<WebFile> handWrittenWebFile(
  Uri packageRoot,
  String name,
  String path,
) async {
  final file = File.fromUri(packageRoot.resolve(path));
  if (!await file.exists()) {
    throw StateError('Hand-written web file $path does not exist.');
  }
  return WebFile(
    name: name,
    sha256: await sha256OfFile(file),
    bytes: await file.length(),
    source: path,
  );
}
