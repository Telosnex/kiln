import 'dart:io';

import 'package:path/path.dart' as p;

/// The shared cache of ADR 001 D9: `<user cache>/native_prebuilt`.
///
/// Build hooks see only the environment variables that hooks_runner passes
/// through (HOME, USERPROFILE, LOCALAPPDATA, ...). XDG_CACHE_HOME is not one
/// of them, so a hook on Linux uses `~/.cache`.
Directory defaultCacheRoot([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  String? value(String name) {
    final v = env[name];
    return v == null || v.isEmpty ? null : v;
  }

  if (Platform.isWindows) {
    final local =
        value('LOCALAPPDATA') ??
        switch (value('USERPROFILE')) {
          final profile? => p.join(profile, 'AppData', 'Local'),
          null => null,
        };
    if (local != null) return Directory(p.join(local, 'native_prebuilt'));
  } else {
    final home = value('HOME');
    if (Platform.isMacOS && home != null) {
      return Directory(p.join(home, 'Library', 'Caches', 'native_prebuilt'));
    }
    final xdg = value('XDG_CACHE_HOME');
    if (xdg != null) return Directory(p.join(xdg, 'native_prebuilt'));
    if (home != null)
      return Directory(p.join(home, '.cache', 'native_prebuilt'));
  }
  throw StateError(
    'Cannot find a user cache directory: HOME, USERPROFILE and LOCALAPPDATA '
    'are not set.',
  );
}
