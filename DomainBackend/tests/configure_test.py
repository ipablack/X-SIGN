from pathlib import Path
import tempfile,json,importlib.util
spec=importlib.util.spec_from_file_location('configure',Path(__file__).parents[1]/'configure.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    root=Path(directory)
    initial={'hosting':[{'site':'another-site','public':'other','rewrites':[{'source':'**','destination':'/other.html'}]},
        {'site':'x-sign','public':'current-website','headers':[{'source':'**','headers':[]}],
        'rewrites':[{'source':'**','destination':'/index.html'}]}],
        'functions':{'source':'original-functions','codebase':'original'}}
    (root/'firebase.json').write_text(json.dumps(initial));(root/'current-website').mkdir()
    (root/'current-website/index.html').write_text('preserve-homepage')
    module.configure(root)
    updated=json.loads((root/'firebase.json').read_text())
    assert updated['hosting'][0]==initial['hosting'][0]
    assert updated['hosting'][1]['public']=='current-website'
    assert updated['hosting'][1]['rewrites'][-1]=={'source':'**','destination':'/index.html'}
    assert (root/'current-website/index.html').read_text()=='preserve-homepage'
    assert updated['functions'][0]['source']=='original-functions'
    module.configure(root)
    assert json.loads((root/'firebase.json').read_text())==updated
    (root/'functions_xsign_ota/core.cjs').write_text('unexpected backend edit')
    before=(root/'firebase.json').read_bytes()
    try:module.configure(root)
    except ValueError:pass
    else:raise AssertionError('Unexpected source change overwritten')
    assert (root/'firebase.json').read_bytes()==before
print('PASS: Firebase merge preserves current website/other sites, is idempotent, and rejects backend conflicts')
