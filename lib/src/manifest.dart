import 'dart:convert';
import 'dart:io';

import 'fetch.dart';
import 'hashing.dart';
import 'runtime_file.dart';
import 'targets.dart';

/// Path of the manifest, relative to the package root.
const manifestPath = 'native_artifacts/prebuilt.json';

/// How an app gets a prebuilt file.
enum Delivery {
  /// A code asset inside the app.
  bundle,

  /// The app downloads the file after install (fllama ADR 004 D14).
  runtime,
}

/// One file of one target in `prebuilt.json`.
final class PrebuiltFile {
  const PrebuiltFile({
    required this.name,
    required this.sha256,
    required this.url,
    required this.downloadSha256,
    required this.delivery,
    this.asset,
    this.pack,
    this.archiveEntry,
  });

  factory PrebuiltFile.fromJson(Object? json, String where) {
    if (json is! Map<String, Object?>) {
      throw FormatException('$where must be an object.');
    }
    final reader = _Reader(json, where);
    final file = PrebuiltFile(
      name: reader.string('name'),
      sha256: reader.string('sha256'),
      url: reader.string('url'),
      downloadSha256: reader.string('downloadSha256'),
      delivery: switch (reader.string('delivery')) {
        'bundle' => Delivery.bundle,
        'runtime' => Delivery.runtime,
        final other => throw FormatException(
          '$where: unknown delivery "$other".',
        ),
      },
      asset: reader.optionalString('asset'),
      pack: reader.optionalString('pack'),
      archiveEntry: reader.optionalString('archiveEntry'),
    );
    file._validate(where);
    return file;
  }

  /// File name in the hook output and on disk.
  final String name;

  /// SHA-256 of the file after gunzip or extraction.
  final String sha256;
  final String url;

  /// SHA-256 of the bytes at [url].
  final String downloadSha256;
  final Delivery delivery;

  /// Code asset name, without `package:<package>/` (bundle files only).
  final String? asset;

  /// GPU pack name (runtime files only).
  final String? pack;
  final String? archiveEntry;

  FetchSpec get fetchSpec => FetchSpec(
    url: url,
    sha256: sha256,
    downloadSha256: downloadSha256,
    archiveEntry: archiveEntry,
  );

  void _validate(String where) {
    validateFileName(name);
    if (!isSha256Hex(sha256) || !isSha256Hex(downloadSha256)) {
      throw FormatException(
        '$where: sha256 values must be SHA-256 hex digests.',
      );
    }
    if (!isAllowedUrl(url)) {
      throw FormatException('$where: url must use https.');
    }
    if (delivery == Delivery.bundle && (asset == null || pack != null)) {
      throw FormatException(
        '$where: a bundle file needs "asset" and no "pack".',
      );
    }
    if (delivery == Delivery.runtime && asset != null) {
      throw FormatException('$where: a runtime file has no "asset".');
    }
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'url': url,
    'downloadSha256': downloadSha256,
    if (archiveEntry != null) 'archiveEntry': archiveEntry,
    'delivery': delivery.name,
    if (asset != null) 'asset': asset,
    if (pack != null) 'pack': pack,
  };
}

/// The prebuilt files of one target.
final class PrebuiltTarget {
  const PrebuiltTarget({
    required this.runner,
    required this.toolchain,
    required this.files,
    this.minOSVersion,
  });

  factory PrebuiltTarget.fromJson(Object? json, String where) {
    if (json is! Map<String, Object?>) {
      throw FormatException('$where must be an object.');
    }
    final reader = _Reader(json, where);
    final files = json['files'];
    if (files is! List<Object?> || files.isEmpty) {
      throw FormatException('$where: "files" must be a non-empty list.');
    }
    final target = PrebuiltTarget(
      runner: reader.string('runner'),
      toolchain: reader.string('toolchain'),
      minOSVersion: switch (json['minOSVersion']) {
        null => null,
        final int value => value,
        _ => throw FormatException('$where: "minOSVersion" must be an int.'),
      },
      files: [
        for (var i = 0; i < files.length; i++)
          PrebuiltFile.fromJson(files[i], '$where.files[$i]'),
      ],
    );
    final names = target.files.map((f) => f.name).toSet();
    if (names.length != target.files.length) {
      throw FormatException('$where: file names must be unique.');
    }
    return target;
  }

