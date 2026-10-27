import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core_api/monitoring_api.dart';
import '../../state/monitoring_controller.dart';
import '../../theme/tokens.dart';

Color monColor(MonStatus s) => switch (s) {
  MonStatus.online => AerColors.sage,
  MonStatus.degraded => AerColors.amber,
  MonStatus.offline => AerColors.terracotta,
  MonStatus.unknown => AerColors.lavender,
  MonStatus.unsupported => AerColors.inkMuted,
};

IconData monIcon(MonStatus s) => switch (s) {
  MonStatus.online => Icons.check_circle_rounded,
  MonStatus.degraded => Icons.error_rounded,
  MonStatus.offline => Icons.power_off_rounded,
  MonStatus.unknown => Icons.help_rounded,
  MonStatus.unsupported => Icons.do_not_disturb_on_rounded,
};

String monLabel(MonStatus s) => switch (s) {
  MonStatus.online => 'В сети',
  MonStatus.degraded => 'Есть проблемы',
  MonStatus.offline => 'Недоступен',
  MonStatus.unknown => 'Неизвестно',
  MonStatus.unsupported => 'Не проверяется',
};

Color sevColor(MonSeverity s) => switch (s) {
  MonSeverity.critical => AerColors.terracotta,
  MonSeverity.warning => AerColors.amber,
  MonSeverity.info => AerColors.blue,
};

String sevLabel(MonSeverity s) => switch (s) {
  MonSeverity.critical => 'Критично',
  MonSeverity.warning => 'Предупреждение',
  MonSeverity.info => 'Информация',
};

IconData sevIcon(MonSeverity s) => switch (s) {
  MonSeverity.critical => Icons.report_rounded,
  MonSeverity.warning => Icons.warning_amber_rounded,
  MonSeverity.info => Icons.info_outline_rounded,
};

String two(int v) => v.toString().padLeft(2, '0');

String clock(DateTime t) {
  final l = t.toLocal();
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

String dateTime(DateTime t) {
  final l = t.toLocal();
  return '${two(l.day)}.${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
}

/// «5 с назад», «12 мин назад», «3 ч назад», date otherwise.
String ago(DateTime? t, [DateTime? now]) {
  if (t == null) return 'никогда';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return '${math.max(0, d.inSeconds)} с назад';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  if (d.inHours < 24) return '${d.inHours} ч назад';
  return dateTime(t);
}

String fmtBytes(double v) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var i = 0;
  while (v.abs() >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0).replaceAll('.', ',')} ${units[i]}';
}

String fmtDuration(double sec) {
  final d = Duration(seconds: sec.round());
  if (d.inDays > 0) return '${d.inDays} д ${d.inHours % 24} ч';
  if (d.inHours > 0) return '${d.inHours} ч ${d.inMinutes % 60} мин';
  return '${d.inMinutes} мин';
}

/// Formats a value with its unit; null stays visibly empty.
String fmtValue(double? v, String unit) {
  if (v == null) return '—';
  return switch (unit) {
    'B' => fmtBytes(v),
    'B/s' => '${fmtBytes(v)}/с',
    '%' => '${v.toStringAsFixed(v < 10 ? 1 : 0).replaceAll('.', ',')} %',
    '°C' => '${v.toStringAsFixed(0)} °C',
    's' => fmtDuration(v),
    'bool' => v >= 0.5 ? 'да' : 'нет',
    '1/s' => '${v.toStringAsFixed(1).replaceAll('.', ',')}/с',
    _ =>
      v == v.roundToDouble()
          ? v.toStringAsFixed(0)
          : v.toStringAsFixed(1).replaceAll('.', ','),
  };
}

const metricLabels = {
  'cpu.usage': 'CPU',
  'mem.used_percent': 'Память',
  'mem.used_bytes': 'Память занято',
  'mem.total_bytes': 'Память всего',
  'swap.used_percent': 'Swap',
  'disk.used_percent': 'Диск',
  'disk.free_bytes': 'Свободно',
  'net.rx_rate': 'Приём',
  'net.tx_rate': 'Передача',
  'net.errors_rate': 'Ошибки сети',
  'cpu.temperature': 'Темп. CPU',
  'gpu.usage': 'GPU',
  'gpu.temperature': 'Темп. GPU',
  'system.uptime': 'Работает',
  'process.count': 'Процессов',
  'service.active': 'Служба',
  'process.cpu_percent': 'CPU процесса',
  'process.rss_bytes': 'Память процесса',
  'bot.api_ok': 'API Telegram',
  'agent.dropped': 'Потеряно',
  'docker.cpu_percent': 'CPU контейнера',
  'docker.mem_bytes': 'Память контейнера',
  'docker.net_rx_rate': 'Приём',
  'docker.net_tx_rate': 'Передача',
};

String metricName(MetricValue m) {
  final base = metricLabels[m.metric] ?? m.metric;
  return m.label.isEmpty ? base : '$base · ${m.label}';
}

class StatusChip extends StatelessWidget {
  const StatusChip(
    this.status, {
    super.key,
    this.stale = false,
    this.dense = false,
  });
  final MonStatus status;
  final bool stale;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = monColor(status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 10,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: stale ? 0.08 : 0.15),
        borderRadius: BorderRadius.circular(AerRadii.large),
        border: Border.all(color: c.withValues(alpha: stale ? 0.4 : 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            monIcon(status),
            size: dense ? 13 : 16,
            color: c.withValues(alpha: stale ? 0.6 : 1),
          ),
          const SizedBox(width: 5),
          Text(
            stale ? '${monLabel(status)} · устарело' : monLabel(status),
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: AerColors.ink),
          ),
        ],
      ),
    );
  }
}

