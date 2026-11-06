"""Package public runtime and verified core containers; never copy local sound packs."""
from pathlib import Path
import argparse,hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[1]
REPO='Craditz/Abiotic-Feral-Fox'
VERSION='0.16.3'
PREFIX='AbioticFactor/Binaries/Win64/'
SCRIPTS=PREFIX+'ue4ss/Mods/FeralFoxPrototype/Scripts/'
def sha(data):return hashlib.sha256(data).hexdigest()
def build(bundle,loader,output):
    output.mkdir(parents=True,exist_ok=True)
    assets=json.loads((ROOT/'asset-manifest.json').read_text())
    assert assets['version']==VERSION and len(assets['assets'])==554
    assert not any(n.startswith('SW_') for n in assets['assets'])
    assert all(not n.startswith('SW_') for n in assets['source_cooked_sha256'])
    members={SCRIPTS+p.name:p.read_bytes() for p in (ROOT/'src/Scripts').glob('*.lua')}
    assert len(members)==17 and f'FeralFoxPrototype {VERSION}'.encode() in members[SCRIPTS+'main.lua'].splitlines()[0]
    for entry in assets['files']:
        assert entry['name'] in ['FeralFoxCore_2_P'+ext for ext in ('.pak','.utoc','.ucas')]
        data=(bundle/entry['name']).read_bytes();assert sha(data)==entry['sha256']
        members['AbioticFactor/Content/Paks/~mods/'+entry['name']]=data
    for name in ('README.md','THIRD-PARTY.md','VALIDATION.md','UE4SS-LICENSE.txt','asset-manifest.json'):
        members['FeralFox-Docs/'+name]=(ROOT/name).read_bytes()
    bootstrap={name:(ROOT/name).read_bytes() for name in ('FeralFox-Updater.ps1','Update-FeralFox.cmd')}
    members.update(bootstrap)
    def archive(name,files):
        path=output/name
        for n in files:
            assert not n.startswith(('/','\\')) and '..' not in Path(n).parts
            assert not any(s in n.lower() for s in ('.sav','.log','.dmp','.wav','.ogg','character-options','network-server-id','player-option','feralfoxassets_p'))
        with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for n,d in sorted(files.items()):z.writestr(n,d)
        with zipfile.ZipFile(path) as z:
            assert z.testzip() is None and set(z.namelist())==set(files)
            assert all(sha(z.read(n))==sha(d) for n,d in files.items())
        return {'name':name,'bytes':path.stat().st_size,'sha256':sha(path.read_bytes()),'files':{n:sha(d) for n,d in sorted(files.items())}}
    packages={'update':archive(f'FeralFox-{VERSION}-update.zip',members)}
    pins=json.loads((ROOT/'loader-files.sha256.json').read_text())
    with zipfile.ZipFile(loader) as z:
        for n,h in pins.items():
            data=z.read(n);assert sha(data)==h,'Unexpected loader bytes: '+n
            members[n]=data
    members[PREFIX+'ue4ss/Mods/mods.txt']=b'FeralFoxPrototype : 1\r\n'
    packages['install']=archive(f'FeralFox-{VERSION}-with-UE4SS-Windows.zip',members)
    bootstrap_receipt=archive('FeralFox-Updater.zip',bootstrap)
    manifest={'schema':1,'repository':REPO,'version':VERSION,'flavor':'core','protocol':2,
        'channel':'experimental','bundled_audio_assets':0,'preserve_existing_base_pack':True,'packages':packages}
    (output/'feralfox-release.json').write_text(json.dumps(manifest,indent=2)+'\n')
    checks={n:sha((output/n).read_bytes()) for n in [p['name'] for p in packages.values()]+['FeralFox-Updater.zip','feralfox-release.json']}
    (output/'SHA256SUMS.txt').write_text(''.join(h+'  '+n+'\n' for n,h in sorted(checks.items())))
    print(json.dumps({'version':VERSION,'files':checks,'bootstrap':bootstrap_receipt['bytes']},indent=2))
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--bundle',type=Path,required=True)
    parser.add_argument('--loader',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();build(args.bundle,args.loader,args.output)
