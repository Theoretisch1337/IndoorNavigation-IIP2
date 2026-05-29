import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/beacon_placement.dart';
import '../models/fingerprint.dart';
import '../models/telemetry_record.dart';

/// HTTP-Client für den C2-Server (siehe `.ai/specs/02-c2-server.md`).
///
/// Alle Methoden sind **fehler-tolerant**: Netzwerkfehler werfen keine
/// Exception, sondern liefern `false` / leere Ergebnisse. Das ist
/// beabsichtigt — die App muss auch offline funktionieren (Position wird
/// lokal berechnet, der C2-Server ist nur für Telemetrie + Konfig-Sync da).
///
/// Der C2-Server existiert in Phase 1 noch nicht; `postTelemetryBatch`
/// liefert dann konsistent `false` und der [TelemetryUploader] behält die
/// Records in der Queue.
class ApiService {
  ApiService({
    this.baseUrl = defaultBaseUrl,
    this.apiToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  /// Default-Endpoint: C2-Server (PocketBase im Docker auf dem projects-Server).
  /// Domain `indoornav.theoretisch.ch`. Frueher `iip2.theoretisch.ch`
  /// (Bare-Metal) - abgeloest durch das Docker-Deploy (siehe infra/DEPLOY).
  static const String defaultBaseUrl = 'https://indoornav.theoretisch.ch';

  final String baseUrl;
  final String? apiToken;
  final Duration timeout;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Innav-Token': ?apiToken,
      };

  /// Sendet eine Batch von Telemetrie-Records an den C2-Server.
  /// Gibt `true` bei HTTP 2xx zurück, sonst `false` (inkl. Netzwerkfehler,
  /// Timeout, oder wenn der Server nicht erreichbar ist).
  Future<bool> postTelemetryBatch(List<TelemetryRecord> records) async {
    if (records.isEmpty) return true;
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/telemetry/batch'),
            headers: _headers,
            body: jsonEncode({
              'records': records.map((r) => r.toJson()).toList(),
            }),
          )
          .timeout(timeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // --- Konfig-Sync: Beacon-Platzierungen ---------------------------------

  /// Lädt platzierte Beacons hoch (für alle Geräte verfügbar). 2xx → true.
  Future<bool> postPlacements(List<BeaconPlacement> placements) async {
    if (placements.isEmpty) return true;
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/placements/batch'),
            headers: _headers,
            body: jsonEncode({
              'placements': [
                for (final p in placements)
                  {
                    'beaconId': p.beaconId,
                    'floorId': p.floorId,
                    'xMeters': p.xMeters,
                    'yMeters': p.yMeters,
                    if (p.label != null) 'label': p.label,
                    if (p.txPowerOverride != null) 'txPower': p.txPowerOverride,
                  },
              ],
            }),
          )
          .timeout(timeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Lädt alle geteilten Beacon-Platzierungen vom C2. Leere Liste bei Fehler.
  Future<List<BeaconPlacement>> fetchPlacements() async {
    try {
      final filter = Uri.encodeQueryComponent('floorId != ""');
      final resp = await _client
          .get(
            Uri.parse(
              '$baseUrl/api/collections/beacons/records?perPage=200&filter=$filter',
            ),
            headers: _headers,
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return const [];
      final items = (jsonDecode(resp.body)['items'] as List?) ?? const [];
      return [
        for (final it in items.whereType<Map<String, dynamic>>())
          _placementFromC2(it),
      ];
    } catch (_) {
      return const [];
    }
  }

  BeaconPlacement _placementFromC2(Map<String, dynamic> it) {
    final tx = (it['txPower'] as num?)?.toInt();
    final label = (it['label'] as String?)?.trim();
    return BeaconPlacement(
      beaconId: (it['beaconId'] as num).toInt(),
      floorId: it['floorId'] as String? ?? '',
      xMeters: (it['xMeters'] as num?)?.toDouble() ?? 0,
      yMeters: (it['yMeters'] as num?)?.toDouble() ?? 0,
      txPowerOverride: (tx == null || tx == 0) ? null : tx,
      label: (label == null || label.isEmpty) ? null : label,
    );
  }

  // --- Konfig-Sync: Fingerprints -----------------------------------------

  /// Lädt Fingerprints hoch (Upsert nach `id`/clientId). 2xx → true.
  Future<bool> postFingerprints(
    List<Fingerprint> fps, {
    String? deviceId,
  }) async {
    if (fps.isEmpty) return true;
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/fingerprints/batch'),
            headers: _headers,
            body: jsonEncode({
              'fingerprints': [
                for (final f in fps)
                  {
                    'clientId': f.id,
                    'floorId': f.floorId,
                    'xMeters': f.xMeters,
                    'yMeters': f.yMeters,
                    'rssiByBeaconJson':
                        f.rssiByBeaconId.map((k, v) => MapEntry('$k', v)),
                    'sampleCount': f.sampleCount,
                    'capturedAt': f.capturedAt.toUtc().toIso8601String(),
                    'capturedBy': ?deviceId,
                  },
              ],
            }),
          )
          .timeout(timeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Lädt alle geteilten Fingerprints vom C2. Leere Liste bei Fehler.
  Future<List<Fingerprint>> fetchFingerprints() async {
    try {
      final resp = await _client
          .get(
            Uri.parse(
              '$baseUrl/api/collections/fingerprints/records?perPage=500',
            ),
            headers: _headers,
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return const [];
      final items = (jsonDecode(resp.body)['items'] as List?) ?? const [];
      return [
        for (final it in items.whereType<Map<String, dynamic>>())
          _fingerprintFromC2(it),
      ];
    } catch (_) {
      return const [];
    }
  }

  Fingerprint _fingerprintFromC2(Map<String, dynamic> it) {
    final rssiRaw = (it['rssiByBeaconJson'] as Map?) ?? const {};
    return Fingerprint(
      id: it['clientId'] as String,
      floorId: it['floorId'] as String? ?? '',
      xMeters: (it['xMeters'] as num?)?.toDouble() ?? 0,
      yMeters: (it['yMeters'] as num?)?.toDouble() ?? 0,
      rssiByBeaconId: {
        for (final e in rssiRaw.entries)
          int.parse('${e.key}'): (e.value as num).toDouble(),
      },
      sampleCount: (it['sampleCount'] as num?)?.toInt() ?? 0,
      capturedAt: DateTime.tryParse(it['capturedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Health-Check des C2-Servers. `true` wenn erreichbar.
  Future<bool> ping() async {
    try {
      final resp =
          await _client.get(Uri.parse('$baseUrl/api/health')).timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void dispose() => _client.close();
}
