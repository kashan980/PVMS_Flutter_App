/// One OBD-II reading. Field names match the backend JSON contract exactly.
class TelemetrySample {
  final int timestampMs;
  final double? rpm;
  final double? speed;
  final double? throttlePos;
  final double? engineLoad;
  final double? coolantTemp;
  final double? intakeTemp;
  final double? shortFuelTrim1;
  final double? longFuelTrim1;
  final double? o2B1S1;
  final double? batteryVoltage;
  final double? maf;
  final double? intakePressure;

  const TelemetrySample({
    required this.timestampMs,
    this.rpm,
    this.speed,
    this.throttlePos,
    this.engineLoad,
    this.coolantTemp,
    this.intakeTemp,
    this.shortFuelTrim1,
    this.longFuelTrim1,
    this.o2B1S1,
    this.batteryVoltage,
    this.maf,
    this.intakePressure,
  });

  /// Builds a sample from a map keyed by backend field names (used by the OBD reader).
  factory TelemetrySample.fromFields(int timestampMs, Map<String, double?> f) => TelemetrySample(
        timestampMs: timestampMs,
        rpm: f['rpm'],
        speed: f['speed'],
        throttlePos: f['throttle_pos'],
        engineLoad: f['engine_load'],
        coolantTemp: f['coolant_temp'],
        intakeTemp: f['intake_temp'],
        shortFuelTrim1: f['short_fuel_trim_1'],
        longFuelTrim1: f['long_fuel_trim_1'],
        o2B1S1: f['o2_b1s1'],
        batteryVoltage: f['battery_voltage'],
        maf: f['maf'],
        intakePressure: f['intake_pressure'],
      );

  factory TelemetrySample.fromJson(Map<String, dynamic> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    return TelemetrySample(
      timestampMs: (j['timestamp_ms'] as num).toInt(),
      rpm: d('rpm'),
      speed: d('speed'),
      throttlePos: d('throttle_pos'),
      engineLoad: d('engine_load'),
      coolantTemp: d('coolant_temp'),
      intakeTemp: d('intake_temp'),
      shortFuelTrim1: d('short_fuel_trim_1'),
      longFuelTrim1: d('long_fuel_trim_1'),
      o2B1S1: d('o2_b1s1'),
      batteryVoltage: d('battery_voltage'),
      maf: d('maf'),
      intakePressure: d('intake_pressure'),
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp_ms': timestampMs,
        'rpm': rpm,
        'speed': speed,
        'throttle_pos': throttlePos,
        'engine_load': engineLoad,
        'coolant_temp': coolantTemp,
        'intake_temp': intakeTemp,
        'short_fuel_trim_1': shortFuelTrim1,
        'long_fuel_trim_1': longFuelTrim1,
        'o2_b1s1': o2B1S1,
        'battery_voltage': batteryVoltage,
        'maf': maf,
        'intake_pressure': intakePressure,
      };

  double? get totalFuelTrim =>
      (shortFuelTrim1 == null || longFuelTrim1 == null) ? null : shortFuelTrim1! + longFuelTrim1!;

  TelemetrySample copyWith({
    int? timestampMs,
    double? coolantTemp,
    double? shortFuelTrim1,
    double? longFuelTrim1,
    double? o2B1S1,
    double? batteryVoltage,
  }) =>
      TelemetrySample(
        timestampMs: timestampMs ?? this.timestampMs,
        rpm: rpm,
        speed: speed,
        throttlePos: throttlePos,
        engineLoad: engineLoad,
        coolantTemp: coolantTemp ?? this.coolantTemp,
        intakeTemp: intakeTemp,
        shortFuelTrim1: shortFuelTrim1 ?? this.shortFuelTrim1,
        longFuelTrim1: longFuelTrim1 ?? this.longFuelTrim1,
        o2B1S1: o2B1S1 ?? this.o2B1S1,
        batteryVoltage: batteryVoltage ?? this.batteryVoltage,
        maf: maf,
        intakePressure: intakePressure,
      );
}
