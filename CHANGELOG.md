## 0.1.0

- First release on pub.dev. The package was named `native_prebuilt`.
- `NativePrebuilt` is now `Kiln`. Import `package:kiln/kiln.dart`. The commands are `dart run kiln:<command>`.
- Renamed files, directories and user defines:

  | Before | Now |
  |---|---|
  | `<user cache>/native_prebuilt/` | `<user cache>/kiln/` |
  | user define `native_prebuilt_cache` | `kiln_cache` |
  | `<app>/web/native_prebuilt/<package>/` | `<app>/web/kiln/<package>/` |
  | `lib/web/.native_prebuilt_web_version` | `lib/web/.kiln_web_version` |
  | `lib/src/native_prebuilt.g.dart`, `nativePrebuiltRuntimeFiles` | `lib/src/kiln.g.dart`, `prebuiltRuntimeFiles` |
  | `native_prebuilt_release.json` | `kiln_release.json` |
  | Flatpak `.native_prebuilt_downloads/` | `.kiln_downloads/` |

- A web install deletes `<app>/web/native_prebuilt/<package>/`. `web install-dev` replaces the old block in `lib/web/.gitignore`.
- The source key also skips a top-level `doc/` directory, the pub layout name for documentation.
- Release tags stay `native-<16 characters of the source key>`.
