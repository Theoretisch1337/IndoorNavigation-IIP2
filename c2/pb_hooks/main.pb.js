/// <reference path="../pb_data/types.d.ts" />

// InNav-C2 — Server-Logik (PocketBase JSVM-Hooks).
//
// Kernstück: der Sammel-Upload-Endpunkt, den die Mobile-App nutzt
// (services/api_service.dart → POST /api/telemetry/batch). Der Endpunkt
// matcht den App-Vertrag exakt:
//
//   Header: X-Innav-Token: <token>            (nur geprüft, wenn INNAV_TOKEN gesetzt)
//   Body:   { "records": [ { beaconId, deviceId, rssi, batteryPercent?,
//                            sequence?, ts }, ... ] }
//
// /api/health liefert PocketBase bereits selbst — nicht hier nötig.

// Hinweis: PocketBase führt jeden Hook-Handler in einer isolierten JS-VM aus —
// gemeinsame Top-Level-Helfer, die $-Bindings ($os/$app) nutzen, sind dort NICHT
// verfügbar. Darum ist die Token-Prüfung in jedem Handler inline.

routerAdd('POST', '/api/telemetry/batch', (e) => {
  const expectedToken = $os.getenv('INNAV_TOKEN');
  if (expectedToken &&
      e.request.header.get('X-Innav-Token') !== expectedToken) {
    return e.json(401, { error: 'invalid or missing X-Innav-Token' });
  }

  const body = e.requestInfo().body || {};
  const records = body.records;
  if (!Array.isArray(records)) {
    return e.json(400, { error: 'body.records[] required' });
  }

  let saved = 0;
  e.app.runInTransaction((txApp) => {
    const beaconsCol = txApp.findCollectionByNameOrId('beacons');
    const telemetryCol = txApp.findCollectionByNameOrId('telemetry');

    for (const r of records) {
      const beaconId = Number(r.beaconId);
      if (!isFinite(beaconId)) continue;

      const rssi = Number(r.rssi);
      const battery = r.batteryPercent == null ? null : Number(r.batteryPercent);
      const sequence = r.sequence == null ? null : Number(r.sequence);
      const deviceId = r.deviceId || '';
      const ts = r.ts || new Date().toISOString();

      // 1) Append-only-Telemetrie-Zeile.
      const t = new Record(telemetryCol, {
        beaconId: beaconId,
        deviceId: deviceId,
        rssi: rssi,
        batteryPercent: battery,
        sequence: sequence,
        ts: ts,
      });
      txApp.save(t);
      saved++;

      // 2) Beacon-Übersicht upserten (Datenquelle fürs Dashboard).
      let beacon = null;
      try {
        beacon = txApp.findFirstRecordByFilter(
          'beacons',
          'beaconId = {:id}',
          { id: beaconId }
        );
      } catch (_) {
        beacon = null; // noch kein Beacon mit dieser ID
      }
      if (!beacon) {
        beacon = new Record(beaconsCol, { beaconId: beaconId });
      }
      beacon.set('lastRssi', rssi);
      if (battery !== null) beacon.set('lastBatteryPercent', battery);
      if (sequence !== null) beacon.set('lastSequence', sequence);
      beacon.set('lastDeviceId', deviceId);
      beacon.set('lastSeenAt', ts);
      txApp.save(beacon);
    }
  });

  return e.json(200, { ok: true, saved: saved });
});

// POST /api/placements/batch — Beacon-Platzierungen teilen (für alle Geräte).
// Upsert in die beacons-Collection (floorId/x/y/label/txPower); lastRssi etc.
// bleiben vom Telemetrie-Hook unberührt.
routerAdd('POST', '/api/placements/batch', (e) => {
  const expectedToken = $os.getenv('INNAV_TOKEN');
  if (expectedToken &&
      e.request.header.get('X-Innav-Token') !== expectedToken) {
    return e.json(401, { error: 'invalid token' });
  }

  const placements = (e.requestInfo().body || {}).placements;
  if (!Array.isArray(placements)) {
    return e.json(400, { error: 'body.placements[] required' });
  }

  let saved = 0;
  e.app.runInTransaction((txApp) => {
    const beaconsCol = txApp.findCollectionByNameOrId('beacons');
    for (const p of placements) {
      const beaconId = Number(p.beaconId);
      if (!isFinite(beaconId)) continue;

      let beacon = null;
      try {
        beacon = txApp.findFirstRecordByFilter(
          'beacons',
          'beaconId = {:id}',
          { id: beaconId }
        );
      } catch (_) {
        beacon = null;
      }
      if (!beacon) beacon = new Record(beaconsCol, { beaconId: beaconId });

      beacon.set('floorId', p.floorId || '');
      beacon.set('xMeters', Number(p.xMeters) || 0);
      beacon.set('yMeters', Number(p.yMeters) || 0);
      if (p.label != null) beacon.set('label', p.label);
      if (p.txPower != null) beacon.set('txPower', Number(p.txPower));
      txApp.save(beacon);
      saved++;
    }
  });

  return e.json(200, { ok: true, saved: saved });
});