/// Shows whether the data is live, stale (with its time) or missing.
class FreshnessPill extends StatelessWidget {
  const FreshnessPill({super.key, required this.controller});
  final MonitoringController controller;

  @override
  Widget build(BuildContext context) {
    final at = controller.updatedAt;
    final (icon, color, text) = switch (controller.freshness) {
      MonFreshness.live => (
        Icons.sync_rounded,
        AerColors.sage,
        'Обновлено в ${at == null ? '—' : clock(at)}',
      ),
      MonFreshness.stale => (
        Icons.history_rounded,
        AerColors.amber,
        'Нет связи с Core — последние данные от ${at == null ? '—' : dateTime(at)}, они устарели',
      ),
      MonFreshness.none => (
        Icons.cloud_off_rounded,
        AerColors.inkMuted,
        'Данных мониторинга пока нет',
      ),
    };
    return Container(
      key: const Key('mon-freshness'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AerColors.surface,
        borderRadius: BorderRadius.circular(AerRadii.large),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Line chart with gaps where data is missing (null → break, never 0).
class MetricChart extends StatelessWidget {
  const MetricChart({super.key, required this.series, this.height = 220});
  final MetricSeries series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final values = [for (final p in series.points) ?p.value];
    if (values.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Нет данных за выбранный период',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: AerColors.inkMuted),
          ),
        ),
      );
    }
    return SizedBox(
      key: const Key('metric-chart'),
      height: height,
      child: CustomPaint(
        painter: _ChartPainter(series, Theme.of(context).textTheme.labelSmall!),
        size: Size.infinite,
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.s, this.label);
  final MetricSeries s;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 64.0, bottom = 22.0, top = 8.0, right = 8.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    final vals = [for (final p in s.points) ?p.value];
    var lo = vals.reduce(math.min), hi = vals.reduce(math.max);
    if (s.unit == '%') {
      lo = 0;
      hi = math.max(hi, 100);
    } else {
      lo = math.min(lo, 0);
      if (hi == lo) hi = lo + 1;
      hi *= 1.1;
    }
    final grid = Paint()
      ..color = AerColors.border
      ..strokeWidth = 1;
    void text(String t, Offset at, {bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: t,
          style: label.copyWith(color: AerColors.inkMuted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - Offset(right ? tp.width : 0, tp.height / 2));
    }

    for (var i = 0; i <= 4; i++) {
      final y = top + h * i / 4;
      canvas.drawLine(Offset(left, y), Offset(left + w, y), grid);
      text(
        fmtValue(hi - (hi - lo) * i / 4, s.unit),
        Offset(left - 6, y),
        right: true,
      );
    }
    final n = s.points.length;
    Offset at(int i, double v) => Offset(
      left + (n <= 1 ? 0 : w * i / (n - 1)),
      top + h * (1 - (v - lo) / (hi - lo)),
    );
    final line = Paint()
      ..color = AerColors.accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = AerColors.accent.withValues(alpha: 0.12);
    final band = Paint()..color = AerColors.accentSoft.withValues(alpha: 0.35);
    // Draw each contiguous run separately: gaps stay visible.
    var i = 0;
    while (i < n) {
      while (i < n && s.points[i].value == null) {
        i++;
      }
      final start = i;
      while (i < n && s.points[i].value != null) {
        i++;
      }
      if (start >= n) break;
      final run = [for (var k = start; k < i; k++) k];
      if (run.length == 1) {
        canvas.drawCircle(
          at(run.first, s.points[run.first].value!),
          2.5,
          Paint()..color = AerColors.accent,
        );
        continue;
      }
      if (s.resolution != 'raw') {
        final b = Path()
          ..moveTo(
            at(run.first, s.points[run.first].max!).dx,
            at(run.first, s.points[run.first].max!).dy,
          );
        for (final k in run) {
          b.lineTo(at(k, s.points[k].max!).dx, at(k, s.points[k].max!).dy);
        }
        for (final k in run.reversed) {
          b.lineTo(at(k, s.points[k].min!).dx, at(k, s.points[k].min!).dy);
        }
        canvas.drawPath(b..close(), band);
      }
      final p = Path()
        ..moveTo(
          at(run.first, s.points[run.first].value!).dx,
          at(run.first, s.points[run.first].value!).dy,
        );
      for (final k in run.skip(1)) {
        p.lineTo(at(k, s.points[k].value!).dx, at(k, s.points[k].value!).dy);
      }
      final area = Path.from(p)
        ..lineTo(at(run.last, lo).dx, top + h)
        ..lineTo(at(run.first, lo).dx, top + h)
        ..close();
      canvas.drawPath(area, fill);
      canvas.drawPath(p, line);
    }
    if (n > 0) {
      text(dateTime(s.points.first.t), Offset(left, size.height - 8));
      text(
        dateTime(s.points.last.t),
        Offset(left + w, size.height - 8),
        right: true,
      );
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.s != s;
}

/// A section card in the Cozy Beige style.
class MonCard extends StatelessWidget {
  const MonCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AerSpacing.m),
  });
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: padding, child: child),
  );
}
