# ADR 002 — Web runtime files built by Actions and installed by the package hook
Status: ACCEPTED (2026-10-12)

This ADR extends ADR 001 to web files. ADR 001 NG2 excluded them. The
reopen condition of NG2 is true now: each web build needs a toolchain
that a web developer does not have (§1, item 5).

## 1. Problem

Four Telosnex packages ship web runtime files: WebAssembly modules, their
Emscripten glue, and JavaScript workers and loaders. ADR 001 automated the
native libraries of these packages. The web files have no automation:

| Package | Generated web files | Producer now | Delivery to Telosnex |
|---------|--------------------|--------------|----------------------|
| zxing_dart | `lib/web/zxing_dart_module.{mjs,wasm}`, 1.3 MB | `tool/build_web.sh` on a Mac, Emscripten 5.0.0 | `flutter.assets` |
| image_ffmpeg | `lib/web/image_ffmpeg_module.{mjs,wasm}`, 2.6 MB | three `tool/build_*web.sh` scripts on a Mac, Emscripten 5.0.0 | `flutter.assets` |
| fllama | `assets/web/wllama/**`, 9.0 MB | upstream wllama `766d28e` plus a patch, built with Docker `emscripten/emsdk:4.0.20`, copied by hand (fllama `RUNBOOK_WEB_RUNTIME.md`) | `flutter.assets`, plus a script tag in the Telosnex `web/index.html` |
| fonnx | `lib/web/ort*.{mjs,wasm}`, 13.5 MB | extracted from the `onnxruntime-web` 1.27.0 npm tarball | **none**: copies in the Telosnex `web/` directory |

These facts follow:

1. **Flutter stable does not bundle data assets from a build hook.** In
   `flutter_tools/lib/src/features.dart:215`, the `dartDataAssets` feature is
   available only on the master channel. On Flutter 3.47.1 stable, a prototype
   hook ran and its eight data assets were absent from `build/web`. With the
   gate enabled in a copy of the tool, all eight files were bundled, and a
   Chrome test passed for the JS and the Wasm builds
   (`prototypes/web_data_assets`).
2. **On Flutter stable, a hook can write files into the app `web/`
   directory, and the web build ships them.** A probe on Flutter 3.47.1
   (`/tmp/hook_web_probe`) had a dependency hook copy the four zxing web
   files into `<app>/web/hook_probe/`. Results:

   | Case | Result |
   |------|--------|
   | Clean `flutter build web`, JS and `--wasm` | Hook ran. All four files were in `build/web`, byte-identical. |
   | Rebuild, no change | Hook did not run. Files stayed. |
   | Written files deleted, rebuild | Hook ran and wrote them again. |
   | Source file changed, rebuild | Hook ran. `build/web` had the new file. |
   | `flutter run -d web-server` | Hook ran. Worker and `.wasm` file: HTTP 200, new content, `application/wasm`. |

   The order is in the tool. `WebReleaseBundle` depends on
   `LinkHooks(platform: HookPlatform.web)`, which depends on the build hooks,
   and its build action then copies `web/`
   (`build_system/targets/web.dart:581-672`). In debug,
   `isolated/web_asset_server.dart:535` reads `web/` from disk for each
   request. A web build gives the hook an empty `buildAssetTypes` list.
   Native builds request code assets (ADR 001).
3. **The fonnx web runtime in Telosnex is old.** Telosnex `web/` holds hand
   copies. `whisper_worker.js` imports ORT 1.17.1. Five other workers import
   ORT 1.21.0. `minishlab_worker.js` imports ORT 1.19.0 from
   `cdn.jsdelivr.net`. fonnx pins ORT 1.27.0. A `pub upgrade` of fonnx does not
   change any of these files.
4. **Telosnex lists package files by name.** `web/index.html` imports seven
   fonnx init scripts and `assets/packages/fllama/assets/web/fllama_web_init.js`.
   `dev/ci/build_web.sh` rewrites the `?v=` query of each of these imports.
5. **Only a Mac with a sibling `../emsdk` can build the zxing and
   image_ffmpeg web files.** Both scripts source `../emsdk/emsdk_env.sh`. The
   zxing script calls `sysctl -n hw.ncpu`, which does not exist on Linux. The
   wllama `scripts/build_wasm.sh` has `set -e` commented out, so a failed
   step does not stop the build.
6. **Nothing binds a web file to its sources.** zxing_dart and image_ffmpeg
   exclude `tool/build_web.sh` from the source key (their
   `native_artifacts/source_excludes.txt`). fllama keeps its wllama patch in
   `docs/`, which the source key excludes by default. A changed C++ source
   gets a new native release, and the old Wasm file stays in git with no
   error.
