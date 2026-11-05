"""Correct provisioning in the pinned Zsign fork; preserve any other dependency edit."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / 'Zsign/src/bundle.cpp'
BEFORE = '3a2c3c807951394a9ce0ee8d7f4aec0164d3c0b09ec78474b929833b5cce25ab'
AFTER = '77ccf5e704f93172499f4cd57fab1ab7bd3a091a0eb9306d2c8d03a19d84c8d9'

def prepare(path=PATH):
    raw = path.read_bytes()
    current = hashlib.sha256(raw).hexdigest()
    if current == AFTER:
        return False
    if current != BEFORE:
        raise RuntimeError('Zsign dependency differs from the reviewed revision; existing source was preserved.')
    content = raw.decode()
    changes = [
        ('if (bRemoveProvision) {\n\t\t\tif (!ZFile::WriteFileV', 'if (!bRemoveProvision) {\n\t\t\tif (!ZFile::WriteFileV'),
        ('if (excludeProvisioning) {\n\t\tif ("/" == jvNode["path"])', 'if (!excludeProvisioning) {\n\t\tif ("/" == jvNode["path"])'),
        ('bRemoveProvision ? "NO" : "YES"', 'bRemoveProvision ? "YES" : "NO"')
    ]
    for old, new in changes:
        if content.count(old) != 1:
            raise RuntimeError('Unknown Zsign provisioning implementation')
        content = content.replace(old, new, 1)
    if hashlib.sha256(content.encode()).hexdigest() != AFTER:
        raise RuntimeError('Zsign target integrity failed')
    path.write_text(content)
    return True

if __name__ == '__main__':
    print('Prepared Zsign provisioning fix' if prepare() else 'Zsign provisioning fix is already applied')
