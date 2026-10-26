import 'package:flutter/material.dart';

import '../state/connection_controller.dart';
import '../theme/tokens.dart';

/// Icon + text + colour for a link state. Colour is never the only signal.
class LinkPresentation {
  const LinkPresentation(this.icon, this.label, this.color, this.explanation);

  final IconData icon;
  final String label;
  final Color color;
  final String explanation;

  static LinkPresentation of(CoreLink link) => switch (link) {
    CoreLink.checking => const LinkPresentation(
      Icons.hourglass_empty_rounded,
      'Проверка…',
      AerColors.blue,
      'Связываемся с AER Core.',
    ),
    CoreLink.online => const LinkPresentation(
      Icons.check_circle_outline_rounded,
      'Core на связи',
      AerColors.sage,
      'AER Core отвечает, токен принят.',
    ),
    CoreLink.degraded => const LinkPresentation(
      Icons.report_problem_outlined,
      'Core с проблемами',
      AerColors.amber,
      'AER Core отвечает, но сообщает о неполадке хранилища.',
    ),
    CoreLink.unauthorized => const LinkPresentation(
      Icons.key_off_outlined,
      'Нет доступа',
      AerColors.amber,
      'AER Core отвечает, но токен не найден или отклонён. '
          'Проверьте файл токена (AER_CORE_TOKEN_FILE).',
    ),
    CoreLink.offline => const LinkPresentation(
      Icons.cloud_off_outlined,
      'Core недоступен',
      AerColors.terracotta,
      'AER Core не отвечает. Приложение работает автономно: '
          'показаны последние известные данные, действия заблокированы.',
    ),
    CoreLink.incompatible => const LinkPresentation(
      Icons.sync_problem_outlined,
      'Несовместимый ответ',
      AerColors.terracotta,
      'AER Core ответил в неожиданном формате. '
          'Возможно, версии клиента и Core не совпадают.',
    ),
  };
}

/// Short human-readable age of a timestamp, e.g. "12 с назад".
String formatAge(DateTime? at, DateTime now) {
  if (at == null) return 'никогда';
  final d = now.difference(at);
  if (d.inSeconds < 5) return 'только что';
  if (d.inMinutes < 1) return '${d.inSeconds} с назад';
  if (d.inHours < 1) return '${d.inMinutes} мин назад';
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
}

String formatUptime(int seconds) {
  final d = Duration(seconds: seconds);
  if (d.inDays > 0) return '${d.inDays} д ${d.inHours % 24} ч';
  if (d.inHours > 0) return '${d.inHours} ч ${d.inMinutes % 60} мин';
  if (d.inMinutes > 0) return '${d.inMinutes} мин';
  return '${d.inSeconds} с';
}