7. **Package web URLs do not change when their contents change.** The zxing
   worker URL has no query. image_ffmpeg appends its ABI version, which
   changes only with the ABI. app.telosnex.com sends no `Cache-Control` header
   for `.js`, `.mjs` or `.wasm` files (`dev/ci/htaccessAppTelosnexCom`). A
   browser can therefore use a cached old file after a deploy (inferred, not
   reproduced). zxing and image_ffmpeg then fail with an ABI mismatch error.

**Outcome.** A `flutter pub upgrade` of a package gives Telosnex web the web
runtime of that package commit. GitHub Actions builds the generated web files
from the package sources, in the same release workflow and the same merge as
the native libraries. The package build hook installs the files into the app
at build time. Git holds no generated web file. The Telosnex release fails if
a shipped web file does not match its package commit.

## 2. Requirements

| ID | Requirement | Source | Hardness |
|----|-------------|--------|----------|
| R1 | After `flutter pub upgrade <package>`, the Telosnex web build uses the web runtime files of the resolved package commit. Telosnex needs no other change. | founder | hard |
| R2 | Delivery works on the Flutter stable version that Telosnex uses (3.47.1 now). | platform | hard |
| R3 | Package web runtime files load from the app origin. The app sets `Cross-Origin-Embedder-Policy: require-corp` for threaded Wasm, and its CSP draft allows scripts only from `'self'`. | platform | hard |
| R4 | GitHub Actions makes every generated web file from the package sources. No developer machine makes a released generated file. | founder, for the Telosnex packages; the package workflows own it (D10) | hard |
| R5 | A Telosnex release fails if a shipped package web file does not come from the sources of the resolved package commit. | founder, for the Telosnex packages | hard |
| R6 | After a deploy, a browser does not run a package web file from an earlier deploy. | founder, for the Telosnex packages | hard |
| R7 | Package repositories hold no generated web file (ADR 001 R7). | ADR 001 | soft |
| R8 | A developer can change web sources and test the result locally, without a release. | founder, for the Telosnex packages | soft |

## 3. Decisions

D1 to D9 and D13 are what native_prebuilt does. D10 is what it recommends to
a package release workflow; native_prebuilt does not check it. D11 is the
Telosnex adoption plan, with the choices of each package.

