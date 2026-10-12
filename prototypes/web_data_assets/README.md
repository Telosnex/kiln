# Prototype: hook-supplied Flutter web JS/Wasm assets

**Result: the bundling mechanism works, but is unavailable on the tested Flutter
stable release. Do not remove production `flutter.assets` entries yet.**

This is an isolated prototype, not a change to `native_prebuilt`'s public API,
release manifests, or any dependent package. Nothing here requires Emscripten,
Docker, npm dependencies, or production source edits.

## Observed results

Tested on macOS arm64, Flutter **3.47.1 stable / 6655482ec0**, Dart **3.13.1**,
`hooks` 2.2.0 and `data_assets` 0.20.0, Chrome headless:

| Tooling / build | Hook receives data-assets support | Bundled files | Browser smoke |
| --- | --- | --- | --- |
| Unmodified stable, release JS | false | 0/8 | Not run: files missing |
| Isolated feature-gate patch, release JS | true | 8/8, byte-identical | PASS |
| Isolated feature-gate patch, release `--wasm` | true | 8/8, byte-identical | PASS |

The positive tests use the **real** image_ffmpeg and zxing_dart worker, loader,
Emscripten module, and Wasm binary. The fixture dependency has no `flutter.assets`
entries and no generated files in `lib/`. Its hook copies staged external inputs
into `input.outputDirectory` and registers eight `DataAsset`s. This offline copy
stands in for a future verified release download; it does **not** prototype the
network/cache/release plumbing.

Verified from the built Flutter app served under **`/probe/`**, not site root:

- Flutter `rootBundle` reads both JS modules and both Wasm binaries.
- Module workers import their sibling adapters/modules and instantiate Wasm.
- zxing ABI 3 encodes a nonempty 20x20 DataMatrix.
- image_ffmpeg ABI 5 encodes a 1x1 red PNG (91 bytes), then decodes it with exact
  pixel equality.
- image_ffmpeg propagates the worker's query string through to the Wasm request.
- Both normal Dart-to-JS and Dart-to-Wasm app builds pass. Browser checks use fresh
  profiles, so an earlier build's service worker/cache cannot mask missing files.

## Why stock stable fails

In Flutter's `packages/flutter_tools/lib/src/features.dart`, `dartDataAssets`
(`enable-dart-data-assets`) is available on master, not stable.
`FlutterFeatureFlags.isEnabled` in `flutter_features.dart` rejects unavailable
features **before** consulting environment/config values. This machine already
had `enable-dart-data-assets: true`, displayed as **Unavailable**.

The unmodified stable build succeeds, but the hook receives
`buildDataAssets=false` and the output omits all eight files. Merely setting
`FLUTTER_DART_DATA_ASSETS=true` or a Flutter config flag is **not** a workaround.

To test the downstream mechanism, `prepare.py --experimental-tools` copies only
Flutter's tooling sources into ignored `.work/`, enables that one gate on stable,
and runs them using the original SDK and a rewritten package configuration. It
never patches the installed SDK, changes channel, or changes global config.
**This is an artificial positive control, not a test of an official master SDK
or a supported stable deployment.**

Flutter's asset bundler maps `DataAsset(package: P, name: N, ...)` to
`assets/packages/P/N`. This preserves existing sibling-URL loading semantics.
The fixture uses `P=web_payload_probe`, `N=web/<filename>`; a real package would
use its own name and preserve today's public URLs exactly.

## Reproduce

Prerequisites: Flutter 3.47.1 SDK with initialized tooling dependencies, Python 3,
Node >=22, Chrome, and sibling `image_ffmpeg` / `zxing_dart` checkouts containing
their existing `lib/web` runtimes. Override source locations with `prepare.py`
flags and Chrome with `CHROME_EXECUTABLE` as needed.

Run from this directory:

```sh
# Negative control: installed stable SDK; no feature/config modifications.
python3 prepare.py
(cd .work/app && flutter build web --release --base-href /probe/ \
  --no-web-resources-cdn) > .work/stable.log 2>&1
python3 check_bundle.py --expect-absent

# Positive control: copy tooling and open the otherwise-unavailable feature gate.
# Preparation resets ONLY the disposable fixture app/payload/artifacts, giving
# each tool configuration a clean build. Changing the gate alone did not
# invalidate Flutter's existing build cache in the initial experiment.
python3 prepare.py --experimental-tools
(cd .work/app && ../flutter-experimental build web --release \
  --base-href /probe/ --no-web-resources-cdn) > .work/experimental.log 2>&1
python3 check_bundle.py
node browser_smoke.mjs > .work/browser-js.json

(cd .work/app && ../flutter-experimental build web --wasm --release \
  --base-href /probe/ --no-web-resources-cdn) > .work/experimental-wasm.log 2>&1
python3 check_bundle.py
node browser_smoke.mjs .work/app/build/web --expect-dart-wasm > .work/browser-wasm.json
```

`.work/inputs.json` records SDK version, source revisions and all input hashes.
All artifacts, generated apps, build caches, copied tooling and logs stay in
ignored `.work/`. Dart sources in the fixture templates have `.template` suffixes
so the parent package's analyzer doesn't treat them as production libraries;
preparation removes those suffixes in the runnable copies.

## Implication for native_prebuilt

The desired zero-extra-step path is technically viable **once the consumer's
Flutter tooling supports data assets**: download the JS/Wasm release pair into
the hook output, register it plus authored loader/worker assets, and retain
existing same-origin URLs. No runtime CDN is necessary.

For current stable users, retain checked-in/published assets and their pubspec
entries. We can independently migrate artifact production to GitHub Actions,
but release hosting alone cannot make stock stable bundle hook-generated web
files. Don't silently replace static assets with this hook on unsupported SDKs.

Still outside this prototype: official supported-SDK rollout, debug/hot reload,
web tests, non-Flutter consumers, release downloads/checksums/offline caching,
web-specific source keys, and avoiding registration on unwanted native builds.
A production migration must remove overlapping static declarations: Flutter
explicitly rejects duplicate assets declared by both pubspec and hook.
