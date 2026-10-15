import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'hashing.dart';

/// Package excludes, one entry per line, `#` starts a comment. The file is
/// itself part of the source key.
const sourceExcludesPath = 'native_artifacts/source_excludes.txt';

/// Paths that never change the source key (ADR 001 §5). An entry that ends
/// in `/` excludes a top-level directory. Other entries are exact paths.
///
/// Also excluded: every top-level name that starts with `.`, top-level
/// `*.md` files, and `.git` and `.dart_tool` directories at any depth.
const defaultSourceExcludes = [
  'build/',
  'docs/',
  'example/',
  'integration_test/',
  'lib/',
  'test/',
  'native_artifacts/prebuilt.json',
  'native_artifacts/web.json',
  'pubspec.lock',
  // The package LICENSE holds the notices of the native code too, in the
  // Flutter multi-license format. A notice change needs no new release.
  'LICENSE',
];

/// A file that the source key covers.
final class SourceFile {
  const SourceFile(this.path, this.sha256, this.uri);

  /// Path relative to the package root, with `/`.
  final String path;
  final String sha256;
  final Uri uri;
}

/// The source key of a package and the files that it covers.
final class SourceKey {
  const SourceKey(this.key, this.files, {required this.usedGit});

  final String key;
  final List<SourceFile> files;

  /// Whether `git ls-files` listed the files.
  final bool usedGit;

  /// First 16 hex digits, used in release tags.
  String get short => key.substring(0, 16);

  /// The lines that the key hashes, one per file.
  String get listing => files.map((f) => '${f.path}\t${f.sha256}\n').join();
}

/// Computes the source key of the package at [packageRoot] (ADR 001 D3).
///
/// If the package is in a git work tree, the files are the output of
/// `git ls-files --cached --others --exclude-standard`: tracked files, and
/// new files that are not ignored. Otherwise every file under the package
/// root. The entries of [sourceExcludesPath] and [excludes] are added to
/// [defaultSourceExcludes], with the same syntax.
///
/// With [memoDirectory], file hashes are reused while the size and the
/// modification time of a file do not change.
Future<SourceKey> computeSourceKey(
  Uri packageRoot, {
  List<String> excludes = const [],
  Directory? memoDirectory,
}) async {
  final root = Directory.fromUri(packageRoot).absolute.path;
  final excluder = _Excluder([
    ...defaultSourceExcludes,
    ...await _packageExcludes(root),
    ...excludes,
  ]);
  final listed = await _gitFiles(root);
  final paths = <String>{};
  if (listed != null) {
    for (final path in listed) {
      if (excluder.excludes(path)) continue;
      final full = p.join(root, p.fromUri(path));
      final type = FileSystemEntity.typeSync(full, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        // A submodule: git lists it as one entry.
        paths.addAll(await _walk(root, full, excluder));
      } else if (type != FileSystemEntityType.notFound) {
        paths.add(path);
      }
    }
  } else {
    paths.addAll(await _walk(root, root, excluder));
  }

  // Files that git stores with LF but checked out with CRLF (Windows with
  // core.autocrlf, also pub's git cache): hashed as stored, so a checkout
  // gets the same key on every host.
  final crlf = listed == null ? const <String>{} : await _crlfCheckouts(root);
  final memo = memoDirectory == null ? null : _Memo(memoDirectory, root);
  await memo?.load();
  final sorted = paths.toList()..sort();
  final files = <SourceFile>[];
  for (final path in sorted) {
    final full = p.join(root, p.fromUri(path));
    files.add(
      SourceFile(
        path,
        crlf.contains(path)
            ? sha256OfBytes(_lf(await File(full).readAsBytes()))
            : await _hashEntry(full, memo, path),
        File(full).uri,
      ),
    );
  }
  await memo?.save();
  final listing = files.map((f) => '${f.path}\t${f.sha256}\n').join();
  return SourceKey(sha256OfString(listing), files, usedGit: listed != null);
}

