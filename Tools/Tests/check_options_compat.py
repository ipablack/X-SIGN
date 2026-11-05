"""Compile the actual Options struct and verify migration of saved configurations."""
import argparse, platform, subprocess, tempfile
from pathlib import Path

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--swiftc',default='swiftc')
    parser.add_argument('--sdk')
    parser.add_argument('--target')
    args=parser.parse_args()
    host_flags=[]
    if platform.system() == 'Darwin' or args.sdk:
        sdk=args.sdk or subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
        if not Path(sdk).is_dir(): raise RuntimeError('The selected macOS SDK is missing: '+sdk)
        target=args.target or platform.machine()+'-apple-macosx13.0'
        host_flags=['-sdk',sdk,'-target',target]
        print('Options test macOS SDK: '+sdk+'; target: '+target,flush=True)
    root=Path(__file__).resolve().parents[2]
    source=(root/'Feather/Backend/Observable/OptionsManager.swift').read_text()
    source=source[source.index('struct Options:'):]
    support='''import Foundation
extension String { static func localized(_ value: String) -> String { value } }
'''
    checks='''
@main struct OptionsChecks {
 static func main() throws {
  let data=try JSONEncoder().encode(Options.defaultOptions)
  var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  object.removeValue(forKey:"matchCertificateAppID")
  let legacy=try JSONDecoder().decode(Options.self,from:JSONSerialization.data(withJSONObject:object))
  guard legacy.matchCertificateAppID != true else { throw NSError(domain:"Migration",code:1) }
  object["matchCertificateAppID"]=true
  let enabled=try JSONDecoder().decode(Options.self,from:JSONSerialization.data(withJSONObject:object))
  guard enabled.matchCertificateAppID == true else { throw NSError(domain:"Migration",code:2) }
  object["matchCertificateAppID"]="true"
  var rejected=false
  do { _=try JSONDecoder().decode(Options.self,from:JSONSerialization.data(withJSONObject:object)) } catch { rejected=true }
  guard rejected else { throw NSError(domain:"Migration",code:3) }
  print("PASS: actual Options decoder preserves older configurations, opts out by default and accepts the new explicit Boolean")
 }
}
'''
    with tempfile.TemporaryDirectory() as folder:
        folder=Path(folder);file=folder/'options.swift';file.write_text(support+source+checks)
        subprocess.run([args.swiftc,*host_flags,'-swift-version','5','-parse-as-library',str(file),'-o',str(folder/'check')],check=True)
        subprocess.run([str(folder/'check')],check=True)

if __name__=='__main__': main()
