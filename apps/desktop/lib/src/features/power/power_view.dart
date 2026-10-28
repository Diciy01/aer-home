import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/core_client.dart';
import '../../core_api/power_api.dart';
import '../../state/power_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';

/// «Питание»: computers with their real state, what can be done now (and
/// why not), the running job and the history. Dangerous actions show the
/// plan Core computed and need an explicit second confirmation.
class PowerView extends StatefulWidget {
  const PowerView({super.key, required this.power, this.onOpenRemote});
  final PowerController power;

  /// Opens Remote for a computer (null when Remote is not available).
  final void Function(String entityId)? onOpenRemote;

  @override
  State<PowerView> createState() => _PowerViewState();
}

class _PowerViewState extends State<PowerView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.power.start());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.power,
      builder: (context, _) {
        final p = widget.power;
        return DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AerSpacing.l,
                  AerSpacing.m,
                  AerSpacing.l,
                  0,
                ),
                child: Row(
                  children: [
                    Text('Питание', style: text.headlineSmall),
                    const SizedBox(width: AerSpacing.m),
                    Flexible(child: _Freshness(p: p)),
                    const Spacer(),
                    IconButton(
                      key: const Key('power-refresh'),
                      tooltip: 'Обновить',
                      onPressed: !p.loading ? p.refresh : null,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: AerSpacing.m),
                tabs: [
                  Tab(key: Key('power-tab-devices'), text: 'Компьютеры'),
                  Tab(key: Key('power-tab-history'), text: 'История операций'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _Devices(p: p, onOpenRemote: widget.onOpenRemote),
                    PowerHistory(p: p),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Freshness extends StatelessWidget {
  const _Freshness({required this.p});
  final PowerController p;

  @override
  Widget build(BuildContext context) {
    final at = p.updatedAt;
    final (icon, color, label) = p.isStale
        ? (
            Icons.history_rounded,
            AerColors.amber,
            'Нет связи с Core — данные от ${at == null ? '—' : dateTime(at)} устарели, команды недоступны',
          )
        : (
            Icons.sync_rounded,
            AerColors.sage,
            at == null ? 'Загрузка…' : 'Обновлено в ${clock(at)}',
          );
    return Row(
      key: const Key('power-freshness'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Devices extends StatelessWidget {
  const _Devices({required this.p, this.onOpenRemote});
  final PowerController p;
  final void Function(String entityId)? onOpenRemote;

  @override
  Widget build(BuildContext context) {
    if (p.updatedAt == null) {
      if (p.error != null) return Center(child: Text(describeError(p.error!)));
      return const Center(child: CircularProgressIndicator());
    }
    if (p.devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AerSpacing.l),
          child: Text(
            'Нет компьютеров с возможностями питания. Отметьте у компьютера в «Устройствах» «Wake-on-LAN», «Выключение» или «Перезагрузку» '
            'и установите на нём агент aer-power-host (docs/POWER_CONNECT.md).',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AerSpacing.l),
      child: Wrap(
        spacing: AerSpacing.m,
        runSpacing: AerSpacing.m,
        children: [
          for (final d in p.devices)
            SizedBox(
              width: 440,
              child: PowerDeviceCard(
                power: p,
                device: d,
                onOpenRemote: onOpenRemote,
              ),
            ),
        ],
      ),
    );
  }
}

Color stateColor(String state) => switch (state) {
  'online' => AerColors.sage,
  'offline' => AerColors.inkMuted,
  'unknown' => AerColors.inkMuted,
  _ => AerColors.blue,
};

IconData actionIcon(PowerAction a) => switch (a) {
  PowerAction.wake => Icons.power_settings_new_rounded,
  PowerAction.shutdown => Icons.power_off_outlined,
  PowerAction.reboot => Icons.restart_alt_rounded,
  PowerAction.suspend => Icons.bedtime_outlined,
  PowerAction.switchOs => Icons.swap_horiz_rounded,
  PowerAction.check => Icons.fact_check_outlined,
};

class PowerStateChip extends StatelessWidget {
  const PowerStateChip({super.key, required this.device, this.stale = false});
  final PowerDevice device;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final c = stale ? AerColors.amber : stateColor(device.state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: c),
          const SizedBox(width: 5),
          Text(
            stale ? '${device.stateLabel} (устарело)' : device.stateLabel,
            key: Key('power-state-${device.entityId}'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class PowerDeviceCard extends StatelessWidget {
  const PowerDeviceCard({
    super.key,
    required this.power,
    required this.device,
    this.onOpenRemote,
  });
  final PowerController power;
  final PowerDevice device;
  final void Function(String entityId)? onOpenRemote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = device;
    final muted = text.labelSmall?.copyWith(color: AerColors.inkMuted);
    final agent = d.activeAgent;
    final job = power.followed(d.entityId) ?? d.activeJob;
    return Card(
      key: Key('power-device-${d.entityId}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.computer_rounded, color: AerColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: text.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        d.currentOs.isEmpty
                            ? 'ОС: неизвестно'
                            : 'Сейчас: ${osLabel(d.currentOs)}',
                        style: muted,
                      ),
                    ],
                  ),
                ),
                PowerStateChip(device: d, stale: power.isStale),
              ],
            ),
            const SizedBox(height: 6),
            Text(d.stateReason, style: text.bodySmall, maxLines: 2),
            const SizedBox(height: 4),
            Text(
              [
                'Последний контакт: ${d.lastContactAt == null ? 'нет' : ago(d.lastContactAt)}',
                if (agent == null)
                  'агент питания не на связи'
                else if (agent.dryRun)
                  'агент в режиме проверки'
                else
                  'агент выполняет команды',
              ].join(' · '),
              style: muted,
            ),
            Text(
              d.wol == null
                  ? 'Wake-on-LAN не настроен'
                  : 'Wake-on-LAN: ${d.wol!.mac} → ${d.wol!.broadcast}${d.wol!.interface.isEmpty ? '' : ' через ${d.wol!.interface}'}',
              style: muted,
            ),
            if (agent?.dryRun ?? false) ...[
              const SizedBox(height: 6),
              const _Note(
                key: Key('power-dry-run'),
                icon: Icons.science_outlined,
                text:
                    'Агент работает в режиме проверки: команды не выполняются, результат — SIMULATED. '
                    'Включается владельцем в конфигурации агента ("execute": true).',
              ),
            ],
            if (d.sameMachine) ...[
              const SizedBox(height: 6),
              _Note(
                key: const Key('power-same-machine'),
                icon: Icons.info_outline_rounded,
                text: d.sameMachineNote,
              ),
            ],
            if (job != null &&
                (!job.state.terminal ||
                    power.followed(d.entityId) != null)) ...[
              const SizedBox(height: 8),
              PowerJobProgress(power: power, job: job),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in d.actions)
                  if (a.action != PowerAction.check)
                    _ActionButton(power: power, device: d, info: a),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: Key('power-check-${d.entityId}'),
                  onPressed: power.canAct
                      ? () =>
                            runPowerAction(context, power, d, PowerAction.check)
                      : null,
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('Проверить состояние'),
                ),
                TextButton(
                  key: Key('power-wol-${d.entityId}'),
                  onPressed: power.canAct
                      ? () => showWoLDialog(context, power, d)
                      : null,
                  child: const Text('Wake-on-LAN…'),
                ),
                TextButton(
                  key: Key('power-policy-${d.entityId}'),
                  onPressed: power.canAct
                      ? () => showPowerPolicyDialog(context, power, d)
                      : null,
                  child: const Text('Политика'),
                ),
                TextButton(
                  key: Key('power-history-${d.entityId}'),
                  onPressed: () => showDeviceHistory(context, power, d),
                  child: const Text('История'),
                ),
                if (onOpenRemote != null)
                  TextButton(
                    key: Key('power-remote-${d.entityId}'),
                    onPressed: () => onOpenRemote!(d.entityId),
                    child: const Text('Удалённый доступ'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AerColors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AerColors.amber),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.power,
    required this.device,
    required this.info,
  });
  final PowerController power;
  final PowerDevice device;
  final PowerActionInfo info;

  @override
  Widget build(BuildContext context) {
    final enabled = info.available && power.canAct;
    final b = OutlinedButton.icon(
      key: Key('power-${info.action.wire}-${device.entityId}'),
      style: info.dangerous && enabled
          ? OutlinedButton.styleFrom(foregroundColor: AerColors.terracotta)
          : null,
      onPressed: enabled
          ? () => runPowerAction(context, power, device, info.action)
          : null,
      icon: Icon(actionIcon(info.action), size: 18),
      label: Text(info.action.label),
    );
    // Unavailable actions stay visible, disabled, with the real reason.
    return Tooltip(
      message: enabled
          ? info.label
          : (info.reason.isNotEmpty
                ? info.reason
                : 'Нет связи с Core — команды недоступны'),
      child: b,
    );
  }
}

/// Plan → explicit confirmation → job. Check needs no confirmation.
Future<void> runPowerAction(
  BuildContext context,
  PowerController p,
  PowerDevice d,
  PowerAction action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (action == PowerAction.check) {
      final j = await p.check(d.entityId);
      messenger.showSnackBar(SnackBar(content: Text(j.message)));
      return;
    }
    var target = '';
    if (action == PowerAction.switchOs) {
      final t = await _chooseTarget(context, d);
      if (t == null) return;
      target = t;
    }
    final c = await p.prepare(d.entityId, action, targetOs: target);
    if (!context.mounted) return;
    final dangerous = d.action(action)?.dangerous ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => PowerConfirmDialog(
        device: d,
        action: action,
        confirmation: c,
        dangerous: dangerous,
      ),
    );
    if (ok != true) return;
    await p.run(d.entityId, action, confirmation: c, targetOs: target);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
  }
}

Future<String?> _chooseTarget(BuildContext context, PowerDevice d) {
  final targets = d.action(PowerAction.switchOs)?.targets ?? const [];
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      key: const Key('power-target-dialog'),
      title: Text('В какую ОС перезагрузить «${d.name}»?'),
      children: [
        for (final t in targets)
          ListTile(
            key: Key('power-target-${t.os}'),
            enabled: t.available,
            leading: Icon(
              t.available ? Icons.radio_button_unchecked : Icons.block_rounded,
            ),
            title: Text(t.label),
            subtitle: Text(
              t.available
                  ? 'Одноразовая загрузка, запись ${t.entryId}'
                  : t.reason,
            ),
            onTap: t.available ? () => Navigator.pop(context, t.os) : null,
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Text(
            'Постоянный порядок загрузки, GRUB и rEFInd не меняются. Если цель не загрузится, '
            'следующая обычная загрузка пойдёт как прежде.',
          ),
        ),
      ],
    ),
  );
}

