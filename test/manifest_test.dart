import 'dart:convert';

import 'package:kiln/kiln.dart';
import 'package:test/test.dart';

final a = 'a' * 64, b = 'b' * 64, c = 'c' * 64;

Map<String, Object?> manifestJson() => {
  'schema': 1,
  'sourceKey': c,
  'release': 'https://github.com/o/r/releases/tag/native-cccccccccccccccc',
  'targets': {
    'windows-x64': {
      'runner': 'windows-2022',
      'toolchain': 'MSVC',
      'files': [
        {
          'name': 'fllama.dll',
          'sha256': a,
          'url': 'https://example.com/fllama.dll.gz',
          'downloadSha256': b,
          'delivery': 'bundle',
          'asset': 'fllama_bindings_generated.dart',
        },
        {
          'name': 'ggml-vulkan.dll',
          'sha256': a,
          'url': 'https://example.com/ggml-vulkan.dll.gz',
          'downloadSha256': b,
          'delivery': 'runtime',
          'pack': 'vulkan',
        },
      ],
    },
  },
};

void main() {
  test('round trip', () {
    final manifest = PrebuiltManifest.fromJson(manifestJson());
    expect(manifest.targets['windows-x64']!.files[1].pack, 'vulkan');
    expect(jsonDecode(manifest.encode()), manifestJson());
  });

  test('rejects invalid manifests', () {
    void rejects(void Function(Map<String, Object?> json) change, String why) {
      final json =
          jsonDecode(jsonEncode(manifestJson())) as Map<String, Object?>;
      change(json);
      expect(
        () => PrebuiltManifest.fromJson(json),
        throwsFormatException,
        reason: why,
      );
    }

    Map<String, Object?> file(Map<String, Object?> json, int i) =>
        ((json['targets'] as Map)['windows-x64'] as Map)['files'][i]
            as Map<String, Object?>;

    rejects((j) => j['schema'] = 2, 'schema');
    rejects((j) => j['sourceKey'] = 'abc', 'source key');
    rejects((j) => (j['targets'] as Map)['windows-amd64'] = {}, 'target name');
    rejects((j) => file(j, 0)['url'] = 'http://example.com/x', 'http');
    rejects((j) => file(j, 0)['name'] = '../x.dll', 'path in name');
    rejects((j) => file(j, 0).remove('asset'), 'bundle without asset');
    rejects((j) => file(j, 1)['asset'] = 'x', 'runtime with asset');
    rejects((j) => file(j, 1)['name'] = 'fllama.dll', 'duplicate name');
    rejects((j) => file(j, 0)['sha256'] = 'A' * 64, 'uppercase hex');
    for (final bad in [true, -1, '12.x', '1.2.3.4', '']) {
      rejects((j) => target(j)['minOSVersion'] = bad, 'minOSVersion $bad');
    }
  });

  test('minOSVersion: an int, or a string with a minor version', () {
    for (final (json, version) in [
      (12, const OSVersion(12)),
      ('12.3', const OSVersion(12, 3)),
      ('12.3.1', const OSVersion(12, 3, 1)),
      ('13.0', const OSVersion(13)),
    ]) {
      final manifest = PrebuiltManifest.fromJson(
        manifestJson()
          ..['targets'] = {
            'macos-arm64': {...target(manifestJson()), 'minOSVersion': json},
          },
      );
      final read = manifest.targets['macos-arm64']!.minOSVersion;
      expect(read, version);
      // A whole version stays an int, as kiln 0.1 wrote and reads it.
      expect(read!.toJson(), version.minor == 0 ? version.major : '$version');
    }
  });

  test('OSVersion order and text', () {
    expect(const OSVersion(12, 3) < const OSVersion(12, 10), isTrue);
    expect(const OSVersion(12, 9, 9) < const OSVersion(13), isTrue);
    expect(const OSVersion(13) < const OSVersion(13), isFalse);
    expect(OSVersion.parse('14'), const OSVersion(14));
    expect('${const OSVersion(14, 0, 1)}', '14.0.1');
    expect('${const OSVersion(14, 2)}', '14.2');
  });
}

Map<String, Object?> target(Map<String, Object?> json) =>
    (json['targets'] as Map)['windows-x64'] as Map<String, Object?>;