  /// The GitHub runner image that built the files.
  final String runner;

  /// Free text: compiler and SDK versions.
  final String toolchain;

  /// Oldest OS version the files support: iOS and macOS major version, or
  /// Android API level. Null for Linux and Windows.
  final int? minOSVersion;
  final List<PrebuiltFile> files;

  Map<String, Object?> toJson() => {
    'runner': runner,
    'toolchain': toolchain,
    if (minOSVersion != null) 'minOSVersion': minOSVersion,
    'files': [for (final file in files) file.toJson()],
  };
}

/// The `runtimeFiles` section (ADR 001 D12).
final class RuntimeFileSet {
  const RuntimeFileSet({required this.release, required this.files});

  factory RuntimeFileSet.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('runtimeFiles must be an object.');
    }
    final files = json['files'];
    if (files is! List<Object?>) {
      throw const FormatException('runtimeFiles.files must be a list.');
    }
    return RuntimeFileSet(
      release: _Reader(json, 'runtimeFiles').string('release'),
      files: [
        for (final file in files)
          if (file is Map<String, Object?>)
            RuntimeFile.fromJson(file)
          else
            throw const FormatException('runtimeFiles.files: invalid entry.'),
      ],
    );
  }

  final String release;
  final List<RuntimeFile> files;

  Map<String, Object?> toJson() => {
    'release': release,
    'files': [for (final file in files) file.toJson()],
  };
}

/// `native_artifacts/prebuilt.json` (ADR 001 §5).
final class PrebuiltManifest {
  const PrebuiltManifest({
    required this.sourceKey,
    required this.release,
    required this.targets,
    this.runtimeFiles,
  });

  factory PrebuiltManifest.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('The manifest must be a JSON object.');
    }
    if (json['schema'] != 1) {
      throw FormatException('Unsupported manifest schema: ${json['schema']}.');
    }
    final reader = _Reader(json, 'manifest');
    final sourceKey = reader.string('sourceKey');
    if (!isSha256Hex(sourceKey)) {
      throw const FormatException('sourceKey must be a SHA-256 hex digest.');
    }
    final targets = json['targets'];
    if (targets is! Map<String, Object?>) {
      throw const FormatException('"targets" must be an object.');
    }
    return PrebuiltManifest(
      sourceKey: sourceKey,
      release: reader.optionalString('release'),
      targets: {
        for (final MapEntry(:key, :value) in targets.entries)
          TargetName.parse(key).name: PrebuiltTarget.fromJson(
            value,
            'targets.$key',
          ),
      },
      runtimeFiles: json['runtimeFiles'] == null
          ? null
          : RuntimeFileSet.fromJson(json['runtimeFiles']),
    );
  }

  /// Reads the manifest of the package at [packageRoot], or null if the
  /// package has none.
  static Future<PrebuiltManifest?> load(Uri packageRoot) async {
    final file = File.fromUri(packageRoot.resolve(manifestPath));
    if (!await file.exists()) return null;
    try {
      return PrebuiltManifest.fromJson(jsonDecode(await file.readAsString()));
    } on FormatException catch (error) {
      throw FormatException('${file.path}: ${error.message}');
    }
  }

  final String sourceKey;

  /// URL of the GitHub release page. Null if no target has files.
  final String? release;
  final Map<String, PrebuiltTarget> targets;
  final RuntimeFileSet? runtimeFiles;

  Map<String, Object?> toJson() => {
    'schema': 1,
    'sourceKey': sourceKey,
    if (release != null) 'release': release,
    'targets': {
      for (final name in targets.keys.toList()..sort())
        name: targets[name]!.toJson(),
    },
    if (runtimeFiles != null) 'runtimeFiles': runtimeFiles!.toJson(),
  };

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  Future<void> save(Uri packageRoot) async {
    final file = File.fromUri(packageRoot.resolve(manifestPath));
    await file.parent.create(recursive: true);
    await file.writeAsString(encode());
  }
}

final class _Reader {
  _Reader(this.json, this.where);

  final Map<String, Object?> json;
  final String where;

  String string(String key) => switch (json[key]) {
    final String value => value,
    _ => throw FormatException('$where: "$key" must be a string.'),
  };

  String? optionalString(String key) => switch (json[key]) {
    null => null,
    final String value => value,
    _ => throw FormatException('$where: "$key" must be a string.'),
  };
}