class PowerConfirmDialog extends StatefulWidget {
  const PowerConfirmDialog({
    super.key,
    required this.device,
    required this.action,
    required this.confirmation,
    required this.dangerous,
  });
  final PowerDevice device;
  final PowerAction action;
  final PowerConfirmation confirmation;
  final bool dangerous;

  @override
  State<PowerConfirmDialog> createState() => _PowerConfirmDialogState();
}

class _PowerConfirmDialogState extends State<PowerConfirmDialog> {
  bool _ack = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = widget.confirmation;
    return AlertDialog(
      key: const Key('power-confirm-dialog'),
      title: Text(c.summary),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Проверки', style: text.labelLarge),
              for (final ch in c.checks)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      ch.ok ? Icons.check_rounded : Icons.warning_amber_rounded,
                      size: 16,
                      color: ch.ok ? AerColors.sage : AerColors.amber,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(ch.message, style: text.bodySmall)),
                  ],
                ),
              if (c.risks.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Риски', style: text.labelLarge),
                for (final r in c.risks)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('• $r', style: text.bodySmall),
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                'Подтверждение действует до ${clock(c.expiresAt)} и используется один раз.',
                style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
              ),
              if (widget.dangerous)
                CheckboxListTile(
                  key: const Key('power-confirm-ack'),
                  contentPadding: EdgeInsets.zero,
                  value: _ack,
                  onChanged: (v) => setState(() => _ack = v ?? false),
                  title: const Text(
                    'Я сохранил работу на этом компьютере и понимаю последствия',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('power-confirm-go'),
          style: widget.dangerous
              ? FilledButton.styleFrom(backgroundColor: AerColors.terracotta)
              : null,
          onPressed: !widget.dangerous || _ack
              ? () => Navigator.pop(context, true)
              : null,
          child: Text(widget.action.label),
        ),
      ],
    );
  }
}

