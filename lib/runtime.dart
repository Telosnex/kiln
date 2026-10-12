/// Download and check of runtime files (ADR 001 D13): models and GPU packs.
///
/// This library has no Flutter and no build hook dependency. It uses
/// `dart:io`, so web apps must import it conditionally.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/fetch.dart';
import 'src/runtime_file.dart';

export 'src/fetch.dart' show FetchException;
export 'src/runtime_file.dart' show RuntimeFile;

/// Makes `<directory>/<file.name>` a file with SHA-256 [RuntimeFile.sha256]
/// and returns it.
///
/// A file that is already there with that SHA-256 is not downloaded again.
/// A download goes to a temporary file next to the final path. It is
/// gunzipped or extracted if needed, checked, and then renamed into place.
Future<File> ensureRuntimeFile(
  RuntimeFile file,
  Directory directory, {
  HttpClient? client,
  void Function(int received, int? total)? onProgress,
}) {
  file.validate();
  return fetchVerified(
    FetchSpec(
      url: file.url,
      sha256: file.sha256,
      downloadSha256: file.downloadSha256,
      archiveEntry: file.archiveEntry,
    ),
    File(p.join(directory.path, file.name)),
    client: client,
    onProgress: onProgress,
  );
}