```
D1: The build hook of each package installs the web runtime files of the
    package into <app>/web/native_prebuilt/<package>/, for a web build.
    The web build then copies them to build/web like any web/ file (§1.2).
    The hook writes <app>/web/native_prebuilt/.gitignore with the content
    "*", so the app repository needs no change.
    Because: R1, R2, R3, R7
    Instead of: hook data assets. Flutter stable does not bundle them
    (§1.1, NG1).
    Instead of: generated files in git, delivered with flutter.assets.
    They fail R7. Each change of a 13.5 MB file adds a permanent copy.
    Instead of: an app command before each web build (fallback, D9). It
    needs a change in each app and in each developer workflow (R1).
    Instead of: a download from GitHub Releases at runtime. The files are
    then cross-origin (R3).
    Cost: the hook writes outside its output directory. This breaks the
    hook contract. Flutter can block it in a future version, with no
    warning. I4 finds that case, and D9 is the fallback.

D2: The hook writes web files only when the build requests no code assets
    (input.config.buildCodeAssets is false). It finds the app as the
    parent of the .dart_tool directory that holds outputDirectoryShared.
    The user define web_root overrides this path, for a pub workspace. The
    hook replaces the directory of its package as a whole: it writes to a
    temporary directory beside it, then renames it. It declares each file
    that it writes, and web.json, as hook dependencies.
    Because: R1. The declared dependencies make the hook run again when a
    file is deleted or changed (§1.2).
    Instead of: a check of buildAssetTypes for a web type. A web build
    sends an empty list (§1.2).

D3: The command `release --web <dir>` adds the web files to the native
    release. It hashes each generated file in <dir>, uploads it to
    native-<key>, and writes native_artifacts/web.json beside prebuilt.json
    in the native-manifest/<tag> branch. The merge of that branch releases
    native and web files together. native_prebuilt does not build the
    files and does not check how they were built. The runner and toolchain
    fields of web.json are text that the package workflow passes.
    Because: R1, R5
    Instead of: a separate web workflow and branch. Two merges can release
    native and web files from different sources.
    Instead of: a build command in native_prebuilt that runs a package
    script. The builds differ: CMake, an FFmpeg configure script, an npm
    tarball. A directory of files is the whole interface.

D4: The hook gets the generated files in one of two modes, set by the user
    define web_build:
    - download (default): it downloads each file from the release in
      web.json, into the native_prebuilt cache, and verifies its SHA-256.
      If the web.json source key differs from the local source key, the
      hook fails with a message that names the mismatch.
    - local: it copies the files from the directory in the user define
      web_build_dir, which holds the generated files at their web.json
      names. It does not verify hashes.
    The hook copies the hand-written files from the package source in both
    modes.
    Because: R5 (download), R8 (local)
    Instead of: an automatic local build when the keys differ, as native
    mode auto does. A web build needs Emscripten, which a web developer
    does not have (NG2).

D5: The package source key (ADR 001 D3) covers the web build inputs. Each
    package removes its web build scripts from source_excludes.txt and keeps
    its web pins in files that the key covers. Hand-written web files stay
    outside the key, because no build reads them.
    Because: R5
    Instead of: a second key for web files. Two keys need two comparisons,
    and a package can release one without the other. Cost of one key: a
    change to a web input rebuilds all native targets, and a change to a
    native input rebuilds the web files. Both cost CI time only.

D6: web.json lists every installed web file of the package: generated and
    hand-written. For each file it has the path, the SHA-256 and the size.
    It also has the source key, the release and the toolchain.
    native_prebuilt:check fails if the source key differs from the local key,
    or if a hand-written file differs from its entry. Telosnex already runs
    this check for each package (ADR 001 D10). `native_prebuilt:web stamp`
    updates the hand-written entries. Only the release workflow writes the
    generated entries.
    Because: R5
    Instead of: entries for the generated files only. Then a changed worker
    keeps its old version string (D7, R6).

D7: Each package loads every web runtime file with the query
    ?v=<webVersion>. webVersion is a hash over the web.json file entries
    (§5). A generated Dart constant holds it. The package loader passes the
    query to the files that it loads in turn, including the .wasm file.
    Because: R6
    Instead of: a Cache-Control header on app.telosnex.com. It is specific to
    one host, and each page load then checks 26 MB of files with the server.
    Instead of: the ABI version (image_ffmpeg now). It does not change for a
    fix that keeps the ABI.

D8: Each package loads its web runtime from Dart at first use, from
    native_prebuilt/<package>/ relative to the document base URI. Packages
    remove their web files from flutter.assets. An app adds no file to
    web/ and no tag to index.html for a package runtime. fonnx and fllama
    change to do this.
    Because: R1
    Instead of: script tags in the app. Each new or renamed package file
    then needs an app change (§1.4), and fonnx shows the result (§1.3).

D9: Fallback: the command `dart run native_prebuilt:web_install`, run in the
    app, does the same install as the hook, for each dependency that has
    web.json. The hook and the command call one library function. If I4
    fails after a Flutter upgrade, Telosnex adds the command to
    dev/ci/build_web.sh and to its web run scripts. Packages do not change.
    Because: R1, R2 if Flutter blocks D1.
    Instead of: a return to generated files in git (R7).

D10: Recommended package release workflow. native_prebuilt checks none of
    this:
    - Build the generated files in the release workflow, not on a
      developer machine (R4).
    - Pin the toolchain, for example a container image by digest, so a
      rebuild uses the same tools.
    - Run `web install-dev --from` on the build output, then the package
      browser tests, before `release --web`.
    Because: R4, and risk 1. Only the package knows its build and tests.
    Instead of: a required toolchain or runner. native_prebuilt receives
    a directory of files (D3) and cannot see how they were made.

D13: The command `dart run native_prebuilt:web install-dev [--from <dir>]`,
    run in a package, installs its web files into its lib/web/ for the
    package's own tests. Without --from, it downloads the generated files
    in web.json and verifies them, as download mode does. With --from, it
    copies a local build and does not verify hashes, as local mode does.
    It adds the generated names to lib/web/.gitignore and writes the
    installed webVersion to lib/web/.native_prebuilt_web_version. It runs
    no tests. The package selects its browsers and compilers, or has no
    browser tests.
    Because: R4, R8. A package test cannot use D2, because `dart test -p
    chrome` runs the hook as a host code-asset build (risk 7).
    Instead of: tool/test_web.sh in each package. native_prebuilt cannot
    make a package script install the files first.
    Instead of: a command that also runs `dart test`. The test set is a
    package decision.

D11: Adoption order: zxing_dart, fonnx, image_ffmpeg, fllama.
    zxing_dart has one small build and 24 browser tests for each of JS and
    Wasm, so it tests the flow with the least risk. fonnx is next, because
    its Telosnex files are the oldest (§1.3). image_ffmpeg adds the FFmpeg
    and libaom Wasm builds. fllama adds an upstream build.
    Each package follows D10. Its build choices:
    - zxing_dart and image_ffmpeg: a Dart web build script (AGENTS.md
      rule), run in emscripten/emsdk:5.0.0 pinned by digest. The Linux
      output passes the zxing browser tests (§B).
    - fllama: wllama at a pinned commit, with its patch, in the emsdk
      image that wllama selects, pinned by digest.
    - fonnx: no compile. The job extracts the files from the npm tarball
      whose SHA-256 fonnx pins.
    Taste, with the reason given.
```

