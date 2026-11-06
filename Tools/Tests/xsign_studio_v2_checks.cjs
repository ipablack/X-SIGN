const fs=require('node:fs'),path=require('node:path'),{execFileSync}=require('node:child_process');
const root=path.resolve(__dirname,'../StudioSource');
execFileSync('python3',['scripts/build.py'],{cwd:root,stdio:'inherit'});
for(const name of ['XSign_Studio.html','XSign_Studio_v2.html']) {
 if(!fs.readFileSync(path.join(root,'dist/index.html')).equals(fs.readFileSync(path.resolve(root,'..',name))))throw Error('Dashboard source and '+name+' differ');
}
execFileSync(process.execPath,['--test',...fs.readdirSync(path.join(root,'tests')).filter(n=>n.endsWith('.test.cjs')).sort().map(n=>'tests/'+n)],{cwd:root,stdio:'inherit'});
