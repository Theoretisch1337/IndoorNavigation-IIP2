/// <reference path="../pb_data/types.d.ts" />

// Initiale Collections für den InNav-C2-Server (Spec 02).
//
// - beacons:      Live-Übersicht je Beacon (vom Telemetrie-Hook upserted) —
//                 Datenquelle für das Dashboard (Akku-Ampel, letzte Sicht).
// - telemetry:    Append-only-Log aller RSSI-Messungen, die die App meldet.
// - fingerprints: Kalibrier-Signaturen (Phase-2-Sync aus der App).
//
// Lese-Regeln sind öffentlich ("") → das statische Dashboard liest ohne Login.
// Schreiben ist gesperrt (null) — Telemetrie kommt ausschliesslich über den
// Server-Hook /api/telemetry/batch (läuft mit DAO-Rechten, umgeht API-Regeln).
// Produktiv-Härtung: Regeln auf Auth umstellen + Dashboard-Login (README).

migrate(
  (app) => {
    const beacons = new Collection({
      type: 'base',
      name: 'beacons',
      listRule: '',
      viewRule: '',
      fields: [
        { name: 'beaconId', type: 'number', required: true, onlyInt: true },
        { name: 'label', type: 'text' },
        { name: 'floorId', type: 'text' },
        { name: 'xMeters', type: 'number' },
        { name: 'yMeters', type: 'number' },
        { name: 'txPower', type: 'number' },
        { name: 'lastRssi', type: 'number' },
        { name: 'lastBatteryPercent', type: 'number' },
        { name: 'lastSequence', type: 'number' },
        { name: 'lastDeviceId', type: 'text' },
        { name: 'lastSeenAt', type: 'date' },
        { name: 'created', type: 'autodate', onCreate: true, onUpdate: false },
        { name: 'updated', type: 'autodate', onCreate: true, onUpdate: true },
      ],
      indexes: [
        'CREATE UNIQUE INDEX `idx_beacons_beaconId` ON `beacons` (`beaconId`)',
      ],
    });
    app.save(beacons);

    const telemetry = new Collection({
      type: 'base',
      name: 'telemetry',
      listRule: '',
      viewRule: '',
      fields: [
        { name: 'beaconId', type: 'number', required: true, onlyInt: true },
        { name: 'deviceId', type: 'text' },
        { name: 'rssi', type: 'number', required: true },
        { name: 'batteryPercent', type: 'number' },
        { name: 'sequence', type: 'number' },
        { name: 'ts', type: 'date', required: true },
        { name: 'created', type: 'autodate', onCreate: true, onUpdate: false },
      ],
      indexes: [
        'CREATE INDEX `idx_telemetry_beaconId` ON `telemetry` (`beaconId`)',
        'CREATE INDEX `idx_telemetry_ts` ON `telemetry` (`ts`)',
      ],
    });
    app.save(telemetry);

    const fingerprints = new Collection({
      type: 'base',
      name: 'fingerprints',
      listRule: '',
      viewRule: '',
      fields: [
        // App-seitige Fingerprint-ID ("fp-…") für idempotenten Upsert beim Sync.
        { name: 'clientId', type: 'text', required: true },
        { name: 'floorId', type: 'text', required: true },
        { name: 'xMeters', type: 'number', required: true },
        { name: 'yMeters', type: 'number', required: true },
        { name: 'rssiByBeaconJson', type: 'json', maxSize: 200000 },
        { name: 'sampleCount', type: 'number', onlyInt: true },
        { name: 'capturedAt', type: 'date' },
        { name: 'capturedBy', type: 'text' },
        { name: 'created', type: 'autodate', onCreate: true, onUpdate: false },
      ],
      indexes: [
        'CREATE INDEX `idx_fingerprints_floorId` ON `fingerprints` (`floorId`)',
        'CREATE UNIQUE INDEX `idx_fingerprints_clientId` ON `fingerprints` (`clientId`)',
      ],
    });
    app.save(fingerprints);
  },
  (app) => {
    // Rollback — in umgekehrter Reihenfolge löschen.
    for (const name of ['fingerprints', 'telemetry', 'beacons']) {
      try {
        app.delete(app.findCollectionByNameOrId(name));
      } catch (_) {
        // Collection existiert nicht (mehr) — ignorieren.
      }
    }
  }
);
