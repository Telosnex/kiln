# Builds without network (Flatpak, Flathub)

> The package was named `native_prebuilt` before 0.1.0.

Flathub builds offline and from source. kiln supports that with
four pieces; together they let a packager generate every source a build
hook needs, with no package-specific manifest entries.

## 1. Pinned upstream sources: `native_artifacts/sources.json`

A package lists what its source build fetches:

```json
{"schema": 1,
 "sources": [
   {"name": "zxing-cpp", "git": "https://github.com/zxing-cpp/zxing-cpp.git",
    "commit": "<40 hex>", "submodules": true},
   {"name": "onnxruntime", "targets": ["linux-arm64"],
    "url": "https://.../onnxruntime-linux-aarch64-1.27.0.tgz", "sha256": "<64 hex>"}
 ],
 "cargo_locks": ["rust/Cargo.lock"]}
```

The file is part of the source key. In the source build, use
`source.pinnedSource('zxing-cpp')`: it returns
`<cache>/sources/<name>-<16 hex>`, fetching it first unless a packager put
it there. Do not fetch upstream code any other way.

## 2. Defaults for every package: `<cache>/defaults.json`

```json
{"schema": 1, "user_defines": {"native_build": "source", "host_toolchain": true}}
```

A package's own user define wins. Hooks get only a few environment
variables (HOME, PATH, ...), so this file is the switch for a build that
cannot edit the app's pubspec. With HOME=<build dir>/home it is
`<build dir>/home/.cache/kiln/defaults.json`.

## 3. `host_toolchain`

`SourceBuild.hostToolchain`: use the tools on PATH, download nothing (no
rustup, no toolchain downloads). Missing pinned sources fail with the path
to fill. Cargo reads vendored crates from `$HOME/.cargo/config.toml`.

## 4. The generator

```sh
dart run kiln:flatpak --app <app> --source \
  --build-root /run/build/<module> --out native-sources.json
```

Writes flatpak-builder sources: every pinned source into the cache,
vendored crates of `cargo_locks` with a Cargo config, and defaults.json.
Without `--source`, it places the prebuilt files of `prebuilt.json`
instead (offline, but not from source). The manifest module must set
`HOME: /run/build/<module>/home`.

## Also for portable source keys and hooks

- The source key hashes files that git stores with LF and checks out with
  CRLF (Windows `core.autocrlf`) as stored, so every checkout gets the
  same key.
- `bashExecutable()`: Git Bash on Windows; the System32 bash is WSL.

## Not covered

native_toolchain_cmake passes a cross toolchain file naming Debian's
compilers (`aarch64-linux-gnu-g++`) even for native builds. The Flatpak
SDK names them `aarch64-unknown-linux-gnu-g++`; until that changes
upstream, the manifest links the Debian names.
