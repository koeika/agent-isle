"""Package only CPython + standard library from a PSF universal2 framework.
Never copy the build machine's site-packages, user configuration or caches.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = Path(os.environ.get('AGENT_ISLE_PYTHON_FRAMEWORK', '/Library/Frameworks/Python.framework/Versions/3.13'))
TARGET = REPO / 'dist/Agent Isle.app/Contents/Resources/Runtime/python'


def main():
    source_hash = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(SOURCE / 'Python')], text=True).split()[0]
    receipt = TARGET / 'runtime-receipt.json'
    if receipt.exists() and json.loads(receipt.read_text()).get('source_sha256') == source_hash and json.loads(receipt.read_text()).get('bundle_schema') == 2:
        print('Using packaged standard-library runtime'); return
    if TARGET.exists():
        shutil.rmtree(TARGET)
    (TARGET / 'bin').mkdir(parents=True)
    (TARGET / 'lib').mkdir()
    shutil.copy2(SOURCE / 'bin/python3.13', TARGET / 'bin/python3')
    shutil.copy2(SOURCE / 'Python', TARGET / 'Python')
    shutil.copytree(SOURCE / 'Resources/Python.app', TARGET / 'Resources/Python.app', ignore=shutil.ignore_patterns('_CodeSignature'))
    ignore = shutil.ignore_patterns('site-packages', '__pycache__', '*.pyc', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'config-*', '_test*', '_tkinter*')
    shutil.copytree(SOURCE / 'lib/python3.13', TARGET / 'lib/python3.13', ignore=ignore)
    for lib in (SOURCE / 'lib').glob('*.dylib'):
        if not lib.name.startswith('libpython'):
            shutil.copy2(lib, TARGET / 'lib' / lib.name)
    license_file = SOURCE / 'Resources/English.lproj/License.rtf'
    std_license = SOURCE / 'lib/python3.13/LICENSE.txt'
    if std_license.exists():
        shutil.copy2(std_license, TARGET / 'LICENSE.txt')
    elif license_file.exists():
        shutil.copy2(license_file, TARGET / 'LICENSE.rtf')
    else:
        raise RuntimeError('Python redistribution license missing')
    machos = []
    for file in TARGET.rglob('*'):
        if not file.is_file(): continue
        with file.open('rb') as f: magic = f.read(4)
        if magic not in [bytes.fromhex(x) for x in ['cafebabe', 'cffaedfe', 'feedfacf', 'bebafeca']]: continue
        machos.append(file)
        deps = subprocess.check_output(['otool', '-L', str(file)], text=True)
        changes = []
        for line in deps.splitlines():
            dep = line.strip().split(' (')[0]
            if dep.startswith(str(SOURCE) + '/'):
                replacement = TARGET / dep[len(str(SOURCE)) + 1:]
                if not replacement.exists(): raise RuntimeError('Missing runtime dependency: ' + dep)
                rel = os.path.relpath(replacement, file.parent)
                changes += ['-change', dep, '@loader_path/' + rel]
        if changes:
            subprocess.run(['install_name_tool', *changes, str(file)], check=True, capture_output=True)
        if file.name == 'Python' or file.suffix == '.dylib':
            subprocess.run(['install_name_tool', '-id', '@loader_path/' + file.name, str(file)], check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(file)], check=True, capture_output=True)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(TARGET / 'Resources/Python.app')], check=True, capture_output=True)
    version = subprocess.check_output([str(SOURCE / 'bin/python3.13'), '--version'], text=True).strip()
    receipt.write_text(json.dumps({'bundle_schema': 2, 'implementation': 'CPython', 'version': version, 'source': 'https://www.python.org/downloads/release/python-3132/', 'source_sha256': source_hash, 'architectures': ['arm64', 'x86_64'], 'site_packages': False, 'mach_o_files': len(machos)}, indent=2))
    print('Bundled', version, 'standard library; no user packages')


if __name__ == '__main__':
    main()
