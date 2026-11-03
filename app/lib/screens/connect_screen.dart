import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/monitoring_controller.dart';
import '../services/obd/elm327_ble_source.dart';

/// Scans for Bluetooth Low Energy OBD-II scanners and pairs one.
class ConnectScreen extends StatefulWidget {
  final MonitoringController c;
  const ConnectScreen({super.key, required this.c});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  List<ScanResult> _results = [];
  bool _scanning = false;
  bool _showAll = false;
  String? _error;
  StreamSubscription<List<ScanResult>>? _sub;
  StreamSubscription<bool>? _scanSub;

  @override
  void initState() {
    super.initState();
    _sub = FlutterBluePlus.scanResults.listen((r) => setState(() => _results = r));
    _scanSub = FlutterBluePlus.isScanning.listen((s) => setState(() => _scanning = s));
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _error = null);
    try {
      if (!await FlutterBluePlus.isSupported) {
        setState(() => _error = 'Bluetooth LE is not supported on this device.');
        return;
      }
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        setState(() => _error = 'Turn Bluetooth on, then tap Scan.');
        return;
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      setState(() => _error = 'Scan failed: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = _results
        .where((r) => _showAll || Elm327BleSource.looksLikeObd(r))
        .toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(title: const Text('Pair OBD-II scanner')),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Plug the scanner into the OBD-II port (under the dashboard, driver side) and turn the '
              'ignition on. Bluetooth LE scanners do not appear in phone Bluetooth settings — pair them here.'),
        ),
        SwitchListTile(
          title: const Text('Show all Bluetooth devices'),
          value: _showAll,
          onChanged: (v) => setState(() => _showAll = v),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_scanning) const LinearProgressIndicator(),
        Expanded(
          child: list.isEmpty
              ? Center(child: Text(_scanning ? 'Scanning…' : 'No scanners found.'))
              : ListView(children: [
                  for (final r in list)
                    ListTile(
                      leading: const Icon(Icons.bluetooth_rounded),
                      title: Text(r.advertisementData.advName.isNotEmpty
                          ? r.advertisementData.advName
                          : (r.device.platformName.isNotEmpty ? r.device.platformName : r.device.remoteId.str)),
                      subtitle: Text('${r.device.remoteId.str} · signal ${r.rssi} dBm'),
                      trailing: FilledButton.tonal(
                        onPressed: () {
                          final messenger = ScaffoldMessenger.of(context);
                          widget.c.setScanner(r.device);
                          Navigator.of(context).pop();
                          messenger.showSnackBar(
                              const SnackBar(content: Text('Scanner saved. Press "Start trip" to connect.')));
                        },
                        child: const Text('Use'),
                      ),
                    ),
                ]),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _scan,
        icon: const Icon(Icons.search_rounded),
        label: const Text('Scan'),
      ),
    );
  }
}
