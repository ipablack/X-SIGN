'use strict';
const {onRequest} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');
const {createHandler} = require('./core.cjs');
const manifestKey = defineSecret('XSIGN_OTA_MANIFEST_KEY');
// No IPA/P12 storage, URL fetching, database, or request-body logging is performed.
const handler = createHandler({keyProvider: () => manifestKey.value()});
exports.xsignNativeOTA = onRequest({region:'us-central1', memory:'256MiB', timeoutSeconds:30,
  maxInstances:2, minInstances:0, concurrency:2, cors:false, secrets:[manifestKey]}, handler);
