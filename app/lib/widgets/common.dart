import 'dart:math';

import 'package:flutter/material.dart';

import '../models/prediction.dart';

/// Colours + labels for the four health states.
class StatusStyle {
  final Color color;
  final String label;
  final IconData icon;
  const StatusStyle(this.color, this.label, this.icon);

  static StatusStyle of(String? status) => switch (status) {
        'healthy' => const StatusStyle(Color(0xFF22C55E), 'Healthy', Icons.check_circle_rounded),
        'monitor' => const StatusStyle(Color(0xFFEAB308), 'Monitor', Icons.visibility_rounded),
        'warning' => const StatusStyle(Color(0xFFF97316), 'Attention needed', Icons.warning_amber_rounded),
        'critical' => const StatusStyle(Color(0xFFEF4444), 'Critical', Icons.report_rounded),
        'offline' => const StatusStyle(Color(0xFF94A3B8), 'AI paused', Icons.cloud_off_rounded),
        _ => const StatusStyle(Color(0xFF64748B), 'Waiting for data', Icons.hourglass_empty_rounded),
      };

  static Color forHealth(double? h) {
    if (h == null) return const Color(0xFF64748B);
    if (h >= 70) return of('healthy').color;
    if (h >= 50) return of('monitor').color;
    if (h >= 25) return of('warning').color;
    return of('critical').color;
  }
}

/// 270° arc gauge showing the 0–100 health score.
class HealthGauge extends StatelessWidget {
  final double? value;
  final double size;
  const HealthGauge({super.key, required this.value, this.size = 170});

  @override
  Widget build(BuildContext context) {
    final color = StatusStyle.forHealth(value);
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: (value ?? 0) / 100),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          painter: _GaugePainter(v, color, Theme.of(context).colorScheme.surfaceContainerHighest),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(value == null ? '--' : value!.round().toString(),
                  style: t.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
              Text('health', style: t.labelMedium?.copyWith(color: t.bodySmall?.color)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double v;
  final Color color, track;
  _GaugePainter(this.v, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    const start = 0.75 * pi, sweep = 1.5 * pi;
    final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, p..color = track);
    if (v > 0) canvas.drawArc(rect, start, sweep * v.clamp(0, 1), false, p..color = color);
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.v != v || o.color != color;
}

class MetricTile extends StatelessWidget {
  final String label, unit;
  final double? value;
  final int decimals;
  final IconData icon;
  final Color? highlight;
  const MetricTile(
      {super.key, required this.label, required this.value, required this.unit, required this.icon, this.decimals = 0, this.highlight});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: highlight == null ? null : Border.all(color: highlight!, width: 1.5),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: highlight ?? cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant), overflow: TextOverflow.ellipsis),
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: value == null ? '--' : value!.toStringAsFixed(decimals),
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                TextSpan(text: ' $unit', style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
              maxLines: 1,
            ),
          ]),
        ),
      ]),
    );
  }
}

class FindingCard extends StatelessWidget {
  final Finding f;
  const FindingCard(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (f.severity) {
      'critical' => StatusStyle.of('critical').color,
      'warning' => StatusStyle.of('warning').color,
      _ => cs.primary,
    };
    final icon = switch (f.severity) {
      'critical' => Icons.report_rounded,
      'warning' => Icons.warning_amber_rounded,
      _ => Icons.info_outline_rounded,
    };
    final sourceLabel = switch (f.source) {
      'model' => 'AI model',
      'local' => 'On-phone check',
      'ecu' => 'Car computer (ECU)',
      _ => 'Diagnostic rule',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: color.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color.withValues(alpha: 0.5))),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon, color: color),
          title: Text(f.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(f.message),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What to do', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color)),
            const SizedBox(height: 4),
            Text(f.recommendation),
            const SizedBox(height: 8),
            Text('$sourceLabel · ${f.code}', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Expanded(
              child: Text(text.toUpperCase(),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      letterSpacing: 1.1, color: Theme.of(context).colorScheme.onSurfaceVariant))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Simple line chart of health per trip (oldest → newest).
class TrendChart extends StatelessWidget {
  final List<double> values;
  const TrendChart({super.key, required this.values});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 140,
        child: CustomPaint(
          size: Size.infinite,
          painter: _TrendPainter(values, Theme.of(context).colorScheme),
        ),
      );
}

class _TrendPainter extends CustomPainter {
  final List<double> v;
  final ColorScheme cs;
  _TrendPainter(this.v, this.cs);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 28.0, bottom = 6.0;
    final w = size.width - left, h = size.height - bottom;
    final grid = Paint()
      ..color = cs.outlineVariant.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final g in [0, 50, 100]) {
      final y = h - h * g / 100;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      tp.text = TextSpan(text: '$g', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant));
      tp.layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }
    if (v.isEmpty) return;
    Offset pt(int i) => Offset(left + (v.length == 1 ? w / 2 : w * i / (v.length - 1)), h - h * v[i].clamp(0, 100) / 100);
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = cs.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    for (var i = 0; i < v.length; i++) {
      canvas.drawCircle(pt(i), 3.5, Paint()..color = StatusStyle.forHealth(v[i]));
    }
  }

  @override
  bool shouldRepaint(_TrendPainter o) => o.v != v;
}

String formatDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}
