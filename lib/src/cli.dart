import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

/// Runs a command, prints usage on bad arguments, and sets the exit code.
Future<void> runCommand(
  List<String> arguments,
  ArgParser parser,
  String usage,
  Future<int> Function(ArgResults args) body,
) async {
  parser.addFlag('help', abbr: 'h', negatable: false);
  ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(usage)
      ..writeln(parser.usage);
    exitCode = 64;
    return;
  }
  if (args.flag('help')) {
    stdout
      ..writeln(usage)
      ..writeln(parser.usage);
    return;
  }
  try {
    exitCode = await body(args);
  } on StateError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 1;
  }
}

/// `--repo`, or GITHUB_REPOSITORY in GitHub Actions.
String repositoryOf(ArgResults args) {
  final repository =
      args.option('repo') ?? Platform.environment['GITHUB_REPOSITORY'];
  if (repository == null || repository.isEmpty) {
    throw StateError('Pass --repo owner/name (GITHUB_REPOSITORY is not set).');
  }
  return repository;
}

Uri packageRootOf(ArgResults args) =>
    Directory(args.option('package')!).absolute.uri;

void log(String message) => stderr.writeln('[prebuilt] $message');

/// `--staging`, or a new temporary directory.
Future<Directory> stagingOf(ArgResults args, String prefix) async =>
    switch (args.option('staging')) {
      final path? => Directory(path),
      null => await Directory.systemTemp.createTemp(prefix),
    };

/// Parses `name=value` of `--define`. A JSON value is decoded.
Map<String, Object> parseDefine(String define) {
  final i = define.indexOf('=');
  if (i <= 0) throw FormatException('Expected name=value: "$define".');
  final value = define.substring(i + 1);
  Object decoded;
  try {
    decoded = jsonDecode(value) as Object? ?? value;
  } on FormatException {
    decoded = value;
  }
  return {define.substring(0, i): decoded};
}
