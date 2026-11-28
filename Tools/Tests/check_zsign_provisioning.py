"""Execute the pinned engine's actual provision write/removal blocks in C++."""
from pathlib import Path
import argparse, subprocess, tempfile

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path('Zsign/src/bundle.cpp'))
    args = parser.parse_args()
    source = args.source.read_text()
    start = source.index('ZFile::RemoveFileV("%s/embedded.mobileprovision"')
    end = source.index('\n\tif (!arrInjectDylibs.empty())', start)
    writer = source[start:end]
    start = source.index('if (m_bRemoveProvision && strKey == "embedded.mobileprovision")')
    end = source.index('\n\t\tstring strFile =', start)
    remover = source[start:end]
    code = r'''
#include <filesystem>
#include <fstream>
#include <string>
#include <cstdarg>
#include <cstdio>
#include <stdexcept>
using namespace std;
struct ZLog { static void ErrorV(const char*, ...) {} static void Print(const char*, ...) {} };
struct ZFile {
 static string path(const char* format, va_list args) { char result[4096]; vsnprintf(result,sizeof(result),format,args); return result; }
 static void RemoveFileV(const char* format, ...) { va_list args; va_start(args,format); auto p=path(format,args); va_end(args); filesystem::remove(p); }
 static bool WriteFileV(const string& data,const char* format,...) { va_list args; va_start(args,format); auto p=path(format,args); va_end(args); ofstream file(p,ios::binary); file<<data; return bool(file); }
};
struct Asset { string m_strProvData; };
bool prepareProfile(const string& m_strAppFolder, Asset* pSignAsset, bool bRemoveProvision) {
''' + writer + r'''
 return true;
}
void resourceProfile(const string& strFolder,bool m_bRemoveProvision) {
 for(const string strKey : {string("embedded.mobileprovision")}) {
''' + remover + r'''
 }
}
int main(int argc,char** argv) {
 const string dir=argv[1]; const auto file=filesystem::path(dir)/"embedded.mobileprovision";
 Asset asset{"new-profile"};
 for(bool remove : {false,true}) {
   ofstream(file)<<"old-profile";
   if(!prepareProfile(dir,&asset,remove)) throw runtime_error("profile setup failed");
   resourceProfile(dir,remove);
   if(filesystem::exists(file)==remove) throw runtime_error("provision flag was inverted or profile was deleted after writing");
   if(!remove) { ifstream stream(file); string value; stream>>value; if(value!="new-profile") throw runtime_error("old profile remained"); }
 }
 Asset noProfile{""};
 if(!prepareProfile(dir,&noProfile,false) || filesystem::exists(file)) throw runtime_error("unexpected profile without signing asset");
 const string absent=dir+"/missing/subdirectory";
 if(prepareProfile(absent,&asset,false)) throw runtime_error("profile write failure reported success");
 puts("PASS: actual Zsign C++ embeds the selected profile by default, removes it only on request, and rejects failed writes");
}
'''
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        (root/'check.cpp').write_text(code)
        subprocess.run(['c++','-std=c++17',str(root/'check.cpp'),'-o',str(root/'check')], check=True)
        subprocess.run([str(root/'check'),str(root)],check=True)


def check_application_identifiers():
    native = Path('Zsign/src')
    common = native / 'common'
    source = (native / 'openssl.cpp').read_text()
    policy = source[source.index('static bool provisionAllows('):source.index('bool ZSignAsset::Init(')]
    program = r'''
#include <ctime>
#include <cassert>
#include <cstdio>
#include "json.h"

struct ZSignAsset {
    bool m_bAdhoc = false;
    string m_strApplicationId, m_strEntitleData, m_strTeamId;
    jvalue m_provisionEntitlements;
    bool ApplicationIdentifierForBundle(const string&, string&) const;
    bool EntitlementsForBundle(const string&, string&) const;
};
''' + policy + r'''
int main() {
    ZSignAsset asset;
    asset.m_strTeamId = "TEAM";
    asset.m_strApplicationId = "PREFIX.com.example.*";
    jvalue requested;
    requested["application-identifier"] = "PREVIOUS.com.original";
    requested["keychain-access-groups"].push_back("PREFIX.com.example.*");
    requested["keychain-access-groups"].push_back("PREFIX.com.example.shared");
    requested["keychain-access-groups"].push_back("PREVIOUS.com.original");
    asset.m_strEntitleData = requested.style_write_plist();
    asset.m_provisionEntitlements["keychain-access-groups"].push_back("PREFIX.com.example.*");
    for (const string bundle : {"com.example.changed", "com.example.changed.extension"}) {
        string signedEntitlements;
        assert(asset.EntitlementsForBundle(bundle, signedEntitlements));
        jvalue actual;
        assert(actual.read_plist(signedEntitlements));
        assert(actual.at("application-identifier").as_string() == "PREFIX." + bundle);
        assert(actual.at("com.apple.developer.team-identifier").as_string() == "TEAM");
        const auto& groups = actual.at("keychain-access-groups");
        assert(groups.size() == 2);
        assert(groups.at(0).as_string() == "PREFIX." + bundle);
        assert(groups.at(1).as_string() == "PREFIX.com.example.shared");
    }
    string identifier;
    assert(!asset.ApplicationIdentifierForBundle("com.unrelated", identifier));
    assert(!asset.ApplicationIdentifierForBundle("com.example.", identifier));
    asset.m_strApplicationId = "PREFIX.com.example.app";
    assert(asset.ApplicationIdentifierForBundle("com.example.app", identifier));
    assert(!asset.ApplicationIdentifierForBundle("com.example.app.extension", identifier));
    asset.m_strApplicationId = "PREFIX.*";
    assert(asset.ApplicationIdentifierForBundle("Xsign", identifier) && identifier == "PREFIX.Xsign");
    puts("PASS: actual Zsign entitlements preserve exact app IDs, scope wildcards and validate keychain access groups");
}
'''
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        (root / 'identity.cpp').write_text(program)
        sources = [common / filename for filename in ('json.cpp', 'base64.cpp', 'fs.cpp', 'util.cpp', 'log.cpp')]
        subprocess.run(['c++', '-std=c++17', '-I', str(common), str(root / 'identity.cpp'),
                        *map(str, sources), '-o', str(root / 'identity')], check=True)
        subprocess.run([str(root / 'identity')], check=True)


if __name__ == '__main__':
    main()
    check_application_identifiers()
