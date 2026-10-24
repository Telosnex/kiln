import 'dart:io';

import 'package:args/args.dart';
import 'package:prebuilt/prebuilt.dart';
import 'package:prebuilt/src/cli.dart';
import 'package:prebuilt/src/release_tool.dart';

Future<void> main(List<String> arguments) => runCommand(
  arguments,
  ArgParser()
    ..addOption('target', mandatory: true, help: 'For example windows-x64.')
    ..addOption('out', mandatory: true, help: 'Directory for the files.')
    ..addOption('package', defaultsTo: '.')
    ..addOption('repo', help: 'owner/name. Default: GITHUB_REPOSITORY.')
    ..addOption(
      'runner',
      help: 'Default: ImageOS and ImageVersion, or "local".',
    )
    ..addOption('toolchain', defaultsTo: '')
    ..addMultiOption(
      'define',
      help:
          'A user define for the hook, name=value. A value that is JSON '
          '(an object, a number) is decoded.',
      splitCommas: false,
    )
    ..addOption('macos-version', defaultsTo: '$defaultMacOSVersion')
    ..addOption('ios-version', defaultsTo: '$defaultIOSVersion')
    ..addOption('android-api', defaultsTo: '$defaultAndroidApi'),
  'dart run prebuilt:build --target <target> --out <dir>\n'
  'Runs hook/build.dart with native_build: source and native_release.',
  (args) async {
    final env = Platform.environment;
    final image = [env['ImageOS'], env['ImageVersion']].nonNulls.join(' ');
    await buildTarget(
      packageRoot: packageRootOf(args),
      target: TargetName.parse(args.option('target')!),
      out: Directory(args.option('out')!),
      repository: repositoryOf(args),
      runner: args.option('runner') ?? (image.isEmpty ? 'local' : image),
      toolchain: args.option('toolchain')!,
      userDefines: {
        for (final define in args.multiOption('define')) ...parseDefine(define),
      },
      macOSVersion: int.parse(args.option('macos-version')!),
      iOSVersion: int.parse(args.option('ios-version')!),
      androidApi: int.parse(args.option('android-api')!),
      log: log,
    );
    return 0;
  },
);