## 4. Invariants

```
I1: At each commit on the main branch of a package, the web.json source key
    equals the source key of that commit, and each hand-written file has
    its recorded SHA-256.
    If violated: the hook fails in download mode, or Telosnex ships a web
    runtime that does not match the Dart code of that commit.
    Pinned by: native_prebuilt:check, on each pull
    request that changes a manifest, once a day on main, and in the Telosnex
    release (ADR 001 D10).

I2: Each generated entry in web.json names a file in the immutable release
    of its source key, with the same SHA-256.
    If violated: the hook fails for every user of that commit.
    Pinned by: native_prebuilt:check --download, in the
    native-manifest pull request.

I3: Every request that a package makes for a web runtime file has the query
    ?v=<webVersion> of that package.
    If violated: a browser can use an old cached file after a deploy (R6).
    Pinned by: a browser test in each package that records the requests,
    as browser_smoke.mjs in the prototype does (planned).

I4: A Telosnex web build contains, under native_prebuilt/<package>/, each
    web.json file of each resolved package, with its SHA-256.
    If violated: Flutter no longer runs the hook before it copies web/, or
    the hook failed silently. The web build has missing or old files (D1).
    Pinned by: checkWebRuntimeFiles in dev/ci/releases/native_prebuilt.dart,
    which release.dart runs after the web build.
```

## 5. Formats & names

Manifest: `native_artifacts/web.json` in each package. The source key excludes
it, as it excludes `prebuilt.json`.

```json
{
  "schema": 1,
  "sourceKey": "<64 hex>",
  "release": "https://github.com/Telosnex/zxing_dart/releases/tag/native-<16 hex>",
  "runner": "ubuntu-24.04, emscripten/emsdk@sha256:<64 hex>",
  "toolchain": "Emscripten 5.0.0 (a7c5deabd7c88ba1c38ebe988112256775f944c6)",
  "webVersion": "<16 hex>",
  "files": [
    {"name": "zxing_dart_module.wasm", "sha256": "<64 hex>", "bytes": 1330977, "source": "release",
     "url": "https://github.com/Telosnex/zxing_dart/releases/download/native-<16 hex>/web-zxing_dart_module.wasm.gz",
     "downloadSha256": "<64 hex>"},
    {"name": "zxing_dart_worker.mjs", "sha256": "<64 hex>", "bytes": 1761, "source": "lib/web/zxing_dart_worker.mjs"}
  ]
}
```

- `name`: the path under `web/native_prebuilt/<package>/`, with `/`.
- `source: "release"`: a generated file. The release asset is the gzip of
  the file, named `web-<name with "/" replaced by "__">.gz`. `url` is the
  asset URL, and `downloadSha256` is the SHA-256 of the gzip. The hook
  downloads `url`, verifies `downloadSha256`, unpacks, and verifies
  `sha256`. Only the release workflow changes the entry.
- `source: <path>`: a hand-written file at that path in the package.
  `native_prebuilt:web stamp` changes the entry.

`webVersion`: the first 16 hex of the SHA-256 over the lines
`<name>\t<sha256>\n`, sorted by name, of all entries in `files`.

Generated Dart file: `lib/src/web_runtime.g.dart`, with
`const webRuntimeVersion = '<16 hex>';`. The release workflow and
`web stamp` write it. The source key excludes `lib/`.

Install directory in the app: `web/native_prebuilt/<package>/`. The browser
URL is `native_prebuilt/<package>/<name>?v=<webVersion>`, relative to the
document base URI. The name avoids `packages/`, which the debug server uses
for Dart sources.

User defines, under `hooks.user_defines.<package>` in the app pubspec:

| Key | Values | Default |
|-----|--------|---------|
| `web_build` | `download`, `local` | `download` |
| `web_build_dir` | directory with a local build of the generated files | none, required for `local` |
| `web_root` | app directory that contains `web/` | parent of `.dart_tool` |

Commands of the shared package:

