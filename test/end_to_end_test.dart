@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:kiln/kiln.dart';
import 'package:kiln/src/hashing.dart';
import 'package:kiln/src/publisher.dart';
import 'package:kiln/src/release_tool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

/// Records uploads. The test server then serves them.
final class FakePublisher implements Publisher {
  FakePublisher(this.server);

  final TestServer server;
  final published = <String, Map<String, String>>{};
  var publishCount = 0;
  final latestByTag = <String, bool>{};

  @override
  Future<void> publish({
    required String repository,
    required String tag,
    required List<File> assets,
    required String notes,
    required bool latest,
  }) async {
    if (published.containsKey(tag)) throw StateError('exists');
    publishCount++;
    latestByTag[tag] = latest;
    published[tag] = {};
    for (final asset in assets) {
      final bytes = await asset.readAsBytes();
      server.files['$tag/${p.basename(asset.path)}'] = bytes;
      published[tag]![p.basename(asset.path)] = sha256OfBytes(bytes);
    }
  }

  @override
  Future<Map<String, String>?> publishedAssetDigests({
    required String repository,
    required String tag,
  }) async => published[tag];
}

const hookSource = r'''
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:kiln/kiln.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    await Kiln(input: input, output: output).run((source) async {
      final release = source.release;
      final name = input.config.code.targetOS.dylibFileName('fake');
      final file = File.fromUri(input.outputDirectory.resolve(name));
      await file.writeAsString(
        'source build; pack ${release?.assetUrl('pack.bin')}',
      );
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'fake.dart',
          linkMode: DynamicLoadingBundled(),
          file: file.uri,
        ),
      );
      if (release != null) {
        final pack = File.fromUri(input.outputDirectory.resolve('pack.bin'));
        await pack.writeAsString('gpu pack');
        release.addRuntimeFile(pack.uri, pack: 'gpu');
      }
    });
  });
}
''';

