import 'dart:io';

import 'package:args/args.dart';
import 'package:prebuilt/prebuilt.dart';
import 'package:prebuilt/src/cli.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption('package', defaultsTo: '.')
    ..addFlag('list', help: 'Print the hashed lines (compare them with diff).'),
  'dart run prebuilt:key [--list]\nPrints the source key (ADR 001 D3).',
  (args) async {
    final key = await computeSourceKey(packageRootOf(args));
    if (args.flag('list')) stdout.write(key.listing);
    stdout.writeln(key.key);
    stderr.writeln(
      '${key.files.length} files, listed by ${key.usedGit ? 'git' : 'a directory walk'}',
    );
    return 0;
  },
);
