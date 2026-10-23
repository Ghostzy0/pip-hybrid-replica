#!/usr/bin/env python3
"""Fetch an immutable, hash-pinned upstream runtime; never download model weights here."""
import hashlib, json, os, pathlib, shutil, tarfile, tempfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1] / 'apps/mac/.runtime'
TAG = 'b11768'
NAME = f'llama-{TAG}-bin-macos-arm64.tar.gz'
DIGEST = '15afe10cd251b3c22926fae17348bc2bd85dd2cba9ed39a97659983d01b9f979'
URL = f'https://github.com/ggml-org/llama.cpp/releases/download/{TAG}/{NAME}'

def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()

def manifest(directory):
    files = {p.name: digest(p) for p in directory.iterdir() if p.is_file() and p.name != 'localswitch-runtime.json'}
    (directory / 'localswitch-runtime.json').write_text(json.dumps(files, indent=2) + '\n')

if __name__ == '__main__':
    ROOT.mkdir(parents=True, exist_ok=True)
    archive = ROOT / NAME
    if not archive.exists() or digest(archive) != DIGEST:
        part = archive.with_suffix('.partial')
        with urllib.request.urlopen(URL, timeout=60) as response, part.open('wb') as f:
            shutil.copyfileobj(response, f)
        if digest(part) != DIGEST:
            part.unlink(missing_ok=True)
            raise SystemExit('Runtime SHA-256 mismatch. Installation refused.')
        part.replace(archive)
    # Re-extract only from the verified archive. Reject unexpected paths/symlink escapes.
    with tempfile.TemporaryDirectory(dir=ROOT) as temp:
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                p = pathlib.PurePosixPath(member.name)
                if p.is_absolute() or '..' in p.parts or p.parts[0] != f'llama-{TAG}' or not (member.isfile() or member.isdir() or member.issym()):
                    raise SystemExit('Unsafe runtime archive entry.')
                if member.issym() and ('/' in member.linkname or '..' in member.linkname):
                    raise SystemExit('Unsafe runtime archive symlink.')
            tar.extractall(temp)
        source = pathlib.Path(temp) / f'llama-{TAG}'
        target = ROOT / f'llama-{TAG}'
        if target.exists(): shutil.rmtree(target)
        shutil.move(str(source), str(target))
    manifest(target)
    (ROOT / 'provenance.json').write_text(json.dumps({'version':TAG,'commit':'1ba568c5ad5c6c718984bd2bf4e7c71485b706f9','url':URL,'sha256':DIGEST},indent=2)+'\n')
    print(f'Verified llama.cpp {TAG}: {target}')