```
dart run native_prebuilt:web stamp                    # hand-written entries, webVersion, Dart file
dart run native_prebuilt:web install-dev [--from <dir>]   # D13, into the package lib/web/
dart run native_prebuilt:web_install [--web-root <dir>]   # D9 fallback, run in an app
dart run native_prebuilt:release <dirs…> --web <dir>  # also uploads, writes web.json
dart run native_prebuilt:check [--download]           # adds I1, and I2 with --download
```

Web inputs that the Telosnex packages add to their source key (D5):

| Package | Inputs |
|---------|--------|
| zxing_dart | its web build script (with the CMake, `src/` and fetch inputs already in the key) |
| image_ffmpeg | its web build script and the libaom and FFmpeg steps that it runs |
| fllama | `web_build/wllama.json` (repository, commit, emsdk image digest), `web_build/wllama.patch` (moved from `docs/patches/`) |
| fonnx | `web_build/onnxruntime_web.json` (npm tarball URL, SHA-256, file list) |

## 6. Non-goals

```
NG1: Web files as hook data assets.
     Reopens when: dartDataAssets in flutter_tools features.dart is available
     on the stable channel of the Flutter version that Telosnex uses. Then
     the hook outputs data assets instead of writing to web/, and each
     package loader changes its base URL. Apps do not change.

NG2: An automatic local web build when the source keys differ, as native
     mode auto does. A developer uses web_build: local (R8).
     Reopens when: a web build needs no toolchain outside pub, or NG1
     reopens.

NG3: Removing web binaries from git history.
     Reopens when: a clone of a package takes more than one minute on the
     Telosnex release runner (as ADR 001 NG1).

NG4: Web files of packages outside this group, for example sqlite3mc.wasm
     in Telosnex web/.
     Reopens when: a version difference between such a file and its Dart
     package causes a defect in Telosnex.

NG5: Byte-identical web builds.
     Reopens when: a user needs to prove that a web file comes from its
     source (as ADR 001 NG3).

NG6: Removal of the install directory of a package that the app no longer
     depends on. No hook of that package runs, so its files stay in
     web/native_prebuilt/ and in build/web.
     Reopens when: a removed package leaves files in a Telosnex release.
     The I4 check can then fail on an unknown directory.
```

## 7. Risks

Ranked by irreversibility.

1. **A defective web runtime reaches users.** A Telosnex web deploy replaces
   the live site. A runtime defect then affects every web user until the next
   deploy. Browser tests before the release (D10) find load and ABI defects.
   They do not find all behavior defects, for example in fllama, whose web
   smoke test needs a GGUF model file.
2. **Flutter blocks or reorders hook writes to web/.** A new Flutter version
   can run hooks in a sandbox, or copy web/ before it runs hooks. Then the
   web build has missing or old files. I4 fails the Telosnex release, and
   D9 restores delivery with one app change. A debug run has no I4 check,
   so a developer sees a load error first.
3. **The hook finds the wrong app directory.** In a pub workspace,
   `.dart_tool` is at the workspace root, not in the app. Then the hook
   writes to a web/ directory that the build does not read. Telosnex is not
   a workspace now. The web_root user define (D2) and I4 cover this.
4. **The first web build downloads all web files.** That is 26 MB for
   Telosnex, then the native_prebuilt cache holds them (ADR 001). An offline
   first build fails.
5. **Web build time in CI.** Measured 2026-10-13, without a cache: the
   image_ffmpeg web build (libaom, FFmpeg, shim) takes 254 s, and the fllama
   wllama build takes 366 s. Each web job runs in parallel with the native
   jobs and is shorter than the longest of them. A cache is not necessary.
6. **One key couples web and native releases (D5).** A change to the wllama
   patch rebuilds all 12 fllama native targets. The cost is CI time.
7. **Package browser tests need the files.** `dart test -p chrome` in a
   package runs the hook as a code-asset build for the host (step 1), so D2
   installs no web files. The tests load `packages/<package>/web/`, which
   package:test serves from `lib/web/`. So the package runs `web
   install-dev` first (D13). Without it, the tests fail because the files
   are missing. Old files from an earlier install can pass. A package
   test can compare `lib/web/.native_prebuilt_web_version` with the
   generated webVersion to catch this.

## 8. Workplan

1. **Done. Spike: Linux build and package tests.** Build the zxing_dart
   web files in a pinned `emscripten/emsdk:5.0.0` container on ubuntu-24.04.
   Run the 48 zxing browser tests against the output. Record if `dart test
   -p chrome` runs the package hook (risk 7). Record the job time. Record
   the results in §B.
