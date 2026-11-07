import 'dart:io';

import 'package:kiln/src/manifest.dart';
import 'package:kiln/src/release_tool.dart';
import 'package:kiln/src/runtime_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('dart format leaves the runtimeFilesDart output as it is', () async {
    final sha = 'a' * 64;
    final source = runtimeFilesDart(
      RuntimeFileSet(
        release: 'https://huggingface.co/acme/models',
        files: [
          RuntimeFile(
            name: 'short.onnx',
            sha256: sha,
            bytes: 12,
            url: 'https://example.com/short.onnx',
          ),
          RuntimeFile(
            name: 'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
            sha256: sha,
            bytes: 277985,
            url:
                'https://huggingface.co/acme/models/resolve/'
                '4cd3bbfa3d43d88da1ccdd41ddbf3a03baaf3979/'
                'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
            downloadSha256: 'b' * 64,
          ),
        ],
      ),
    );
    final dir = Directory.systemTemp.createTempSync('kiln_runtime_dart_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'kiln.g.dart'));
    // dart format wraps a long string argument up to language version 3.12,
    // and not from 3.13.
    for (final version in ['3.10', '3.12', '3.13']) {
      file.writeAsStringSync(source);
      final result = await Process.run(Platform.resolvedExecutable, [
        'format',
        '--language-version=$version',
        '--set-exit-if-changed',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: 'language $version: ${result.stdout}');
      expect(file.readAsStringSync(), source);
    }
  });
}
