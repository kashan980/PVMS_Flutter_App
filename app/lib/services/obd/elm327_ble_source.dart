import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../models/telemetry_sample.dart';
import 'obd_pids.dart';
import 'telemetry_source.dart';

/// Talks to an ELM327-compatible OBD-II scanner over Bluetooth Low Energy.
///
/// Works on Android AND iOS (iPhones only support BLE, not "Bluetooth Classic"
/// ELM327 clones). Protocol: send ASCII command + '\r', collect notification
/// chunks until the '>' prompt, then parse.
class Elm327BleSource extends TelemetrySource {
  final BluetoothDevice device;
  Elm327BleSource(this.device);

  /// Known GATT layouts of popular BLE OBD adapters: service -> (notify, write).
  static final _known = <String, (String, String)>{
    'fff0': ('fff1', 'fff2'), // most "ELM327 V1.5 BLE" clones, Veepeak
    'ffe0': ('ffe1', 'ffe1'), // HM-10 based adapters
    'e7810a71-73ae-499d-8c15-faa9aef0c3f2': // Vgate iCar Pro BLE (other brands, e.g. OBDLink CX,
        // are found by the generic notify+write search below)
        ('bef8d6c9-9c21-4c9e-b632-bd58c1009f9f', 'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f'),
  };

  final _samples = StreamController<TelemetrySample>.broadcast();
  final _status = StreamController<(SourceState, String)>.broadcast();
  BluetoothCharacteristic? _rx, _tx;
  StreamSubscription<List<int>>? _rxSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final StringBuffer _buf = StringBuffer();
  Completer<String>? _pending;
  Future<void> _lock = Future.value();
  bool _running = false;
  bool _isCan = true;
  Set<String> _supported = {};
  String adapterInfo = '';

  @override
  String get name => device.platformName.isEmpty ? 'OBD-II scanner' : device.platformName;

  @override
  Stream<TelemetrySample> get samples => _samples.stream;

  @override
  Stream<(SourceState, String)> get status => _status.stream;

  void _set(SourceState s, String msg) {
    debugPrint('[ELM327] $msg');
    if (!_status.isClosed) _status.add((s, msg));
  }

