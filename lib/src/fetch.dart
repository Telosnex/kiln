import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'hashing.dart';
import 'locks.dart';

/// A file at a URL, pinned by SHA-256.
final class FetchSpec {
  const FetchSpec({
    required this.url,
    required this.sha256,
    this.downloadSha256,
    this.archiveEntry,
  });

  final String url;

  /// SHA-256 of the file after gunzip, or after extraction from an archive.
  final String sha256;

  /// SHA-256 of the bytes at [url]. Required for archives. Optional for
  /// `.gz` files: [sha256] is then checked after gunzip only.
  final String? downloadSha256;

  /// Path of the file inside a `.zip`, `.aar`, `.tgz` or `.tar.gz` archive.
  final String? archiveEntry;
}

/// A download or check failure.
final class FetchException implements Exception {
  FetchException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => 'FetchException: $message';
}

enum _Encoding { raw, gzip, zip, tarGzip }

_Encoding _encodingOf(FetchSpec spec) {
  final path = Uri.parse(spec.url).path.toLowerCase();
  final encoding = path.endsWith('.zip') || path.endsWith('.aar')
      ? _Encoding.zip
      : path.endsWith('.tgz') || path.endsWith('.tar.gz')
      ? _Encoding.tarGzip
      : path.endsWith('.gz')
      ? _Encoding.gzip
      : _Encoding.raw;
  final isArchive = encoding == _Encoding.zip || encoding == _Encoding.tarGzip;
  if (isArchive && spec.archiveEntry == null) {
    throw FormatException(
      '${spec.url} is an archive; archiveEntry is required.',
    );
  }
  if (!isArchive && spec.archiveEntry != null) {
    throw FormatException(
      '${spec.url} is not a .zip, .aar, .tgz or .tar.gz archive; '
      'archiveEntry must not be set.',
    );
  }
  if (isArchive && spec.downloadSha256 == null) {
    throw FormatException(
      '${spec.url} is an archive; downloadSha256 is required.',
    );
  }
  return encoding;
}

var _unique = 0;

/// Makes [destination] a file with SHA-256 [FetchSpec.sha256].
///
/// If [destination] already has that SHA-256, nothing is downloaded.
/// Otherwise the file is downloaded and decoded next to [destination], checked,
/// and renamed into place. [destination] never holds a file with another
/// SHA-256 when this returns or throws (ADR 001 I7).
///
/// [archiveCache] keeps downloaded archives at
/// `<archiveCache>/<downloadSha256>/<file name>`, so several entries of one
/// archive download once. Without it, archives are deleted after extraction.
Future<File> fetchVerified(
  FetchSpec spec,
  File destination, {
  HttpClient? client,
  Directory? archiveCache,
  void Function(String message)? log,
  void Function(int received, int? total)? onProgress,
  int attempts = 3,
}) async {
  final encoding = _encodingOf(spec);
  if (await destination.exists()) {
    if (await sha256OfFile(destination) == spec.sha256) return destination;
    log?.call(
      'Replacing ${destination.path}: its SHA-256 is not ${spec.sha256}',
    );
    await destination.delete();
  }
  await destination.parent.create(recursive: true);

  final unique = '$pid.${_unique++}';
  final partial = File('${destination.path}.$unique.partial');
  File? temporaryDownload;
  final ownClient = client == null;
  final http = client ?? HttpClient();
  Future<void> download(File file, String? expected) => _download(
    http,
    spec.url,
    file,
    expectedSha256: expected,
    attempts: attempts,
    log: log,
    onProgress: onProgress,
  );
  try {
    switch (encoding) {
      case _Encoding.raw:
        if (spec.downloadSha256 != null && spec.downloadSha256 != spec.sha256) {
          throw FormatException(
            '${spec.url}: downloadSha256 differs from sha256 for a file '
            'that is not compressed.',
          );
        }
        await download(partial, spec.sha256);
      case _Encoding.gzip:
        temporaryDownload = File('${destination.path}.$unique.download');
        await download(temporaryDownload, spec.downloadSha256);
        await temporaryDownload
            .openRead()
            .transform(gzip.decoder)
            .pipe(partial.openWrite());
      case _Encoding.zip:
      case _Encoding.tarGzip:
        final File archive;
        if (archiveCache == null) {
          archive = temporaryDownload = File(
            '${destination.path}.$unique.download',
          );
          await download(archive, spec.downloadSha256);
        } else {
          final digest = spec.downloadSha256!;
          archive = File(
            p.join(archiveCache.path, digest, _fileNameOf(spec.url)),
          );
          await withFileLock(
            File(p.join(archiveCache.path, '$digest.lock')),
            () async {
              if (await archive.exists() &&
                  await sha256OfFile(archive) == digest) {
                return;
              }
              await archive.parent.create(recursive: true);
              final archivePartial = File('${archive.path}.$unique.partial');
              try {
                await download(archivePartial, digest);
                if (await archive.exists()) await archive.delete();
                await archivePartial.rename(archive.path);
              } finally {
                if (await archivePartial.exists())
                  await archivePartial.delete();
              }
            },
          );
        }
        await _extract(archive, encoding, spec, partial);
    }

    final actual = await sha256OfFile(partial);
    if (actual != spec.sha256) {
      throw FetchException(
        'SHA-256 mismatch for ${spec.url}'
        '${encoding == _Encoding.raw ? '' : ' after decoding'}: '
        'expected ${spec.sha256}, got $actual.',
      );
    }
    try {
      await partial.rename(destination.path);
    } on FileSystemException {
      // Another process put the same file in place first (Windows does not
      // rename over an existing file).
      if (!await destination.exists() ||
          await sha256OfFile(destination) != spec.sha256) {
        rethrow;
      }
    }
    return destination;
  } finally {
    if (ownClient) http.close(force: true);
    if (await partial.exists()) await partial.delete();
    final download = temporaryDownload;
    if (download != null && await download.exists()) await download.delete();
  }
}

