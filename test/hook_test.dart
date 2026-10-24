import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:prebuilt/prebuilt.dart';
import 'package:prebuilt/src/hashing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final library = utf8.encode('prebuilt dylib');
  final gz = gzip.encode(library);

  late TestServer server;
  late Directory package;
  late Directory cache;

  setUp(() async {
    server = await TestServer.start();
    server.files['macos-arm64-libfake.dylib.gz'] = gz;
    package = await fakePackage();
    cache = await tempDir();
  });

  Future<void> writeManifest({String? sourceKey, int minOSVersion = 12}) async {
    final key = sourceKey ?? (await computeSourceKey(package.uri)).key;
    await PrebuiltManifest(
      sourceKey: key,
      release: null,
      targets: {
        'macos-arm64': PrebuiltTarget(
          runner: 'macos-15',
          toolchain: 'clang',
          minOSVersion: minOSVersion,
          files: [
            PrebuiltFile(
              name: 'libfake.dylib',
              sha256: sha256OfBytes(library),
              url: server.url('macos-arm64-libfake.dylib.gz'),
              downloadSha256: sha256OfBytes(gz),
              delivery: Delivery.bundle,
              asset: 'fake_native.dart',
            ),
            PrebuiltFile(
              name: 'pack.dylib',
              sha256: sha256OfBytes(library),
              url: server.url('not-downloaded.gz'),
              downloadSha256: sha256OfBytes(gz),
              delivery: Delivery.runtime,
              pack: 'gpu',
            ),
          ],
        ),
      },
    ).save(package.uri);
  }

  /// Runs the hook logic. Returns the output and whether the source build
  /// ran.
  Future<(BuildOutput, bool, PrebuiltRelease?)> run({
    Map<String, Object> defines = const {},
    int macOSVersion = 12,
    Object? sourceError,
  }) async {
    final input = await buildInput(
      package,
      defines: defines,
      macOSVersion: macOSVersion,
    );
    final output = BuildOutputBuilder();
    var built = false;
    PrebuiltRelease? release;
    await Prebuilt(input: input, output: output, cacheRoot: cache).run((
      source,
    ) async {
      final r = source.release;
      expect(source.sourceKey.key, hasLength(64));
      built = true;
      release = r;
      if (sourceError != null) throw sourceError;
      final file = File.fromUri(input.outputDirectory.resolve('libfake.dylib'));
      await file.writeAsString('source build');
      output.assets.code.add(
        CodeAsset(
          package: 'fake_native',
          name: 'fake_native.dart',
          linkMode: DynamicLoadingBundled(),
          file: file.uri,
        ),
      );
      if (r != null) {
        final pack = File.fromUri(input.outputDirectory.resolve('pack.dylib'));
        await pack.writeAsString('pack');
        r.addRuntimeFile(pack.uri, pack: 'gpu');
      }
    });
    return (output.build(), built, release);
  }

  Future<String> bundled(BuildOutput output) async {
    final assets = output.assets.code;
    expect(assets, hasLength(1));
    expect(assets.single.id, 'package:fake_native/fake_native.dart');
    return File.fromUri(assets.single.file!).readAsString();
  }

  test('auto: matching manifest publishes the prebuilt bundle file', () async {
    await writeManifest();
    final (output, built, _) = await run();
    expect(built, isFalse);
    expect(await bundled(output), 'prebuilt dylib');
    expect(server.hits['not-downloaded.gz'], isNull);
    expect(output.dependencies, contains(package.uri.resolve('src/lib.c')));
    expect(
      output.dependencies,
      contains(package.uri.resolve('native_artifacts/prebuilt.json')),
    );
  });

  test('I3, auto: a source change builds from source', () async {
    await writeManifest();
    await writeFiles(package, {'src/lib.c': 'int changed;'});
    final (output, built, release) = await run();
    expect(built, isTrue);
    expect(release, isNull);
    expect(await bundled(output), 'source build');
  });

  test('auto: no manifest builds from source', () async {
    final (_, built, _) = await run();
    expect(built, isTrue);
  });

  test('auto: an app with an older OS builds from source', () async {
    await writeManifest(minOSVersion: 13);
    final (_, built, _) = await run(macOSVersion: 12);
    expect(built, isTrue);
  });

  test('download: a source change fails', () async {
    await writeManifest(sourceKey: 'f' * 64);
    await expectLater(
      run(defines: {'native_build': 'download'}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('differ'),
        ),
      ),
    );
  });

  test('source: builds from source with a matching manifest', () async {
    await writeManifest();
    final (_, built, _) = await run(defines: {'native_build': 'source'});
    expect(built, isTrue);
  });

  test('I1: a changed cache entry is downloaded again', () async {
    await writeManifest();
    await run();
    final entry = File(
      p.join(cache.path, sha256OfBytes(library), 'libfake.dylib'),
    );
    await entry.writeAsString('changed');
    final (output, _, _) = await run();
    expect(await bundled(output), 'prebuilt dylib');
    expect(server.hits['macos-arm64-libfake.dylib.gz'], 2);
  });

  test('native_release passes release info and writes the sidecar', () async {
    final (output, built, release) = await run(
      defines: {'native_release': 'Telosnex/fake'},
    );
    expect(built, isTrue);
    final key = await computeSourceKey(package.uri);
    expect(release!.sourceKey, key.key);
    expect(
      release.assetUrl('pack.dylib'),
      'https://github.com/Telosnex/fake/releases/download/'
      'native-${key.short}/macos-arm64-pack.dylib.gz',
    );
    final assetFile = output.assets.code.single.file!;
    final sidecar =
        jsonDecode(
              File(
                p.join(p.dirname(assetFile.toFilePath()), releaseSidecarName),
              ).readAsStringSync(),
            )
            as Map;
    expect(sidecar['target'], 'macos-arm64');
    expect((sidecar['runtimeFiles'] as List).single['pack'], 'gpu');
  });

  test('a failed source build rethrows', () async {
    await expectLater(
      run(sourceError: StateError('no cmake')),
      throwsStateError,
    );
  });
}
