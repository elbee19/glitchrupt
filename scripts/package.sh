#!/bin/bash
# Build reviewable local archives only; never publish or install configuration.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--source-only") ]]; then
  echo "Usage: ./scripts/package.sh [--source-only]" >&2
  exit 2
fi
python3 - "$@" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import re
import stat
import subprocess
import sys
import time
import zipfile

root = Path.cwd()
source_only = '--source-only' in sys.argv[1:]
dist = root / 'dist'
version_match = re.search(r'^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"$',
                          (root / 'pyproject.toml').read_text(), re.MULTILINE)
if not version_match:
    raise SystemExit('Cannot determine a safe package version from pyproject.toml')
version = version_match.group(1)
files = ('README.md', 'LICENSE', 'AGENTS.md', 'CLAUDE.md', 'pyproject.toml',
         'uv.lock', '.python-version', '.gitignore')
directories = ('Sources', 'src', 'assets/sounds', 'assets/brand', 'assets/demo', 'scripts', 'docs', 'tests',
               'examples', '.github')
excluded = {'.git', '.venv', '.pytest_cache', '__pycache__', '.ds_store',
            'build', 'dist', 'localnotes', 'local-notes', 'prototype-reference',
            'prototype_reference', 'captures', 'recordings', 'logs', 'references',
            'reference', 'film', 'clips', '.env'}
sound_names = {name + '.wav' for name in ('classic', 'fracture', 'brownout', 'arc', 'stutter')}
sound_names.add('manifest.json')
demo_names = {'demo.gif', 'demo.mp4', 'poster.png'}
brand_names = {'logo.svg', 'icon.svg', 'logo.png', 'icon.png', 'AppIcon.icns', 'MenuIcon.png'}
allowed_media = {'assets/brand/logo.png', 'assets/brand/icon.png', 'assets/brand/MenuIcon.png',
                 'build/Glitchrupt.app/Contents/Resources/MenuIcon.png',
                 'assets/demo/demo.gif', 'assets/demo/demo.mp4', 'assets/demo/poster.png'}
# Derive local paths at runtime; keep developer identities out of source.
private_needles = tuple(str(path).encode() for path in (Path.home(), root))

def fail(message):
    raise SystemExit('Package audit failed: ' + message)

def ignored(relative):
    return any(part.lower() in excluded or part.startswith('._') or part.endswith('.egg-info')
               for part in relative.parts) or relative.suffix in {'.pyc', '.pyo', '.log'}

def audit(path, relative):
    if path.is_symlink():
        fail('symlink is not allowed: ' + relative.as_posix())
    if not path.is_file():
        fail('unexpected non-regular file: ' + relative.as_posix())
    if relative.suffix.lower() in {'.gif', '.mp4', '.mov', '.m4v', '.mp3', '.m4a', '.aiff', '.png', '.jpg', '.jpeg', '.heic'} and relative.as_posix() not in allowed_media:
        fail('capture/reference media is not allowed: ' + relative.as_posix())
    payload = path.read_bytes()
    if any(needle in payload for needle in private_needles):
        fail('machine-specific path in ' + relative.as_posix())
    return payload

candidates = set()
for name in files:
    path = root / name
    if path.exists() or path.is_symlink():
        candidates.add(path)
for name in directories:
    folder = root / name
    if folder.is_symlink():
        fail('symlink source directory: ' + name)
    if not folder.exists():
        continue
    for current, subdirs, names in os.walk(folder, followlinks=False):
        current = Path(current)
        for dirname in list(subdirs):
            path = current / dirname
            relative = path.relative_to(root)
            if ignored(relative):
                subdirs.remove(dirname)
            elif path.is_symlink():
                fail('symlink source directory: ' + relative.as_posix())
        for filename in names:
            path = current / filename
            relative = path.relative_to(root)
            if ignored(relative):
                continue
            if relative.parts[:2] == ('assets', 'sounds') and (
                    len(relative.parts) != 3 or filename not in sound_names):
                fail('unexpected sound asset: ' + relative.as_posix())
            if relative.parts[:2] == ('assets', 'brand') and (
                    len(relative.parts) != 3 or filename not in brand_names):
                fail('unexpected brand asset: ' + relative.as_posix())
            if relative.parts[:2] == ('assets', 'demo') and (
                    len(relative.parts) != 3 or filename not in demo_names):
                fail('unexpected demo asset: ' + relative.as_posix())
            candidates.add(path)
