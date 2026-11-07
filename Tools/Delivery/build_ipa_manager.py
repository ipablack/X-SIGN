"""Refresh the embedded engine in the standalone catalogue workflow."""
import base64
import re
import zlib
from pathlib import Path

root = Path(__file__).resolve().parent
workflow = root / 'ipa_manager.yml'
source = (root / 'ipa_publisher.py').read_bytes()
encoded = base64.b64encode(zlib.compress(source, 9)).decode('ascii')
text, count = re.subn(r'(?m)^(\s*XSIGN_IPA_ENGINE_B64:) [A-Za-z0-9+/=]+$',
                      lambda match: match[1] + ' ' + encoded, workflow.read_text())
if count != 1:
    raise SystemExit('Expected one embedded IPA engine in ipa_manager.yml.')
workflow.write_text(text)
