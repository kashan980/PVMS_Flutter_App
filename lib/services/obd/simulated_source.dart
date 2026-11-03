import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;

import '../../models/telemetry_sample.dart';
import 'fault_scenarios.dart';
import 'telemetry_source.dart';

/// Replays a REAL recorded trip (Opel 2012, cold start → warm, 35 min, from the
/// project dataset) at its original timing, optionally sped up, with optional
/// fault injection. Lets the whole app be developed and demonstrated before the
/// ELM327 scanner is bought.
class SimulatedObdSource extends TelemetrySource {
  static const assetPath = 'assets/sim/opel_trip.csv';

  final FaultInjector injector = FaultInjector();
  double speedFactor;

  SimulatedObdSource({this.speedFactor = 4, FaultScenario scenario = FaultScenario.none}) {
    injector.setScenario(scenario);
  }

  final _samples = StreamController<TelemetrySample>.broadcast();
  final _status = StreamController<(SourceState, String)>.broadcast();
  List<_Row>? _rows;
  Timer? _timer;
  int _i = 0;
  int _simClockMs = 0;

  @override
  String get name => 'Simulator · ${injector.scenario.label}';

  @override
  Stream<TelemetrySample> get samples => _samples.stream;

  @override
  Stream<(SourceState, String)> get status => _status.stream;

  void setScenario(FaultScenario s) => injector.setScenario(s);

  Future<List<_Row>> _load() async {
    final csv = await rootBundle.loadString(assetPath);
    final lines = csv.trim().split(RegExp(r'\r?\n'));
    final header = lines.first.split(',');
    return [
      for (final line in lines.skip(1))
        _Row.parse(header, line.split(',')),
    ];
  }

  @override
  Future<void> start() async {
    _status.add((SourceState.connecting, 'Loading recorded trip…'));
    _rows ??= await _load();
    _i = 0;
    _simClockMs = DateTime.now().millisecondsSinceEpoch;
    _status.add((SourceState.streaming, 'Replaying real Opel trip at ${speedFactor.toStringAsFixed(0)}× speed'));
    _scheduleNext();
  }

  void _scheduleNext() {
    final rows = _rows!;
    if (_i >= rows.length) _i = 0; // loop the trip
    final row = rows[_i];
    final dtS = _i == 0 ? 0.0 : row.tS - rows[_i - 1].tS;
    _timer = Timer(Duration(milliseconds: (dtS * 1000 / speedFactor).round()), () {
      _simClockMs += (dtS * 1000).round();
      final sample = injector.apply(row.toSample(_simClockMs), dtS);
      if (!_samples.isClosed) _samples.add(sample);
      _i++;
      _scheduleNext();
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _status.add((SourceState.idle, 'Stopped'));
  }
}

class _Row {
  final double tS;
  final Map<String, double?> v;
  _Row(this.tS, this.v);

  factory _Row.parse(List<String> header, List<String> cells) {
    final v = <String, double?>{};
    for (var k = 1; k < header.length && k < cells.length; k++) {
      v[header[k]] = double.tryParse(cells[k]);
    }
    return _Row(double.parse(cells[0]), v);
  }

  TelemetrySample toSample(int timestampMs) => TelemetrySample.fromFields(timestampMs, v);
}
