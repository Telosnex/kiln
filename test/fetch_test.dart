import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:prebuilt/prebuilt.dart';
import 'package:prebuilt/runtime.dart';
import 'package:prebuilt/src/hashing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final content = utf8.encode('library bytes ' * 1000);
  final contentSha = sha256OfBytes(content);
  final gz = gzip.encode(content);
  final gzSha = sha256OfBytes(gz);

  late TestServer server;
  late Directory dir;
  setUp(() async {
    server = await TestServer.start();
    dir = await tempDir();
  });

  List<String> leftovers() => dir
      .listSync(recursive: true)
      .map((e) => p.basename(e.path))
      .where((n) => n.contains('.partial') || n.contains('.download'))
      .toList();

  test('downloads, gunzips and checks a .gz file', () async {
    server.files['lib.so.gz'] = gz;
    final file = await fetchVerified(
      FetchSpec(
        url: server.url('lib.so.gz'),
        sha256: contentSha,
        downloadSha256: gzSha,
      ),
      File(p.join(dir.path, 'lib.so')),
    );
    expect(await file.readAsBytes(), content);
    expect(leftovers(), isEmpty);
  });

  test('does not download a file that is in place', () async {
    server.files['lib.so.gz'] = gz;
    final spec = FetchSpec(url: server.url('lib.so.gz'), sha256: contentSha);
    final destination = File(p.join(dir.path, 'lib.so'));
    await fetchVerified(spec, destination);
    await fetchVerified(spec, destination);
    expect(server.hits['lib.so.gz'], 1);
  });

  test('I1: replaces a changed cache entry', () async {
    server.files['lib.so.gz'] = gz;
    final spec = FetchSpec(url: server.url('lib.so.gz'), sha256: contentSha);
    final destination = File(p.join(dir.path, 'lib.so'));
    await fetchVerified(spec, destination);
    await destination.writeAsString('changed');
    await fetchVerified(spec, destination);
    expect(await destination.readAsBytes(), content);
    expect(server.hits['lib.so.gz'], 2);
  });

  test('I7: a changed download leaves no file', () async {
    server.files['lib.so.gz'] = gzip.encode(utf8.encode('other'));
    final destination = File(p.join(dir.path, 'lib.so'));
    await expectLater(
      fetchVerified(
        FetchSpec(
          url: server.url('lib.so.gz'),
          sha256: contentSha,
          downloadSha256: gzSha,
        ),
        destination,
      ),
      throwsA(isA<FetchException>()),
    );
    expect(destination.existsSync(), isFalse);
    expect(leftovers(), isEmpty);
    expect(server.hits['lib.so.gz'], 1, reason: 'a mismatch is not retried');
  });

  test('I7: a wrong file after gunzip leaves no file', () async {
    server.files['lib.so.gz'] = gzip.encode(utf8.encode('other'));
    final destination = File(p.join(dir.path, 'lib.so'));
    await expectLater(
      fetchVerified(
        FetchSpec(url: server.url('lib.so.gz'), sha256: contentSha),
        destination,
      ),
      throwsA(isA<FetchException>()),
    );
    expect(destination.existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('I7: a cut download is retried, then leaves no file', () async {
    server.files['lib.so.gz'] = gz;
    server.truncate.add('lib.so.gz');
    final destination = File(p.join(dir.path, 'lib.so'));
    await expectLater(
      fetchVerified(
        FetchSpec(url: server.url('lib.so.gz'), sha256: contentSha),
        destination,
        attempts: 2,
      ),
      throwsA(anything),
    );
    expect(server.hits['lib.so.gz'], 2);
    expect(destination.existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('HTTP 404 fails without retry', () async {
    await expectLater(
      fetchVerified(
        FetchSpec(url: server.url('missing.gz'), sha256: contentSha),
        File(p.join(dir.path, 'lib.so')),
      ),
      throwsA(isA<FetchException>()),
    );
    expect(server.hits['missing.gz'], 1);
  });

  test('a file that is not compressed is checked by sha256', () async {
    server.files['model.onnx'] = content;
    final file = await fetchVerified(
      FetchSpec(url: server.url('model.onnx'), sha256: contentSha),
      File(p.join(dir.path, 'model.onnx')),
    );
    expect(await file.readAsBytes(), content);
  });

  test('extracts one zip entry and keeps the archive in the cache', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('jni/arm64-v8a/libx.so', content))
      ..addFile(ArchiveFile.bytes('jni/x86_64/libx.so', utf8.encode('x64')));
    final zip = ZipEncoder().encode(archive);
    server.files['x.aar'] = zip;
    final cache = await tempDir();
    final spec = FetchSpec(
      url: server.url('x.aar'),
      sha256: contentSha,
      downloadSha256: sha256OfBytes(zip),
      archiveEntry: 'jni/arm64-v8a/libx.so',
    );
    final file = await fetchVerified(
      spec,
      File(p.join(dir.path, 'a', 'libx.so')),
      archiveCache: cache,
    );
    expect(await file.readAsBytes(), content);
    await fetchVerified(
      FetchSpec(
        url: spec.url,
        sha256: sha256OfBytes(utf8.encode('x64')),
        downloadSha256: spec.downloadSha256,
        archiveEntry: 'jni/x86_64/libx.so',
      ),
      File(p.join(dir.path, 'b', 'libx.so')),
      archiveCache: cache,
    );
    expect(server.hits['x.aar'], 1);
  });

  test('archives need archiveEntry and downloadSha256', () {
    expect(
      () => fetchVerified(
        FetchSpec(url: server.url('x.zip'), sha256: contentSha),
        File(p.join(dir.path, 'x')),
      ),
      throwsFormatException,
    );
  });

  test('concurrent fetches of one cache entry agree', () async {
    server.files['lib.so.gz'] = gz;
    final spec = FetchSpec(url: server.url('lib.so.gz'), sha256: contentSha);
    final destination = File(p.join(dir.path, 'lib.so'));
    await Future.wait([
      for (var i = 0; i < 4; i++) fetchVerified(spec, destination),
    ]);
    expect(await destination.readAsBytes(), content);
    expect(leftovers(), isEmpty);
  });

  test('ensureRuntimeFile reports progress and writes <dir>/<name>', () async {
    server.files['model.onnx.gz'] = gz;
    final received = <int>[];
    final file = await ensureRuntimeFile(
      RuntimeFile(
        name: 'model.onnx',
        sha256: contentSha,
        url: server.url('model.onnx.gz'),
        downloadSha256: gzSha,
      ),
      dir,
      onProgress: (bytes, total) => received.add(bytes),
    );
    expect(file.path, p.join(dir.path, 'model.onnx'));
    expect(received.last, gz.length);
  });
}
