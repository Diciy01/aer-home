import 'package:flutter/material.dart';

import '../../core_api/bots_api.dart';
import '../../state/bots_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';

IconData runtimeIcon(String runtime) => switch (runtime) {
  'python' => Icons.terminal_rounded,
  'docker' => Icons.inventory_2_outlined,
  'telegram' => Icons.send_rounded,
  'n8n' => Icons.account_tree_outlined,
  'service' => Icons.settings_suggest_outlined,
  _ => Icons.smart_toy_outlined,
};

String runtimeLabel(String runtime) => botRuntimeLabels[runtime] ?? runtime;

(Color, IconData, String) jobLook(JobStatus s) => switch (s) {
  JobStatus.success => (
    AerColors.sage,
    Icons.check_circle_outline_rounded,
    'Успешно',
  ),
  JobStatus.failed => (AerColors.terracotta, Icons.error_outline, 'Ошибка'),
  JobStatus.running => (AerColors.blue, Icons.autorenew_rounded, 'Выполняется'),
  JobStatus.pending => (AerColors.inkMuted, Icons.schedule_rounded, 'Ожидает'),
  JobStatus.cancelled => (AerColors.lavender, Icons.block_rounded, 'Отменено'),
};

String runtimeStateLabel(String s) => switch (s) {
  'running' => 'процесс запущен',
  'stopped' => 'остановлен',
  'starting' => 'запускается',
  'unavailable' => 'адаптер недоступен',
  _ => 'неизвестно',
};

class JobChip extends StatelessWidget {
  const JobChip(this.status, {super.key});
  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final (c, icon, label) = jobLook(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AerRadii.large),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

String fmtMs(int? ms) {
  if (ms == null) return '—';
  if (ms < 1000) return '$ms мс';
  if (ms < 60000) {
    return '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} с';
  }
  return fmtDuration(ms / 1000);
}

IconData actionIcon(String id) => switch (id) {
  'start' => Icons.play_arrow_rounded,
  'stop' => Icons.stop_rounded,
  'restart' => Icons.restart_alt_rounded,
  'check' => Icons.network_check_rounded,
  _ => Icons.replay_rounded,
};

/// The only way the UI runs a bot action: Core issues a confirmation
/// (summary, risks, expiry), the owner confirms, the action runs once with
/// a fresh idempotency key. «Проверить соединение» is read-only and runs
/// without confirmation.
Future<BotActionRecord?> runBotAction(
  BuildContext context,
  BotsController bots, {
  required String entityId,
  required String action,
  String? jobId,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    BotConfirmation? conf;
    if (action != 'check') {
      conf = await bots.api.confirm(entityId, action, jobId: jobId);
      if (!context.mounted) return null;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _ConfirmDialog(conf: conf!),
      );
      if (ok != true) return null;
    }
    final rec = await bots.run(
      entityId,
      action,
      confirmation: conf,
      jobId: jobId,
    );
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${rec.status == 'succeeded' ? 'Готово' : 'Не выполнено'}: ${rec.message}',
        ),
      ),
    );
    return rec;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(describeError(e))));
    return null;
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.conf});
  final BotConfirmation conf;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final danger = conf.action == 'stop' || conf.action == 'restart';
    return AlertDialog(
      key: const Key('bot-confirm'),
      icon: Icon(
        actionIcon(conf.action),
        color: danger ? AerColors.terracotta : AerColors.accent,
      ),
      title: Text('${conf.summary}?'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in conf.risks)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: AerColors.amber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r, style: text.bodyMedium)),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Подтверждение действует до ${clock(conf.expiresAt)}. Действие выполнится один раз и попадёт в журнал аудита.',
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('bot-confirm-ok'),
          style: danger
              ? FilledButton.styleFrom(backgroundColor: AerColors.terracotta)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Подтвердить'),
        ),
      ],
    );
  }
}

/// Buttons for start/stop/restart/check: unavailable ones are disabled
/// with the reason in a tooltip (e.g. «Только мониторинг»).
class BotActionButtons extends StatelessWidget {
  const BotActionButtons({
    super.key,
    required this.bots,
    required this.entityId,
    required this.actions,
    this.dense = false,
    this.onDone,
  });

  final BotsController bots;
  final String entityId;
  final List<BotAction> actions;
  final bool dense;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AerSpacing.s,
      runSpacing: AerSpacing.s,
      children: [
        for (final a in actions.where((a) => a.id != 'job.retry'))
          Tooltip(
            message: a.available
                ? (a.risk.isEmpty ? a.label : a.risk)
                : a.reason,
            child: OutlinedButton.icon(
              key: Key('bot-action-${a.id}'),
              style: dense
                  ? OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    )
                  : null,
              onPressed: a.available && bots.canAct
                  ? () async {
                      await runBotAction(
                        context,
                        bots,
                        entityId: entityId,
                        action: a.id,
                      );
                      onDone?.call();
                    }
                  : null,
              icon: Icon(actionIcon(a.id), size: 18),
              label: Text(a.label),
            ),
          ),
      ],
    );
  }
}

/// A labelled value in a fact grid.
class Fact extends StatelessWidget {
  const Fact(this.label, this.value, {super.key, this.width = 200});
  final String label;
  final String value;
  final double width;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
          ),
          const SizedBox(height: 2),
          Text(value, style: text.bodyMedium),
        ],
      ),
    );
  }
}
