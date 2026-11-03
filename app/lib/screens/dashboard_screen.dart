import 'package:flutter/material.dart';

import '../models/prediction.dart';
import '../services/app_settings.dart';
import '../services/monitoring_controller.dart';
import '../services/obd/fault_scenarios.dart';
import '../services/obd/obd_pids.dart';
import '../services/obd/telemetry_source.dart';
import '../widgets/common.dart';

class DashboardScreen extends StatelessWidget {
  final MonitoringController c;
  const DashboardScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final r = c.lastResult;
        return Scaffold(
          appBar: AppBar(
            title: const Text('PVMS', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
            actions: [
              _ServerChip(c),
              const SizedBox(width: 12),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: c.running ? c.stopTrip : c.startTrip,
            backgroundColor: c.running ? const Color(0xFFEF4444) : null,
            icon: Icon(c.running ? Icons.stop_rounded : Icons.play_arrow_rounded),
            label: Text(c.running ? 'Stop trip' : 'Start trip'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
            children: [
              _SourceLine(c),
              const SizedBox(height: 12),
              _StatusCard(c, r),
              if (!c.serverReachable || c.pendingCount > 0) _OfflineBanner(c),
              if (c.settings.activeVehicleId != null && !c.calibrated && c.serverReachable) _LearningBanner(c),
              const SectionTitle('Live data'),
              _LiveGrid(c),
              SectionTitle('Diagnosis',
                  trailing: r?.contributors.isNotEmpty == true
                      ? Text('AI explanation available', style: Theme.of(context).textTheme.labelSmall)
                      : null),
              ..._findings(context, r),
              const SectionTitle('Predictive forecast'),
              _ForecastCard(c),
              if (c.settings.source == DataSourceKind.simulator) ...[
                const SectionTitle('Simulator fault (demo)'),
                _ScenarioPicker(c),
              ],
            ],
          ),
        );
      },
    );
  }

  List<Widget> _findings(BuildContext context, PredictionResult? r) {
    final codes = [
      for (final code in c.dtcs ?? const <String>[])
        FindingCard(Finding(
          code: code,
          severity: 'warning',
          title: 'Fault code $code stored by the car',
          message: kDtcDescriptions[code] ?? 'Manufacturer-specific code.',
          recommendation: 'Show this code to a mechanic. It was recorded by the car\'s own computer (ECU).',
          source: 'ecu',
        )),
    ];
    return [...codes, ..._liveFindings(r)];
  }

  List<Widget> _liveFindings(PredictionResult? r) {
    if (r == null) {
      return [
        _InfoCard(
          icon: Icons.directions_car_filled_rounded,
          text: c.running
              ? 'Collecting the first 30 readings (about 30 seconds of driving)…'
              : 'Press "Start trip" to begin monitoring.',
        )
      ];
    }
    if (r.findings.isEmpty && r.offline) {
      return [
        const _InfoCard(
            icon: Icons.cloud_off_rounded,
            text: 'Server offline: only basic overheating and charging checks are running on the phone. '
                'Saved data will be analysed when the server is back.')
      ];
    }
    if (r.findings.isEmpty) {
      return [
        const _InfoCard(icon: Icons.verified_rounded, text: 'No problems detected in the latest readings.', good: true)
      ];
    }
    return r.findings.map((f) => FindingCard(f)).toList();
  }
}

class _ServerChip extends StatelessWidget {
  final MonitoringController c;
  const _ServerChip(this.c);
  @override
  Widget build(BuildContext context) {
    final ok = c.serverReachable;
    final rtt = c.lastResult?.roundTripMs;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(ok ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
          size: 16, color: ok ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
      label: Text(ok ? (rtt == null ? 'Server' : '$rtt ms') : 'Offline'),
    );
  }
}

