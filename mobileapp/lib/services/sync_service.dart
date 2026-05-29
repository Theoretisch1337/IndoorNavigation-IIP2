import 'api_service.dart';
import 'storage.dart';

/// Synchronisiert **Beacon-Platzierungen** und **Fingerprints** mit dem
/// C2-Server, damit die einmal eingerichtete Konfiguration auf **allen**
/// Geräten verfügbar ist.
///
/// Bewusst **explizit** (push / pull / syncNow) statt Auto-Push bei jeder
/// Änderung — das vermeidet Sync-Schleifen (pull → Storage-Write → Revision →
/// push → …). Alles ist fehler-tolerant (ApiService liefert bei Offline
/// `false`/leer); die App funktioniert ohne C2 unverändert lokal.
class SyncService {
  SyncService({required this.api, required this.storage, this.deviceId});

  final ApiService api;
  final Storage storage;
  final String? deviceId;

  /// Lädt alle lokalen Platzierungen + Fingerprints zum C2 hoch.
  Future<bool> push() async {
    final placements = await storage.loadBeaconPlacements();
    final fps = await storage.loadFingerprints();
    final okP = await api.postPlacements(placements);
    final okF = await api.postFingerprints(fps, deviceId: deviceId);
    return okP && okF;
  }

  /// Holt geteilte Platzierungen + Fingerprints vom C2 und merged sie lokal
  /// (remote gewinnt pro ID). Liefert die übernommenen Anzahlen.
  Future<({int placements, int fingerprints})> pull() async {
    final placements = await api.fetchPlacements();
    final fingerprints = await api.fetchFingerprints();
    await storage.mergePlacements(placements);
    await storage.mergeFingerprints(fingerprints);
    return (
      placements: placements.length,
      fingerprints: fingerprints.length,
    );
  }

  /// Vollständiger Sync: erst lokale Daten teilen (push), dann fremde holen
  /// (pull). Für den manuellen „Sync"-Knopf.
  Future<({int placements, int fingerprints})> syncNow() async {
    await push();
    return pull();
  }
}
