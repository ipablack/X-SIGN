"""Merge only XSign OTA routes/codebase into an EXISTING Firebase website project."""
from pathlib import Path
import argparse,json,shutil,sys,hashlib

ROUTES=['/native/prepare','/native/manifest.plist','/native/status']
CODEBASE='xsign-ota'
SOURCE='functions_xsign_ota'

def configure(project: Path):
    project=project.resolve()
    path=project/'firebase.json'
    if not path.is_file() or path.is_symlink():
        raise ValueError('An existing Firebase website firebase.json is required; no blank Hosting project was created.')
    raw=path.read_text();config=json.loads(raw)
    all_hosts=config.get('hosting')
    hosts=all_hosts if isinstance(all_hosts,list) else [all_hosts]
    selected=[h for h in hosts if isinstance(h,dict) and (h.get('site')=='x-sign' or h.get('target')=='xsign')]
    if len(selected)!=1:raise ValueError('Select exactly one existing Hosting site="x-sign" or target="xsign" before merging.')
    hosting=selected[0]
    if not any(hosting.get(key) for key in ['public','source']):raise ValueError('Existing website content configuration must be preserved.')
    rewrites=hosting.get('rewrites',[])
    if not isinstance(rewrites,list):raise ValueError('Invalid existing Hosting rewrites')
    hosting['rewrites']=[{'source':route,'function':{'functionId':'xsignNativeOTA','region':'us-central1'}} for route in ROUTES]+[
        item for item in rewrites if item.get('source') not in ROUTES]
    functions=config.get('functions',[])
    if isinstance(functions,dict):functions=[functions]
    if not isinstance(functions,list):raise ValueError('Invalid existing functions configuration')
    existing=[f for f in functions if f.get('codebase')==CODEBASE]
    if existing and (len(existing)!=1 or existing[0].get('source')!=SOURCE):raise ValueError('Existing codebase conflicts; nothing was written.')
    if not existing:functions.append({'source':SOURCE,'codebase':CODEBASE,'ignore':['node_modules','.git','*.log']})
    config['functions']=functions
    package=project/SOURCE
    source=Path(__file__).resolve().parent/'functions'
    if package.is_symlink():raise ValueError('Symlink backend directory rejected')
    # Plan every write and validate conflicts before changing any file.
    planned=[]
    for child in source.iterdir():
        if child.is_file() and child.suffix in ['.cjs','.json']:
            target=package/child.name
            if target.is_symlink():raise ValueError('Symlink backend target rejected')
            if target.exists() and target.read_bytes()!=child.read_bytes():raise ValueError('Existing backend source differs: '+child.name)
            planned.append((target,child.read_bytes()))
    backup=project/'firebase.before-xsign-ota.json'
    if backup.exists() and backup.read_text()!=raw and json.loads(raw)!=config:
        raise ValueError('Review the existing Firebase backup before a different merge.')
    if not backup.exists():backup.write_text(raw)
    package.mkdir(parents=True,exist_ok=True)
    for target,data in planned:
        if target.is_symlink():raise ValueError('Symlink backend target rejected')
        target.write_bytes(data)
    tmp=project/'firebase.xsign-ota.tmp'
    tmp.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    tmp.replace(path)
    print('Merged only XSign OTA codebase/routes. Existing website files and other Hosting sites were preserved.')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('firebase_project',type=Path)
    args=parser.parse_args()
    try:configure(args.firebase_project)
    except (ValueError,TypeError,KeyError,json.JSONDecodeError) as error:sys.exit(str(error))
