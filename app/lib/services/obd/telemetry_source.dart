import 'dart:async';

import '../../models/telemetry_sample.dart';

enum SourceState { idle, connecting, streaming, error }

/// Anything that produces live OBD-II samples: the ELM327 scanner or the simulator.
/// The rest of the app does not care which one is in use.
abstract class TelemetrySource {
  String get name;

  /// Emits one sample per polling cycle (~1 Hz for an ELM327).
  Stream<TelemetrySample> get samples;

  /// Current state + human readable detail for the UI.
  Stream<(SourceState, String)> get status;

  Future<void> start();
  Future<void> stop();

  /// Reads stored + pending trouble codes. Simulator returns an empty list.
  Future<List<String>> readDtcs() async => const [];
}