// POST /api/fingerprints/batch — Kalibrier-Fingerprints teilen (Upsert nach
// clientId, damit erneutes Hochladen keine Duplikate erzeugt).
routerAdd('POST', '/api/fingerprints/batch', (e) => {
  const expectedToken = $os.getenv('INNAV_TOKEN');
  if (expectedToken &&
      e.request.header.get('X-Innav-Token') !== expectedToken) {
    return e.json(401, { error: 'invalid token' });
  }

  const fps = (e.requestInfo().body || {}).fingerprints;
  if (!Array.isArray(fps)) {
    return e.json(400, { error: 'body.fingerprints[] required' });
  }

  let saved = 0;
  e.app.runInTransaction((txApp) => {
    const col = txApp.findCollectionByNameOrId('fingerprints');
    for (const f of fps) {
      const clientId = String(f.clientId || '');
      if (!clientId) continue;

      let rec = null;
      try {
        rec = txApp.findFirstRecordByFilter(
          'fingerprints',
          'clientId = {:c}',
          { c: clientId }
        );
      } catch (_) {
        rec = null;
      }
      if (!rec) rec = new Record(col, { clientId: clientId });

      rec.set('floorId', f.floorId || '');
      rec.set('xMeters', Number(f.xMeters) || 0);
      rec.set('yMeters', Number(f.yMeters) || 0);
      rec.set('rssiByBeaconJson', f.rssiByBeaconJson || {});
      rec.set('sampleCount', Number(f.sampleCount) || 0);
      if (f.capturedAt) rec.set('capturedAt', f.capturedAt);
      if (f.capturedBy) rec.set('capturedBy', f.capturedBy);
      txApp.save(rec);
      saved++;
    }
  });

  return e.json(200, { ok: true, saved: saved });
});

// POST /api/fingerprints/delete — Fingerprints nach clientId loeschen.
// Gegenstueck zum lokalen Loeschen in der App: ohne diesen Endpunkt kaeme ein
// am Handy geloeschter Fingerprint beim naechsten Sync vom Server zurueck
// (C2 ist Source of Truth). Token-geschuetzt wie die batch-Hooks.
routerAdd('POST', '/api/fingerprints/delete', (e) => {
  const expectedToken = $os.getenv('INNAV_TOKEN');
  if (expectedToken &&
      e.request.header.get('X-Innav-Token') !== expectedToken) {
    return e.json(401, { error: 'invalid token' });
  }

  const ids = (e.requestInfo().body || {}).clientIds;
  if (!Array.isArray(ids)) {
    return e.json(400, { error: 'body.clientIds[] required' });
  }

  let deleted = 0;
  e.app.runInTransaction((txApp) => {
    for (const raw of ids) {
      const clientId = String(raw || '');
      if (!clientId) continue;
      let rec = null;
      try {
        rec = txApp.findFirstRecordByFilter(
          'fingerprints',
          'clientId = {:c}',
          { c: clientId }
        );
      } catch (_) {
        rec = null;
      }
      if (rec) {
        txApp.delete(rec);
        deleted++;
      }
    }
  });

  return e.json(200, { ok: true, deleted: deleted });
});

// Telemetrie älter als 30 Tage täglich um 03:00 entfernen (Tabelle wächst
// hochfrequent — siehe Spec 02, Risiko "unbounded growth").
cronAdd('cleanup_telemetry', '0 3 * * *', () => {
  const cutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  $app
    .db()
    .newQuery('DELETE FROM telemetry WHERE ts < {:cutoff}')
    .bind({ cutoff: cutoff })
    .execute();
});
