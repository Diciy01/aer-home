import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Icon for a catalog/entity icon key. Unknown keys fall back to a neutral icon,
/// so new catalog types render without a client update.
IconData entityIcon(String key) => switch (key.split('/').first) {
  'computer' => Icons.computer_outlined,
  'server' => Icons.dns_outlined,
  'router' => Icons.router_outlined,
  'tv' => Icons.tv_outlined,
  'phone' => Icons.smartphone_outlined,
  'network' => Icons.lan_outlined,
  'bot' => Icons.smart_toy_outlined,
  'app' => Icons.apps_outlined,
  'process' => Icons.memory_outlined,
  'container' => Icons.view_in_ar_outlined,
  'database' => Icons.storage_outlined,
  'web' => Icons.language_outlined,
  'service' => Icons.miscellaneous_services_outlined,
  'automation' => Icons.auto_mode_outlined,
  'storage' => Icons.save_outlined,
  'virtual' => Icons.bubble_chart_outlined,
  _ => Icons.category_outlined,
};

/// Soft tile colour per catalog group.
Color groupTint(String? group) => switch (group) {
  'hardware' => AerColors.accentSoft,
  'network' => AerColors.blue.withValues(alpha: 0.28),
  'software' => AerColors.sage.withValues(alpha: 0.28),
  'virtual' => AerColors.lavender.withValues(alpha: 0.32),
  _ => AerColors.surfaceMuted,
};

const groupLabels = {
  'hardware': 'Устройства',
  'network': 'Сеть и сайты',
  'software': 'Программы и сервисы',
  'virtual': 'Прочее',
};

const discoveryLabels = {
  'manual': 'Добавлен вручную',
  'agent': 'Агент',
  'docker': 'Docker',
  'network_scan': 'Сканирование сети',
  'import': 'Импорт',
  'external': 'Внешний источник',
};

/// Rounded icon tile used on cards and in the wizard.
class EntityIconTile extends StatelessWidget {
  const EntityIconTile({
    super.key,
    required this.icon,
    required this.group,
    this.size = 44,
  });

  final String icon;
  final String? group;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: groupTint(group),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Icon(entityIcon(icon), color: AerColors.ink, size: size * 0.5),
    );
  }
}
