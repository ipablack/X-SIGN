from pathlib import Path
import os,subprocess
root=Path(os.environ['RUNNER_TEMP'])/'xsign-self-update-key'
root.mkdir(exist_ok=True)
def call(*args):subprocess.run(['openssl',*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
call('req','-x509','-newkey','rsa:2048','-nodes','-subj','/CN=XSign Self Update Test','-days','1','-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem'))
call('x509','-in',str(root/'cert.pem'),'-outform','DER','-out',str(root/'cert.der'))
call('pkcs12','-export','-inkey',str(root/'key.pem'),'-in',str(root/'cert.pem'),'-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1','-passout','pass:fixture-only','-out',str(root/'identity.p12'))
print('Created ephemeral self-update identity fixture outside the application bundle')