String _fileNameOf(String url) {
  final segments = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty);
  return segments.isEmpty ? 'download' : segments.last;
}

Future<void> _download(
  HttpClient client,
  String url,
  File file, {
  required String? expectedSha256,
  required int attempts,
  void Function(String message)? log,
  void Function(int received, int? total)? onProgress,
}) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await _downloadOnce(client, url, file, onProgress);
      break;
    } on Object catch (error) {
      if (await file.exists()) await file.delete();
      final retryable = switch (error) {
        FetchException(:final retryable) => retryable,
        SocketException() || HttpException() || TimeoutException() => true,
        _ => false,
      };
      if (!retryable || attempt >= attempts) rethrow;
      log?.call('Download of $url failed ($error); attempt ${attempt + 1}');
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
    }
  }
  if (expectedSha256 != null) {
    final actual = await sha256OfFile(file);
    if (actual != expectedSha256) {
      await file.delete();
      throw FetchException(
        'SHA-256 mismatch for the download of $url: expected '
        '$expectedSha256, got $actual. The file was deleted.',
      );
    }
  }
}

Future<void> _downloadOnce(
  HttpClient client,
  String url,
  File file,
  void Function(int received, int? total)? onProgress,
) async {
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set(HttpHeaders.userAgentHeader, 'prebuilt/1');
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw FetchException(
      'Download of $url failed with HTTP ${response.statusCode}.',
      retryable: response.statusCode >= 500 || response.statusCode == 429,
    );
  }
  final total = response.contentLength >= 0 ? response.contentLength : null;
  var received = 0;
  final sink = file.openWrite();
  try {
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
  } finally {
    await sink.close();
  }
  if (total != null && received != total) {
    throw FetchException(
      'Download of $url ended after $received of $total bytes.',
      retryable: true,
    );
  }
}

Future<void> _extract(
  File archiveFile,
  _Encoding encoding,
  FetchSpec spec,
  File output,
) async {
  final bytes = await archiveFile.readAsBytes();
  final Archive archive = encoding == _Encoding.zip
      ? ZipDecoder().decodeBytes(bytes, verify: true)
      : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  String normalize(String name) {
    var n = name.replaceAll(r'\', '/');
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    return n;
  }

  final wanted = normalize(spec.archiveEntry!);
  final matches = archive.files
      .where((entry) => entry.isFile && normalize(entry.name) == wanted)
      .toList();
  if (matches.length != 1) {
    throw FetchException(
      'Expected one entry $wanted in ${spec.url}, found ${matches.length}.',
    );
  }
  final content = matches.single.readBytes();
  if (content == null) {
    throw FetchException('Cannot read entry $wanted in ${spec.url}.');
  }
  await output.writeAsBytes(content, flush: true);
}
