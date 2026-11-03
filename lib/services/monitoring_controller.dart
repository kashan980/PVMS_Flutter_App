import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/prediction.dart';
import '../models/telemetry_sample.dart';
import 'api_service.dart';
import 'app_settings.dart';
import 'database_helper.dart';
import 'obd/elm327_ble_source.dart';
import 'obd/fault_scenarios.dart';
import 'obd/simulated_source.dart';
import 'obd/telemetry_source.dart';

/// Orchestrates a monitoring session:
///   source samples → rolling 30-sample window (sent every 15 samples, 50 % overlap,
///   same as training) → FastAPI /predict → UI + sqflite.
/// If the server is unreachable the window is stored offline and basic safety
/// checks run on the phone, so critical alerts never depend on the network.
class MonitoringController extends ChangeNotifier {
  static const windowSize = 30;
  static const windowStep = 15;

  final AppSettings settings;
  final DatabaseHelper db = DatabaseHelper.instance;
  late final ApiService api = ApiService(settings.serverUrl);

  MonitoringController(this.settings);

  // ----------------------------------------------------------------- state --
  TelemetrySource? _source;
  StreamSubscription<TelemetrySample>? _sampleSub;
  StreamSubscription<(SourceState, String)>? _statusSub;
  BluetoothDevice? scannerDevice;

  bool running = false;
  SourceState sourceState = SourceState.idle;
  String sourceMessage = '';
  TelemetrySample? current;
  PredictionResult? lastResult;
  ForecastResult? forecast;
  bool serverReachable = true;
  bool calibrated = false; // server holds a learned profile for settings.vehicleId
  int learningCollected = 0;
  int learningNeeded = 60;
  int pendingCount = 0;
  String? toast; // one-off message for the UI (snackbar)
  List<String>? dtcs;

  // trip
  int? tripId;
  int? _tripStartSampleMs;
  double tripKm = 0;
  double _odometerKm = 0;
  final List<TelemetrySample> _window = [];
  int _sinceLast = 0;
  final List<bool> _recentFlags = [];
  bool _inFlight = false;
  Timer? _syncTimer;
  bool _syncing = false;

  /// Which car's history this session belongs to. The Opel simulator has its own
  /// history so it never pollutes a real car's trips or Time-To-Failure trend.
  String get vehicleKey => settings.useBaseModel ? DatabaseHelper.demoVehicleKey : settings.vehicleId;

  String get sourceName => _source?.name ??
      (settings.source == DataSourceKind.simulator
          ? 'Simulator · ${settings.scenario.label}'
          : (settings.lastDeviceName ?? 'OBD-II scanner (not paired)'));

  double? get tripElapsedS => (current == null || _tripStartSampleMs == null)
      ? null
      : (current!.timestampMs - _tripStartSampleMs!) / 1000.0;

