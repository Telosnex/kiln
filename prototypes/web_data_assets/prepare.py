#!/usr/bin/env python3
"""Stage an offline asset-hook probe; optionally copy and un-gate Flutter tools.

Only writes inside .work/. Does not edit the SDK or the source packages.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
from urllib.parse import urljoin

ROOT = Path(__file__).resolve().parent
DEV = ROOT.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--flutter-sdk', type=Path,
                    default=Path(shutil.which('flutter') or 'flutter').resolve().parent.parent)
parser.add_argument('--image-ffmpeg', type=Path, default=DEV / 'image_ffmpeg')
parser.add_argument('--zxing-dart', type=Path, default=DEV / 'zxing_dart')
parser.add_argument('--experimental-tools', action='store_true',
                    help='Copy flutter_tools sources and enable its data-assets gate on stable')
args = parser.parse_args()
sdk = args.flutter_sdk.resolve()
work = ROOT / '.work'
work.mkdir(exist_ok=True)
for name in ['app', 'payload', 'artifacts']:
    shutil.rmtree(work / name, ignore_errors=True)
for name in ['app', 'payload']:
    shutil.copytree(ROOT / name, work / name)
    for template in (work / name).rglob('*.template'):
        template.rename(template.with_suffix(''))
(work / 'artifacts').mkdir()
evidence = {'flutter': subprocess.check_output(
    [str(sdk / 'bin/flutter'), '--version'], text=True), 'inputs': {}}
for name, source in [('image_ffmpeg', args.image_ffmpeg), ('zxing_dart', args.zxing_dart)]:
    source = source.resolve()
    evidence['inputs'][name] = {
        'revision': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
        'sha256': {},
    }
    for suffix in ['worker.mjs', 'loader.mjs', 'module.mjs', 'module.wasm']:
        asset = source / 'lib/web' / f'{name}_{suffix}'
        shutil.copy2(asset, work / 'artifacts' / asset.name)
        evidence['inputs'][name]['sha256'][asset.name] = hashlib.sha256(asset.read_bytes()).hexdigest()
(work / 'inputs.json').write_text(json.dumps(evidence, indent=2) + '\n')

if args.experimental_tools:
    original = sdk / 'packages/flutter_tools'
    copied = work / 'experimental_flutter_tools'
    shutil.rmtree(copied, ignore_errors=True)
    for name in ['lib', 'bin']:
        shutil.copytree(original / name, copied / name)
    features = copied / 'lib/src/features.dart'
    text = features.read_text()
    old = ("configSetting: 'enable-dart-data-assets',\n"
           "  environmentOverride: 'FLUTTER_DART_DATA_ASSETS',\n"
           "  master: FeatureChannelSetting(available: true),")
    if text.count(old) != 1:
        raise SystemExit('Flutter feature definition changed. Reassess this prototype; do not blindly patch.')
    features.write_text(text.replace(old, old + '\n  stable: FeatureChannelSetting(available: true),', 1))
    config_path = original / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text())
    for package in config['packages']:
        package['rootUri'] = urljoin(config_path.as_uri(), package['rootUri'])
        if package['name'] == 'flutter_tools':
            package['rootUri'] = copied.as_uri() + '/'
    (work / 'experimental_packages.json').write_text(json.dumps(config, indent=2) + '\n')
    command = [str(sdk / 'bin/cache/dart-sdk/bin/dart'),
               '--packages=' + str(work / 'experimental_packages.json'),
               str(copied / 'bin/flutter_tools.dart')]
    launcher = work / 'flutter-experimental'
    launcher.write_text('#!/bin/sh\n' +
                       'export FLUTTER_ROOT=' + shlex.quote(str(sdk)) + '\n' +
                       'export FLUTTER_DART_DATA_ASSETS=true\n' +
                       'exec ' + shlex.join(command) + ' "$@"\n')
    launcher.chmod(0o755)
    print('Experimental Flutter tool copy ready. The installed SDK is unchanged.')
print('Fixture ready in', work)
