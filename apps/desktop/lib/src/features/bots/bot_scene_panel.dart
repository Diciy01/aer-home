import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/bots_api.dart';
import '../../state/bots_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import 'bot_details.dart';
import 'bot_widgets.dart';

/// The bot part of the house quick card. The scene object stays bound to
/// the Registry entity through the usual binding (M03/M04); this panel only
/// appears when that entity is a bot.
class BotScenePanel extends StatefulWidget {
  const BotScenePanel({
    super.key,
    required this.bots,
    required this.bot,
    required this.onOpen,
  });

  final BotsController bots;
  final Bot bot;

  /// Opens the bot page on a tab.
  final void Function(BotTab tab) onOpen;

  @override
  State<BotScenePanel> createState() => _BotScenePanelState();
}

class _BotScenePanelState extends State<BotScenePanel> {
  BotDetail? _d;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(BotScenePanel old) {
    super.didUpdateWidget(old);
    if (old.bot.entityId != widget.bot.entityId) {
      _d = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!widget.bots.canAct) return;
    try {
      final d = await widget.bots.api.get(widget.bot.entityId);
      if (mounted) setState(() => _d = d);
    } catch (_) {
      // The card still shows the list data; actions stay hidden.
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = _d?.bot ?? widget.bot;
    final actions = (_d?.actions ?? const <BotAction>[])
        .where((a) => a.id == 'start' || a.id == 'stop' || a.id == 'restart')
        .toList();
    return Container(
      key: const Key('scene-bot-panel'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AerColors.surfaceMuted.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(runtimeIcon(b.runtime), size: 16, color: AerColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [
                    'Бот · ${runtimeLabel(b.runtime)}',
                    if (b.version.isNotEmpty) 'v${b.version}',
                  ].join(' · '),
                  style: text.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              'Heartbeat: ${b.heartbeat.credentials == 0 ? 'не настроен' : ago(b.heartbeat.lastSeenAt)}',
              if (b.runtimeState case final rt?) runtimeStateLabel(rt.state),
              if (b.uptimeSec != null)
                'работает ${fmtDuration(b.uptimeSec!.toDouble())}',
            ].join(' · '),
            style: text.bodySmall,
          ),
          if (b.lastError.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Ошибка: ${b.lastError}',
              key: const Key('scene-bot-error'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: AerColors.terracotta),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FilledButton.tonalIcon(
                key: const Key('scene-bot-open'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => widget.onOpen(BotTab.overview),
                icon: const Icon(Icons.smart_toy_outlined, size: 16),
                label: const Text('Карточка бота'),
              ),
              OutlinedButton(
                key: const Key('scene-bot-errors'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => widget.onOpen(BotTab.errors),
                child: const Text('Ошибки'),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 6),
            if (actions.every((a) => !a.available))
              Text(
                actions.first.reason,
                style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
              )
            else
              BotActionButtons(
                bots: widget.bots,
                entityId: b.entityId,
                actions: actions,
                dense: true,
                onDone: _load,
              ),
          ],
        ],
      ),
    );
  }
}
