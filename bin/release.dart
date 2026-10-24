import 'dart:io';

import 'package:args/args.dart';
import 'package:prebuilt/src/cli.dart';
import 'package:prebuilt/src/publisher.dart';
import 'package:prebuilt/src/release_tool.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption('package', defaultsTo: '.')
    ..addOption('repo', help: 'owner/name. Default: GITHUB_REPOSITORY.')
    ..addOption('staging', help: 'Directory for the .gz assets.')
    ..addOption(
      'web',
      help:
          'Directory of the generated web files. They go into the same '
          'release, and web.json is written (ADR 002 D3).',
    )
    ..addOption('web-runner', defaultsTo: '', help: 'Text for web.json.')
    ..addOption('web-toolchain', defaultsTo: '', help: 'Text for web.json.')
    ..addFlag('dry-run', help: 'Write the manifests, upload nothing.'),
  'dart run prebuilt:release [options] <build output dirs...>\n'
  'Uploads the files of prebuilt:build and writes prebuilt.json, '
  'and with --web also web.json.',
  (args) async {
    if (args.rest.isEmpty)
      throw StateError('Pass the build output directories.');
    await releaseTargets(
      packageRoot: packageRootOf(args),
      targetDirectories: args.rest.map(Directory.new).toList(),
      repository: repositoryOf(args),
      staging: await stagingOf(args, 'native_release_'),
      webDirectory: switch (args.option('web')) {
        final path? => Directory(path),
        null => null,
      },
      webRunner: args.option('web-runner')!,
      webToolchain: args.option('web-toolchain')!,
      publisher: args.flag('dry-run') ? null : GhPublisher(log: log),
      log: log,
    );
    return 0;
  },
);
