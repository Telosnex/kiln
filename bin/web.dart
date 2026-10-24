import 'dart:io';

import 'package:args/args.dart';
import 'package:kiln/src/cli.dart';
import 'package:kiln/src/web_tool.dart';

Future<void> main(List<String> arguments) {
  final stamp = ArgParser()
    ..addOption('package', defaultsTo: '.')
    ..addMultiOption(
      'add',
      help:
          'A hand-written file: a path, or name=path. A path in lib/web/ '
          'keeps its path below lib/web/ as name; other paths use their base '
          'name.',
      splitCommas: false,
    )
    ..addMultiOption('remove', help: 'Name of a file to remove.')
    ..addFlag('help', abbr: 'h', negatable: false);
  final installDevParser = ArgParser()
    ..addOption('package', defaultsTo: '.')
    ..addOption(
      'from',
      help:
          'A local build of the generated files. Default: download the '
          'files in web.json.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  return runCommand(
    arguments,
    ArgParser()
      ..addCommand('stamp', stamp)
      ..addCommand('install-dev', installDevParser),
    'dart run kiln:web <command> [options]\n'
    '  stamp        Update the hand-written entries of web.json, its '
    'webVersion, and lib/src/web_runtime.g.dart.\n'
    '  install-dev  Install the web files into lib/web/ for the package '
    'tests.\n'
    'Use "<command> --help" for the options of a command.',
    (args) async {
      final command = args.command;
      if (command == null) throw const FormatException('Pass a command.');
      if (command.flag('help')) {
        stdout.writeln(
          (command.name == 'stamp' ? stamp : installDevParser).usage,
        );
        return 0;
      }
      final packageRoot = packageRootOf(command);
      switch (command.name) {
        case 'stamp':
          await stampWeb(
            packageRoot: packageRoot,
            add: Map.fromEntries(command.multiOption('add').map(parseWebAdd)),
            remove: command.multiOption('remove').toSet(),
            log: log,
          );
        case 'install-dev':
          await installDev(
            packageRoot: packageRoot,
            from: switch (command.option('from')) {
              final path? => Directory(path),
              null => null,
            },
            log: log,
          );
      }
      return 0;
    },
  );
}
