/// OBD-II Mode 01 PIDs used by PVMS, their decoding formulas (SAE J1979),
/// and helpers for parsing ELM327 text responses.
///
/// Only standard PIDs are used so the same app works on Suzuki, Toyota,
/// Honda, Hyundai, Opel ... any petrol car with an OBD-II port.
library;

class ObdPid {
  final String code; // e.g. '0C'
  final String field; // TelemetrySample field name (matches backend JSON)
  final int bytes;
  final double Function(List<int> d) decode;
  const ObdPid(this.code, this.field, this.bytes, this.decode);
}

double _a(List<int> d) => d[0].toDouble();
double _ab(List<int> d) => (d[0] * 256 + d[1]).toDouble();
double _pct(List<int> d) => d[0] * 100 / 255;
double _trim(List<int> d) => (d[0] - 128) * 100 / 128;

/// Polled every cycle, in this order.
const List<ObdPid> kPolledPids = [
  ObdPid('0C', 'rpm', 2, _rpm),
  ObdPid('0D', 'speed', 1, _a),
  ObdPid('04', 'engine_load', 1, _pct),
  ObdPid('11', 'throttle_pos', 1, _pct),
  ObdPid('05', 'coolant_temp', 1, _minus40),
  ObdPid('0F', 'intake_temp', 1, _minus40),
  ObdPid('06', 'short_fuel_trim_1', 1, _trim),
  ObdPid('07', 'long_fuel_trim_1', 1, _trim),
  ObdPid('14', 'o2_b1s1', 2, _o2),
  ObdPid('10', 'maf', 2, _maf),
  ObdPid('0B', 'intake_pressure', 1, _a),
];

double _rpm(List<int> d) => _ab(d) / 4;
double _minus40(List<int> d) => d[0] - 40.0;
double _o2(List<int> d) => d[0] / 200.0;
double _maf(List<int> d) => _ab(d) / 100;

/// Removes spaces, prompt characters and echo noise; returns non-empty lines.
List<String> cleanLines(String raw) => raw
    .replaceAll('>', '')
    .split(RegExp(r'[\r\n]+'))
    .map((l) => l.replaceAll(' ', '').trim().toUpperCase())
    .where((l) => l.isNotEmpty && l != 'SEARCHING...' && !l.startsWith('BUSINIT'))
    .toList();

bool isNoData(String raw) {
  final s = raw.toUpperCase().replaceAll(' ', '');
  return s.contains('NODATA') ||
      s.contains('UNABLETOCONNECT') ||
      s.contains('STOPPED') ||
      s.contains('ERROR') ||
      s.contains('?');
}

/// Extracts the data bytes of a Mode 01 response for [pid] ("410C1AF8" -> [0x1A, 0xF8]).
/// Works with multi-ECU replies (takes the first matching line).
List<int>? parseMode01(String raw, String pid, int nBytes) {
  if (isNoData(raw)) return null;
  final prefix = '41${pid.toUpperCase()}';
  for (final line in cleanLines(raw)) {
    final i = line.indexOf(prefix);
    if (i < 0) continue;
    final hex = line.substring(i + prefix.length);
    if (hex.length < nBytes * 2) continue;
    final out = <int>[];
    for (var k = 0; k < nBytes; k++) {
      final v = int.tryParse(hex.substring(k * 2, k * 2 + 2), radix: 16);
      if (v == null) return null;
      out.add(v);
    }
    return out;
  }
  return null;
}

double? decodePid(String raw, ObdPid pid) {
  final d = parseMode01(raw, pid.code, pid.bytes);
  return d == null ? null : pid.decode(d);
}

/// "ATRV" -> "14.2V"
double? parseVoltage(String raw) {
  final m = RegExp(r'(\d{1,2}\.\d)\s*V', caseSensitive: false).firstMatch(raw);
  return m == null ? null : double.tryParse(m.group(1)!);
}

/// Supported-PID bitmask from a "0100" reply. Returns the set of PIDs (hex, e.g. '0C').
Set<String> parseSupportedPids(String raw) {
  final d = parseMode01(raw, '00', 4);
  if (d == null) return {};
  final out = <String>{};
  for (var byte = 0; byte < 4; byte++) {
    for (var bit = 0; bit < 8; bit++) {
      if ((d[byte] & (0x80 >> bit)) != 0) {
        final pid = byte * 8 + bit + 1;
        out.add(pid.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
    }
  }
  return out;
}

/// Parses Mode 03 (stored) or Mode 07 (pending) trouble codes.
/// [isCan]: on CAN protocols the first byte after 43/47 is the number of codes.
List<String> parseDtcs(String raw, {String mode = '03', bool isCan = true}) {
  if (isNoData(raw)) return [];
  final header = mode == '07' ? '47' : '43';
  final codes = <String>[];
  for (final line in cleanLines(raw)) {
    final i = line.indexOf(header);
    if (i < 0) continue;
    var hex = line.substring(i + 2);
    if (isCan && hex.length >= 2) hex = hex.substring(2);
    for (var k = 0; k + 4 <= hex.length; k += 4) {
      final b0 = int.tryParse(hex.substring(k, k + 2), radix: 16);
      final b1 = int.tryParse(hex.substring(k + 2, k + 4), radix: 16);
      if (b0 == null || b1 == null || (b0 == 0 && b1 == 0)) continue;
      const letters = ['P', 'C', 'B', 'U'];
      final code = '${letters[b0 >> 6]}${(b0 >> 4) & 0x3}'
          '${(b0 & 0xF).toRadixString(16).toUpperCase()}'
          '${b1.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      if (!codes.contains(code)) codes.add(code);
    }
  }
  return codes;
}

/// Plain-English meaning of common codes (anything else links the driver to a mechanic).
const Map<String, String> kDtcDescriptions = {
  'P0101': 'Mass air flow (MAF) sensor reading out of range',
  'P0113': 'Intake air temperature sensor circuit high',
  'P0117': 'Coolant temperature sensor circuit low',
  'P0118': 'Coolant temperature sensor circuit high',
  'P0128': 'Engine not reaching operating temperature (thermostat)',
  'P0130': 'Oxygen sensor circuit (bank 1, sensor 1)',
  'P0133': 'Oxygen sensor slow response (bank 1, sensor 1)',
  'P0135': 'Oxygen sensor heater circuit (bank 1, sensor 1)',
  'P0171': 'Engine running too lean (bank 1)',
  'P0172': 'Engine running too rich (bank 1)',
  'P0300': 'Random / multiple cylinder misfire',
  'P0301': 'Cylinder 1 misfire',
  'P0302': 'Cylinder 2 misfire',
  'P0303': 'Cylinder 3 misfire',
  'P0304': 'Cylinder 4 misfire',
  'P0325': 'Knock sensor circuit',
  'P0335': 'Crankshaft position sensor circuit',
  'P0340': 'Camshaft position sensor circuit',
  'P0420': 'Catalytic converter efficiency below threshold',
  'P0441': 'Evaporative emission (EVAP) purge flow',
  'P0500': 'Vehicle speed sensor',
  'P0505': 'Idle control system',
  'P0562': 'System voltage low (charging system)',
  'P0563': 'System voltage high (charging system)',
};
