import 'dart:io';

import 'package:args/args.dart';
import 'package:kiln/src/cli.dart';
import 'package:kiln/src/publisher.dart';
import 'package:kiln/src/release_tool.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption('package', defaultsTo: '.')
    ..addOption('repo', help: 'owner/name. Default: GITHUB_REPOSITORY.')
    ..addOption('staging', help: 'Directory for the .gz assets.')
    ..addFlag('dry-run', help: 'Write the manifest, upload nothing.'),
  'dart run kiln:runtime_release [options] <files...>\n'
  'Uploads the complete set of runtime files and writes runtimeFiles and '
  '$runtimeDartPath.',
  (args) async {
    if (args.rest.isEmpty) throw StateError('Pass the runtime files.');
    await runtimeRelease(
      packageRoot: packageRootOf(args),
      files: args.rest.map(File.new).toList(),
      repository: repositoryOf(args),
      staging: await stagingOf(args, 'native_runtime_'),
      publisher: args.flag('dry-run') ? null : GhPublisher(log: log),
      log: log,
    );
    return 0;
  },
);
