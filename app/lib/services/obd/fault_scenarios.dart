import 'dart:math';

import '../../models/telemetry_sample.dart';

/// Faults the simulator can inject into the real recorded Opel trip, so every
/// screen and alert can be demonstrated without a car. The signatures mirror
/// backend/pvms/faults.py, which is used for the Precision/Recall evaluation.
enum FaultScenario {
  none('Healthy (as recorded)', 'Real driving data, no fault injected'),
  overheating('Overheating', 'Coolant climbs ~15–20 °C above normal (fan / coolant fault)'),
  vacuumLeak('Vacuum leak', 'Unmetered air: ECU adds ~20 % extra fuel'),
  injectorLeakSubtle('Leaking injector (subtle)',
      'Trims drop ~18 % — inside universal limits, only the AI model can catch it'),
  alternatorFailure('Alternator failure', 'Battery no longer charged: ~12.4 V and falling'),
  o2SensorDead('Dead O2 sensor', 'Upstream O2 sensor stuck at ~0.45 V'),
  thermostatStuckOpen('Thermostat stuck open', 'Engine never warms above ~62 °C');

  final String label;
  final String description;
  const FaultScenario(this.label, this.description);
}

class FaultInjector {
  final Random _rng = Random(42);
  FaultScenario scenario = FaultScenario.none;
  double _onsetS = 0; // simulated seconds since this fault was switched on

  void setScenario(FaultScenario s) {
    if (s != scenario) _onsetS = 0;
    scenario = s;
  }

  double _noise(double sd) => (_rng.nextDouble() * 2 - 1) * sd;

  /// [dtS]: simulated seconds since the previous sample.
  TelemetrySample apply(TelemetrySample s, double dtS) {
    if (scenario == FaultScenario.none) return s;
    _onsetS += dtS;
    final ramp = min(1.0, _onsetS / 120.0); // faults develop over ~2 simulated minutes
    switch (scenario) {
      case FaultScenario.none:
        return s;
      case FaultScenario.overheating:
        final c = s.coolantTemp;
        return c == null || c < 75 ? s : s.copyWith(coolantTemp: c + 6 + 14 * ramp);
      case FaultScenario.vacuumLeak:
        return s.copyWith(
          shortFuelTrim1: s.shortFuelTrim1 == null ? null : s.shortFuelTrim1! + 12 * ramp + _noise(1.5),
          longFuelTrim1: s.longFuelTrim1 == null ? null : s.longFuelTrim1! + 10 * ramp,
        );
      case FaultScenario.injectorLeakSubtle:
        return s.copyWith(
          shortFuelTrim1: s.shortFuelTrim1 == null ? null : s.shortFuelTrim1! - 8 * ramp + _noise(1.5),
          longFuelTrim1: s.longFuelTrim1 == null ? null : s.longFuelTrim1! - 10 * ramp,
        );
      case FaultScenario.alternatorFailure:
        final v = s.batteryVoltage ?? 14.1;
        final target = 12.45 - 0.002 * max(0, _onsetS - 120);
        return s.copyWith(batteryVoltage: v + (target - v) * ramp + _noise(0.03));
      case FaultScenario.o2SensorDead:
        return s.o2B1S1 == null ? s : s.copyWith(o2B1S1: s.o2B1S1! + (0.45 - s.o2B1S1!) * ramp + _noise(0.008));
      case FaultScenario.thermostatStuckOpen:
        final c = s.coolantTemp;
        return c == null || c <= 62 ? s : s.copyWith(coolantTemp: 60 + _noise(1.5));
    }
  }
}