for required in ('README.md', 'LICENSE', 'AGENTS.md', 'CLAUDE.md', 'pyproject.toml', 'uv.lock',
                 'scripts/build.sh', 'scripts/generate_sounds.py', 'Sources/main.swift',
                 'src/glitchrupt/cli.py', 'src/glitchrupt/server.py', 'src/glitchrupt/client.py'):
    if root / required not in candidates:
        fail('missing source file: ' + required)

app = root / 'build' / 'Glitchrupt.app'
if not source_only:
    if not (app / 'Contents' / 'MacOS' / 'Glitchrupt').is_file():
        fail('build/Glitchrupt.app is missing; run ./scripts/build.sh first')
    for current, subdirs, names in os.walk(app, followlinks=False):
        current = Path(current)
        for dirname in subdirs:
            path = current / dirname
            if path.is_symlink():
                fail('symlink app directory: ' + path.relative_to(root).as_posix())
        for filename in names:
            path = current / filename
            relative = path.relative_to(root)
            if ignored(relative.relative_to('build')):
                # Finder sidecars are excluded by ditto; logs/captures are an error.
                if filename.startswith('._') or filename == '.DS_Store':
                    continue
                fail('unexpected development file in app: ' + relative.as_posix())
            audit(path, relative)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)

# Audit all input before creating an archive. Archive paths never include local roots.
ordered = sorted(candidates, key=lambda path: path.relative_to(root).as_posix())
for path in ordered:
    audit(path, path.relative_to(root))
dist.mkdir(exist_ok=True)
source_zip = dist / f'Glitchrupt-{version}-source.zip'
top = f'Glitchrupt-{version}-source'
epoch = max(315532800, int(os.environ.get('SOURCE_DATE_EPOCH', '315532800')))
stamp = time.gmtime(epoch)[:6]
with zipfile.ZipFile(source_zip, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in ordered:
        relative = path.relative_to(root)
        info = zipfile.ZipInfo(top + '/' + relative.as_posix(), date_time=stamp)
        info.create_system = 3
        executable = path.suffix == '.sh' or bool(path.stat().st_mode & stat.S_IXUSR) and path.suffix == '.py'
        info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, audit(path, relative))
artifacts = [source_zip]
if not source_only:
    executable = app / 'Contents' / 'MacOS' / 'Glitchrupt'
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).strip().split()
    architecture = 'universal' if len(architectures) > 1 else architectures[0]
    if architecture not in {'arm64', 'x86_64', 'universal'}:
        fail('unexpected application architecture')
    app_zip = dist / f'Glitchrupt-{version}-macos-{architecture}.zip'
    if app_zip.exists():
        app_zip.unlink()
    environment = dict(os.environ, COPYFILE_DISABLE='1')
    # Stage file contents/modes only so Finder sidecars are omitted; ditto strips
    # extended attributes from the downloadable app. Resource bytes and signature stay intact.
    def copy_regular(source, destination):
        shutil.copyfile(source, destination)
        os.chmod(destination, stat.S_IMODE(os.stat(source).st_mode))
        return destination
    with tempfile.TemporaryDirectory(prefix='glitchrupt-package-') as temporary:
        staged_app = Path(temporary) / 'Glitchrupt.app'
        shutil.copytree(app, staged_app, copy_function=copy_regular,
                        ignore=lambda folder, names: [name for name in names
                            if name.startswith('._') or name == '.DS_Store'])
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                        str(staged_app)], check=True)
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc',
                        '--noextattr', '--noqtn', str(staged_app), str(app_zip)],
                       check=True, env=environment)
    with zipfile.ZipFile(app_zip) as archive:
        for name in archive.namelist():
            if not name.startswith('Glitchrupt.app/') or any(part.startswith('._') for part in Path(name).parts):
                fail('unexpected entry in app archive: ' + name)
    artifacts.append(app_zip)
checksums = dist / 'SHA256SUMS'
checksums.write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' +
                             path.relative_to(root).as_posix() + '\n' for path in artifacts))
for path in artifacts + [checksums]:
    print(path.relative_to(root))
PY
