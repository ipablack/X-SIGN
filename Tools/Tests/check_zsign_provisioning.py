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

if __name__ == '__main__': main()