  Future<void> init() async {
    final last = settings.lastDeviceId;
    if (last != null) scannerDevice = BluetoothDevice.fromId(last);
    pendingCount = await db.pendingCount();
    unawaited(refreshServerInfo());
    unawaited(refreshForecast());
    // Background retry: whenever offline windows are waiting, check the server every 30 s
    // and sync automatically once it is reachable again.
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) => _autoSync());
    notifyListeners();
  }

  Future<void> _autoSync() async {
    if (pendingCount == 0 || _syncing) return;
    final (ok, _, _) = await api.ping();
    serverReachable = ok;
    if (ok) {
      final n = await syncPending();
      if (n > 0) _toast('Server back online: $n offline windows analysed.');
    }
    notifyListeners();
  }

  void setServerUrl(String url) {
    settings.serverUrl = url;
    api.baseUrl = settings.serverUrl;
    unawaited(refreshServerInfo());
  }

  Future<(bool, int, String?)> refreshServerInfo() async {
    final p = await api.ping();
    serverReachable = p.$1;
    if (p.$1) await refreshVehicleStatus();
    notifyListeners();
    return p;
  }

  Future<void> refreshVehicleStatus() async {
    final v = await api.vehicleStatus(settings.vehicleId);
    if (v != null) {
      calibrated = v.$1;
      learningCollected = v.$2;
      learningNeeded = v.$3;
    }
    notifyListeners();
  }

  void setScenario(FaultScenario s) {
    settings.scenario = s;
    final src = _source;
    if (src is SimulatedObdSource) src.setScenario(s);
    notifyListeners();
  }

  void setScanner(BluetoothDevice d) {
    scannerDevice = d;
    settings.lastDeviceId = d.remoteId.str;
    settings.lastDeviceName = d.platformName.isEmpty ? 'OBD-II scanner' : d.platformName;
    settings.source = DataSourceKind.obdScanner;
    notifyListeners();
  }

  // ------------------------------------------------------------ trip flow --
  Future<void> startTrip() async {
    if (running) return;
    final TelemetrySource src;
    if (settings.source == DataSourceKind.simulator) {
      src = SimulatedObdSource(speedFactor: settings.simSpeed, scenario: settings.scenario);
    } else {
      if (scannerDevice == null) {
        _toast('Pair your OBD-II scanner first (Settings → Scanner).');
        return;
      }
      src = Elm327BleSource(scannerDevice!);
    }
    _source = src;
    _window.clear();
    _recentFlags.clear();
    _sinceLast = 0;
    tripKm = 0;
    lastResult = null;
    current = null;
    _tripStartSampleMs = null;
    _odometerKm = await db.lastOdometer(vehicleKey);
    tripId = await db.startTrip(src.name, vehicleKey, _odometerKm);
    running = true;
    try {
      await WakelockPlus.enable(); // keep the screen (and BLE stream) alive while driving
    } catch (_) {
      // not critical
    }
    dtcs = null;
    _statusSub = src.status.listen((s) {
      final firstStream = s.$1 == SourceState.streaming && sourceState != SourceState.streaming;
      sourceState = s.$1;
      sourceMessage = s.$2;
      if (s.$1 == SourceState.error) _toast(s.$2);
      // Instant diagnosis: read the ECU's stored fault codes as soon as the scanner is live.
      if (firstStream && src is Elm327BleSource) unawaited(readDtcs());
      notifyListeners();
    });
    _sampleSub = src.samples.listen(_onSample);
    notifyListeners();
    await src.start();
  }

  Future<void> stopTrip() async {
    if (!running) return;
    running = false;
    await _sampleSub?.cancel();
    await _statusSub?.cancel();
    await _source?.stop();
    _source = null;
    sourceState = SourceState.idle;
    sourceMessage = '';
    try {
      await WakelockPlus.disable();
    } catch (_) {
      // not critical
    }
    await _finishTrip();
    notifyListeners();
  }

  Future<void> _finishTrip() async {
    final id = tripId;
    if (id == null) return;
    tripId = null;
    await db.finishTrip(id, {'km': tripKm, 'odometer_km': _odometerKm + tripKm});
    await db.recomputeTrip(id); // summary built from the stored predictions
    if (await db.predictionCount(id) == 0 && tripKm < 0.05) await db.deleteTrip(id);
    await refreshForecast();
  }

  void _onSample(TelemetrySample s) {
    final prev = current;
    current = s;
    _tripStartSampleMs ??= s.timestampMs;
    if (prev != null && s.speed != null) {
      final dt = (s.timestampMs - prev.timestampMs) / 1000.0;
      if (dt > 0 && dt < 10) tripKm += s.speed! * dt / 3600.0;
    }
    _window.add(s);
    if (_window.length > windowSize) _window.removeAt(0);
    _sinceLast++;
    if (_window.length >= windowSize && _sinceLast >= windowStep) {
      _sinceLast = 0;
      unawaited(_analyse(List.of(_window)));
    }
    notifyListeners();
  }

  Future<void> _analyse(List<TelemetrySample> window) async {
    final id = tripId;
    if (id == null || _inFlight) return;
    _inFlight = true;
    // Real car → identified by vehicle id, never judged by the Opel base model.
    final vehicleId = settings.activeVehicleId;
    final useBase = settings.useBaseModel;
    final flags = _recentFlags.length > 2 ? _recentFlags.sublist(_recentFlags.length - 2) : List.of(_recentFlags);
    try {
      final r = await api.predict(window,
          vehicleId: vehicleId, useBaseModel: useBase, tripElapsedS: tripElapsedS, recentModelFlags: flags);
      serverReachable = true;
      _accept(id, r);
      if (pendingCount > 0) unawaited(syncPending());
    } on ApiException catch (e) {
      final wasReachable = serverReachable;
      serverReachable = false;
      await db.savePending(id, {
        'samples': window.map((s) => s.toJson()).toList(),
        'vehicle_id': vehicleId,
        'use_base_model': useBase,
        'trip_elapsed_s': tripElapsedS,
      });
      pendingCount = await db.pendingCount();
      final local = _localSafetyCheck(window);
      lastResult = local;
      if (wasReachable) _toast('${e.message}. Recording offline — data will be analysed when the server is back.');
    } finally {
      _inFlight = false;
      notifyListeners();
    }
  }

  void _accept(int tripId, PredictionResult r) {
    lastResult = r;
    _updateLearning(r);
    if (r.modelApplied) _recentFlags.add(r.modelAnomaly);
    unawaited(db.savePrediction(tripId, r));
  }

  void _updateLearning(PredictionResult r) {
    if (r.modelUsed == 'learning') {
      learningCollected = r.learningCollected ?? learningCollected;
      learningNeeded = r.learningNeeded ?? learningNeeded;
      if (learningCollected >= learningNeeded) {
        calibrated = true;
        _toast('PVMS has learned this car\'s normal behaviour. AI fault prediction is now active.');
      }
    } else if (r.modelUsed == 'vehicle') {
      calibrated = true;
    }
  }

  /// Minimal on-phone checks used only while the server is unreachable.
  PredictionResult _localSafetyCheck(List<TelemetrySample> w) {
    double? mean(double? Function(TelemetrySample) f) {
      final v = w.map(f).whereType<double>().toList();
      return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    }

    final cool = w.map((s) => s.coolantTemp).whereType<double>().fold<double?>(null, (m, v) => m == null ? v : max(m, v));
    final volt = mean((s) => s.batteryVoltage);
    final rpm = mean((s) => s.rpm) ?? 0;
    final findings = <Finding>[];
    if (cool != null && cool >= 112) {
      findings.add(Finding(
          code: 'COOLANT_OVERHEAT', severity: 'critical', title: 'Engine overheating',
          message: 'Coolant reached ${cool.toStringAsFixed(0)}°C.',
          recommendation: 'Pull over safely and switch the engine off.', source: 'local'));
    }
    if (rpm > 400 && volt != null && volt < 12.6) {
      findings.add(Finding(
          code: 'CHARGING_FAILURE', severity: 'critical', title: 'Battery is not being charged',
          message: 'System voltage is ${volt.toStringAsFixed(1)} V with the engine running.',
          recommendation: 'Drive to a mechanic; the alternator may have failed.', source: 'local'));
    }
    // Without the server there is no AI verdict, so no health score is claimed —
    // only the two safety checks below can raise an alarm.
    return PredictionResult(
      healthScore: findings.isEmpty ? null : 20,
      status: findings.isEmpty ? 'offline' : 'critical',
      regime: rpm > 400 ? 'warm' : 'engine_off',
      modelApplied: false,
      modelAnomaly: false,
      persistent: false,
      modelUsed: 'local',
      findings: findings,
      contributors: const [],
      features: const {},
      offline: true,
    );
  }

  /// Re-sends windows recorded offline (oldest first), then rebuilds the affected
  /// trips' summaries so the late results count in history and Time-To-Failure.
  Future<int> syncPending() async {
    if (_syncing) return 0;
    _syncing = true;
    var done = 0;
    final touched = <int>{};
    try {
      for (final row in await db.pending(limit: 500)) {
        final tid = row['trip_id'] as int;
        try {
          final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          final r = await api.predictRaw(payload);
          _updateLearning(r);
          await db.savePrediction(tid, r, late: true);
          await db.deletePending(row['id'] as int);
          touched.add(tid);
          done++;
        } on ApiException catch (e) {
          if (e.message.startsWith('Server unreachable')) break; // still offline: try later
          await db.deletePending(row['id'] as int); // server rejected it (bad data): don't retry forever
        } on FormatException {
          await db.deletePending(row['id'] as int);
        }
      }
      for (final tid in touched) {
        if (tid != tripId) await db.recomputeTrip(tid); // a running trip is summarised when it ends
      }
      if (touched.isNotEmpty) serverReachable = true;
    } finally {
      _syncing = false;
    }
    pendingCount = await db.pendingCount();
    if (touched.isNotEmpty) await refreshForecast();
    notifyListeners();
    return done;
  }

  /// Forget this car's learned profile (e.g. after a major repair) and learn again.
  Future<void> resetLearning() async {
    try {
      await api.resetCalibration(settings.vehicleId);
      calibrated = false;
      learningCollected = 0;
    } catch (_) {
      _toast('Server unreachable — could not reset.');
    }
    notifyListeners();
  }

  // ------------------------------------------------------ forecast / DTC --
  Future<void> refreshForecast() async {
    final trips = (await db.trips(vehicleKey)).reversed.toList();
    if (trips.isEmpty) {
      forecast = const ForecastResult(status: 'insufficient_data', trips: 0);
      notifyListeners();
      return;
    }
    try {
      forecast = await api.forecast([
        for (final t in trips)
          {
            'km': (t['odometer_km'] as num?)?.toDouble() ?? 0,
            'health': (t['avg_health'] as num?)?.toDouble(),
            'ltft_mean': (t['ltft_mean'] as num?)?.toDouble(),
            'volt_mean': (t['volt_mean'] as num?)?.toDouble(),
            'coolant_mean': (t['coolant_mean'] as num?)?.toDouble(),
          }
      ]);
    } on ApiException {
      // keep previous forecast
    }
    notifyListeners();
  }

  Future<void> importDemoHistory() async {
    final raw = await rootBundle.loadString('assets/sim/opel_history.json');
    final rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    await db.importHistory(rows);
    await refreshForecast();
    _toast(vehicleKey == DatabaseHelper.demoVehicleKey
        ? 'Imported ${rows.length} real trip segments (~14 000 km) from the Opel dataset.'
        : 'Imported into the Opel demo history — switch the data source to Simulator to see it.');
  }

  Future<void> clearHistory() async {
    await db.clearAll();
    pendingCount = 0;
    await refreshForecast();
  }

  Future<void> readDtcs() async {
    final src = _source;
    if (src == null || !running || src is SimulatedObdSource) {
      _toast('Start a trip with the OBD-II scanner connected to read fault codes.');
      return;
    }
    try {
      dtcs = await src.readDtcs();
      if (dtcs!.isNotEmpty) _toast('The car\'s computer has ${dtcs!.length} stored fault code(s): ${dtcs!.join(', ')}');
    } catch (e) {
      _toast('Could not read codes: $e');
    }
    notifyListeners();
  }

  // ----------------------------------------------------------------- misc --
  void _toast(String m) {
    toast = m;
    notifyListeners();
  }

  String? takeToast() {
    final t = toast;
    toast = null;
    return t;
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _sampleSub?.cancel();
    _statusSub?.cancel();
    _source?.stop();
    super.dispose();
  }
}