2. **Done. native_prebuilt.** Add the web.json model, webVersion, the install
   function (D2, D4), the hook entry point, `web stamp`,
   `web install-dev` (D13), `web_install`, `release --web` and the check
   extension (I1, I2). Add unit tests for webVersion, the app directory
   search, the web_root override, the code-asset gate, a changed
   hand-written file, a hash mismatch in a download, a source key mismatch,
   and the install-dev .gitignore and version file.
3. **Done. zxing_dart.** Replace `tool/build_web.sh` with a Dart script that
   writes to a given directory (D11). Remove the build script from
   `source_excludes.txt`. Run `web install-dev` before the
   browser tests in `tool/test_all.sh`, and convert that script to Dart.
   Call the install function from `hook/build.dart`. Load from
   `native_prebuilt/zxing_dart/` with `?v=` on the worker, loader, module
   and .wasm requests (D7, D8, I3). Remove `lib/web` from `flutter.assets`
   and delete the generated files from git. Add the web job (D10). Make a
   release. Done when Telosnex web builds with the released files after
   only `flutter pub upgrade zxing_dart`.
4. **Done. Telosnex check.** Add I4 to `dev/ci/releases/release.dart`. Do this
   before the next package, so a release with zxing_dart has the guard.
5. **Done. fonnx.** Do step 3 for fonnx. Load each init module from Dart at first
   use (D8). The web job extracts ORT from the pinned tarball. Then in
   Telosnex: delete the fonnx files and old ORT files from `web/`, remove
   their tags from `web/index.html`, and remove their names from
   `dev/ci/build_web.sh`. Done when every fonnx web model passes its
   browser test in a Telosnex web build with ORT 1.27.0.
6. **Done. image_ffmpeg.** Do step 3 for image_ffmpeg. Its three web build
   scripts become one Dart script (D11). Measure the web job
   time (risk 5).
7. **Done. fllama.** Move the wllama patch to `web_build/`. Add
   `web_build/wllama.json`. Build wllama in the web job with `set -e`.
   Load `fllama_web_init.js` from Dart (D8). Remove its tag from Telosnex
   `web/index.html` and from `dev/ci/build_web.sh`. Update
   fllama `RUNBOOK_WEB_RUNTIME.md` and fllama ADR 003 to name the
   workflow as the builder.

---

## ──────── non-normative ────────

### A. Alternatives & notes

- **Generated files in git, delivered with flutter.assets.** The first draft
  of this ADR decided this. It works on stable without a contract break. It
  adds a permanent copy of each changed file to git, up to 13.5 MB for
  fonnx, and it needs proof that Emscripten output is deterministic to keep
  that growth to real changes.
- **App command before each web build.** D9 keeps it as the fallback. As the
  primary path it fails R1, and a developer who forgets it in
  `flutter run -d chrome` gets old files.
- **Flutter master channel.** It allows data assets with
  `flutter config --enable-dart-data-assets`. Telosnex releases on stable
  (R2).
- **A patched copy of flutter_tools.** The prototype used one to prove that
  data assets bundle. Telosnex already builds web with a patched web SDK
  (`dev/patched_web_sdk.dart`), but a patched build tool affects every
  platform build. Rejected for R2.
- **Web files on a CDN at a versioned URL.** It satisfies R6 without D7. It
  fails R3, and it adds a host that each app must allow in its CSP.
- **Wasm bytes in Dart source.** It needs no assets. Each page load then
  downloads all 26 MB with main.dart.js, and git still grows.
- **A web section in prebuilt.json.** Both manifests have the same
  `sourceKey` and release, and both change on each release. A separate
  `web.json` leaves native-only packages unchanged, and `web stamp` can
  update hand-written entries without writing the native manifest.

### B. Revision history

- 2026-10-07: First draft. Generated files in git, delivered with
  flutter.assets.
- 2026-10-12: Changed delivery to installation by the package hook (D1, D2,
  D4, D9), after the probe in §1.2. Removed the determinism spike and the
  git growth risk. Added I4 as a guard for the hook path.
- 2026-10-12: Moved from fllama `docs/ADR_006_WEB_RUNTIME_FILES.md` and
  renumbered ADR 002. ADR 001 was fllama ADR 005. The former step 8, the
  ADR 001 NG2 pointer, is done.
