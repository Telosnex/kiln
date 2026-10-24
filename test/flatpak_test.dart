import 'dart:convert';
import 'dart:io';

import 'package:kiln/src/flatpak.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _download =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late Directory app;

  setUp(() => app = Directory.systemTemp.createTempSync('kiln_flatpak_'));
  tearDown(() => app.deleteSync(recursive: true));

  /// A package [name] with a prebuilt manifest and a pinned source, that
  /// depends on [tool].
  void addPackage(String name, String? tool) {
    final root = Directory(p.join(app.path, 'packages', name))
      ..createSync(recursive: true);
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
      'name: $name\n'
      '${tool == null ? '' : 'dependencies:\n  $tool: any\n'}',
    );
    File(p.join(root.path, 'native_artifacts', 'prebuilt.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'targets': {
            'linux-x64': {
              'files': [
                {
                  'name': 'lib$name.so',
                  'url': 'https://example.com/lib$name.so.gz',
                  'sha256': _sha,
                  'downloadSha256': _download,
                },
              ],
            },
          },
        }),
      );
    File(
      p.join(root.path, 'native_artifacts', 'sources.json'),
    ).writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'sources': [
          {
            'name': '${name}_src',
            'url': 'https://example.com/s.tgz',
            'sha256': _sha,
          },
        ],
      }),
    );
  }

  void writeConfig(List<String> names) {
    File(p.join(app.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in names)
              {'name': name, 'rootUri': '../packages/$name/'},
          ],
        }),
      );
  }

  test('each package gets the cache of the tool it depends on', () async {
    addPackage('new_pkg', 'kiln');
    addPackage('old_pkg', 'native_prebuilt');
    addPackage('plain_pkg', null);
    writeConfig(['new_pkg', 'old_pkg', 'plain_pkg']);

    final packages = await kilnPackages(app);
    expect(
      {for (final p in packages) p.name: p.tool},
      {'new_pkg': 'kiln', 'old_pkg': 'native_prebuilt', 'plain_pkg': 'kiln'},
    );

    final prebuilt = await flatpakSources(packages, const FlatpakOptions());
    final commands = [
      for (final s in prebuilt)
        if (s['type'] == 'shell') ...(s['commands'] as List).cast<String>(),
    ];
    expect(commands, [
      contains('home/.cache/kiln/$_sha/libnew_pkg.so'),
      contains('home/.cache/native_prebuilt/$_sha/libold_pkg.so'),
      contains('home/.cache/kiln/$_sha/libplain_pkg.so'),
    ]);
  });

  test('from source: pinned sources and defaults.json per cache', () async {
    addPackage('new_pkg', 'kiln');
    addPackage('old_pkg', 'native_prebuilt');
    writeConfig(['new_pkg', 'old_pkg']);

    final sources = await flatpakSources(
      await kilnPackages(app),
      const FlatpakOptions(fromSource: true),
    );
    expect(
      [
        for (final s in sources)
          if (s['type'] == 'file') s['dest'],
      ],
      [
        'home/.cache/kiln/sources/new_pkg_src-aaaaaaaaaaaaaaaa',
        'home/.cache/native_prebuilt/sources/old_pkg_src-aaaaaaaaaaaaaaaa',
      ],
    );
    expect(
      [
        for (final s in sources)
          if (s['dest-filename'] == 'defaults.json') s['dest'],
      ],
      ['home/.cache/kiln', 'home/.cache/native_prebuilt'],
    );
  });

  test('cacheDestFor keeps a custom cache directory', () {
    const options = FlatpakOptions(cacheDest: 'x/cache/kiln');
    expect(options.cacheDestFor('kiln'), 'x/cache/kiln');
    expect(options.cacheDestFor('native_prebuilt'), 'x/cache/native_prebuilt');
  });
}
