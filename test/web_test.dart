import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:prebuilt/prebuilt.dart';
import 'package:prebuilt/src/hashing.dart';
import 'package:prebuilt/src/release_tool.dart';
import 'package:prebuilt/src/web_install.dart';
import 'package:prebuilt/src/web_tool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'end_to_end_test.dart' show FakePublisher;
import 'helpers.dart';

/// A [BuildInput] like the one a Flutter web build passes: no asset types,
/// and the shared output in `<app>/.dart_tool`.
BuildInput webBuildInput(
  Directory packageRoot,
  Directory app, {
  Map<String, Object> defines = const {},
}) {
  final shared = app.uri.resolve(
    '.dart_tool/hooks_runner/shared/fake_native/build/',
  );
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: packageRoot.uri,
      packageName: 'fake_native',
      outputFile: app.uri.resolve('.dart_tool/hooks_runner/out/output.json'),
      outputDirectoryShared: shared,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: defines,
          basePath: app.uri,
        ),
      ),
    )
    ..setupBuildInput()
    ..config.setupBuild(linkingEnabled: false);
  return builder.build();
}

void main() {
  final wasm = utf8.encode('wasm bytes');
  final module = utf8.encode('export default 1;');
  const worker = 'self.onmessage = () => {};\n';

  late TestServer server;
  late Directory package;
  late Directory app;
  late Directory cache;

  setUp(() async {
    server = await TestServer.start();
    server.files['web-fake.wasm.gz'] = gzip.encode(wasm);
    server.files['web-sub__module.mjs.gz'] = gzip.encode(module);
    package = await fakePackage(extra: {'lib/web/fake_worker.mjs': worker});
    app = await tempDir();
    await writeFiles(app, {'web/index.html': '<html></html>'});
    cache = await tempDir();
  });

  WebFile generated(String name, List<int> bytes) => WebFile(
    name: name,
    sha256: sha256OfBytes(bytes),
    bytes: bytes.length,
    source: webReleaseSource,
    url: server.url(webAssetName(name)),
    downloadSha256: sha256OfBytes(gzip.encode(bytes)),
  );

  /// Writes a web.json with two generated files and the worker.
  Future<WebManifest> writeWebManifest({String? sourceKey}) async {
    final manifest = WebManifest(
      sourceKey: sourceKey ?? (await computeSourceKey(package.uri)).key,
      release: 'https://github.com/Telosnex/fake/releases/tag/native-x',
      runner: 'test',
      toolchain: 'emcc',
      files: [
        generated('fake.wasm', wasm),
        generated('sub/module.mjs', module),
        await handWrittenWebFile(
          package.uri,
          'fake_worker.mjs',
          'lib/web/fake_worker.mjs',
        ),
      ],
    );
    await manifest.save(package.uri);
    return manifest;
  }

  Directory installed() =>
      Directory(p.join(app.path, 'web', 'native_prebuilt', 'fake_native'));

  Future<BuildOutput> runWeb({Map<String, Object> defines = const {}}) async {
    final output = BuildOutputBuilder();
    await Prebuilt(
      input: webBuildInput(package, app, defines: defines),
      output: output,
      cacheRoot: cache,
    ).installWeb();
    return output.build();
  }

  Future<Map<String, String>> installedFiles([Directory? directory]) async => {
    for (final MapEntry(:key, :value) in (await listWebDirectory(
      directory ?? installed(),
    )).entries)
      key: await value.readAsString(),
  };

  group('web.json', () {
    test('webVersion depends on names and SHA-256 only, not order', () {
      final a = (name: 'a', sha256: '1' * 64);
      final b = (name: 'b', sha256: '2' * 64);
      expect(webVersionOf([a, b]), webVersionOf([b, a]));
      expect(webVersionOf([a, b]), hasLength(16));
      expect(
        webVersionOf([a, b]),
        isNot(webVersionOf([a, (name: 'b', sha256: '3' * 64)])),
      );
      expect(
        webVersionOf([a, b]),
        isNot(webVersionOf([a, (name: 'c', sha256: '2' * 64)])),
      );
    });

    test('round trip, and a stale webVersion is rejected', () async {
      final manifest = await writeWebManifest();
      final json = jsonDecode(manifest.encode()) as Map<String, Object?>;
      expect(WebManifest.fromJson(json).encode(), manifest.encode());
      expect(json['webVersion'], manifest.webVersion);
      expect(
        () => WebManifest.fromJson({...json, 'webVersion': '0' * 16}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('stamp'),
          ),
        ),
      );
      expect(
        File.fromUri(
          package.uri.resolve(webRuntimeDartPath),
        ).readAsStringSync(),
        contains("const webRuntimeVersion = '${manifest.webVersion}';"),
      );
    });

    test('invalid names and release fields are rejected', () {
      for (final name in ['../x', '/x', 'a//b', r'a\b', '', 'a/./b']) {
        expect(
          () => validateWebName(name),
          throwsFormatException,
          reason: name,
        );
      }
      final hand = WebFile(
        name: 'w.mjs',
        sha256: '1' * 64,
        bytes: 1,
        source: 'lib/web/w.mjs',
      );
      expect(
        () => WebManifest(files: [generated('x.wasm', wasm)]),
        throwsFormatException,
      );
      expect(
        () => WebManifest(files: [hand], sourceKey: '1' * 64),
        throwsFormatException,
      );
      expect(
        () => WebManifest(
          files: [
            hand,
            WebFile(name: 'w.mjs/x', sha256: '1' * 64, bytes: 1, source: 'x'),
          ],
        ),
        throwsFormatException,
      );
    });
  });

  test('findAppRoot is the parent of .dart_tool', () {
    expect(
      findAppRoot(
        Uri.directory('/a/app/.dart_tool/hooks_runner/shared/x/build/'),
      ).path,
      Directory('/a/app/').path,
    );
    expect(() => findAppRoot(Uri.directory('/tmp/x/')), throwsStateError);
  });

  group('hook', () {
    test('a code-asset build installs nothing', () async {
      await writeWebManifest();
      final output = BuildOutputBuilder();
      await Prebuilt(
        input: await buildInput(package),
        output: output,
        cacheRoot: cache,
      ).installWeb();
      expect(
        Directory(p.join(app.path, 'web', 'native_prebuilt')).existsSync(),
        isFalse,
      );
    });

    test('no web.json installs nothing', () async {
      final output = await runWeb();
      expect(output.dependencies, isEmpty);
      expect(installed().existsSync(), isFalse);
    });

    test('download installs every file and declares them', () async {
      await writeWebManifest();
      final output = await runWeb();
      expect(await installedFiles(), {
        'fake.wasm': 'wasm bytes',
        'sub/module.mjs': 'export default 1;',
        'fake_worker.mjs': worker,
      });
      expect(
        File(
          p.join(app.path, 'web', 'native_prebuilt', '.gitignore'),
        ).readAsStringSync(),
        '*\n',
      );
      expect(
        output.dependencies,
        containsAll([
          package.uri.resolve(webManifestPath),
          package.uri.resolve('lib/web/fake_worker.mjs'),
          package.uri.resolve('src/lib.c'),
          File(p.join(installed().path, 'fake.wasm')).uri,
          File(p.join(installed().path, 'sub', 'module.mjs')).uri,
        ]),
      );

      // Again: from the cache, and the directory is not replaced.
      final before = File(
        p.join(installed().path, 'fake.wasm'),
      ).statSync().modified;
      await runWeb();
      expect(server.hits['web-fake.wasm.gz'], 1);
      expect(
        File(p.join(installed().path, 'fake.wasm')).statSync().modified,
        before,
      );

      // An extra file is removed.
      await writeFiles(installed(), {'stale.js': 'old'});
      await runWeb();
      expect((await installedFiles()).keys, isNot(contains('stale.js')));
    });

    test('download: a wrong SHA-256 fails and installs nothing', () async {
      await writeWebManifest();
      server.files['web-fake.wasm.gz'] = gzip.encode(utf8.encode('evil'));
      await expectLater(runWeb(), throwsA(isA<FetchException>()));
      expect(installed().existsSync(), isFalse);
    });

    test('download: a source key mismatch fails', () async {
      await writeWebManifest(sourceKey: 'f' * 64);
      await expectLater(
        runWeb(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('differ'), contains('web_build: local')),
          ),
        ),
      );
    });

    test('download: a changed hand-written file fails', () async {
      await writeWebManifest();
      await writeFiles(package, {'lib/web/fake_worker.mjs': 'changed'});
      await expectLater(
        runWeb(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('web stamp'),
          ),
        ),
      );
    });

    test('local copies the build directory and verifies nothing', () async {
      await writeWebManifest(sourceKey: 'f' * 64);
      await writeFiles(package, {'lib/web/fake_worker.mjs': 'changed'});
      final build = await tempDir();
      await writeFiles(build, {'fake.wasm': 'local wasm', 'new.mjs': 'new'});
      final output = await runWeb(
        defines: {'web_build': 'local', 'web_build_dir': build.path},
      );
      expect(await installedFiles(), {
        'fake.wasm': 'local wasm',
        'new.mjs': 'new',
        'fake_worker.mjs': 'changed',
      });
      expect(server.hits, isEmpty);
      expect(
        output.dependencies,
        contains(File(p.join(build.path, 'fake.wasm')).uri),
      );
    });

    test('local without web_build_dir fails', () async {
      await writeWebManifest();
      await expectLater(
        runWeb(defines: {'web_build': 'local'}),
        throwsStateError,
      );
    });

    test('web_root overrides the app directory', () async {
      await writeWebManifest();
      final other = await tempDir();
      await writeFiles(other, {'web/index.html': ''});
      await runWeb(defines: {'web_root': other.path});
      expect(
        (await installedFiles(
          Directory(
            p.join(other.path, 'web', 'native_prebuilt', 'fake_native'),
          ),
        )).keys,
        hasLength(3),
      );
      expect(installed().existsSync(), isFalse);
    });

    test('an app without web/ fails with a web_root hint', () async {
      await writeWebManifest();
      await Directory(p.join(app.path, 'web')).delete(recursive: true);
      await expectLater(
        runWeb(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('web_root'),
          ),
        ),
      );
    });
  });

  group('stamp', () {
    test('creates web.json, then follows a changed file', () async {
      final first = await stampWeb(
        packageRoot: package.uri,
        add: Map.fromEntries([parseWebAdd('lib/web/fake_worker.mjs')]),
      );
      expect(first.files.single.name, 'fake_worker.mjs');
      expect(first.sourceKey, isNull);
      expect(await WebManifest.load(package.uri), isNotNull);

      await writeFiles(package, {'lib/web/fake_worker.mjs': 'changed'});
      final second = await stampWeb(packageRoot: package.uri);
      expect(second.webVersion, isNot(first.webVersion));
      expect(
        File.fromUri(
          package.uri.resolve(webRuntimeDartPath),
        ).readAsStringSync(),
        contains(second.webVersion),
      );

      // A stale webVersion is written again.
      final file = File.fromUri(package.uri.resolve(webManifestPath));
      await file.writeAsString(
        file.readAsStringSync().replaceAll(second.webVersion, '0' * 16),
      );
      expect(() => WebManifest.load(package.uri), throwsFormatException);
      expect(
        (await stampWeb(packageRoot: package.uri)).webVersion,
        second.webVersion,
      );

      final third = await stampWeb(
        packageRoot: package.uri,
        remove: {'fake_worker.mjs'},
      );
      expect(third.files, isEmpty);
    });

    test('keeps the generated entries and release fields', () async {
      final manifest = await writeWebManifest();
      await writeFiles(package, {'lib/web/fake_worker.mjs': 'changed'});
      final stamped = await stampWeb(packageRoot: package.uri);
      expect(stamped.sourceKey, manifest.sourceKey);
      expect(stamped.generated.map((f) => f.name), [
        'fake.wasm',
        'sub/module.mjs',
      ]);
      expect(
        () => stampWeb(
          packageRoot: package.uri,
          add: {'fake.wasm': 'lib/web/fake_worker.mjs'},
        ),
        throwsStateError,
      );
    });

    test('parseWebAdd', () {
      expect(parseWebAdd('lib/web/a/b.mjs'), isA<MapEntry<String, String>>());
      expect(parseWebAdd('lib/web/a/b.mjs').key, 'a/b.mjs');
      expect(parseWebAdd('assets/web/x.js').key, 'x.js');
      expect(parseWebAdd('y.js=assets/web/x.js').key, 'y.js');
      expect(parseWebAdd('y.js=assets/web/x.js').value, 'assets/web/x.js');
    });
  });

  group('install-dev', () {
    test('downloads into lib/web and keeps .gitignore lines', () async {
      await writeWebManifest();
      await writeFiles(package, {'lib/web/.gitignore': '/own.txt\n'});
      final set = await installDev(packageRoot: package.uri, cacheRoot: cache);
      final libWeb = Directory.fromUri(package.uri.resolve('lib/web/'));
      expect(
        File(p.join(libWeb.path, 'fake.wasm')).readAsStringSync(),
        'wasm bytes',
      );
      expect(
        File(p.join(libWeb.path, 'sub', 'module.mjs')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(libWeb.path, devVersionFileName)).readAsStringSync(),
        '${set.webVersion}\n',
      );
      expect(set.webVersion, (await WebManifest.load(package.uri))!.webVersion);
      final gitignore = File(
        p.join(libWeb.path, '.gitignore'),
      ).readAsStringSync();
      expect(gitignore, startsWith('/own.txt\n'));
      expect(gitignore, contains('/fake.wasm\n'));
      expect(gitignore, contains('/sub/module.mjs\n'));
      expect(gitignore, contains('/$devVersionFileName\n'));
      expect(gitignore, isNot(contains('fake_worker.mjs')));

      // The generated files do not change the source key.
      expect(
        (await computeSourceKey(package.uri)).key,
        (await WebManifest.load(package.uri))!.sourceKey,
      );

      // --from with fewer files removes the old ones, once.
      final build = await tempDir();
      await writeFiles(build, {'fake.wasm': 'local'});
      await installDev(packageRoot: package.uri, from: build, cacheRoot: cache);
      expect(
        File(p.join(libWeb.path, 'fake.wasm')).readAsStringSync(),
        'local',
      );
      expect(
        File(p.join(libWeb.path, 'sub', 'module.mjs')).existsSync(),
        isFalse,
      );
      final again = File(p.join(libWeb.path, '.gitignore')).readAsStringSync();
      expect(again, isNot(contains('module.mjs')));
      expect(
        RegExp('# native_prebuilt web install-dev:').allMatches(again),
        hasLength(1),
      );
    });
  });

  group('release and check', () {
    late FakePublisher publisher;
    late Directory targets;
    late Directory webBuild;

    setUp(() async {
      publisher = FakePublisher(server);
      await git(package, ['init', '-q']);
      await git(package, ['add', '-A']);
      await git(package, ['commit', '-qm', 'fixture']);
      final key = await computeSourceKey(package.uri);
      targets = await tempDir();
      final dylib = utf8.encode('dylib');
      await writeFiles(targets, {
        'macos-arm64/libfake.dylib': 'dylib',
        'macos-arm64/target.json': jsonEncode({
          'schema': 1,
          'package': 'fake_native',
          'target': 'macos-arm64',
          'sourceKey': key.key,
          'runner': 'test',
          'toolchain': '',
          'files': [
            {
              'name': 'libfake.dylib',
              'sha256': sha256OfBytes(dylib),
              'delivery': 'bundle',
              'asset': 'fake_native.dart',
            },
          ],
        }),
      });
      webBuild = await tempDir();
      await writeFiles(webBuild, {
        'fake.wasm': 'wasm bytes',
        'sub/module.mjs': 'export default 1;',
      });
      await stampWeb(
        packageRoot: package.uri,
        add: {'fake_worker.mjs': 'lib/web/fake_worker.mjs'},
      );
    });

    Future<PrebuiltManifest> release({Directory? web}) => releaseTargets(
      packageRoot: package.uri,
      targetDirectories: [targets],
      repository: 'Telosnex/fake',
      staging: Directory(p.join(targets.path, 'staging')),
      webDirectory: web,
      webRunner: 'ubuntu-24.04, emsdk',
      webToolchain: 'Emscripten 5.0.0',
      publisher: publisher,
      assetUrl: (tag, asset) => server.url('$tag/$asset'),
    );

    test(
      'release --web uploads with the native files and check passes',
      () async {
        final native = await release(web: webBuild);
        final tag = nativeReleaseTag(native.sourceKey);
        expect(publisher.published[tag]!.keys, {
          'macos-arm64-libfake.dylib.gz',
          'web-fake.wasm.gz',
          'web-sub__module.mjs.gz',
        });
        final web = (await WebManifest.load(package.uri))!;
        expect(web.sourceKey, native.sourceKey);
        expect(web.release, native.release);
        expect(web.runner, 'ubuntu-24.04, emsdk');
        expect(web.toolchain, 'Emscripten 5.0.0');
        expect(web.files.map((f) => (f.name, f.source)), [
          ('fake.wasm', 'release'),
          ('fake_worker.mjs', 'lib/web/fake_worker.mjs'),
          ('sub/module.mjs', 'release'),
        ]);
        expect(
          await checkPackage(packageRoot: package.uri, download: true),
          isEmpty,
        );

        // The released files install in a web build.
        await runWeb();
        expect(await installedFiles(), {
          'fake.wasm': 'wasm bytes',
          'sub/module.mjs': 'export default 1;',
          'fake_worker.mjs': worker,
        });

        // I1: a changed worker and a stale Dart file fail the check.
        await writeFiles(package, {'lib/web/fake_worker.mjs': 'changed'});
        expect(await checkPackage(packageRoot: package.uri), [
          contains('fake_worker.mjs differs from its entry'),
        ]);
        await stampWeb(packageRoot: package.uri);
        expect(await checkPackage(packageRoot: package.uri), isEmpty);
        await File.fromUri(
          package.uri.resolve(webRuntimeDartPath),
        ).writeAsString('// old');
        expect(await checkPackage(packageRoot: package.uri), [
          contains(webRuntimeDartPath),
        ]);
        await stampWeb(packageRoot: package.uri);

        // I2: a changed release asset fails the download check.
        server.files['$tag/web-fake.wasm.gz'] = gzip.encode(utf8.encode('x'));
        expect(await checkPackage(packageRoot: package.uri, download: true), [
          contains('web/fake.wasm'),
        ]);

        // I1: a source change fails the check for both manifests.
        await writeFiles(package, {'src/lib.c': 'int changed;'});
        final problems = await checkPackage(packageRoot: package.uri);
        expect(problems, hasLength(2));
        expect(problems.first, contains(webManifestPath));
      },
    );

    test(
      'release without --web fails once web.json has generated files',
      () async {
        await release(web: webBuild);
        publisher.published.clear();
        await expectLater(
          release(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('--web'),
            ),
          ),
        );
      },
    );

    test('release --web rejects a generated hand-written name', () async {
      await writeFiles(webBuild, {'fake_worker.mjs': 'x'});
      await expectLater(release(web: webBuild), throwsStateError);
    });

    test('release without web.json leaves it absent', () async {
      await File.fromUri(package.uri.resolve(webManifestPath)).delete();
      await release();
      expect(await WebManifest.load(package.uri), isNull);
    });
  });

  test('web_install installs each dependency that has web.json', () async {
    await writeWebManifest();
    await writeFiles(app, {
      '.dart_tool/package_config.json': jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'fake_native', 'rootUri': package.uri.toString()},
          {'name': 'plain', 'rootUri': app.uri.toString()},
        ],
      }),
    });
    expect(await webInstallApp(appRoot: app, cacheRoot: cache), [
      'fake_native',
    ]);
    expect((await installedFiles()).keys, hasLength(3));

    final build = await tempDir();
    await writeFiles(build, {'fake.wasm': 'local'});
    await webInstallApp(
      appRoot: app,
      cacheRoot: cache,
      local: {'fake_native': build},
    );
    expect(await installedFiles(), {
      'fake.wasm': 'local',
      'fake_worker.mjs': worker,
    });
    await expectLater(
      webInstallApp(appRoot: app, cacheRoot: cache, local: {'nope': build}),
      throwsStateError,
    );
  });
}
