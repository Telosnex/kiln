import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Defaults for the user defines of every kiln package, in
/// `<cache root>/defaults.json`:
///
/// ```json
/// {"schema": 1, "user_defines": {"native_build": "source", "host_toolchain": true}}
/// ```
///
/// A user define of the package itself wins. Hooks see only a few
/// environment variables (HOME, PATH, ...), so a build that cannot edit the
/// app's pubspec (a Flatpak manifest) sets this file instead: with HOME at a
/// build directory, the file is `$HOME/.cache/kiln/defaults.json`.
const defaultsFileName = 'defaults.json';

/// Standard user defines of ADR 001.
abstract final class StandardDefines {
  /// `auto`, `download`, or `source` (D2).
  static const nativeBuild = 'native_build';

  /// `true`: a source build uses the tools on PATH and never downloads a
  /// toolchain or a dependency. Dependencies come from pinned sources that
  /// are already in the cache (see `SourceBuild.pinnedSource`), or from the
  /// tool's own vendoring under HOME (Cargo: `$HOME/.cargo/config.toml`).
  static const hostToolchain = 'host_toolchain';
}

/// The parsed defaults file. Missing file: no defaults.
final class UserDefineDefaults {
  const UserDefineDefaults(this.values, {this.file});

  static const none = UserDefineDefaults({});

  final Map<String, Object?> values;

  /// The file the values came from, if it exists.
  final File? file;

  static Future<UserDefineDefaults> load(Directory cacheRoot) async {
    final file = File(p.join(cacheRoot.path, defaultsFileName));
    if (!await file.exists()) return none;
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw FormatException('${file.path}: ${e.message}');
    }
    if (decoded case {
      'schema': 1,
      'user_defines': final Map<String, Object?> values,
    }) {
      return UserDefineDefaults(values, file: file);
    }
    throw FormatException(
      '${file.path}: expected {"schema": 1, "user_defines": {...}}.',
    );
  }
}