Future<String> _hashEntry(String full, _Memo? memo, String path) async {
  if (FileSystemEntity.isLinkSync(full)) {
    // Git stores a link as its target text. On hosts without links, git
    // checks it out as a file with that text, so both hash the same.
    return sha256OfString(Link(full).targetSync().replaceAll(r'\', '/'));
  }
  final file = File(full);
  final stat = await file.stat();
  final cached = memo?.lookup(path, stat);
  if (cached != null) return cached;
  final digest = await sha256OfFile(file);
  memo?.record(path, stat, digest);
  return digest;
}

Future<List<String>> _packageExcludes(String root) async {
  final file = File(p.join(root, p.fromUri(sourceExcludesPath)));
  if (!await file.exists()) return const [];
  return [
    for (final line in await file.readAsLines())
      if (line.split('#').first.trim() case final entry when entry.isNotEmpty)
        entry,
  ];
}

final class _Excluder {
  _Excluder(List<String> entries)
    : _directories = [
        for (final e in entries)
          if (e.endsWith('/')) e,
      ],
      _files = {
        for (final e in entries)
          if (!e.endsWith('/')) e,
      };

  final List<String> _directories;
  final Set<String> _files;

  bool excludes(String path) {
    final segments = path.split('/');
    if (segments.first.startsWith('.')) return true;
    if (segments.any((s) => s == '.git' || s == '.dart_tool')) return true;
    if (segments.length == 1 && path.toLowerCase().endsWith('.md')) return true;
    return _files.contains(path) || _directories.any(path.startsWith);
  }
}

/// Paths whose index copy has LF line endings and whose checkout has CRLF.
Future<Set<String>> _crlfCheckouts(String root) async {
  ProcessResult result;
  try {
    result = await Process.run(
      'git',
      ['ls-files', '-z', '--eol', '--cached'],
      workingDirectory: root,
      stdoutEncoding: utf8,
    );
  } on ProcessException {
    return const {};
  }
  if (result.exitCode != 0) return const {};
  // Entries: "i/lf    w/crlf  attr/                 \tpath".
  return {
    for (final entry in (result.stdout as String).split('\x00'))
      if (entry.indexOf('\t') case final tab when tab > 0)
        if (RegExp(r'^i/lf\s+w/crlf\b').hasMatch(entry.substring(0, tab)))
          entry.substring(tab + 1),
  };
}

/// [bytes] with each CRLF replaced by LF.
List<int> _lf(List<int> bytes) {
  final out = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 13 && i + 1 < bytes.length && bytes[i + 1] == 10) continue;
    out.add(bytes[i]);
  }
  return out;
}

Future<List<String>?> _gitFiles(String root) async {
  ProcessResult result;
  try {
    result = await Process.run(
      'git',
      ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
      workingDirectory: root,
      stdoutEncoding: utf8,
    );
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) return null;
  final paths = (result.stdout as String)
      .split('\x00')
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();
  // The package is in a repository that does not track it.
  if (!paths.contains('pubspec.yaml')) return null;
  return paths;
}

Future<List<String>> _walk(
  String root,
  String start,
  _Excluder excluder,
) async {
  final paths = <String>[];
  Future<void> visit(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final path = p.relative(entity.path, from: root).replaceAll(r'\', '/');
      if (excluder.excludes(entity is Directory ? '$path/' : path)) continue;
      if (entity is Directory) {
        await visit(entity);
      } else {
        paths.add(path);
      }
    }
  }

  await visit(Directory(start));
  return paths;
}

final class _Memo {
  _Memo(Directory directory, String root)
    : _file = File(
        p.join(directory.path, '${sha256OfString(root).substring(0, 16)}.json'),
      );

  final File _file;
  Map<String, Object?> _old = {};
  final Map<String, List<Object>> _new = {};

  Future<void> load() async {
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded case {
        'schema': 1,
        'files': final Map<String, Object?> files,
      }) {
        _old = files;
      }
    } on Object {
      _old = {};
    }
  }

  String? lookup(String path, FileStat stat) {
    if (_old[path]
        case [final int size, final int modified, final String digest]
        when size == stat.size &&
            modified == stat.modified.microsecondsSinceEpoch) {
      _new[path] = [size, modified, digest];
      return digest;
    }
    return null;
  }

  void record(String path, FileStat stat, String digest) =>
      _new[path] = [stat.size, stat.modified.microsecondsSinceEpoch, digest];

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.$pid.tmp');
    await temporary.writeAsString(jsonEncode({'schema': 1, 'files': _new}));
    try {
      await temporary.rename(_file.path);
    } on FileSystemException {
      // Windows: another hook wrote the memo at the same time. Either copy
      // is valid.
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
