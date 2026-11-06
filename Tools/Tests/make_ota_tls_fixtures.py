from pathlib import Path
import os,subprocess
root=Path(os.environ['RUNNER_TEMP'])/'xsign-ota-tls-fixtures'
root.mkdir(parents=True,exist_ok=True)
ca_cfg=root/'ca.cnf'
ca_cfg.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=XSign Test Root CA\n[ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=XSign Test Root CA',
 '-config',str(ca_cfg),'-keyout',str(root/'ca-key.pem'),'-out',str(root/'ca-cert.pem')],
 check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
leaf_cfg=root/'leaf.cnf'
leaf_cfg.write_text('[req]\nprompt=no\ndistinguished_name=dn\nreq_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
subprocess.run(['openssl','req','-new','-newkey','rsa:2048','-nodes','-subj','/CN=localhost',
 '-config',str(leaf_cfg),'-keyout',str(root/'private-key.pem'),'-out',str(root/'leaf.csr')],
 check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['openssl','x509','-req','-days','1','-in',str(root/'leaf.csr'),
 '-CA',str(root/'ca-cert.pem'),'-CAkey',str(root/'ca-key.pem'),'-CAcreateserial',
 '-extfile',str(leaf_cfg),'-extensions','ext','-out',str(root/'leaf-cert.pem')],
 check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
(root/'certificate.pem').write_bytes((root/'leaf-cert.pem').read_bytes()+(root/'ca-cert.pem').read_bytes())
(root/'private-key.pem').chmod(0o600)
print(root)