  // ------------------------------------------------------------ connection --
  @override
  Future<void> start() async {
    try {
      _set(SourceState.connecting, 'Connecting to $name…');
      await device.connect(timeout: const Duration(seconds: 15));
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _running) {
          _running = false;
          _set(SourceState.error, 'Scanner disconnected');
        }
      });
      await _findCharacteristics();
      await _initElm();
      _running = true;
      _set(SourceState.streaming, 'Live data from $name ($adapterInfo)');
      unawaited(_pollLoop());
    } catch (e) {
      _set(SourceState.error, _friendly(e));
      await _teardown();
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('UNABLE TO CONNECT')) {
      return 'Scanner found, but the car did not answer. Turn the ignition ON (or start the engine) and retry.';
    }
    if (s.contains('Timed out') || s.contains('timeout')) return 'Connection timed out. Is the scanner plugged in?';
    return 'Could not start scanner: $s';
  }

  Future<void> _findCharacteristics() async {
    final services = await device.discoverServices();
    for (final s in services) {
      final pair = _known[s.serviceUuid.str.toLowerCase()];
      if (pair == null) continue;
      for (final c in s.characteristics) {
        final id = c.characteristicUuid.str.toLowerCase();
        if (id == pair.$1) _rx = c;
        if (id == pair.$2) _tx = c;
      }
      if (_rx != null && _tx != null) break;
    }
    // Fallback: any custom service exposing notify + write characteristics.
    if (_rx == null || _tx == null) {
      for (final s in services) {
        final sid = s.serviceUuid.str.toLowerCase();
        if (sid == '1800' || sid == '1801' || sid == '180a') continue;
        BluetoothCharacteristic? n, w;
        for (final c in s.characteristics) {
          if (c.properties.notify || c.properties.indicate) n ??= c;
          if (c.properties.write || c.properties.writeWithoutResponse) w ??= c;
        }
        if (n != null && w != null) {
          _rx = n;
          _tx = w;
          break;
        }
      }
    }
    if (_rx == null || _tx == null) {
      throw StateError('This Bluetooth device does not look like an OBD-II scanner.');
    }
    await _rx!.setNotifyValue(true);
    _rxSub = _rx!.onValueReceived.listen(_onData);
  }

  void _onData(List<int> bytes) {
    _buf.write(latin1.decode(bytes, allowInvalid: true));
    final s = _buf.toString();
    final p = s.indexOf('>');
    if (p >= 0) {
      _buf.clear();
      if (p + 1 < s.length) _buf.write(s.substring(p + 1));
      final c = _pending;
      _pending = null;
      if (c != null && !c.isCompleted) c.complete(s.substring(0, p));
    }
  }

  /// Sends one command and waits for the '>' prompt. Commands are serialised.
  Future<String> send(String cmd, {Duration timeout = const Duration(seconds: 3)}) {
    final run = _lock.then((_) async {
      _pending = Completer<String>();
      _buf.clear();
      final bytes = ascii.encode('$cmd\r');
      final noResp = _tx!.properties.writeWithoutResponse && !_tx!.properties.write;
      await _tx!.write(bytes, withoutResponse: noResp);
      return _pending!.future.timeout(timeout, onTimeout: () => 'TIMEOUT');
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _initElm() async {
    _set(SourceState.connecting, 'Initialising adapter…');
    final id = await send('ATZ', timeout: const Duration(seconds: 5)); // reset
    adapterInfo = cleanLines(id).firstWhere((l) => l.contains('ELM'), orElse: () => 'ELM327');
    for (final c in ['ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATAT1', 'ATSP0']) {
      await send(c);
    }
    _set(SourceState.connecting, 'Detecting car protocol (can take 10 s)…');
    final r = await send('0100', timeout: const Duration(seconds: 15));
    if (isNoData(r) || r == 'TIMEOUT') throw StateError('UNABLE TO CONNECT: $r');
    _supported = parseSupportedPids(r);
    final dp = (await send('ATDPN')).replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final proto = dp.isEmpty ? '' : dp.substring(dp.length - 1).toUpperCase();
    _isCan = ['6', '7', '8', '9', 'A', 'B', 'C'].contains(proto);
    debugPrint('[ELM327] protocol=$proto CAN=$_isCan supported=$_supported');
  }

  // ------------------------------------------------------------- polling --
  Future<void> _pollLoop() async {
    final pids = kPolledPids.where((p) => _supported.isEmpty || _supported.contains(p.code)).toList();
    var failures = 0;
    while (_running) {
      final values = <String, double?>{};
      final ts = DateTime.now().millisecondsSinceEpoch;
      for (final p in pids) {
        if (!_running) return;
        try {
          values[p.field] = decodePid(await send('01${p.code}'), p);
        } catch (_) {
          values[p.field] = null;
        }
      }
      try {
        values['battery_voltage'] = parseVoltage(await send('ATRV'));
      } catch (_) {
        // some clones do not support ATRV; voltage is then imputed by the server
      }
      final got = values.values.where((v) => v != null).length;
      failures = got == 0 ? failures + 1 : 0;
      if (failures >= 5) {
        _set(SourceState.error, 'No data from the car — ignition off?');
        _running = false;
        return;
      }
      if (got > 0 && !_samples.isClosed) _samples.add(TelemetrySample.fromFields(ts, values));
    }
  }

  @override
  Future<List<String>> readDtcs() async {
    final stored = parseDtcs(await send('03', timeout: const Duration(seconds: 5)), mode: '03', isCan: _isCan);
    final pending = parseDtcs(await send('07', timeout: const Duration(seconds: 5)), mode: '07', isCan: _isCan);
    return {...stored, ...pending}.toList();
  }

  Future<void> _teardown() async {
    _running = false;
    await _rxSub?.cancel();
    await _connSub?.cancel();
    _rxSub = null;
    _connSub = null;
    try {
      await device.disconnect();
    } catch (_) {
      // already disconnected
    }
  }

  @override
  Future<void> stop() async {
    await _teardown();
    _set(SourceState.idle, 'Disconnected');
  }

  // ---------------------------------------------------------------- scan --
  static bool looksLikeObd(ScanResult r) {
    final n = (r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName)
        .toUpperCase();
    return ['OBD', 'ELM', 'VGATE', 'ICAR', 'V-LINK', 'VLINK', 'VEEPEAK', 'OBDLINK', 'KONNWEI', 'IOS-VLINK']
        .any(n.contains);
  }
}
