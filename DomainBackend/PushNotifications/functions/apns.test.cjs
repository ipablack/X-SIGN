const {test} = require('node:test');
const assert = require('node:assert/strict');
const {generateKeyPairSync, verify} = require('node:crypto');
const {registration, campaign, payload, providerToken} = require('./apns.cjs');

const id = 'a'.repeat(32);
const messages = {ar:{title:'تحديث',body:'النسخة الجديدة'}, en:{title:'Update',body:'New version'}, ckb:{title:'نوێکردنەوە',body:'وەشانی نوێ'}};

test('registration accepts a valid token and the provisioned app only', () => {
  assert.deepEqual(registration({token:id,language:'ckb',bundle:'Xsign'}, 'Xsign'), {token:id,language:'ckb'});
  assert.equal(registration({token:id,language:'ckb',bundle:'Other'},'Xsign'), null);
  assert.equal(registration({token:id,language:'xx',bundle:'Xsign'},'Xsign'), null);
  assert.equal(registration({token:'../app',language:'ar',bundle:'Xsign'},'Xsign'), null);
});

test('alerts carry only the selected language and verified destination type', () => {
  const notice = campaign({id,kind:'app',target:'com.example.product',messages});
  assert.deepEqual(JSON.parse(payload(notice,'ckb')), {aps:{alert:messages.ckb,sound:'default',
    category:'XSIGN_STUDIO_NOTICE'},xsign_kind:'app',xsign_target:'com.example.product'});
  assert.deepEqual(JSON.parse(payload(notice,'unrecognized')).aps.alert, messages.ar);
  assert.ok(campaign({id,kind:'link',target:'https://example.test/help#installation',messages}));
  assert.ok(campaign({id,kind:'tweak',target:id,messages}));
  assert.equal(campaign({id,kind:'link',target:'https://user:password@example.test',messages}), null);
  assert.equal(campaign({id,kind:'link',target:'http://example.test',messages}), null);
  assert.equal(campaign({id,kind:'tweak',target:'unknown',messages}), null);
  assert.equal(campaign({id,kind:'app',target:'product',messages:{ar:messages.ar,en:messages.en}}), null);
});

test('APNs bearer uses a valid raw P-256 signature', () => {
  const {privateKey, publicKey} = generateKeyPairSync('ec', {namedCurve:'prime256v1'});
  const key = privateKey.export({type:'pkcs8',format:'pem'});
  const [header, claims, signature] = providerToken({key,keyID:'ABCDEFGHIJ',teamID:'ZYXWVUTSRQ'}, 1234).split('.');
  const decode = piece => JSON.parse(Buffer.from(piece,'base64url').toString());
  assert.deepEqual(decode(header),{alg:'ES256',kid:'ABCDEFGHIJ'});
  assert.deepEqual(decode(claims),{iss:'ZYXWVUTSRQ',iat:1234});
  assert.ok(verify('sha256', Buffer.from(header+'.'+claims),
    {key:publicKey,dsaEncoding:'ieee-p1363'}, Buffer.from(signature,'base64url')));
});