/// The running (or just finished) job of a device.
class PowerJobProgress extends StatelessWidget {
  const PowerJobProgress({super.key, required this.power, required this.job});
  final PowerController power;
  final PowerJob job;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = jobColor(job.state);
    return Container(
      key: Key('power-job-${job.entityId}'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(actionIcon(job.action), size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${job.title}: ${job.state.label}',
                  key: Key('power-job-state-${job.entityId}'),
                  style: text.labelLarge,
                ),
              ),
              if (job.state == JobState.queued)
                TextButton(
                  key: Key('power-job-cancel-${job.entityId}'),
                  onPressed: power.canAct ? () => power.cancel(job) : null,
                  child: const Text('Отменить'),
                ),
            ],
          ),
          if (!job.state.terminal) ...[
            const SizedBox(height: 4),
            const LinearProgressIndicator(minHeight: 3),
          ],
          if (job.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(job.message, style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}

Color jobColor(JobState s) => switch (s) {
  JobState.succeeded => AerColors.sage,
  JobState.failed || JobState.rejected => AerColors.terracotta,
  JobState.timeout || JobState.simulated => AerColors.amber,
  JobState.cancelled => AerColors.inkMuted,
  _ => AerColors.blue,
};

Future<void> showWoLDialog(
  BuildContext context,
  PowerController p,
  PowerDevice d,
) async {
  final messenger = ScaffoldMessenger.of(context);
  PowerNet? net;
  try {
    net = await p.interfaces();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _WoLDialog(power: p, device: d, net: net!),
  );
}

class _WoLDialog extends StatefulWidget {
  const _WoLDialog({
    required this.power,
    required this.device,
    required this.net,
  });
  final PowerController power;
  final PowerDevice device;
  final PowerNet net;

  @override
  State<_WoLDialog> createState() => _WoLDialogState();
}

class _WoLDialogState extends State<_WoLDialog> {
  late final TextEditingController _mac;
  late final TextEditingController _dst;
  late String _iface;
  Map<String, String> _errors = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final w = widget.device.wol;
    _mac = TextEditingController(text: w?.mac ?? '');
    _dst = TextEditingController(text: w?.broadcast ?? '255.255.255.255');
    _iface = w?.interface ?? '';
  }

  @override
  void dispose() {
    _mac.dispose();
    _dst.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.power.setWoL(
        widget.device.entityId,
        WoLTarget(
          mac: _mac.text.trim(),
          broadcast: _dst.text.trim(),
          interface: _iface,
        ),
      );
      if (mounted) Navigator.pop(context);
    } on CoreApiException catch (e) {
      setState(
        () => _errors = e.isValidation ? e.fieldErrors : {'mac': e.message},
      );
    } catch (e) {
      setState(() => _errors = {'mac': describeError(e)});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ifs = widget.net.interfaces.where(
      (i) => i.up && !i.loopback && i.addresses.isNotEmpty,
    );
    return AlertDialog(
      key: const Key('power-wol-dialog'),
      title: Text('Wake-on-LAN: ${widget.device.name}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.net.wolEnabled)
              const _Note(
                key: Key('power-wol-disabled'),
                icon: Icons.block_rounded,
                text:
                    'Отправка Wake-on-LAN выключена в конфигурации Core (power.wol.enabled). Настройки сохранятся, '
                    'но включить компьютер нельзя, пока владелец не разрешит отправку.',
              ),
            if (widget.device.sameMachine)
              _Note(
                icon: Icons.info_outline_rounded,
                text: widget.device.sameMachineNote,
              ),
            TextField(
              key: const Key('power-wol-mac'),
              controller: _mac,
              decoration: InputDecoration(
                labelText: 'MAC-адрес сетевой карты компьютера',
                hintText: '00:11:22:33:44:55',
                errorText: _errors['mac'],
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: const Key('power-wol-iface'),
              initialValue: ifs.any((i) => i.name == _iface) ? _iface : '',
              decoration: const InputDecoration(
                labelText: 'Интерфейс Core для отправки',
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Выбирает система'),
                ),
                for (final i in ifs)
                  DropdownMenuItem(
                    value: i.name,
                    child: Text('${i.name} · ${i.addresses.join(', ')}'),
                  ),
              ],
              onChanged: (v) => setState(() {
                _iface = v ?? '';
                final i = ifs.where((x) => x.name == _iface).firstOrNull;
                if (i != null && i.broadcasts.isNotEmpty) {
                  _dst.text = i.broadcasts.first;
                }
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('power-wol-dst'),
              controller: _dst,
              decoration: InputDecoration(
                labelText: 'Адрес назначения (широковещательный адрес сети)',
                errorText: _errors['broadcast'] ?? _errors['interface'],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Пакет отправляет Core по UDP (порт ${widget.net.defaultPort}) только в домашнюю сеть. '
              'Wake-on-LAN должен быть разрешён в UEFI и в драйвере сетевой карты обеих ОС — AER HOME эти настройки не меняет.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        if (widget.device.wol != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await widget.power.deleteWoL(widget.device.entityId);
                    if (context.mounted) Navigator.pop(context);
                  },
            child: const Text('Удалить'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('power-wol-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

Future<void> showPowerPolicyDialog(
  BuildContext context,
  PowerController p,
  PowerDevice d,
) async {
  var pol = d.policy;
  final saved = await showDialog<PowerPolicy>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, set) {
        SwitchListTile row(
          String key,
          String title,
          bool v,
          PowerPolicy Function(bool) f, [
          String? sub,
        ]) => SwitchListTile(
          key: Key('power-policy-$key'),
          dense: true,
          value: v,
          onChanged: (x) => set(() => pol = f(x)),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub),
        );
        return AlertDialog(
          key: const Key('power-policy-dialog'),
          title: Text('Политика питания: ${d.name}'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  'enabled',
                  'Управление питанием разрешено',
                  pol.enabled,
                  (x) => pol.copyWith(enabled: x),
                  'Выключение отменяет команды, которые ещё не переданы',
                ),
                row(
                  'wake',
                  'Включение по сети',
                  pol.wake,
                  (x) => pol.copyWith(wake: x),
                ),
                row(
                  'shutdown',
                  'Выключение',
                  pol.shutdown,
                  (x) => pol.copyWith(shutdown: x),
                ),
                row(
                  'reboot',
                  'Перезагрузка',
                  pol.reboot,
                  (x) => pol.copyWith(reboot: x),
                ),
                row(
                  'suspend',
                  'Сон',
                  pol.suspend,
                  (x) => pol.copyWith(suspend: x),
                ),
                row(
                  'switchOs',
                  'Смена ОС (одноразовая загрузка)',
                  pol.switchOs,
                  (x) => pol.copyWith(switchOs: x),
                  'Выключено по умолчанию',
                ),
                row(
                  'bitlocker',
                  'Разрешить смену ОС при включённом BitLocker',
                  pol.allowWithBitLocker,
                  (x) => pol.copyWith(allowWithBitLocker: x),
                  'Только если ключ восстановления под рукой',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('power-policy-save'),
              onPressed: () => Navigator.pop(context, pol),
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    ),
  );
  if (saved == null) return;
  try {
    await p.setPolicy(d.entityId, saved);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }
}

Future<void> showDeviceHistory(
  BuildContext context,
  PowerController p,
  PowerDevice d,
) {
  final jobs = p.history.where((j) => j.entityId == d.entityId).toList();
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('power-device-history'),
      title: Text('История операций: ${d.name}'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: jobs.isEmpty
            ? const Center(child: Text('Операций ещё не было'))
            : ListView(
                children: [
                  for (final j in jobs) PowerJobTile(power: p, job: j),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

class PowerHistory extends StatelessWidget {
  const PowerHistory({super.key, required this.p});
  final PowerController p;

  @override
  Widget build(BuildContext context) {
    if (p.history.isEmpty) {
      return const Center(child: Text('Операций ещё не было'));
    }
    return ListView(
      key: const Key('power-history'),
      padding: const EdgeInsets.all(AerSpacing.m),
      children: [for (final j in p.history) PowerJobTile(power: p, job: j)],
    );
  }
}

class PowerJobTile extends StatelessWidget {
  const PowerJobTile({super.key, required this.power, required this.job});
  final PowerController power;
  final PowerJob job;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        actionIcon(job.action),
        size: 18,
        color: jobColor(job.state),
      ),
      title: Text('${job.deviceName} · ${job.title} · ${job.state.label}'),
      subtitle: Text(
        '${dateTime(job.requestedAt)}${job.message.isEmpty ? '' : ' · ${job.message}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _showJob(context),
    );
  }

  Future<void> _showJob(BuildContext context) async {
    PowerJob full = job;
    try {
      full = await power.job(job.id);
    } catch (_) {}
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('power-job-dialog'),
        title: Text('${full.deviceName}: ${full.title}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                full.state.label,
                style: TextStyle(color: jobColor(full.state)),
              ),
              if (full.message.isNotEmpty) Text(full.message),
              const Divider(),
              for (final e in full.events)
                Text(
                  '${clock(e.at)} · ${e.kind} · ${e.message}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}

/// The power part of the house quick card (shown for bound computers):
/// state, the running job and only the actions that are available now.
class PowerScenePanel extends StatelessWidget {
  const PowerScenePanel({
    super.key,
    required this.power,
    required this.device,
    required this.onOpen,
    this.onOpenRemote,
  });
  final PowerController power;
  final PowerDevice device;
  final VoidCallback onOpen;
  final VoidCallback? onOpenRemote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = device;
    final job = power.followed(d.entityId) ?? d.activeJob;
    final quick = [
      for (final a in d.actions)
        if (a.available && a.action != PowerAction.check && power.canAct) a,
    ];
    return Container(
      key: const Key('scene-power-panel'),
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
              const Icon(
                Icons.power_settings_new_rounded,
                size: 16,
                color: AerColors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Питание · ${d.stateLabel}${d.currentOs.isEmpty ? '' : ' · ${osLabel(d.currentOs)}'}',
                  key: const Key('scene-power-state'),
                  style: text.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            d.stateReason,
            style: text.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (d.sameMachine)
            Text(
              'Core на этом ПК: включить его по сети нельзя',
              style: text.labelSmall?.copyWith(color: AerColors.amber),
            ),
          if (job != null &&
              (!job.state.terminal || power.followed(d.entityId) != null)) ...[
            const SizedBox(height: 6),
            PowerJobProgress(power: power, job: job),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in quick)
                OutlinedButton.icon(
                  key: Key('scene-power-${a.action.wire}'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => runPowerAction(context, power, d, a.action),
                  icon: Icon(actionIcon(a.action), size: 16),
                  label: Text(a.action.label),
                ),
              OutlinedButton(
                key: const Key('scene-power-open'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onOpen,
                child: const Text('Управление питанием'),
              ),
              if (onOpenRemote != null)
                OutlinedButton(
                  key: const Key('scene-power-remote'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onOpenRemote,
                  child: const Text('Удалённый доступ'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
