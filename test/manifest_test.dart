import 'dart:convert';

import 'package:prebuilt/prebuilt.dart';
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
  });
}
