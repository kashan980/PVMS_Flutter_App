import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/monitoring_controller.dart';
import '../services/obd/obd_pids.dart';
import '../widgets/common.dart';
import 'connect_screen.dart';

class SettingsScreen extends StatefulWidget {
  final MonitoringController c;
  const SettingsScreen({super.key, required this.c});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  MonitoringController get c => widget.c;
  AppSettings get s => c.settings;
  late final TextEditingController _url = TextEditingController(text: s.serverUrl);
  late final TextEditingController _vid = TextEditingController(text: s.vehicleId);
  String? _ping;
  bool _testing = false;

  @override
  void dispose() {
    _url.dispose();
    _vid.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    c.setServerUrl(_url.text);
    final (ok, rtt, version) = await c.refreshServerInfo();
    setState(() {
      _testing = false;
      _ping = ok ? 'Connected · $rtt ms · model v$version' : 'Not reachable (${s.serverUrl})';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
          // ------------------------------------------------------- server --
          const SectionTitle('Prediction server'),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'Server URL', hintText: 'http://192.168.1.100:8000'),
                  onSubmitted: (_) => _test(),
                ),
                const SizedBox(height: 8),
                Text(
                  'Run backend\\run_server.bat on your laptop and enter the IPv4 address it prints. '
                  'Phone and laptop must be on the same Wi-Fi or hotspot. Android emulator: http://10.0.2.2:8000',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: const Text('Save & test'),
                  ),
                  const SizedBox(width: 12),
                  if (_ping != null) Expanded(child: Text(_ping!)),
                ]),
              ]),
            ),
          ),

          // -------------------------------------------------- data source --
          const SectionTitle('Data source'),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SegmentedButton<DataSourceKind>(
                  segments: const [
                    ButtonSegment(value: DataSourceKind.simulator, icon: Icon(Icons.science_rounded), label: Text('Simulator')),
                    ButtonSegment(value: DataSourceKind.obdScanner, icon: Icon(Icons.bluetooth_rounded), label: Text('OBD-II scanner')),
                  ],
                  selected: {s.source},
                  onSelectionChanged: c.running
                      ? null
                      : (v) => setState(() => s.source = v.first),
                ),
                const SizedBox(height: 12),
                if (s.source == DataSourceKind.simulator) ...[
                  const Text('Replays a real 35-minute trip from the Opel dataset. Pick a fault on the dashboard.'),
                  const SizedBox(height: 12),
                  Text('Replay speed', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SegmentedButton<double>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1× real time')),
                      ButtonSegment(value: 4, label: Text('4×')),
                      ButtonSegment(value: 10, label: Text('10×')),
                    ],
                    selected: {s.simSpeed},
                    onSelectionChanged: c.running ? null : (v) => setState(() => s.simSpeed = v.first),
                  ),
                ] else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.usb_rounded),
                    title: Text(s.lastDeviceName ?? 'No scanner paired'),
                    subtitle: Text(s.lastDeviceId ?? 'Needs a Bluetooth LE (4.0) ELM327 scanner'),
                    trailing: FilledButton.tonal(
                      onPressed: c.running
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConnectScreen(c: c))),
                      child: const Text('Pair'),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.readDtcs,
                    icon: const Icon(Icons.fact_check_rounded),
                    label: const Text('Read fault codes (DTC)'),
                  ),
                  if (c.dtcs != null) ...[
                    const SizedBox(height: 8),
                    if (c.dtcs!.isEmpty) const Text('No stored or pending trouble codes.'),
                    for (final code in c.dtcs!)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.error_outline_rounded),
                        title: Text(code),
                        subtitle: Text(kDtcDescriptions[code] ?? 'Ask a mechanic to look up this manufacturer code.'),
                      ),
                  ],
                ],
              ]),
            ),
          ),

          // ---------------------------------------------- vehicle learning --
          const SectionTitle('Vehicle & AI learning'),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _vid,
                  decoration: const InputDecoration(labelText: 'Vehicle ID', hintText: 'e.g. alto-2022 or civic-2019'),
                  onSubmitted: (v) async {
                    s.vehicleId = v;
                    await c.refreshVehicleStatus();
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'Every car has its own "normal" (fuel trim, charging voltage, running temperature). A new car is '
                  'never judged by the Opel training car: PVMS starts with universal safety rules and fault codes, '
                  'learns this car automatically during the first ~18 min of warm-engine driving, then turns the AI on.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(c.calibrated ? Icons.verified_rounded : Icons.school_rounded),
                  title: Text(c.calibrated
                      ? 'AI profile learned'
                      : 'Learning: ${c.learningCollected}/${c.learningNeeded} healthy windows'),
                  subtitle: Text(c.calibrated
                      ? 'Predictions for "${s.vehicleId}" use its own normal behaviour.'
                      : 'Rules-only mode until learning completes.'),
                  trailing: TextButton(onPressed: c.resetLearning, child: const Text('Re-learn')),
                ),
                if (s.source == DataSourceKind.simulator)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Demo: treat simulator as a new car'),
                    subtitle: const Text('Shows the learning → AI flow using vehicle ID above instead of the Opel base model'),
                    value: s.simulatorAsNewCar,
                    onChanged: c.running ? null : (v) => setState(() => s.simulatorAsNewCar = v),
                  ),
              ]),
            ),
          ),

          // --------------------------------------------------------- data --
          const SectionTitle('Data'),
          Card(
            elevation: 0,
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.cloud_upload_rounded),
                title: Text('${c.pendingCount} windows waiting (recorded offline)'),
                trailing: TextButton(onPressed: c.pendingCount == 0 ? null : c.syncPending, child: const Text('Sync now')),
              ),
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('Load Opel demo history'),
                subtitle: const Text('22 real refuelling segments (~14 000 km) to demonstrate the Time-To-Failure trend'),
                onTap: c.importDemoHistory,
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_rounded),
                title: const Text('Clear all history'),
                onTap: () => _confirmClear(context),
              ),
            ]),
          ),

          // ------------------------------------------------- performance --
          const SectionTitle('System performance'),
          FutureBuilder<(int, double, int, double)>(
            future: c.db.latencyStats(),
            builder: (context, snap) {
              final d = snap.data;
              return Card(
                elevation: 0,
                child: ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(d == null || d.$1 == 0
                      ? 'No measurements yet'
                      : 'Round-trip latency: mean ${d.$2.toStringAsFixed(0)} ms · p95 ${d.$3} ms'),
                  subtitle: Text(d == null || d.$1 == 0
                      ? 'Measured on every prediction (phone send → response received).'
                      : 'Server processing ${d.$4.toStringAsFixed(1)} ms · ${d.$1} predictions'),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text('Trips, alerts and offline data on this phone will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await c.clearHistory();
  }
}
