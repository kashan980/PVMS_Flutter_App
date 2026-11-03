import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/prediction.dart';
import '../services/monitoring_controller.dart';
import '../widgets/common.dart';

/// Offline vehicle health history (sqflite).
class HistoryScreen extends StatefulWidget {
  final MonitoringController c;
  const HistoryScreen({super.key, required this.c});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<Map<String, Object?>>> _trips;

  @override
  void initState() {
    super.initState();
    _shownKey = widget.c.vehicleKey;
    _trips = widget.c.db.trips(widget.c.vehicleKey);
    widget.c.addListener(_reloadIfIdle);
  }

  bool _wasRunning = false;
  String? _shownKey;
  void _reloadIfIdle() {
    // reload when a trip finishes or the vehicle / data source changes
    if ((_wasRunning && !widget.c.running) || _shownKey != widget.c.vehicleKey) _reload();
    _wasRunning = widget.c.running;
  }

  void _reload() => setState(() {
        _shownKey = widget.c.vehicleKey;
        _trips = widget.c.db.trips(widget.c.vehicleKey);
      });

  @override
  void dispose() {
    widget.c.removeListener(_reloadIfIdle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('History · ${widget.c.vehicleKey}'), actions: [
        IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ]),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _trips,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final trips = snap.data!;
          if (trips.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No trips yet. Completed trips appear here, even without internet.',
                    textAlign: TextAlign.center),
              ),
            );
          }
          final trend = trips.reversed.map((t) => (t['avg_health'] as num?)?.toDouble()).whereType<double>().toList();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                const SectionTitle('Average health per trip'),
                Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(12), child: TrendChart(values: trend))),
                SectionTitle('${trips.length} trips'),
                for (final t in trips) _TripTile(t, onOpen: () => _open(t)),
              ],
            ),
          );
        },
      ),
    );
  }

  void _open(Map<String, Object?> t) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripDetailScreen(c: widget.c, trip: t)));
}

class _TripTile extends StatelessWidget {
  final Map<String, Object?> t;
  final VoidCallback onOpen;
  const _TripTile(this.t, {required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final h = (t['avg_health'] as num?)?.toDouble();
    final alerts = (t['alerts'] as int?) ?? 0;
    final imported = (t['imported'] as int?) == 1;
    final km = (t['km'] as num?)?.toDouble() ?? 0;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: imported ? null : onOpen,
        leading: CircleAvatar(
          backgroundColor: StatusStyle.forHealth(h).withValues(alpha: 0.2),
          child: Text(h == null ? '–' : h.round().toString(),
              style: TextStyle(color: StatusStyle.forHealth(h), fontWeight: FontWeight.w700)),
        ),
        title: Text(imported ? t['source'] as String : formatDate(t['started_at'] as int)),
        subtitle: Text('${km.toStringAsFixed(1)} km · odometer ${((t['odometer_km'] as num?) ?? 0).toStringAsFixed(0)} km'
            '${imported ? ' · imported' : ' · ${t['source']}'}'),
        trailing: alerts > 0
            ? Chip(
                visualDensity: VisualDensity.compact,
                label: Text('$alerts alert${alerts == 1 ? '' : 's'}'),
                backgroundColor: StatusStyle.of('warning').color.withValues(alpha: 0.2),
              )
            : null,
      ),
    );
  }
}

class TripDetailScreen extends StatelessWidget {
  final MonitoringController c;
  final Map<String, Object?> trip;
  const TripDetailScreen({super.key, required this.c, required this.trip});

  @override
  Widget build(BuildContext context) {
    final id = trip['id'] as int;
    return Scaffold(
      appBar: AppBar(title: Text(formatDate(trip['started_at'] as int)), actions: [
        IconButton(
          tooltip: 'Delete trip',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () async {
            await c.db.deleteTrip(id);
            await c.refreshForecast();
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ]),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: c.db.predictionsForTrip(id),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snap.data!;
          final health = rows.map((r) => (r['health'] as num?)?.toDouble()).whereType<double>().toList();
          final alerts = rows.where((r) => r['status'] == 'warning' || r['status'] == 'critical').toList();
          final rtts = rows.map((r) => (r['rtt_ms'] as num?)?.toInt()).whereType<int>().toList();
          final avgRtt = rtts.isEmpty ? null : rtts.reduce((a, b) => a + b) / rtts.length;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            const SectionTitle('Health during this trip'),
            Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(12), child: TrendChart(values: health))),
            Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(spacing: 24, runSpacing: 8, children: [
                  _kv(context, 'Distance', '${((trip['km'] as num?) ?? 0).toStringAsFixed(1)} km'),
                  _kv(context, 'Windows analysed', '${rows.length}'),
                  _kv(context, 'Alerts', '${alerts.length}'),
                  _kv(context, 'Avg latency', avgRtt == null ? '–' : '${avgRtt.toStringAsFixed(0)} ms'),
                  _kv(context, 'Fuel trim', _fmt(trip['ltft_mean'], '%')),
                  _kv(context, 'Voltage', _fmt(trip['volt_mean'], 'V', 2)),
                  _kv(context, 'Coolant', _fmt(trip['coolant_mean'], '°C')),
                ]),
              ),
            ),
            SectionTitle('Alerts (${alerts.length})'),
            if (alerts.isEmpty)
              const Card(elevation: 0, child: ListTile(title: Text('No alerts on this trip.'))),
            for (final a in alerts.reversed.take(30)) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4, top: 4),
                child: Text(formatDate(a['ts'] as int), style: Theme.of(context).textTheme.labelSmall),
              ),
              for (final f in (jsonDecode(a['findings'] as String) as List))
                FindingCard(Finding.fromJson(f as Map<String, dynamic>)),
            ],
          ]);
        },
      ),
    );
  }

  static String _fmt(Object? v, String unit, [int d = 1]) =>
      v == null ? '–' : '${(v as num).toStringAsFixed(d)} $unit';

  Widget _kv(BuildContext context, String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: Theme.of(context).textTheme.labelSmall),
          Text(v, style: Theme.of(context).textTheme.titleMedium),
        ],
      );
}