- 2026-10-12: Step 1 spike done, with Docker on an Apple M-series Mac. The
  zxing build in `emscripten/emsdk:5.0.0` needs two changes to
  `tool/build_web.sh`: `nproc` for `sysctl -n hw.ncpu`, and `sha256sum`
  for `shasum -a 256`. The build took 42 s for linux/amd64 under emulation
  and 33 s for linux/arm64, with the zxing-cpp clone. The time on a
  GitHub runner is not measured. The amd64 and arm64 outputs are equal.
  The `.mjs` is equal to the Mac build. The `.wasm` differs from the Mac
  build in one byte, the last bit of one f64 constant (NG5). All 48 browser
  tests pass on the Linux output: 24 with dart2js in 17 s and 24 with
  dart2wasm in 8 s. Without the `.wasm` file, they fail. `dart test -p
  chrome` runs the hook once, as a macos-arm64 code-asset build, so D2
  installs no web files there (risk 7).
- 2026-10-12: Added D12 and D13. The web build entry point is
  `tool/build_web.dart`, because a shell script does not run on Windows.
  `web install-dev` replaces `tool/test_web.sh`: native_prebuilt installs
  the files into the package `lib/web/`, and the package selects its own
  tests. Updated D10 with the spike result. Added the rejected
  `prebuilt.json` web section to §A.
- 2026-10-12: Separated what native_prebuilt does from what it recommends.
  native_prebuilt receives a directory of built files (D3); the `web build`
  command and D12 (`tool/build_web.dart` in each package) are removed. D10
  is now the recommended package workflow: CI build, pinned toolchain,
  browser tests before release. The per-package toolchains moved to D11.
- 2026-10-12: Accepted. The founder confirmed R4, R5, R6 and R8 as
  requirements for the Telosnex packages.
- 2026-10-13: Step 2 done. Release assets are gzipped
  (`web-<name>.gz`), and each generated entry records its `url` and
  `downloadSha256` (§5). A `flutter build web` of a test app installed
  the files in download mode, did not rewrite them on a rebuild, used
  local mode, ran again after a local file changed, and removed a stale
  file on the change back to download mode.
- 2026-10-13: Step 3 done (zxing_dart release native-3ae1347f736a5a72).
  Step 5 found that the fonnx Whisper model needs ORT Extensions. Added §C:
  the cutover to the onnx-community split export, the items before
  release, the speed values, and the next steps.
- 2026-10-13: fonnx released `native-4366e2b2a423c0e5` with web.json
  (the ORT Web files from the pinned npm tarball) and the model release
  `runtime-aae5c3ee879612eb`. The release workflow runs the Node and Chrome
  tests of every web model before the release.
- 2026-10-13: Step 6 done: image_ffmpeg release `native-f092e4dab2516e97`.
  Its Worker also lost messages that arrived while its imports loaded; it
  now keeps them. Step 7, fllama release `native-cc228460a674b88e`:
  `tool/build_web.dart` builds wllama in
  the emsdk 4.0.20 image, and the web-test job loads stories15M in Chrome
  before the release. Measured the web build times (risk 5). The Telosnex
  side of steps 5 and 7 is one change after this.
- 2026-10-13: Steps 4, 5 and 7 done. A Telosnex web build at
  `136dfddf9e`, with `dev/ci/build_web.sh` in build-only mode, passed I4:
  fllama 4 files, fonnx 20, image_ffmpeg 4, zxing_dart 4, also in
  `web.zip`. In headless Chrome with the production COOP and COEP headers,
  the app drew its first frame. Each installed file loaded with `?v=` and
  the correct MIME type. fonnx Whisper tiny loaded from blob URLs and ran
  one encode and one decode step. No request to `native_prebuilt/` failed.

### C. fonnx Whisper cutover: open items

Step 5 found that the fonnx Whisper model did not run on stock ORT Web. The
model was an Olive export with ORT Extensions operators (`StftNorm`,
`BpeDecoder`). The ORT Web npm package does not contain these operators.
D11 does not allow a custom ORT Web build for fonnx.

The fonnx worktree now uses the fp32 split export of
`onnx-community/whisper-tiny` at revision
`ff4177021cc41f7db950912b73ea4fdf7d01d8e7`. The export has an encoder and a
merged decoder with a key/value cache. Both graphs use only standard ONNX
and ORT operators. Shared Dart code in `lib/models/whisper/src/` computes
the log-mel features, runs a 2-beam search with the Whisper token
suppression, and decodes the tokens. Native and web use the same Dart code.
The change is in fonnx `main` (`d27949f`).

The beam search is necessary. Greedy decoding drops the first sentence of
a 28 s clip with speech at 0 s. The first token has two near-equal
candidates (" How" 22.3%, " The" 21.2%). 2 beams keep the first sentence,
like the old model.

#### C.1 Items before release

