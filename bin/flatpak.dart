import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:prebuilt/src/cli.dart';
import 'package:prebuilt/src/flatpak.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption('app', defaultsTo: '.', help: 'App directory, after pub get.')
    ..addOption('out', mandatory: true, help: 'flatpak-builder sources JSON.')
    ..addFlag(
      'source',
      help:
          'Build every prebuilt package from source with its pinned '
          'sources (writes defaults.json). Default: place prebuilt files.',
    )
    ..addOption(
      'build-root',
      defaultsTo: '/run/build/app',
      help: 'The module build directory in the sandbox (/run/build/<module>).',
    )
    ..addOption(
      'cache-dest',
      defaultsTo: 'home/.cache/native_prebuilt',
      help:
          'The native_prebuilt cache relative to the build directory. The '
          'manifest sets HOME to match.',
    ),
  'dart run prebuilt:flatpak --out sources.json [--source]\n'
  'Writes Flatpak sources so the build hooks run without network.',
  (args) async {
    final packages = await prebuiltPackages(Directory(args.option('app')!));
    final sources = await flatpakSources(
      packages,
      FlatpakOptions(
        fromSource: args.flag('source'),
        buildRoot: args.option('build-root')!,
        cacheDest: args.option('cache-dest')!,
      ),
      log: log,
    );
    await File(
      args.option('out')!,
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(sources)}\n');
    log(
      '${sources.length} sources for ${packages.map((p) => p.name).join(', ')}',
    );
    return 0;
  },
);
