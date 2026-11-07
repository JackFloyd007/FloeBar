#!/usr/bin/env python3
"""Validate shipped translations and optionally compare Xcode-extracted keys."""
import argparse
import collections
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCALES = {'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es', 'pt-BR'}
parser = argparse.ArgumentParser()
parser.add_argument('--extracted', type=pathlib.Path, help='Xcode Objects-normal/arm64 directory')
parser.add_argument('--bundle', type=pathlib.Path, help='Built app bundle, to check compiled resources')
args = parser.parse_args()
strings = json.loads((ROOT / 'FloeBar/Resources/Localizable.xcstrings').read_text())['strings']
errors = []
pattern = re.compile(r'%(?:\d+\$)?(?:@|lld|ld|d|f|g|s)')
for key, entry in strings.items():
    translations = entry.get('localizations', {})
    if set(translations) != LOCALES:
        errors.append(f'{key}: missing or unexpected locales: {set(translations) ^ LOCALES}')
    expected = collections.Counter(pattern.findall(key))
    for locale, translation in translations.items():
        unit = translation.get('stringUnit', {})
        value = unit.get('value', '')
        if not value or unit.get('state') != 'translated':
            errors.append(f'{locale}: {key}: empty or untranslated')
        if collections.Counter(pattern.findall(value)) != expected:
            errors.append(f'{locale}: {key}: format placeholders differ')
for locale in LOCALES:
    if not (ROOT / f'FloeBar/Resources/{locale}.lproj/InfoPlist.strings').is_file():
        errors.append(f'{locale}: missing screen capture usage description')
if args.extracted:
    for path in args.extracted.glob('*.stringsdata'):
        data = json.loads(path.read_text())
        for entry in data.get('tables', {}).get('Localizable', []):
            if entry['key'] not in strings:
                errors.append(f'{path.stem}: missing key: {entry["key"]}')
if args.bundle:
    for locale in LOCALES:
        path = args.bundle / f'Contents/Resources/{locale}.lproj/Localizable.strings'
        if not path.is_file():
            errors.append(f'{locale}: compiled resource missing')
            continue
        compiled = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
        for key, entry in strings.items():
            expected_value = entry['localizations'][locale]['stringUnit']['value']
            if compiled.get(key) != expected_value:
                errors.append(f'{locale}: compiled translation differs for {key}')
if errors:
    raise SystemExit('\n'.join(sorted(set(errors))))
print(f'PASS: {len(strings)} strings across {len(LOCALES)} locales; placeholders and permission resources verified')
