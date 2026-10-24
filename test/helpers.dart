import 'dart:async';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A temporary directory deleted after the test.
Future<Directory> tempDir() async {
  final dir = await Directory.systemTemp.createTemp('kiln_test_');
  addTearDown(() => dir.delete(recursive: true));
  return Directory(dir.resolveSymbolicLinksSync());
}

/// Writes [files] (path -> content) under [root].
Future<void> writeFiles(Directory root, Map<String, String> files) async {
  for (final MapEntry(:key, :value) in files.entries) {
    final file = File(p.join(root.path, key));
    await file.parent.create(recursive: true);
    await file.writeAsString(value);
  }
}

/// A small package with native sources.
Future<Directory> fakePackage({Map<String, String> extra = const {}}) async {
  final root = await tempDir();
  await writeFiles(root, {
    'pubspec.yaml': 'name: fake_native\n',
    'src/lib.c': 'int answer(void) { return 42; }\n',
    'hook/build.dart': 'void main() {}\n',
    'lib/fake_native.dart': '// Dart code\n',
    'README.md': '# fake\n',
    ...extra,
  });
  return root;
}

Future<void> git(Directory root, List<String> args) async {
  final result = await Process.run('git', [
    '-c', 'user.email=t@example.com', '-c', 'user.name=t', //
    ...args,
  ], workingDirectory: root.path);
  if (result.exitCode != 0) throw StateError('git $args: ${result.stderr}');
}

/// An HTTP server on 127.0.0.1 that serves [files] by path.
final class TestServer {
  TestServer._(this._server);

  static Future<TestServer> start() async {
    final server = TestServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._handle);
    addTearDown(() => server._server.close(force: true));
    return server;
  }

  final HttpServer _server;
  final Map<String, List<int>> files = {};
  final Map<String, int> hits = {};

  /// Paths whose response stops after half of the bytes.
  final Set<String> truncate = {};

  String url(String path) => 'http://127.0.0.1:${_server.port}/$path';

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path.substring(1);
    hits[path] = (hits[path] ?? 0) + 1;
    final bytes = files[path];
    final response = request.response;
    if (bytes == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    if (truncate.contains(path)) {
      final socket = await response.detachSocket(writeHeaders: true);
      socket.add(bytes.sublist(0, bytes.length ~/ 2));
      await socket.flush();
      socket.destroy();
      return;
    }
    response.add(bytes);
    await response.close();
  }
}

/// A [BuildInput] for [packageRoot], like the one Flutter passes.
Future<BuildInput> buildInput(
  Directory packageRoot, {
  OS os = OS.macOS,
  Architecture architecture = Architecture.arm64,
  int macOSVersion = 12,
  Map<String, Object> defines = const {},
}) async {
  final work = await tempDir();
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: packageRoot.uri,
      packageName: 'fake_native',
      outputFile: work.uri.resolve('output.json'),
      outputDirectoryShared: work.uri.resolve('shared/'),
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: defines,
          basePath: packageRoot.uri,
        ),
      ),
    )
    ..setupBuildInput()
    ..config.setupBuild(linkingEnabled: false);
  CodeAssetExtension(
    linkModePreference: LinkModePreference.dynamic,
    targetArchitecture: architecture,
    targetOS: os,
    macOS: os == OS.macOS ? MacOSCodeConfig(targetVersion: macOSVersion) : null,
    iOS: os == OS.iOS
        ? IOSCodeConfig(targetSdk: IOSSdk.iPhoneOS, targetVersion: 13)
        : null,
    android: os == OS.android ? AndroidCodeConfig(targetNdkApi: 24) : null,
  ).setupBuildInput(builder);
  return builder.build();
}
