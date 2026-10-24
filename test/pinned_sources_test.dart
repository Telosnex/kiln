import 'dart:convert';
import 'dart:io';

import 'package:prebuilt/prebuilt.dart';
import 'package:prebuilt/src/flatpak.dart';
import 'package:prebuilt/src/hashing.dart';
import 'package:prebuilt/src/pinned_sources.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('sources.json', () {
    test('parses git and url sources and rejects bad ones', () async {
      final root = await fakePackage(
        extra: {
          'native_artifacts/sources.json': jsonEncode({
            'schema': 1,
            'sources': [
              {
                'name': 'lib',
                'git': 'https://x/lib.git',
                'commit': 'a' * 40,
                'submodules': true,
              },
              {
                'name': 'ort',
                'url': 'https://x/ort.tgz',
                'sha256': 'b' * 64,
                'targets': ['linux-x64'],
              },
            ],
          }),
        },
      );
      final sources = await loadPinnedSources(root.uri);
      expect(sources.map((s) => s.name), ['lib', 'ort']);
      expect(sources[0].cacheDirectoryName, 'lib-${'a' * 16}');
      expect(sources[1].appliesTo('linux-arm64'), isFalse);
      expect(sources[1].fileName, 'ort.tgz');
      for (final bad in [
        {'name': 'a b', 'url': 'u', 'sha256': 'b' * 64},
        {'name': 'x', 'git': 'g', 'commit': 'main'},
        {'name': 'x', 'url': 'u', 'sha256': 'short'},
      ]) {
        expect(() => PinnedSource.fromJson(bad), throwsFormatException);
      }
    });
  });

  group('resolvePinnedSource', () {
    test('fetches a git commit once, then uses the cache', () async {
      final upstream = await tempDir();
      await writeFiles(upstream, {'a.c': 'int a;'});
      await git(upstream, ['init', '-q']);
      await git(upstream, ['add', '-A']);
      await git(upstream, ['commit', '-qm', 'one']);
      final commit = (await Process.run('git', [
        'rev-parse',
        'HEAD',
      ], workingDirectory: upstream.path)).stdout.toString().trim();
      await writeFiles(upstream, {'a.c': 'int b;'});
      await git(upstream, ['commit', '-qam', 'two']);
      // Allow fetching a commit that is not a branch head.
      await git(upstream, ['config', 'uploadpack.allowAnySHA1InWant', 'true']);

      final cache = await tempDir();
      final source = PinnedSource.fromJson({
        'name': 'up',
        'git': 'file://${upstream.path}',
        'commit': commit,
      });
      final dir = await resolvePinnedSource(
        source,
        cacheRoot: cache,
        offline: false,
      );
      expect(await File(p.join(dir.path, 'a.c')).readAsString(), 'int a;');
      // Offline now succeeds from the cache.
      expect(
        (await resolvePinnedSource(
          source,
          cacheRoot: cache,
          offline: true,
        )).path,
        dir.path,
      );
    });

    test('offline without the source names the path to fill', () async {
      final cache = await tempDir();
      final source = PinnedSource.fromJson({
        'name': 'f',
        'url': 'https://example.invalid/f.tgz',
        'sha256': 'c' * 64,
      });
      await expectLater(
        resolvePinnedSource(source, cacheRoot: cache, offline: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(p.join(cache.path, 'sources', 'f-${'c' * 16}', 'f.tgz')),
          ),
        ),
      );
    });

    test('downloads a url source and checks its sha256', () async {
      final server = await TestServer.start();
      server.files['f.tgz'] = utf8.encode('archive');
      final good = PinnedSource.fromJson({
        'name': 'f',
        'url': server.url('f.tgz'),
        'sha256': sha256OfString('archive'),
      });
      final cache = await tempDir();
      final dir = await resolvePinnedSource(
        good,
        cacheRoot: cache,
        offline: false,
      );
      expect(await File(p.join(dir.path, 'f.tgz')).readAsString(), 'archive');
      final bad = PinnedSource.fromJson({
        'name': 'g',
        'url': server.url('f.tgz'),
        'sha256': 'd' * 64,
      });
      await expectLater(
        resolvePinnedSource(bad, cacheRoot: cache, offline: false),
        throwsStateError,
      );
    });
  });

  group('defaults.json', () {
    test('loads user defines, rejects other shapes', () async {
      final cache = await tempDir();
      expect((await UserDefineDefaults.load(cache)).values, isEmpty);
      await writeFiles(cache, {
        defaultsFileName: jsonEncode({
          'schema': 1,
          'user_defines': {'native_build': 'source', 'host_toolchain': true},
        }),
      });
      final defaults = await UserDefineDefaults.load(cache);
      expect(defaults.values['native_build'], 'source');
      expect(defaults.file, isNotNull);
      await writeFiles(cache, {defaultsFileName: '{"native_build": "source"}'});
      expect(UserDefineDefaults.load(cache), throwsFormatException);
    });
  });

  group('flatpak', () {
    test('parses a Cargo.lock and vendors registry and git crates', () async {
      final dir = await tempDir();
      await writeFiles(dir, {
        'Cargo.lock':
            '''
version = 4

[[package]]
name = "app"
version = "0.1.0"
dependencies = ["mime_guess", "unicase"]

[[package]]
name = "mime_guess"
version = "2.0.4"
source = "git+https://github.com/knopp/mime_guess?branch=sne#8c9abd38a5845db2d8a91a02fee16b226c364874"

[[package]]
name = "unicase"
version = "2.7.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "${'e' * 64}"
''',
      });
      final lock = File(p.join(dir.path, 'Cargo.lock'));
      expect(parseCargoLock(await lock.readAsString()).map((c) => c.name), [
        'app',
        'mime_guess',
        'unicase',
      ]);
      final sources = await cargoVendorSources([
        lock,
      ], const FlatpakOptions(buildRoot: '/run/build/x'));
      expect(
        sources.where((s) => s['type'] == 'archive').single['url'],
        'https://static.crates.io/crates/unicase/unicase-2.7.0.crate',
      );
      final gitSource = sources.where((s) => s['type'] == 'git').single;
      expect(gitSource['url'], 'https://github.com/knopp/mime_guess');
      expect(gitSource['commit'], '8c9abd38a5845db2d8a91a02fee16b226c364874');
      final config = sources.last['contents'] as String;
      expect(config, contains('directory = "/run/build/x/cargo/vendor"'));
      expect(
        config,
        contains('[source."https://github.com/knopp/mime_guess?branch=sne"]'),
      );
      expect(config, contains('branch = "sne"'));
      expect(sources.last['dest'], 'home/.cargo');
    });

    test('source mode places pinned sources and defaults.json', () async {
      final root = await fakePackage(
        extra: {
          'native_artifacts/prebuilt.json': '{}',
          'native_artifacts/sources.json': jsonEncode({
            'schema': 1,
            'sources': [
              {'name': 'lib', 'git': 'https://x/lib.git', 'commit': 'a' * 40},
              {
                'name': 'ort',
                'url': 'https://x/ort-arm.tgz',
                'sha256': 'b' * 64,
                'targets': ['linux-arm64'],
              },
            ],
          }),
        },
      );
      final sources = await flatpakSources([
        FlatpakPackage('fake_native', root),
      ], const FlatpakOptions(fromSource: true));
      expect(sources[0], {
        'type': 'git',
        'url': 'https://x/lib.git',
        'commit': 'a' * 40,
        'disable-submodules': true,
        'dest': 'home/.cache/native_prebuilt/sources/lib-${'a' * 16}',
      });
      expect(sources[1]['only-arches'], ['aarch64']);
      expect(sources[1]['dest-filename'], 'ort-arm.tgz');
      expect(jsonDecode(sources.last['contents'] as String)['user_defines'], {
        'native_build': 'source',
        'host_toolchain': true,
      });
    });
  });
}
