# kiln example

## The build hook

`hook/build.dart` of a package with native code. `Kiln.run` downloads the
prebuilt library that matches the package sources, or builds it from source:

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

## A release

```sh
# The source key that the prebuilt files are for.
dart run kiln:key
# Build one target with the hook, then upload the files and write
# native_artifacts/prebuilt.json.
dart run kiln:build --target macos-arm64 --out build/macos-arm64
dart run kiln:release build/macos-arm64
# Check the source key and every URL of the manifest.
dart run kiln:check
```
