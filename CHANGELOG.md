## 0.1.0

- First release on pub.dev. The package was named `native_prebuilt`.
- `NativePrebuilt` is now `Prebuilt`. Import `package:prebuilt/prebuilt.dart`. The commands are `dart run prebuilt:<command>`.
- Renamed files, directories and user defines:

  | Before | Now |
  |---|---|
  | `<user cache>/native_prebuilt/` | `<user cache>/prebuilt/` |
  | user define `native_prebuilt_cache` | `prebuilt_cache` |
  | `<app>/web/native_prebuilt/<package>/` | `<app>/web/prebuilt/<package>/` |
  | `lib/web/.native_prebuilt_web_version` | `lib/web/.prebuilt_web_version` |
  | `lib/src/native_prebuilt.g.dart`, `nativePrebuiltRuntimeFiles` | `lib/src/prebuilt.g.dart`, `prebuiltRuntimeFiles` |
  | `native_prebuilt_release.json` | `prebuilt_release.json` |
  | Flatpak `.native_prebuilt_downloads/` | `.prebuilt_downloads/` |

- A web install deletes `<app>/web/native_prebuilt/<package>/`. `web install-dev` replaces the old block in `lib/web/.gitignore`.
- Release tags stay `native-<16 characters of the source key>`.
