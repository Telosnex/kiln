import 'hashing.dart';

/// A file that an app downloads after install: a model, or a GPU pack
/// (ADR 001 D12, D13).
final class RuntimeFile {
  const RuntimeFile({
    required this.name,
    required this.sha256,
    required this.url,
    this.bytes,
    this.downloadSha256,
    this.archiveEntry,
    this.pack,
  });

  factory RuntimeFile.fromJson(Map<String, Object?> json) {
    String text(String key) => switch (json[key]) {
      final String value => value,
      _ => throw FormatException('Runtime file: "$key" must be a string.'),
    };
    String? optional(String key) => switch (json[key]) {
      null => null,
      final String value => value,
      _ => throw FormatException('Runtime file: "$key" must be a string.'),
    };
    final file = RuntimeFile(
      name: text('name'),
      sha256: text('sha256'),
      url: text('url'),
      bytes: switch (json['bytes']) {
        null => null,
        final int value when value >= 0 => value,
        _ => throw const FormatException('Runtime file: invalid "bytes".'),
      },
      downloadSha256: optional('downloadSha256'),
      archiveEntry: optional('archiveEntry'),
      pack: optional('pack'),
    );
    file.validate();
    return file;
  }

  /// File name on disk. No path separators.
  final String name;

  /// SHA-256 of the file after gunzip or extraction.
  final String sha256;

  final String url;

  /// Size of the file after gunzip or extraction, for progress and disk
  /// space checks.
  final int? bytes;

  /// SHA-256 of the bytes at [url].
  final String? downloadSha256;

  /// Path of the file inside the archive at [url].
  final String? archiveEntry;

  /// The GPU pack that this file belongs to (fllama ADR 004 D13).
  final String? pack;

  /// Throws a [FormatException] if a field is invalid.
  void validate() {
    validateFileName(name);
    if (!isSha256Hex(sha256)) {
      throw FormatException('$name: sha256 is not a SHA-256 hex digest.');
    }
    final download = downloadSha256;
    if (download != null && !isSha256Hex(download)) {
      throw FormatException(
        '$name: downloadSha256 is not a SHA-256 hex digest.',
      );
    }
    if (!isAllowedUrl(url)) {
      throw FormatException('$name: url must use https.');
    }
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    if (bytes != null) 'bytes': bytes,
    'url': url,
    if (downloadSha256 != null) 'downloadSha256': downloadSha256,
    if (archiveEntry != null) 'archiveEntry': archiveEntry,
    if (pack != null) 'pack': pack,
  };
}

/// Throws if [name] is not a plain file name.
void validateFileName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains(r'\')) {
    throw FormatException('"$name" is not a plain file name.');
  }
}

/// Whether [url] uses https, or http to a loopback host (tests).
bool isAllowedUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  return uri.scheme == 'http' &&
      (uri.host == '127.0.0.1' || uri.host == 'localhost');
}
