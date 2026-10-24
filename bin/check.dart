import 'dart:io';

import 'package:args/args.dart';
import 'package:prebuilt/src/cli.dart';
import 'package:prebuilt/src/release_tool.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption('package', defaultsTo: '.')
    ..addFlag('download', help: 'Download and check every file.'),
  'dart run prebuilt:check [--download]\n'
  'Fails if the source key differs from the manifests, a hand-written web '
  'file differs from web.json, or a file is missing.',
  (args) async {
    final problems = await checkPackage(
      packageRoot: packageRootOf(args),
      download: args.flag('download'),
      log: log,
    );
    for (final problem in problems) {
      stderr.writeln('error: $problem');
    }
    if (problems.isEmpty) stdout.writeln('ok');
    return problems.isEmpty ? 0 : 1;
  },
);
