import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'actions.dart';
import 'side_tree.dart';

/// Foto diaria del uso de cada cuenta.
class Usage {
  static const _key = 'mgd_usage_history';
  static const _keepDays = 400;

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// {día: {email: [uso, límite]}}
  static Future<Map<String, Map<String, List<int>>>> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in j.entries)
          e.key: {
            for (final a in (e.value as Map<String, dynamic>).entries)
              a.key: [for (final v in a.value as List) (v as num).toInt()]
          }
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> record(List<Account> accounts) async {
    final data = await read();
    final today = _day(DateTime.now());
    final m = data[today] ?? {};
    for (final a in accounts) {
      final q = a.quota;
      if (q == null) continue;
      m[a.email] = [q.usage, q.limit ?? 0];
    }
    data[today] = m;
    final keys = data.keys.toList()..sort();
    while (keys.length > _keepDays) {
      data.remove(keys.removeAt(0));
    }
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(data));
  }
}

class _Series {
  final Account account;
  final List<(DateTime, int, int)> points; // día, uso, límite
  _Series(this.account, this.points);

  /// Crecimiento diario (bytes/día) con una recta sobre los últimos 30 días.
  double? get perDay {
    final last = points.where((p) => p.$1.isAfter(DateTime.now().subtract(const Duration(days: 31)))).toList();
    if (last.length < 3) return null;
    final x0 = last.first.$1;
    final xs = [for (final p in last) p.$1.difference(x0).inHours / 24.0];
    final ys = [for (final p in last) p.$2.toDouble()];
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n, my = ys.reduce((a, b) => a + b) / n;
    var sxy = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      den += (xs[i] - mx) * (xs[i] - mx);
    }
    return den == 0 ? null : sxy / den;
  }

  DateTime? get fullOn {
    final g = perDay;
    if (g == null || g <= 0 || points.isEmpty) return null;
    final p = points.last;
    if (p.$3 <= 0) return null;
    final days = (p.$3 - p.$2) / g;
    if (days > 3650) return null;
    return DateTime.now().add(Duration(days: max(0, days.round())));
  }
}

class EvolutionPage extends StatefulWidget {
  const EvolutionPage({super.key});

  @override
  State<EvolutionPage> createState() => _EvolutionPageState();
}

class _EvolutionPageState extends State<EvolutionPage> {
  List<_Series> _series = [];
  int _days = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await Usage.read();
    final keys = data.keys.toList()..sort();
    final series = <_Series>[];
    for (final a in DriveActions.store.accounts) {
      final pts = <(DateTime, int, int)>[];
      for (final k in keys) {
        final v = data[k]![a.email];
        if (v != null && v.length == 2) pts.add((DateTime.parse(k), v[0], v[1]));
      }
      if (pts.isNotEmpty) series.add(_Series(a, pts));
    }
    if (mounted) {
      setState(() {
        _series = series;
        _days = keys.length;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    String day(DateTime d) => '${d.day}/${d.month}/${d.year}';
    return Scaffold(
      appBar: AppBar(title: const Text('Evolución del uso'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      body: withSidebar(
        context,
        ListView(padding: const EdgeInsets.all(16), children: [
          Text('% de uso por cuenta · $_days ${_days == 1 ? 'día registrado' : 'días registrados'}',
              style: t.titleSmall),
          const SizedBox(height: 4),
          const Text('Se guarda una foto por día cada vez que se actualizan las cuotas '
              '(al abrir la app o en la revisión diaria).'),
          const SizedBox(height: 12),
          SizedBox(
            height: 240,
            child: _series.isEmpty
                ? const Center(child: Text('Todavía no hay datos. Volvé en unos días.'))
                : CustomPaint(
                    painter: _ChartPainter(_series, Theme.of(context).colorScheme.outlineVariant,
                        t.bodySmall ?? const TextStyle(fontSize: 11)),
                    size: Size.infinite,
                  ),
          ),
          const SizedBox(height: 16),
          for (final s in _series)
            ListTile(
              leading: CircleAvatar(radius: 8, backgroundColor: Color(s.account.color)),
              title: Text(s.account.title),
              subtitle: Text(() {
                final g = s.perDay;
                final full = s.fullOn;
                if (g == null) return 'Hacen falta al menos 3 días de datos para estimar.';
                final rate = g >= 0 ? '+${formatBytes(g.round())}/día' : '−${formatBytes((-g).round())}/día';
                return full == null
                    ? '$rate · no se llena al ritmo actual'
                    : '$rate · al ritmo actual se llena el ${day(full)}';
              }()),
              trailing: Text(s.points.last.$3 > 0
                  ? '${(s.points.last.$2 * 100 / s.points.last.$3).round()} %'
                  : formatBytes(s.points.last.$2)),
            ),
        ]),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<_Series> series;
  final Color grid;
  final TextStyle label;
  _ChartPainter(this.series, this.grid, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, bottom = 18.0;
    final w = size.width - left, h = size.height - bottom;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final pct in [0, 25, 50, 75, 100]) {
      final y = h - h * pct / 100;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(text: TextSpan(text: '$pct%', style: label), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }
    final all = [for (final s in series) ...s.points.map((p) => p.$1)];
    if (all.isEmpty) return;
    final minD = all.reduce((a, b) => a.isBefore(b) ? a : b);
    final maxD = all.reduce((a, b) => a.isAfter(b) ? a : b);
    final span = max(1, maxD.difference(minD).inHours);
    for (final s in series) {
      final paint = Paint()
        ..color = Color(s.account.color)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = s.points[i];
        final pct = p.$3 > 0 ? p.$2 / p.$3 : 0.0;
        final x = left + w * p.$1.difference(minD).inHours / span;
        final y = h - h * pct.clamp(0.0, 1.0).toDouble();
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = Color(s.account.color));
      }
      canvas.drawPath(path, paint);
    }
    String d(DateTime x) => '${x.day}/${x.month}';
    final a = TextPainter(text: TextSpan(text: d(minD), style: label), textDirection: TextDirection.ltr)..layout();
    a.paint(canvas, Offset(left, h + 2));
    final b = TextPainter(text: TextSpan(text: d(maxD), style: label), textDirection: TextDirection.ltr)..layout();
    b.paint(canvas, Offset(size.width - b.width, h + 2));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
