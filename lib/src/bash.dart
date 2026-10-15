import 'dart:io';

/// The bash for a hook's build script.
///
/// On Windows, Git for Windows' bash. The `bash.exe` of System32 (and of
/// WindowsApps) starts WSL, a different system with its own toolchain, so
/// it is skipped even when it comes first on PATH.
String bashExecutable([Map<String, String>? environment]) {
  if (!Platform.isWindows) return 'bash';
  final env = environment ?? Platform.environment;
  for (final dir in (env['PATH'] ?? env['Path'] ?? '').split(';')) {
    final lower = dir.toLowerCase();
    if (dir.isEmpty ||
        lower.contains(r'\system32') ||
        lower.contains(r'\windowsapps')) {
      continue;
    }
    final bash = File('$dir\\bash.exe');
    if (bash.existsSync()) return bash.path;
  }
  for (final root in [
    env['ProgramFiles'] ?? env['PROGRAMFILES'],
    '${env['SYSTEMDRIVE'] ?? 'C:'}\\Program Files',
  ]) {
    if (root == null) continue;
    final git = '$root\\Git\\bin\\bash.exe';
    if (File(git).existsSync()) return git;
  }
  throw StateError(
    'A source build on Windows needs Git for Windows (Git Bash); '
    'the bash of System32 starts WSL.',
  );
}
