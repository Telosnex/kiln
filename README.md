# prebuilt

Prebuilt native libraries and web runtime files for Dart build hooks.

A package with a build hook builds its native code from source. `prebuilt` lets the package publish the output of that same hook as a GitHub release. Users then download the files and check their SHA-256, and do not compile anything. If no prebuilt file matches the source, the hook builds from source.

## Use in a build hook

```dart
import 'package:hooks/hooks.dart';
import 'package:prebuilt/prebuilt.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final prebuilt = Prebuilt(input: input, output: output);
    if (!input.config.buildCodeAssets) return prebuilt.installWeb();
    await prebuilt.run((source) => buildFromSource(input, output, source));
  });
}
```

## Commands

| Command | What it does |
|---|---|
| `dart run prebuilt:key` | Prints the source key of the package. |
| `dart run prebuilt:build` | Runs the build hook for one target and writes the release files. |
| `dart run prebuilt:release` | Uploads the files of `build` and writes `native_artifacts/prebuilt.json`. |
| `dart run prebuilt:check` | Checks the source key and each URL of the manifest. |
| `dart run prebuilt:web` | Builds, stamps and installs the web runtime files. |
| `dart run prebuilt:runtime_release` | Publishes runtime files, for example models. |
| `dart run prebuilt:flatpak` | Writes Flatpak sources for builds without network. |

## Documentation

- [ADR 001: Prebuilt native libraries](docs/ADR_001_PREBUILT_NATIVE_LIBRARIES.md)
- [ADR 002: Web runtime files](docs/ADR_002_WEB_RUNTIME_FILES.md)
- [Builds without network (Flatpak, Flathub)](docs/FLATPAK.md)
