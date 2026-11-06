from pathlib import Path
import io,os,stat,zipfile

root=Path(os.environ['RUNNER_TEMP'])/'xsign-ipa-fixtures'
root.mkdir(parents=True,exist_ok=True)
base={'Payload/Test.app/Info.plist':b'fixture','Payload/Test.app/Test':b'fixture-executable'}
def create(name, extras):
    with zipfile.ZipFile(root/(name+'.ipa'),'w',compression=zipfile.ZIP_STORED) as archive:
        for path,data in base.items():archive.writestr(path,data)
        for path,data in extras:archive.writestr(path,data)
create('valid',[])
create('traversal',[('../outside.txt',b'overwrite')])
create('absolute',[('/outside.txt',b'overwrite')])
create('backslash',[('Payload/Test.app/..\\..\\outside.txt',b'overwrite')])
create('case-collision',[('Payload/Test.app/One',b'one'),('Payload/Test.app/one',b'two')])
create('file-directory',[('Payload/Test.app/nested',b'file'),('Payload/Test.app/nested/item',b'child')])
link=zipfile.ZipInfo('Payload/Test.app/link')
link.create_system=3
link.external_attr=(stat.S_IFLNK | 0o777)<<16
create('symlink',[(link,b'../../../outside.txt')])
create('crc-corrupt',[])
p=root/'crc-corrupt.ipa';data=p.read_bytes().replace(b'fixture-executable',b'broken--executable');p.write_bytes(data)
print(root)
