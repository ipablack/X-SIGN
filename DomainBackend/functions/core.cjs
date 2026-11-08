'use strict';
const crypto = require('node:crypto');
const ORIGIN = 'https://x-sign.web.app';
const AAD = Buffer.from('XSign native manifest v1');
const ROUTES = new Set(['/native/prepare', '/native/manifest.plist', '/native/status']);
const headers = {
  'Cache-Control': 'no-store, max-age=0', Pragma: 'no-cache',
  'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'"
};
function failure(status) { const error = new Error('Request rejected'); error.status = status; return error; }
function keyFromHex(value) {
  if (typeof value !== 'string') throw failure(503);
  value = value.trim();
  if (!/^[0-9a-fA-F]{64}$/.test(value)) throw failure(503);
  return Buffer.from(value, 'hex');
}
function text(value, max) {
  if (typeof value !== 'string' || !value.length || Buffer.byteLength(value) > max ||
      !(typeof value.isWellFormed === 'function' ? value.isWellFormed() : !/[\uD800-\uDFFF]/.test(value.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, ''))) || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/u.test(value)) throw failure(400);
  return value;
}
function validate(input, now = Math.floor(Date.now() / 1000)) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      Object.keys(input).sort().join(',') !== 'bundleIdentifier,bundleVersion,expiresAt,payloadURL,title') throw failure(400);
  const payload = text(input.payloadURL, 2048);
  let url;
  try { url = new URL(payload); } catch { throw failure(400); }
  const local = url.protocol === 'http:' && url.hostname === '127.0.0.1';
  const legacy = url.protocol === 'https:' && url.hostname.endsWith('.backloop.dev');
  if (!(local || legacy) || url.href !== payload || url.hostname.includes('*') ||
      url.username || url.password || url.search || url.hash || !/^[a-z0-9.-]+$/.test(url.hostname) ||
      !/^\/ota\/[0-9a-f]{64}\/payload\.ipa$/.test(url.pathname) ||
      Number(url.port) < 49152 || Number(url.port) > 65535 || !url.port) throw failure(400);
  const identifier = text(input.bundleIdentifier, 255);
  if (!/^[A-Za-z0-9.-]+$/.test(identifier)) throw failure(400);
  const version = text(input.bundleVersion, 64);
  const title = text(input.title, 512);
  if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt <= now || input.expiresAt > now + 3600) throw failure(410);
  return {payloadURL: url.href, bundleIdentifier: identifier, bundleVersion: version, title, expiresAt: input.expiresAt};
}
function seal(descriptor, key) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(AAD);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(descriptor), 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([1]), nonce, cipher.getAuthTag(), ciphertext]).toString('base64url');
}
function unseal(ticket, key, now) {
  if (typeof ticket !== 'string' || ticket.length > 8192 || !/^[A-Za-z0-9_-]+$/.test(ticket)) throw failure(400);
  const bytes = Buffer.from(ticket, 'base64url');
  if (bytes.length < 30 || bytes[0] !== 1 || bytes.toString('base64url') !== ticket) throw failure(400);
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, bytes.subarray(1, 13));
    decipher.setAAD(AAD); decipher.setAuthTag(bytes.subarray(13, 29));
    const plain = Buffer.concat([decipher.update(bytes.subarray(29)), decipher.final()]);
    return validate(JSON.parse(plain.toString('utf8')), now);
  } catch (error) { if (error.status === 410) throw error; throw failure(400); }
}
function xml(value) { return value.replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[char])); }
function manifest(value) {
  return '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict>' +
    '<key>kind</key><string>software-package</string><key>url</key><string>' + xml(value.payloadURL) +
    '</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>' + xml(value.bundleIdentifier) +
    '</string><key>bundle-version</key><string>' + xml(value.bundleVersion) +
    '</string><key>kind</key><string>software</string><key>title</key><string>' + xml(value.title) +
    '</string></dict></dict></array></dict></plist>';
}
function createHandler({keyProvider, clock = () => Math.floor(Date.now() / 1000), rateLimit = 120} = {}) {
  const buckets = new Map();
  return function handler(request, response) {
    for (const [name, value] of Object.entries(headers)) response.setHeader(name, value);
    const reject = status => { response.statusCode = status; response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({error:'Request rejected'})); };
    try {
      const url = new URL(request.originalUrl || request.url, ORIGIN);
      if (url.href.length > 9000) throw failure(414);
      if (!ROUTES.has(url.pathname)) throw failure(404);
      if (request.headers.origin || request.headers['content-encoding'] || request.headers['transfer-encoding']) throw failure(403);
      const now = clock();
      const ip = String(request.ip || request.socket?.remoteAddress || 'unknown').slice(0, 128);
      for (const [key, value] of buckets) if (now - value.start >= 60) buckets.delete(key);
      const budget = buckets.get(ip) || {start: now, count: 0};
      if (buckets.size >= 4096 && !buckets.has(ip)) throw failure(429);
      budget.count++; buckets.set(ip, budget);
      if (budget.count > rateLimit) throw failure(429);
      const key = keyFromHex(keyProvider?.());
      if (url.pathname === '/native/status') {
        if (request.method !== 'GET' || url.search) throw failure(405);
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({service:'xsign-native-ota', version:1, ready:true})); return;
      }
      if (url.pathname === '/native/prepare') {
        if (request.method !== 'POST' || url.search) throw failure(405);
        if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] || '')) throw failure(415);
        const raw = request.rawBody;
        if (!Buffer.isBuffer(raw) || raw.length > 8192) throw failure(413);
        let body;
        try { body = JSON.parse(raw.toString('utf8')); } catch { throw failure(400); }
        const descriptor = validate(body, now);
        const ticket = seal(descriptor, key);
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({manifestURL:ORIGIN + '/native/manifest.plist?ticket=' + ticket})); return;
      }
      if (request.method !== 'GET') throw failure(405);
      if (url.searchParams.size !== 1 || !url.searchParams.has('ticket')) throw failure(400);
      const descriptor = unseal(url.searchParams.get('ticket'), key, now);
      response.setHeader('Content-Type', 'application/xml; charset=utf-8');
      response.end(manifest(descriptor));
    } catch (error) { reject(error.status || 400); }
  };
}
module.exports = {createHandler, validate, seal, unseal, manifest};
