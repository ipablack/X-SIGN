const {createHash, timingSafeEqual} = require('node:crypto');
const {initializeApp} = require('firebase-admin/app');
const {FieldPath, getFirestore} = require('firebase-admin/firestore');
const {onRequest} = require('firebase-functions/v2/https');
const {onDocumentCreated} = require('firebase-functions/v2/firestore');
const {defineSecret, defineString} = require('firebase-functions/params');
const {registration, campaign, sender} = require('./apns.cjs');

initializeApp();
const db = getFirestore();
const devices = db.collection('xsignPushDevices');
const campaigns = db.collection('xsignPushCampaigns');
const batches = db.collection('xsignPushBatches');

const admin = defineSecret('XSIGN_PUSH_ADMIN_TOKEN');
const apnsKey = defineSecret('XSIGN_APNS_PRIVATE_KEY');
const bundle = defineString('XSIGN_APNS_BUNDLE');
const keyID = defineString('XSIGN_APNS_KEY_ID');
const teamID = defineString('XSIGN_APNS_TEAM_ID');
const environment = defineString('XSIGN_APNS_ENVIRONMENT', {default: 'production'});
const pageSize = 72;
const region = 'us-central1';
const digest = value => createHash('sha256').update(value).digest();
const clock = () => Math.floor(Date.now() / 1000);

function authorized(header, key) {
  return typeof key === 'string' && key.length >= 32 && typeof header === 'string' && header.length <= 512
    && timingSafeEqual(digest(header), digest('Bearer ' + key));
}

exports.push = onRequest({region, secrets: [admin], cors: true, maxInstances: 8}, async (req, res) => {
  res.set('Cache-Control', 'no-store');
  const route = req.path;
  if (route === '/register' && req.method === 'POST') {
    const validated = registration(req.body, bundle.value());
    if (!validated || req.rawBody.length > 2048) return res.status(400).end();
    const ref = devices.doc(digest(validated.token).toString('hex'));
    await db.runTransaction(async transaction => {
      const existing = (await transaction.get(ref)).data();
      const updated = clock();
      if (existing?.language !== validated.language || updated - existing.updated > 6 * 3600) {
        transaction.set(ref, {...validated, updated});
      }
    });
    return res.status(204).end();
  }

  if (!authorized(req.get('Authorization'), admin.value())) return res.status(404).end();
  if (route === '/send' && req.method === 'POST') {
    const validated = campaign(req.body);
    if (!validated || req.rawBody.length > 8192) return res.status(400).json({error: 'invalid_notice'});
    const ref = campaigns.doc(validated.id);
    const signature = digest(JSON.stringify(validated)).toString('hex');
    const enqueue = await db.runTransaction(async transaction => {
      const existing = (await transaction.get(ref)).data();
      if (existing) return existing.signature === signature;
      transaction.create(ref, {...validated, signature, expiration: clock() + 86400,
        accepted: 0, failed: 0, status: 'queued'});
      transaction.create(batches.doc(validated.id + '-0'), {campaign: validated.id, page: 0, cursor: ''});
      return true;
    });
    if (!enqueue) return res.status(409).json({error: 'reused_id'});
    return res.status(202).json({id: validated.id, status: 'queued'});
  }

  if (route === '/status' && req.method === 'GET' && typeof req.query.id === 'string' && /^[0-9a-f]{32}$/.test(req.query.id)) {
    const notice = (await campaigns.doc(req.query.id).get()).data();
    if (!notice) return res.status(404).end();
    const {status, accepted, failed} = notice;
    return res.json({status, accepted, failed});
  }
  return res.status(404).end();
});

async function deliver(send, device) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const result = await send(device);
      if (result.status !== 429 && result.status < 500) return result;
    } catch {}
    if (!attempt) await new Promise(resolve => setTimeout(resolve, 400 + 200 * Math.random()));
  }
  return {status: 503};
}

exports.xsignPushPage = onDocumentCreated({
  region, document: 'xsignPushBatches/{id}', secrets: [apnsKey],
  timeoutSeconds: 240, maxInstances: 8, retry: true
}, async event => {
  const batch = event.data;
  if (!batch) return;
  const current = (await batch.ref.get()).data();
  if (!current || current.done) return;
  const ref = campaigns.doc(current.campaign);
  const notice = (await ref.get()).data();
  if (!notice || notice.status === 'finished' || notice.status === 'expired') return;
  if (notice.expiration <= clock()) {
    await ref.update({status: 'expired'});
    return;
  }

  let query = devices.orderBy(FieldPath.documentId()).limit(pageSize);
  if (current.cursor) query = query.startAfter(current.cursor);
  const page = (await query.get()).docs;
  const settings = {key: apnsKey.value(), keyID: keyID.value(), teamID: teamID.value(),
    bundle: bundle.value(), sandbox: environment.value() === 'sandbox'};
  let accepted = 0;
  let failed = 0;
  if (page.length) {
    const client = sender(settings, notice);
    try {
      for (let offset = 0; offset < page.length; offset += 8) {
        await Promise.all(page.slice(offset, offset + 8).map(async snapshot => {
          const device = snapshot.data();
          const result = await deliver(client.send, device);
          if (result.status === 200) accepted++;
          else {
            failed++;
            if (result.status === 410 && result.reason === 'Unregistered') {
              await snapshot.ref.delete({lastUpdateTime: snapshot.updateTime}).catch(() => {});
            }
          }
        }));
      }
    } finally {
      client.close();
    }
  }

  await db.runTransaction(async transaction => {
    const latestBatch = (await transaction.get(batch.ref)).data();
    const latestNotice = (await transaction.get(ref)).data();
    if (!latestBatch || latestBatch.done || !latestNotice) return;
    const more = page.length === pageSize && latestNotice.expiration > clock();
    transaction.update(batch.ref, {done: true});
    transaction.update(ref, {accepted: latestNotice.accepted + accepted, failed: latestNotice.failed + failed,
      status: more ? 'sending' : page.length === pageSize ? 'expired' : 'finished'});
    if (more) {
      const next = current.page + 1;
      transaction.create(batches.doc(notice.id + '-' + next),
        {campaign: notice.id, page: next, cursor: page[page.length - 1].id});
    }
  });
});