class _SourceLine extends StatelessWidget {
  final MonitoringController c;
  const _SourceLine(this.c);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sim = c.settings.source == DataSourceKind.simulator;
    final color = switch (c.sourceState) {
      SourceState.streaming => const Color(0xFF22C55E),
      SourceState.connecting => const Color(0xFFEAB308),
      SourceState.error => const Color(0xFFEF4444),
      SourceState.idle => cs.onSurfaceVariant,
    };
    return Row(children: [
      Icon(sim ? Icons.science_rounded : Icons.bluetooth_rounded, size: 18, color: color),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          c.sourceMessage.isNotEmpty ? c.sourceMessage : c.sourceName,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (c.running)
        Text('${c.tripKm.toStringAsFixed(1)} km', style: Theme.of(context).textTheme.labelMedium),
    ]);
  }
}

class _StatusCard extends StatelessWidget {
  final MonitoringController c;
  final PredictionResult? r;
  const _StatusCard(this.c, this.r);

  @override
  Widget build(BuildContext context) {
    final r = this.r;
    final st = StatusStyle.of(r?.status);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final String regime;
    if (r == null) {
      regime = c.running ? 'Waiting for first analysis' : 'Not monitoring';
    } else if (r.offline) {
      regime = 'Server offline · AI paused, on-phone safety checks only';
    } else if (r.regime == 'engine_off') {
      regime = 'Engine off';
    } else if (r.regime == 'warming_up') {
      regime = 'Engine warming up · AI starts at 75 °C, safety rules active';
    } else if (r.modelUsed == 'learning') {
      regime = 'Engine warm · safety rules active, AI still learning this car';
    } else {
      regime = 'Engine warm · full AI analysis';
    }
    final model = switch (r?.modelUsed) {
      'vehicle' => 'AI profile learned for "${c.settings.vehicleId}"',
      'learning' => 'Learning "${c.settings.vehicleId}": ${c.learningCollected}/${c.learningNeeded} windows',
      'local' => 'No server connection',
      'base' => 'Base model (Opel dataset)',
      _ => '',
    };
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: st.color.withValues(alpha: 0.6), width: 1.5)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          HealthGauge(value: r?.healthScore, size: 150),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(st.icon, color: st.color),
                const SizedBox(width: 6),
                Flexible(child: Text(st.label, style: t.titleLarge?.copyWith(color: st.color, fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 8),
              Text(regime, style: t.bodyMedium),
              if (model.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(model, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
              if (r?.roundTripMs != null) ...[
                const SizedBox(height: 6),
                Text('Latency ${r!.roundTripMs} ms (server ${r.serverProcessingMs?.toStringAsFixed(0) ?? '-'} ms)',
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _LiveGrid extends StatelessWidget {
  final MonitoringController c;
  const _LiveGrid(this.c);
  @override
  Widget build(BuildContext context) {
    final s = c.current;
    final warn = StatusStyle.of('warning').color;
    final crit = StatusStyle.of('critical').color;
    Color? coolantHl() {
      final v = s?.coolantTemp;
      if (v == null) return null;
      return v >= 112 ? crit : (v >= 106 ? warn : null);
    }

    Color? voltHl() {
      final v = s?.batteryVoltage;
      if (v == null || (s?.rpm ?? 0) < 400) return null;
      return v < 12.6 ? crit : (v < 13.2 ? warn : null);
    }

    final tiles = [
      MetricTile(label: 'Engine speed', value: s?.rpm, unit: 'rpm', icon: Icons.speed_rounded),
      MetricTile(label: 'Vehicle speed', value: s?.speed, unit: 'km/h', icon: Icons.directions_car_rounded),
      MetricTile(
          label: 'Coolant', value: s?.coolantTemp, unit: '°C', icon: Icons.thermostat_rounded, highlight: coolantHl()),
      MetricTile(
          label: 'Battery', value: s?.batteryVoltage, unit: 'V', decimals: 1, icon: Icons.battery_charging_full_rounded,
          highlight: voltHl()),
      MetricTile(label: 'Engine load', value: s?.engineLoad, unit: '%', icon: Icons.fitness_center_rounded),
      MetricTile(label: 'Fuel trim (total)', value: s?.totalFuelTrim, unit: '%', icon: Icons.local_gas_station_rounded),
    ];
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth > 560 ? 3 : 2;
      final w = (box.maxWidth - (cols - 1) * 10) / cols;
      return Wrap(spacing: 10, runSpacing: 10, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
    });
  }
}

class _ForecastCard extends StatelessWidget {
  final MonitoringController c;
  const _ForecastCard(this.c);
  @override
  Widget build(BuildContext context) {
    final f = c.forecast;
    final t = Theme.of(context).textTheme;
    final String title;
    final String body;
    IconData icon = Icons.timeline_rounded;
    Color? color;
    if (f == null || f.status == 'insufficient_data') {
      title = 'Building your car\'s history';
      body = 'The Time-To-Failure estimate needs at least 5 trips covering some distance '
          '(${f?.trips ?? 0} so far). Tip: Settings → "Load Opel demo history".';
    } else if (f.status == 'none' || f.status == 'stable') {
      title = 'No degradation trend';
      body = 'Across ${f.trips} trips no monitored indicator is trending towards a fault limit.';
      icon = Icons.trending_flat_rounded;
      color = StatusStyle.of('healthy').color;
    } else if (f.status == 'threshold_reached') {
      title = '${f.indicatorLabel} has reached its limit';
      body = 'Book an inspection — the trend across ${f.trips} trips has already crossed the fault threshold.';
      icon = Icons.report_rounded;
      color = StatusStyle.of('critical').color;
    } else {
      final km = f.kmRemaining ?? 0;
      title = '≈ ${_fmtKm(km)} km until attention needed';
      body = '${f.indicatorLabel} is trending towards its fault limit (based on ${f.trips} trips). '
          'Estimate from linear trend extrapolation.';
      icon = Icons.trending_up_rounded;
      color = km < 2000 ? StatusStyle.of('warning').color : StatusStyle.of('monitor').color;
    }
    return Card(
      elevation: 0,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: color, size: 30),
        title: Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(body)),
      ),
    );
  }

  static String _fmtKm(int km) {
    final s = km.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

class _ScenarioPicker extends StatelessWidget {
  final MonitoringController c;
  const _ScenarioPicker(this.c);
  @override
  Widget build(BuildContext context) {
    final sel = c.settings.scenario;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButton<FaultScenario>(
            isExpanded: true,
            value: sel,
            underline: const SizedBox.shrink(),
            items: [for (final s in FaultScenario.values) DropdownMenuItem(value: s, child: Text(s.label))],
            onChanged: (s) {
              if (s != null) c.setScenario(s);
            },
          ),
          Text(sel.description, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  final MonitoringController c;
  const _OfflineBanner(this.c);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: MaterialBanner(
          backgroundColor: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.35),
          leading: const Icon(Icons.cloud_off_rounded),
          content: Text(c.serverReachable
              ? '${c.pendingCount} data windows recorded offline are waiting to be analysed.'
              : 'Server unreachable. Recording offline (${c.pendingCount} windows saved); '
                  'on-phone safety checks are active.'),
          actions: [TextButton(onPressed: c.syncPending, child: const Text('Sync now'))],
        ),
      );
}

class _LearningBanner extends StatelessWidget {
  final MonitoringController c;
  const _LearningBanner(this.c);
  @override
  Widget build(BuildContext context) {
    final p = c.learningNeeded == 0 ? 0.0 : (c.learningCollected / c.learningNeeded).clamp(0.0, 1.0);
    final minsLeft = ((c.learningNeeded - c.learningCollected).clamp(0, 999) * 18 / 60).ceil();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.school_rounded, size: 20),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('Learning this car (${(p * 100).round()} %)',
                      style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: p),
            const SizedBox(height: 8),
            Text('About $minsLeft min of warm-engine driving left (any number of trips). Until then PVMS uses '
                'the universal safety rules and the car\'s own fault codes; the AI switches on automatically.',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool good;
  const _InfoCard({required this.icon, required this.text, this.good = false});
  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: ListTile(
          leading: Icon(icon, color: good ? StatusStyle.of('healthy').color : null),
          title: Text(text),
        ),
      );
}
