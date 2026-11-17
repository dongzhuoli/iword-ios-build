"""Portable checks, not a substitute for Xcode compilation or device validation."""
from pathlib import Path
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT/'IWord.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert '15.0' in project and 'biz.powerunion.iword' in project
with (ROOT/'IWord/Info.plist').open('rb') as file:
    info = plistlib.load(file)
    assert set(info['UIBackgroundModes']) == {'audio', 'processing'}
    assert info['BGTaskSchedulerPermittedIdentifiers'] == ['biz.powerunion.iword.ai-coach']
assert 'IWord/Info.plist' in project

for source in (ROOT/'IWord').glob('*.swift'):
    assert source.name in project, source.name
ET.parse(ROOT/'IWord.xcodeproj/xcshareddata/xcschemes/IWord.xcscheme')
for data in (ROOT/'IWord/Assets.xcassets').rglob('Contents.json'):
    for image in json.loads(data.read_text()).get('images',[]):
        assert (data.parent/image['filename']).is_file()
with zipfile.ZipFile(ROOT/'IWord/sample.zip') as archive:
    manifest=json.loads(archive.read('manifest.json'))
    assert manifest['wordCount']==5 and manifest['kind']=='iword-mobile-content'
    for file in manifest['files']:
        raw=archive.read(file['path'])
        assert len(raw)==file['bytes'] and hashlib.sha256(raw).hexdigest()==file['sha256']
    entries=[json.loads(line) for line in archive.read('entries.jsonl').decode().splitlines()]
    assert len(entries)==5 and all(entry['audioHash'] for entry in entries)
    assert not any('image' in n or 'screenshot' in n or '..' in n for n in archive.namelist())
for file in ROOT.rglob('*'):
    if file.is_file() and not {'.build','build','release','DerivedData'} & set(file.relative_to(ROOT).parts):
        assert file.suffix not in {'.p12','.mobileprovision','.pdf'}, file.name
print('PASS: source references, iOS15 project, scheme XML, sample package integrity, icons, no book/signing credentials. Xcode/Swift execution is separate.')