- **Model release.** Done: `runtime-aae5c3ee879612eb` (2026-10-13).
- **Telosnex callers.** Done (Telosnex `dcbf8a36de`). `Whisper.load(path)`
  is now `Whisper.load(bundle)`. Each model is two files, an encoder and a
  decoder. fonnx `1231306` added `WhisperBundle.base` and
  `WhisperBundle.small`, so Telosnex keeps its three Whisper sizes. The
  downloads are 151 MB (tiny), 291 MB (base), and 968 MB (small). On web,
  Telosnex reads the two files from IndexedDB and gives fonnx blob URLs.
- **Telosnex `web/`.** Done (Telosnex `632bd95366`). The old `web/` folder
  had the ORT 1.17.1 JS with Wasm files for ORT 1.18. That Whisper did not
  run on web. The step 5 cleanup removed these files.
- **Web JS size.** The Whisper vocabulary is Dart source. It adds 840 KB to
  the dart2js output (235 KB with gzip).
- **Known test failures before this change.** The Magika `?v=` query test
  times out under DDC. `tool/verify_artifacts.dart` fails on the branch for
  the web files that steps 2 to 5 changed.
- **dart2wasm Worker crash: a test server issue.** Under
  `flutter test --platform chrome --wasm`, each fonnx model Worker stopped
  with "Worker crashed: unknown error". The cause is the Flutter test server.
  With `--wasm`, the default renderer is skwasm, and the server sends COOP
  and COEP on the `.html` page only. The page is then cross-origin isolated,
  and Chrome refuses a Worker script that has no COEP header.
  `--no-cross-origin-isolation` does not change the headers of that page.
  Production sends the headers on each file, so production is not affected:
  a `--wasm` build of the fonnx example, with skwasm and the production
  headers, ran Magika and Whisper in Chrome. With the headers on the `.html`
  page only, it failed in the same way. fonnx `tool/test_all.sh` and its
  native release workflow now run `web_runtime_test.dart` under dart2wasm
  with the CanvasKit renderer, which keeps the page not isolated.

#### C.2 Speed

The new model is slower than the old model. Each value is the median time
on an Apple M-series Mac with 16 cores.

| Path | Clip | Old model | New model |
|---|---|---|---|
| Chrome, ORT Web Wasm, 8 threads, dart2js `-O2` | 5 s | 170 ms | 190 ms |
| | 7 s | 163 ms | 203 ms |
| | 28 s | 338 ms | 398 ms |
| Native, ORT through FFI, `flutter test` (JIT) | 5 s | 75 ms | 107 ms |
| | 28 s | 183 ms | 241 ms |

On web, the new time for the 5 s clip has these parts:

| Part | Time |
|---|---|
| Log-mel features (Dart) | 7 ms |
| Encoder (ORT Web) | 119 ms |
| Decoder, 11 steps (ORT Web and Worker messages) | 62 ms |
| Beam search (Dart) | 9 ms |

The cause is the model file, not the Dart code. The old Olive export had
int8 weights: 66 `MatMulInteger` nodes and 59 `DynamicQuantizeLinear`
nodes. It also had fused ORT operators: `Attention`,
`SkipLayerNormalization`, and `BiasGelu`. The new export is fp32 and has no
fused operators. The fp32 encoder alone takes 119 ms on web. The complete
old model takes 170 ms. The Dart code adds 0.5 ms to 1 ms for each token.

The quantized files in `onnx-community/whisper-tiny` are not the solution.
On CPU, each quantized file was slower than fp32. Each quantized file also
changed the transcripts. The `uint8` file repeats one sentence until the
token limit.

The native values come from a JIT test run. A release build was not
measured.

The new model is more accurate on the test clip. It writes "The rain in
Spain falls mainly on the plane." The old model wrote "The rain and Spain".

#### C.3 Next steps

Do these steps as cleanup after the web path of native_prebuilt is stable
for fonnx, image_ffmpeg, and fllama (steps 5 to 7).

1. Make a fonnx export of `openai/whisper-tiny` with the same two-graph
   layout. Apply the ORT transformer fusions. Quantize the encoder MatMul
   weights to int8. Then quantize the decoder MatMul weights to int8.
2. Keep the inputs and outputs of the current graphs. Then the Dart code
   does not change.
3. Measure each export on the three clips, on native release builds and on
   Chrome. Compare the transcripts with the fp32 transcripts.
4. Use an export only if it is faster than the old model and its
   transcripts are equal to the fp32 transcripts.
5. Move the vocabulary from Dart source to a data file that the model
   download contains. This removes 840 KB from the web JS.
6. If the Worker messages become a large part of the decoder time, move the
   beam search into the Worker.
