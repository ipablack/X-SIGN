const http2 = require('node:http2');
const {createPrivateKey, sign} = require('node:crypto');

const languages = ['ar', 'en', 'ckb'];
const category = 'XSIGN_STUDIO_NOTICE';
const bytes = value => Buffer.byteLength(value, 'utf8');

function registration(data, bundle) {
  if (data?.bundle !== bundle || !languages.includes(data.language) ||
      typeof data.token !== 'string' || !/^(?:[a-f0-9]{2}){16,256}$/.test(data.token)) return null;
  return {token: data.token, language: data.language};
}

function campaign(data) {
  if (!data || !/^[0-9a-f]{32}$/.test(data.id ?? '') || !['app','tweak','link'].includes(data.kind) ||
      typeof data.target !== 'string' || !data.target.trim() || /[\x00-\x1f\x7f]/.test(data.target)) return null;
  const target = data.target.trim();
  if (data.kind === 'app' && bytes(target) > 220) return null;
  if (data.kind === 'tweak' && !/^[0-9a-f]{32}$/.test(target)) return null;
  if (data.kind === 'link') {
    try {
      const url = new URL(target);
      if (url.protocol !== 'https:' || url.username || url.password || bytes(target) > 1000) return null;
    } catch { return null; }
  }
  const messages = {};
  for (const language of languages) {
    const {title, body} = data.messages?.[language] ?? {};
    if (typeof title !== 'string' || typeof body !== 'string' || !title.trim() || !body.trim() ||
        bytes(title) > 240 || bytes(body) > 1200) return null;
    messages[language] = {title: title.trim(), body: body.trim()};
  }
  return {id: data.id, kind: data.kind, target, messages};
}

function payload(notice, language) {
  return JSON.stringify({
    aps: {alert: notice.messages[language] ?? notice.messages.ar, sound: 'default', category},
    xsign_kind: notice.kind, xsign_target: notice.target
  });
}

function providerToken({key, keyID, teamID}, now = Math.floor(Date.now() / 1000)) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const input = encode({alg: 'ES256', kid: keyID}) + '.' + encode({iss: teamID, iat: now});
  const signature = sign('sha256', Buffer.from(input), {
    key: createPrivateKey(key.replace(/\\n/g, '\n')), dsaEncoding: 'ieee-p1363'
  });
  return input + '.' + signature.toString('base64url');
}

function sender(settings, notice) {
  let session;
  const bearer = providerToken(settings);
  const host = settings.sandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
  function send(device) {
    return new Promise((resolve, reject) => {
      try {
        if (!session || session.closed || session.destroyed) {
          session = http2.connect(host);
          session.on('error', () => {}); // Individual stream failures drive retries.
        }
        const request = session.request({
          ':method': 'POST', ':path': '/3/device/' + device.token,
          authorization: 'bearer ' + bearer, 'apns-topic': settings.bundle,
          'apns-push-type': 'alert', 'apns-priority': '10',
          'apns-collapse-id': notice.id, 'apns-expiration': String(notice.expiration)
        });
        let status, raw = '';
        request.setEncoding('utf8');
        const timer = setTimeout(() => {
          request.close(http2.constants.NGHTTP2_CANCEL);
          reject(new Error('APNs request timed out'));
        }, 8000);
        request.on('response', headers => { status = headers[':status']; });
        request.on('data', part => { if (raw.length < 4096) raw += part; });
        request.on('error', error => { clearTimeout(timer); reject(error); });
        request.on('end', () => {
          clearTimeout(timer);
          if (typeof status !== 'number') return reject(new Error('Missing APNs response'));
          let reason;
          try { reason = JSON.parse(raw).reason; } catch {}
          resolve({status, reason});
        });
        request.end(payload(notice, device.language));
      } catch (error) { reject(error); }
    });
  }
  return {send, close: () => session?.destroy()};
}

module.exports = {registration, campaign, payload, providerToken, sender};
