import 'dart:io';

import 'package:kiln/kiln.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  Future<String> keyOf(Directory root, {Directory? memo}) async =>
      (await computeSourceKey(root.uri, memoDirectory: memo)).key;

  test('lists included files only, sorted', () async {
    final root = await fakePackage(
      extra: {
        '.github/workflows/x.yml': 'x',
        'doc/a.txt': 'x',
        'docs/a.txt': 'x',
        'test/a_test.dart': 'x',
        'example/main.dart': 'x',
        'build/out.o': 'x',
        'pubspec.lock': 'x',
        'native_artifacts/prebuilt.json': '{}',
        'CHANGELOG.md': 'x',
        'src/notes.md': 'nested markdown is a source file',
        'src/test/vector.cc': 'nested test/ is a source directory',
        'src/.dart_tool/x': 'x',
      },
    );
    final key = await computeSourceKey(root.uri);
    expect(key.usedGit, isFalse);
    expect(key.files.map((f) => f.path), [
      'hook/build.dart',
      'pubspec.yaml',
      'src/lib.c',
      'src/notes.md',
      'src/test/vector.cc',
    ]);
  });

  test('I3: a change to an included file changes the key', () async {
    final root = await fakePackage();
    final before = await keyOf(root);
    await File(p.join(root.path, 'src/lib.c')).writeAsString('int x;\n');
    expect(await keyOf(root), isNot(before));
  });

  test('a new included file changes the key', () async {
    final root = await fakePackage();
    final before = await keyOf(root);
    await writeFiles(root, {'src/new.h': '#pragma once\n'});
    expect(await keyOf(root), isNot(before));
  });

  test('a change to an excluded file keeps the key', () async {
    final root = await fakePackage();
    final before = await keyOf(root);
    await writeFiles(root, {
      'README.md': 'changed',
      'LICENSE': 'changed',
      'lib/fake_native.dart': '// changed',
      'native_artifacts/prebuilt.json': '{"changed": true}',
      '.gitignore': 'x',
    });
    expect(await keyOf(root), before);
  });

  test('source_excludes.txt adds excludes and is itself covered', () async {
    final root = await fakePackage(extra: {'tool/bench.sh': 'echo 1'});
    final before = await keyOf(root);
    await writeFiles(root, {
      'native_artifacts/source_excludes.txt': '# comment\ntool/\n',
    });
    final withExcludes = await computeSourceKey(root.uri);
    expect(withExcludes.key, isNot(before));
    expect(
      withExcludes.files.map((f) => f.path),
      isNot(contains('tool/bench.sh')),
    );
    await writeFiles(root, {'tool/bench.sh': 'echo 2'});
    expect(await keyOf(root), withExcludes.key);
  });

  test('git listing equals a directory walk in a clean checkout', () async {
    final root = await fakePackage();
    final walked = await keyOf(root);
    await git(root, ['init', '-q']);
    await git(root, ['add', '-A']);
    await git(root, ['commit', '-qm', 'x']);
    final listed = await computeSourceKey(root.uri);
    expect(listed.usedGit, isTrue);
    expect(listed.key, walked);
  });

  test('a CRLF checkout of LF files has the key of the LF checkout', () async {
    final origin = await fakePackage();
    await git(origin, ['init', '-q']);
    await git(origin, ['add', '-A']);
    await git(origin, ['commit', '-qm', 'x']);
    final lfKey = (await computeSourceKey(origin.uri)).key;

    // A Windows-style clone: git converts LF to CRLF on checkout.
    final parent = await tempDir();
    await git(parent, [
      '-c', 'core.autocrlf=true', 'clone', '-q', origin.path, 'crlf', //
    ]);
    final clone = Directory(p.join(parent.path, 'crlf'));
    await git(clone, ['config', 'core.autocrlf', 'true']);
    final c = await File(p.join(clone.path, 'src', 'lib.c')).readAsString();
    expect(c, contains('\r\n'));
    expect((await computeSourceKey(clone.uri)).key, lfKey);

    // A real edit still changes the key.
    await writeFiles(clone, {
      'src/lib.c': 'int answer(void) { return 7; }\r\n',
    });
    expect((await computeSourceKey(clone.uri)).key, isNot(lfKey));
  });

  test('a file committed with CRLF keeps its bytes in the key', () async {
    final root = await fakePackage(extra: {'src/win.bat': 'echo hi\r\n'});
    final walked = await keyOf(root);
    await git(root, ['init', '-q']);
    await git(root, ['config', 'core.autocrlf', 'false']);
    await git(root, ['add', '-A']);
    await git(root, ['commit', '-qm', 'x']);
    expect((await computeSourceKey(root.uri)).key, walked);
  });

  test('git: ignored files do not count, new files do', () async {
    final root = await fakePackage(extra: {'.gitignore': 'src/out/\n'});
    await git(root, ['init', '-q']);
    await git(root, ['add', '-A']);
    await git(root, ['commit', '-qm', 'x']);
    final before = await keyOf(root);
    await writeFiles(root, {'src/out/generated.o': 'object'});
    expect(await keyOf(root), before);
    await writeFiles(root, {'src/extra.c': 'int y;'});
    expect(await keyOf(root), isNot(before));
  });

  test('a package in a repository that does not track it is walked', () async {
    final repo = await tempDir();
    await git(repo, ['init', '-q']);
    await writeFiles(repo, {'.gitignore': 'vendor/\n'});
    final root = Directory(p.join(repo.path, 'vendor', 'pkg'));
    await writeFiles(root, {'pubspec.yaml': 'name: pkg\n', 'src/a.c': 'x'});
    final key = await computeSourceKey(root.uri);
    expect(key.usedGit, isFalse);
    expect(key.files.map((f) => f.path), ['pubspec.yaml', 'src/a.c']);
  });

  test('the memo gives the same key and sees edits', () async {
    final root = await fakePackage();
    final memo = await tempDir();
    final plain = await keyOf(root);
    expect(await keyOf(root, memo: memo), plain);
    expect(await keyOf(root, memo: memo), plain);
    await File(p.join(root.path, 'src/lib.c')).writeAsString('int changed;\n');
    expect(await keyOf(root, memo: memo), await keyOf(root));
    expect(await keyOf(root, memo: memo), isNot(plain));
  });

  test('the key is the SHA-256 of the listing', () async {
    final root = await fakePackage();
    final key = await computeSourceKey(root.uri);
    final listing = key.files.map((f) => '${f.path}\t${f.sha256}\n').join();
    expect(key.listing, listing);
    expect(key.short, key.key.substring(0, 16));
  });
}