void main() {
  late Directory package;
  late TestServer server;
  late FakePublisher publisher;
  late Directory cache;
  final target = TargetName.parse('macos-arm64');

  setUp(() async {
    server = await TestServer.start();
    publisher = FakePublisher(server);
    cache = await tempDir();
    package = await tempDir();
    final self = Directory.current.absolute.path;
    await writeFiles(package, {
      'pubspec.yaml':
          'name: fake_native\n'
          'environment:\n  sdk: ^3.10.0\n'
          'dependencies:\n'
          '  code_assets: any\n  hooks: any\n'
          '  kiln:\n    path: ${jsonEncode(self)}\n',
      'hook/build.dart': hookSource,
      'src/fake.c': 'int fake(void) { return 1; }\n',
      '.gitignore': '.dart_tool/\npubspec.lock\n',
    });
    final pubGet = await Process.run(Platform.resolvedExecutable, [
      'pub', 'get', '--offline', //
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
    await git(package, ['init', '-q']);
    await git(package, ['add', '-A']);
    await git(package, ['commit', '-qm', 'fixture']);
  });

  Future<String> runAndRead(Map<String, Object> defines) async {
    final (_, output) = await runHook(
      packageRoot: package.uri,
      packageName: 'fake_native',
      target: target,
      defines: {'kiln_cache': cache.path, ...defines},
    );
    return File.fromUri(output.assets.code.single.file!).readAsString();
  }

  test('build, release, check, then download in a hook', () async {
    final out = Directory(p.join((await tempDir()).path, 'macos-arm64'));
    await buildTarget(
      packageRoot: package.uri,
      target: target,
      out: out,
      repository: 'Telosnex/fake',
      runner: 'test',
    );
    final description =
        jsonDecode(
              File(p.join(out.path, targetDescriptionName)).readAsStringSync(),
            )
            as Map;
    final key = await computeSourceKey(package.uri);
    expect(description['sourceKey'], key.key);
    expect(description['minOSVersion'], defaultMacOSVersion);
    final files = (description['files'] as List).cast<Map>();
    expect(files.map((f) => f['name']), ['libfake.dylib', 'pack.bin']);
    expect(files.first['asset'], 'fake.dart');
    expect(files.last['delivery'], 'runtime');
    expect(
      File(p.join(out.path, 'libfake.dylib')).readAsStringSync(),
      contains('releases/download/native-${key.short}/macos-arm64-pack.bin.gz'),
    );

    final manifest = await releaseTargets(
      packageRoot: package.uri,
      targetDirectories: [out.parent],
      repository: 'Telosnex/fake',
      staging: await tempDir(),
      publisher: publisher,
      assetUrl: (tag, asset) => server.url('$tag/$asset'),
    );
    expect(publisher.publishCount, 1);
    // A package release is the latest release.
    expect(publisher.latestByTag.values.single, true);
    expect(manifest.sourceKey, key.key);
    expect(manifest.targets.keys, ['macos-arm64']);

    // The manifest does not change the key.
    expect((await computeSourceKey(package.uri)).key, key.key);
    expect(
      await checkPackage(packageRoot: package.uri, download: true),
      isEmpty,
    );

    // auto and download: the hook publishes the release build, and does not
    // download the runtime file.
    final packPath = 'native-${key.short}/macos-arm64-pack.bin.gz';
    final packHits = server.hits[packPath];
    expect(await runAndRead({}), contains('source build; pack https://'));
    expect(
      await runAndRead({'native_build': 'download'}),
      contains('source build; pack https://'),
    );
    expect(server.hits[packPath], packHits);

    // A local change: auto builds from source, download fails, check fails.
    await writeFiles(package, {'src/fake.c': 'int fake(void) { return 2; }\n'});
    expect(await runAndRead({}), 'source build; pack null');
    await expectLater(
      runAndRead({'native_build': 'download'}),
      throwsStateError,
    );
    expect(await checkPackage(packageRoot: package.uri), [
      contains('differs from the manifest key'),
    ]);
  });

  test(
    'iOS release default serves Flutter hooks that request iOS 13',
    () async {
      final ios = TargetName.parse('ios-arm64-iphoneos');
      final out = Directory(p.join((await tempDir()).path, ios.name));
      await buildTarget(
        packageRoot: package.uri,
        target: ios,
        out: out,
        repository: 'Telosnex/fake',
        runner: 'test',
      );
      final manifest = await releaseTargets(
        packageRoot: package.uri,
        targetDirectories: [out],
        repository: 'Telosnex/fake',
        staging: await tempDir(),
        publisher: publisher,
        assetUrl: (tag, asset) => server.url('$tag/$asset'),
      );
      expect(manifest.targets[ios.name]!.minOSVersion, 13);
      final released = await File(
        p.join(out.path, 'libfake.dylib'),
      ).readAsString();
      expect(released, contains('source build; pack https://'));

      // Flutter requests 13 even when the app deployment target is 15.
      // A source fallback writes "pack null", not these release bytes.
      for (final mode in ['auto', 'download']) {
        final (_, output) = await runHook(
          packageRoot: package.uri,
          packageName: 'fake_native',
          target: ios,
          iOSVersion: 13,
          defines: {'native_build': mode, 'kiln_cache': cache.path},
        );
        expect(
          await File.fromUri(output.assets.code.single.file!).readAsString(),
          released,
        );
      }
    },
  );

  test('runtime release writes the section and the Dart file', () async {
    final dir = await tempDir();
    await writeFiles(dir, {'b.onnx': 'model b', 'a.onnx': 'model a'});
    Future<RuntimeFileSet> release() => runtimeRelease(
      packageRoot: package.uri,
      files: [
        File(p.join(dir.path, 'b.onnx')),
        File(p.join(dir.path, 'a.onnx')),
      ],
      repository: 'Telosnex/fake',
      staging: Directory(p.join(dir.path, 'staging')),
      publisher: publisher,
      assetUrl: (tag, asset) => server.url('$tag/$asset'),
    );
    final set = await release();
    expect(set.files.map((f) => f.name), ['a.onnx', 'b.onnx']);
    expect(set.files.first.bytes, 7);
    final manifest = await PrebuiltManifest.load(package.uri);
    expect(manifest!.runtimeFiles!.files, hasLength(2));
    final dart = File.fromUri(package.uri.resolve(runtimeDartPath));
    expect(dart.readAsStringSync(), contains("'a.onnx': RuntimeFile("));

    // The same set again reuses the published release.
    final again = await release();
    expect(publisher.publishCount, 1);
    // Runtime files never take the latest label.
    expect(publisher.latestByTag.values.single, false);
    expect(
      again.files.map((f) => f.downloadSha256),
      set.files.map((f) => f.downloadSha256),
    );
    expect(
      await checkPackage(packageRoot: package.uri, download: true),
      isEmpty,
    );
  });
}
