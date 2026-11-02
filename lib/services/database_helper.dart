import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/prediction.dart';

/// Local offline storage (sqflite).
///
///  trips            one row per drive (summary used for history + Time-To-Failure)
///  predictions      every analysed window (health score, findings, latency)
///  pending_windows  windows recorded while the server was unreachable,
///                   re-sent later by "Sync now" → zero telemetry loss
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();
  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'pvms.db');
    return openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE trips(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          source TEXT,
          km REAL DEFAULT 0,
          odometer_km REAL DEFAULT 0,
          avg_health REAL,
          min_health REAL,
          worst_status TEXT,
          alerts INTEGER DEFAULT 0,
          windows INTEGER DEFAULT 0,
          ltft_mean REAL,
          volt_mean REAL,
          coolant_mean REAL,
          imported INTEGER DEFAULT 0
        )''');
      await db.execute('''
        CREATE TABLE predictions(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          trip_id INTEGER NOT NULL,
          ts INTEGER NOT NULL,
          health REAL,
          status TEXT,
          regime TEXT,
          model_anomaly INTEGER,
          findings TEXT,
          rtt_ms INTEGER,
          server_ms REAL,
          late INTEGER DEFAULT 0
        )''');
      await db.execute('''
        CREATE TABLE pending_windows(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          trip_id INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          payload TEXT NOT NULL
        )''');
      await db.execute('CREATE INDEX idx_pred_trip ON predictions(trip_id)');
    });
  }

  // ---------------------------------------------------------------- trips --
  Future<int> startTrip(String source, double odometerKm) async =>
      (await db).insert('trips', {
        'started_at': DateTime.now().millisecondsSinceEpoch,
        'source': source,
        'odometer_km': odometerKm,
      });

  Future<void> finishTrip(int id, Map<String, Object?> summary) async =>
      (await db).update('trips', {...summary, 'ended_at': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ?', whereArgs: [id]);

  Future<List<Map<String, Object?>>> trips({int limit = 200}) async =>
      (await db).query('trips', where: 'ended_at IS NOT NULL', orderBy: 'odometer_km DESC, started_at DESC', limit: limit);

  Future<double> lastOdometer() async {
    final r = await (await db).rawQuery('SELECT MAX(odometer_km) AS o FROM trips');
    return (r.first['o'] as num?)?.toDouble() ?? 0;
  }

  Future<void> deleteTrip(int id) async {
    final d = await db;
    await d.delete('predictions', where: 'trip_id = ?', whereArgs: [id]);
    await d.delete('pending_windows', where: 'trip_id = ?', whereArgs: [id]);
    await d.delete('trips', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final d = await db;
    for (final t in ['predictions', 'pending_windows', 'trips']) {
      await d.delete(t);
    }
  }

  /// Imports per-segment summaries from the Opel dataset (22 refuelling segments,
  /// ~14 000 km) so the Time-To-Failure trend can be demonstrated on real history.
  Future<void> importHistory(List<Map<String, dynamic>> segments) async {
    final d = await db;
    await d.delete('trips', where: 'imported = 1');
    final base = DateTime(2025, 4, 30).millisecondsSinceEpoch;
    for (final s in segments) {
      final start = base + ((s['segment_id'] as num).toInt() - 1) * 18 * 86400000;
      await d.insert('trips', {
        'started_at': start,
        'ended_at': start + 3600000,
        'source': 'Opel dataset · segment ${s['segment_id']}',
        'km': (s['km'] as num).toDouble(),
        'odometer_km': (s['km_end'] as num).toDouble(),
        'avg_health': (s['health_mean'] as num).toDouble(),
        'min_health': (s['health_mean'] as num).toDouble(),
        'worst_status': 'imported',
        'alerts': 0,
        'windows': (s['windows'] as num).toInt(),
        'ltft_mean': (s['ltft_mean'] as num).toDouble(),
        'volt_mean': (s['volt_mean'] as num).toDouble(),
        'coolant_mean': (s['coolant_mean'] as num).toDouble(),
        'imported': 1,
      });
    }
  }

  // ---------------------------------------------------------- predictions --
  Future<void> savePrediction(int tripId, PredictionResult r, {bool late = false}) async =>
      (await db).insert('predictions', {
        'trip_id': tripId,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'health': r.healthScore,
        'status': r.status,
        'regime': r.regime,
        'model_anomaly': r.modelAnomaly ? 1 : 0,
        'findings': jsonEncode(r.findings.map((f) => f.toJson()).toList()),
        'rtt_ms': r.roundTripMs,
        'server_ms': r.serverProcessingMs,
        'late': late ? 1 : 0,
      });

  Future<List<Map<String, Object?>>> predictionsForTrip(int tripId) async =>
      (await db).query('predictions', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'ts ASC');

  /// (count, mean RTT, 95th percentile RTT, mean server ms) over the last 500 predictions.
  Future<(int, double, int, double)> latencyStats() async {
    final rows = await (await db).query('predictions',
        columns: ['rtt_ms', 'server_ms'], where: 'rtt_ms IS NOT NULL', orderBy: 'id DESC', limit: 500);
    if (rows.isEmpty) return (0, 0.0, 0, 0.0);
    final rtt = rows.map((r) => (r['rtt_ms'] as num).toInt()).toList()..sort();
    final srv = rows.map((r) => (r['server_ms'] as num?)?.toDouble() ?? 0).toList();
    final mean = rtt.reduce((a, b) => a + b) / rtt.length;
    final p95 = rtt[((rtt.length - 1) * 0.95).round()];
    return (rtt.length, mean, p95, srv.reduce((a, b) => a + b) / srv.length);
  }

  // -------------------------------------------------------------- offline --
  Future<void> savePending(int tripId, Map<String, dynamic> payload) async => (await db).insert(
      'pending_windows', {'trip_id': tripId, 'created_at': DateTime.now().millisecondsSinceEpoch, 'payload': jsonEncode(payload)});

  Future<List<Map<String, Object?>>> pending({int limit = 50}) async =>
      (await db).query('pending_windows', orderBy: 'id ASC', limit: limit);

  Future<int> pendingCount() async =>
      Sqflite.firstIntValue(await (await db).rawQuery('SELECT COUNT(*) FROM pending_windows')) ?? 0;

  Future<void> deletePending(int id) async => (await db).delete('pending_windows', where: 'id = ?', whereArgs: [id]);
}
