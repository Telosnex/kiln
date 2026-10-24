import 'dart:io';

import 'package:args/args.dart';
import 'package:kiln/src/cli.dart';
import 'package:kiln/src/web_tool.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption(
      'web-root',
      defaultsTo: '.',
      help: 'The app directory that contains web/.',
    )
    ..addMultiOption(
      'local',
      help: 'package=dir: use a local build of the generated files.',
      splitCommas: false,
    ),
  'dart run kiln:web_install [options]\n'
  'Installs the web files of each dependency that has web.json into '
  'web/kiln/, as the build hooks do (ADR 002 D9).',
  (args) async {
    final local = <String, Directory>{};
    for (final spec in args.multiOption('local')) {
      final i = spec.indexOf('=');
      if (i <= 0) throw FormatException('Expected package=dir: "$spec".');
      local[spec.substring(0, i)] = Directory(spec.substring(i + 1));
    }
    final installed = await webInstallApp(
      appRoot: Directory(args.option('web-root')!),
      local: local,
      log: log,
    );
    stdout.writeln(
      installed.isEmpty
          ? 'No dependency has web files.'
          : 'Installed: ${installed.join(', ')}',
    );
    return 0;
  },
);
