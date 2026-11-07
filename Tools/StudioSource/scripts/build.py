from pathlib import Path
import json
import re

root = Path(__file__).resolve().parent.parent
template = (root / 'src/template.html').read_text()
theme = (root / 'src/experience.css').read_text()
template = template.replace('<!-- XSIGN_STUDIO_THEME -->', '<style>\n' + theme + '</style>')
vendor = root / 'node_modules/js-yaml/dist/js-yaml.min.js'
if not vendor.is_file():
    raise SystemExit('Install dependencies before building (npm install).')
boot = "loadLocal();bindEvents();bindStoreEvents();renderAll();openPage(location.hash.slice(1)||'overview',false);"
parts = [vendor.read_text()]
for name in ['contract.js', 'base.js', 'store.js', 'integration.js']:
    parts.append((root / ('src/' + name)).read_text().replace(boot, ''))
install_page = root.parents[1] / 'Feather/Resources/XSignInstall.html'
if not install_page.is_file():
    install_page = root / 'src/XSignInstall.html'  # standalone Studio source export
parts.append('const XSIGN_INSTALL_TEMPLATE = ' + json.dumps(install_page.read_text(), ensure_ascii=False) + ';')
parts.append(boot)
script = '\n'.join(parts)
# Keep inline HTML strings safe for HTML parsers and development live reload.
script = re.sub(r'</script', r'<\\/script', script, flags=re.I)
script = re.sub(r'</body', r'<\\/body', script, flags=re.I)
notice = '<!-- Third-party license: js-yaml 4.1.1\n' + (root / 'node_modules/js-yaml/LICENSE').read_text() + '\n-->\n'
template = template.replace('<!-- XSIGN_APP_SCRIPTS -->', notice + '<!-- XSIGN_APP_SCRIPTS -->')
output = template.replace('<!-- XSIGN_APP_SCRIPTS -->', '<script>\n' + script + '\n</script>')
if '<!-- XSIGN_APP_SCRIPTS -->' in output:
    raise SystemExit('Script insertion failed.')
# Unicode NEL/LS/PS can occur inside valid JavaScript strings in js-yaml.
# splitlines() treats them as newlines and silently breaks the embedded script.
output = '\n'.join(line.rstrip(' \t\r') for line in output.split('\n')).rstrip('\n') + '\n'
(root / 'dist').mkdir(exist_ok=True)
(root / 'dist/index.html').write_text(output)
print('Built dist/index.html:', len(output.encode()), 'bytes')
