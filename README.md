# kiln

Prebuilt native libraries and web runtime files for Dart build hooks.

A package with a build hook builds its native code from source. `kiln` lets the package publish the output of that same hook as a GitHub release. Users then download the files and check their SHA-256, and do not compile anything. If no prebuilt file matches the source, the hook builds from source.

## Use in a build hook

```dart
import 'package:hooks/hooks.dart';
import 'package:kiln/kiln.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final kiln = Kiln(input: input, output: output);
    if (!input.config.buildCodeAssets) return kiln.installWeb();
    await kiln.run((source) => buildFromSource(input, output, source));
  });
}
```

## Commands

| Command | What it does |
|---|---|
| `dart run kiln:key` | Prints the source key of the package. |
| `dart run kiln:build` | Runs the build hook for one target and writes the release files. |
| `dart run kiln:release` | Uploads the files of `build` and writes `native_artifacts/prebuilt.json`. |
| `dart run kiln:check` | Checks the source key and each URL of the manifest. |
| `dart run kiln:web` | Builds, stamps and installs the web runtime files. |
| `dart run kiln:runtime_release` | Publishes runtime files, for example models. |
| `dart run kiln:flatpak` | Writes Flatpak sources for builds without network. |

## Documentation

- [ADR 001: Prebuilt native libraries](docs/ADR_001_PREBUILT_NATIVE_LIBRARIES.md)
- [ADR 002: Web runtime files](docs/ADR_002_WEB_RUNTIME_FILES.md)
- [Builds without network (Flatpak, Flathub)](docs/FLATPAK.md)
