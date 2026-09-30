#!/usr/bin/env python3
"""Validate localized resources and diagnostics without mounting any disks."""
import json
from pathlib import Path
import re
import subprocess

source = Path(__file__).resolve().parent
executable = source.parent / 'VolumeBridge.app/Contents/MacOS/VolumeBridge'
tables = {}
for language in ['zh-Hans', 'en', 'ja']:
    folder = source / 'Localizations' / (language + '.lproj')
    for name in ['Localizable.strings', 'InfoPlist.strings']:
        subprocess.run(['plutil', '-lint', str(folder / name)], check=True)
    tables[language] = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-', str(folder / 'Localizable.strings')]))
reference = tables['zh-Hans']
for language, table in tables.items():
    assert set(table) == set(reference), language
    for key, value in table.items():
        assert value.strip(), (language, key)
        assert re.findall(r'%[@d]', value) == re.findall(r'%[@d]', reference[key]), (language, key)
    for mode in ['--test-localization', '--test-error-mapping']:
        subprocess.run([str(executable), '--language', language, mode], check=True, capture_output=True)
    # Invalid arguments exit before any privileged disk operation.
    result = subprocess.run([str(executable), '--helper', '--language', language], capture_output=True, text=True)
    assert result.returncode == 1
    assert table['挂载操作需要系统管理员授权。'] in result.stderr
print(f'Localization checks passed: {len(reference)} keys in 3 languages.')
