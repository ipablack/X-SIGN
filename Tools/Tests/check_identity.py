"""Check the Xcode identity, offline icon and the uploaded Studio design contract."""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]


def main():
    branding = json.loads((ROOT / 'Tools/Integration/branding.json').read_text())
    contract = json.loads((ROOT / 'Tools/Integration/contract.json').read_text())
    assert branding['display_name'] == contract['display_name'] == 'XSign'
    assert branding['bundle_identifier'] == contract['build_bundle_identifier'] == 'com.ipablack.xsign'
    assert branding['version'] == contract['app_version'] == '1.0'
    assert branding['minimum_ios'] == contract['minimum_ios'] == '15.0'
    config = (ROOT / 'Feather.xcconfig').read_text()
    assert 'FEATHER_PRODUCT_BUNDLE_IDENTIFIER=com.ipablack.xsign' in config
    project = (ROOT / 'Feather.xcodeproj/project.pbxproj').read_text()
    assert project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(FEATHER_PRODUCT_BUNDLE_IDENTIFIER)";') == 2
    assert project.count('PRODUCT_NAME = XSign;') == 2
    assert project.count('PRODUCT_MODULE_NAME = Feather;') == 2
    assert 'path = XSign.app;' in project and 'Feather.app' not in project
    scheme = (ROOT / 'Feather.xcodeproj/xcshareddata/xcschemes/Feather.xcscheme').read_text()
    assert scheme.count('BuildableName = "XSign.app"') == 3
    info = plistlib.loads((ROOT / 'Feather/Resources/Info.plist').read_bytes())
    assert info['CFBundleDisplayName'] == info['CFBundleName'] == branding['display_name']
    assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['xsign']
    assert info['CFBundleURLTypes'][0]['CFBundleURLName'] == branding['bundle_identifier']
    assert 'CFBundleAlternateIcons' not in info['CFBundleIcons']
    assert all(item['UTTypeIdentifier'].startswith('com.ipablack.xsign.') for item in info['UTExportedTypeDeclarations'])

    icon = ROOT / branding['icon_asset']
    png = icon.read_bytes()
    assert hashlib.sha256(png).hexdigest() == branding['icon_sha256']
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    offset = 8
    compressed = []
    ended = False
    while offset < len(png):
        length = struct.unpack('>I', png[offset:offset+4])[0]
        name = png[offset+4:offset+8]
        body = png[offset+8:offset+8+length]
        crc = struct.unpack('>I', png[offset+8+length:offset+12+length])[0]
        assert zlib.crc32(name + body) & 0xffffffff == crc, 'PNG integrity failure'
        if name == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', body)
            assert (width, height, depth, color, interlace) == (1024, 1024, 8, 2, 0), 'Use a 1024px opaque RGB icon'
        if name == b'IDAT':
            compressed.append(body)
        offset += 12 + length
        if name == b'IEND':
            ended = True
            break
    assert ended and offset == len(png)
    assert len(zlib.decompress(b''.join(compressed))) == 1024 * (1 + 1024 * 3)
    contents = json.loads((icon.parent / 'Contents.json').read_text())
    assert len(contents['images']) == 1
    assert contents['images'][0]['filename'] == icon.name

    origin = json.loads((ROOT / 'Tools/Integration/panel-origin.json').read_text())
    template = (ROOT / 'Tools/StudioSource/src/template.html').read_text()
    style = re.search(r'<style>([\s\S]*?)</style>', template)[1]
    original_style = ''.join(style[start:start+length] for start, length in origin['stylesheet_segments'])
    assert len(original_style) == origin['stylesheet_characters']
    assert hashlib.sha256(original_style.encode()).hexdigest() == origin['stylesheet_sha256'], 'Preserve the uploaded panel design'
    assert set(origin['control_ids']) <= set(re.findall(r'\bid="([^"]+)"', template))
    assert set(origin['config_bindings']) <= set(re.findall(r'data-path="([^"]+)"', template))
    integration = (ROOT / 'Tools/StudioSource/src/integration.js').read_text()
    assert "bundle:'com.ipablack.xsign'" in integration
    example = json.loads((ROOT / 'Tools/Delivery/repo.example.json').read_text())
    assert example['iconURL'] == branding['icon_source_url']
    assert [item['url'] for item in example['xsign_config']['dashboard']['sources']] == contract['source_priority']
    print('PASS: XSign name, bundle, scheme, unchanged Swift module, offline 1024px icon, uploaded Studio design and source priority')


if __name__ == '__main__':
    main()
