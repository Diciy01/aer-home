import 'dart:async';

import 'package:aer_remote/aer_remote.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_api/remote_api.dart';
import '../../state/gateway_remote_controller.dart';
import '../../state/remote_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';
import 'remote_view.dart' show RemoteDesktopScreen, RemoteFilesPanel;

/// «Клиенты»: remote access clients the owner allows (M14.5) — AER Connect
/// at work or this app outside the home. Core is the only source of truth;
/// pairing codes are shown once and never stored.
class RemoteClientsTab extends StatelessWidget {
  const RemoteClientsTab({super.key, required this.r});
  final RemoteController r;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final gi = r.gatewayInfo;
    return ListView(
      padding: const EdgeInsets.all(AerSpacing.l),
      children: [
        Card(
          key: const Key('remote-gateway-info'),
          child: ListTile(
            leading: Icon(
              gi?.online ?? false
                  ? Icons.verified_user_outlined
                  : Icons.shield_outlined,
              color: gi?.online ?? false ? AerColors.sage : AerColors.inkMuted,
            ),
            title: Text(
              gi == null
                  ? 'Remote Gateway ещё не сообщал о себе'
                  : 'Remote Gateway ${gi.online ? 'на связи' : 'не отвечает с ${clock(gi.seenAt)}'}',
            ),
            subtitle: gi == null
                ? const Text(
                    'Клиенты подключаются через Gateway на домашнем сервере (docs/REMOTE_GATEWAY.md)',
                  )
                : SelectableText(
                    'Отпечаток сертификата (SHA-256) — сверьте при сопряжении:\n${gi.certSha256}',
                    key: const Key('remote-gateway-fingerprint'),
                    style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
          ),
        ),
        const SizedBox(height: AerSpacing.m),
        Row(
          children: [
            Text('Клиенты удалённого доступа', style: text.titleMedium),
            const Spacer(),
            FilledButton.icon(
              key: const Key('remote-client-new'),
              onPressed: r.canAct ? () => _newClient(context) : null,
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: const Text('Новый клиент'),
            ),
          ],
        ),
        const SizedBox(height: AerSpacing.s),
        if (r.clients.isEmpty)
          Text(
            'Клиентов нет. Клиент — отдельное устройство со своей учётной записью, '
            'доступом только к выбранным компьютерам и мгновенным отзывом.',
            style: text.bodySmall,
          ),
        for (final c in r.clients) _ClientCard(r: r, c: c),
      ],
    );
  }

  Future<void> _newClient(BuildContext context) async {
    final input = await showDialog<_ClientInput>(
      context: context,
      builder: (_) => _ClientDialog(hosts: r.hosts),
    );
    if (input == null || !context.mounted) return;
    try {
      final p = await r.createClient(
        name: input.name,
        hosts: input.hosts,
        clipboard: input.clipboard,
        files: input.files,
      );
      if (context.mounted) await showPairingCode(context, r, p);
    } catch (e) {
      if (context.mounted) _snack(context, describeError(e));
    }
  }
}

void _snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

/// Shows the one-time code once (with the Gateway fingerprint to compare).
Future<void> showPairingCode(
  BuildContext context,
  RemoteController r,
  RemotePairingCode p,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    key: const Key('remote-pairing-dialog'),
    title: Text('Код сопряжения для «${p.client.name}»'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            p.code,
            key: const Key('remote-pairing-code'),
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontFamily: 'monospace', letterSpacing: 2),
          ),
          const SizedBox(height: 8),
          Text(
            'Одноразовый, действует до ${clock(p.expiresAt)}. Код показывается один раз и нигде не сохраняется. '
            'Введите его на новом устройстве вместе с адресом сервера.',
          ),
          if (r.gatewayInfo case final gi?) ...[
            const SizedBox(height: 8),
            Text(
              'Перед вводом кода устройство покажет отпечаток сервера — он должен совпасть:',
            ),
            SelectableText(
              gi.certSha256,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Clipboard.setData(ClipboardData(text: p.code)),
        child: const Text('Скопировать код'),
      ),
      FilledButton(
        key: const Key('remote-pairing-done'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Готово'),
      ),
    ],
  ),
);

class _ClientInput {
  _ClientInput(this.name, this.hosts, this.clipboard, this.files);
  final String name;
  final List<String> hosts;
  final bool clipboard;
  final bool files;
}

class _ClientDialog extends StatefulWidget {
  const _ClientDialog({required this.hosts, this.initial});
  final List<RemoteHost> hosts;
  final RemoteClientInfo? initial;

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final Set<String> _hosts = {...?widget.initial?.hosts};
  late bool _clipboard = widget.initial?.clipboard ?? true;
  late bool _files = widget.initial?.files ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _name.text.trim().isNotEmpty && _hosts.isNotEmpty;
    return AlertDialog(
      key: const Key('remote-client-dialog'),
      title: Text(
        widget.initial == null
            ? 'Новый клиент удалённого доступа'
            : 'Права клиента',
      ),
      content: SizedBox(
        width: 460,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextField(
              key: const Key('remote-client-name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Имя (например, «Рабочий ноутбук»)',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            const Text('Компьютеры, к которым клиент может подключаться:'),
            for (final h in widget.hosts)
              CheckboxListTile(
                key: Key('remote-client-host-${h.entityId}'),
                contentPadding: EdgeInsets.zero,
                value: _hosts.contains(h.entityId),
                onChanged: (v) => setState(
                  () => v! ? _hosts.add(h.entityId) : _hosts.remove(h.entityId),
                ),
                title: Text(h.name),
              ),
            if (widget.hosts.isEmpty)
              const Text('Нет компьютеров с удалённым доступом'),
            SwitchListTile(
              key: const Key('remote-client-clipboard'),
              contentPadding: EdgeInsets.zero,
              value: _clipboard,
              onChanged: (v) => setState(() => _clipboard = v),
              title: const Text('Буфер обмена (текст)'),
            ),
            SwitchListTile(
              key: const Key('remote-client-files'),
              contentPadding: EdgeInsets.zero,
              value: _files,
              onChanged: (v) => setState(() => _files = v),
              title: const Text('Передача файлов'),
            ),
            Text(
              'Итоговые права сеанса — пересечение прав клиента, политики компьютера и того, что разрешает сам компьютер.',
              style: Theme.of(context).textTheme.bodySmall,
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
          key: const Key('remote-client-save'),
          onPressed: ok
              ? () => Navigator.pop(
                  context,
                  _ClientInput(
                    _name.text.trim(),
                    _hosts.toList(),
                    _clipboard,
                    _files,
                  ),
                )
              : null,
          child: Text(
            widget.initial == null ? 'Создать и получить код' : 'Сохранить',
          ),
        ),
      ],
    );
  }
}

class _ClientCard extends StatelessWidget {
  const _ClientCard({required this.r, required this.c});
  final RemoteController r;
  final RemoteClientInfo c;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final names = [
      for (final id in c.hosts) r.hostFor(id)?.name ?? 'удалённый компьютер',
    ];
    final (label, color) = c.revoked
        ? ('Отозван ${clock(c.revokedAt!)}', AerColors.terracotta)
        : c.paired
        ? (
            'Сопряжён${c.deviceName.isEmpty ? '' : ' — ${c.deviceName}'}',
            AerColors.sage,
          )
        : c.pairPending
        ? ('Ждёт сопряжения', AerColors.amber)
        : ('Код истёк — выдайте новый', AerColors.inkMuted);
    return Card(
      key: Key('remote-client-${c.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(c.name, style: text.titleSmall)),
                Text(
                  label,
                  key: Key('remote-client-state-${c.id}'),
                  style: text.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
            Text(
              'Компьютеры: ${names.isEmpty ? '—' : names.join(', ')} · '
              'буфер ${c.clipboard ? 'да' : 'нет'} · файлы ${c.files ? 'да' : 'нет'}'
              '${c.lastSeenAt != null ? ' · последний вход ${clock(c.lastSeenAt!)}${c.lastAddr.isEmpty ? '' : ' с ${c.lastAddr}'}' : ''}',
              style: text.bodySmall,
            ),
            if (!c.revoked)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    key: Key('remote-client-edit-${c.id}'),
                    onPressed: () => _edit(context),
                    child: const Text('Права'),
                  ),
                  TextButton(
                    key: Key('remote-client-repair-${c.id}'),
                    onPressed: () => _repair(context),
                    child: const Text('Новый код'),
                  ),
                  TextButton(
                    key: Key('remote-client-revoke-${c.id}'),
                    style: TextButton.styleFrom(
                      foregroundColor: AerColors.terracotta,
                    ),
                    onPressed: () => _revoke(context),
                    child: const Text('Отозвать доступ'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final input = await showDialog<_ClientInput>(
      context: context,
      builder: (_) => _ClientDialog(hosts: r.hosts, initial: c),
    );
    if (input == null) return;
    try {
      await r.updateClient(
        c.id,
        name: input.name,
        hosts: input.hosts,
        clipboard: input.clipboard,
        files: input.files,
      );
    } catch (e) {
      if (context.mounted) _snack(context, describeError(e));
    }
  }

  Future<void> _repair(BuildContext context) async {
    try {
      final p = await r.repairClient(c.id);
      if (context.mounted) await showPairingCode(context, r, p);
    } catch (e) {
      if (context.mounted) _snack(context, describeError(e));
    }
  }

  Future<void> _revoke(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Отозвать доступ «${c.name}»?'),
        content: const Text(
          'Учётная запись клиента перестанет приниматься сразу, его активные сеансы будут завершены. '
          'Отменить нельзя — для нового доступа создайте клиента заново.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('remote-client-revoke-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: AerColors.terracotta,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await r.revokeClient(c.id);
    } catch (e) {
      if (context.mounted) _snack(context, describeError(e));
    }
  }
}

/// «Через Gateway»: this AER HOME as a client of the owner's Gateway —
/// for use outside the home, without Core in reach.
class GatewayTab extends StatefulWidget {
  const GatewayTab({super.key, required this.r, required this.g});
  final RemoteController r;
  final GatewayRemoteController g;

  @override
  State<GatewayTab> createState() => _GatewayTabState();
}

class _GatewayTabState extends State<GatewayTab> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  String? _seen;
  bool _confirmed = false;
  bool _busy = false;
  String? _err;

  GatewayRemoteController get g => widget.g;

  @override
  void initState() {
    super.initState();
    unawaited(g.load().then((_) => g.refreshHosts()));
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await f();
    } catch (e) {
      _err = GatewayRemoteController.describe(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: g,
    builder: (context, _) => switch (g.phase) {
      GatewayPhase.ready => _paired(context),
      _ => _addServer(context),
    },
  );

  Widget _addServer(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final owner = widget.r.gatewayInfo?.certSha256;
    final matches =
        _seen != null &&
        owner != null &&
        engine.normalizeFingerprint(owner) ==
            engine.normalizeFingerprint(_seen!);
    return ListView(
      padding: const EdgeInsets.all(AerSpacing.l),
      children: [
        if (g.phase == GatewayPhase.unauthorized)
          Card(
            color: AerColors.surface,
            child: ListTile(
              leading: const Icon(
                Icons.lock_outline,
                color: AerColors.terracotta,
              ),
              title: Text(g.error ?? 'Доступ этого устройства отозван'),
              trailing: TextButton(
                key: const Key('gw-forget'),
                onPressed: () => _run(g.forget),
                child: const Text('Удалить и сопрячь заново'),
              ),
            ),
          ),
        Text('Подключение через собственный Gateway', style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Для работы вне дома. Адрес — IP, имя DDNS или свой домен вашего домашнего сервера. '
          'Код сопряжения выдаётся в разделе «Клиенты» дома.',
          style: text.bodySmall,
        ),
        const SizedBox(height: AerSpacing.m),
        TextField(
          key: const Key('gw-address'),
          controller: _address,
          enabled: _seen == null,
          decoration: const InputDecoration(
            labelText: 'Адрес сервера',
            hintText: 'home.example.net или 203.0.113.5:443',
          ),
        ),
        const SizedBox(height: 8),
        if (_seen == null)
          FilledButton(
            key: const Key('gw-probe'),
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final fp = await g.probe(_address.text);
                    setState(() => _seen = fp);
                  }),
            child: const Text('Проверить сертификат'),
          )
        else ...[
          Text(
            'Сервер представил сертификат с отпечатком SHA-256:',
            style: text.bodyMedium,
          ),
          SelectableText(
            _seen!,
            key: const Key('gw-fingerprint'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            owner == null
                ? 'Сверьте его с отпечатком, который показан дома в «Удалённый доступ» → «Клиенты».'
                : matches
                ? 'Совпадает с отпечатком, который Gateway сообщил вашему Core.'
                : 'НЕ совпадает с отпечатком, известным вашему Core — не подтверждайте.',
            key: const Key('gw-fingerprint-hint'),
            style: text.bodySmall?.copyWith(
              color: owner != null && !matches ? AerColors.terracotta : null,
            ),
          ),
          CheckboxListTile(
            key: const Key('gw-confirm'),
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v!),
            title: const Text(
              'Отпечаток совпадает — закрепить этот сертификат',
            ),
          ),
          TextField(
            key: const Key('gw-code'),
            controller: _code,
            enabled: _confirmed,
            decoration: const InputDecoration(
              labelText: 'Код сопряжения (XXXX-XXXX-XXXX)',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('gw-pair'),
                onPressed: _busy || !_confirmed
                    ? null
                    : () =>
                          _run(() => g.pair(_address.text, _seen!, _code.text)),
                child: const Text('Сопрячь'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _seen = null;
                  _confirmed = false;
                }),
                child: const Text('Другой адрес'),
              ),
            ],
          ),
        ],
        if (_err != null ||
            (g.error != null && g.phase != GatewayPhase.unauthorized))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _err ?? g.error!,
              key: const Key('gw-error'),
              style: text.bodySmall?.copyWith(color: AerColors.terracotta),
            ),
          ),
      ],
    );
  }

  Widget _paired(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = g.profile!;
    final a = g.active;
    return ListView(
      padding: const EdgeInsets.all(AerSpacing.l),
      children: [
        Row(
          children: [
            const Icon(Icons.verified_user_outlined, color: AerColors.sage),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Сервер ${p.address} · клиент «${p.clientName}» · сертификат закреплён · учётка: ${g.storeDescription}',
                key: const Key('gw-profile'),
                style: text.bodyMedium,
              ),
            ),
            IconButton(
              key: const Key('gw-refresh'),
              tooltip: 'Обновить',
              onPressed: g.loading ? null : g.refreshHosts,
              icon: const Icon(Icons.refresh_rounded),
            ),
            TextButton(
              key: const Key('gw-forget'),
              onPressed: () => _run(g.forget),
              child: const Text('Удалить сервер'),
            ),
          ],
        ),
        if (g.error != null)
          Text(
            g.error!,
            key: const Key('gw-error'),
            style: text.bodySmall?.copyWith(color: AerColors.terracotta),
          ),
        if (a != null) _GatewaySessionPanel(g: g, a: a),
        const SizedBox(height: AerSpacing.m),
        Wrap(
          spacing: AerSpacing.m,
          runSpacing: AerSpacing.m,
          children: [
            for (final h in g.hosts)
              SizedBox(
                width: 340,
                child: Card(
                  key: Key('gw-host-${h.entityId}'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(h.name, style: text.titleSmall),
                        Text(
                          h.canConnect
                              ? 'Готов · буфер ${h.effective.clipboard ? 'да' : 'нет'} · файлы ${h.effective.files ? 'да' : 'нет'}'
                              : h.reason,
                          style: text.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          key: Key('gw-connect-${h.entityId}'),
                          onPressed: h.canConnect && !(a?.live ?? false)
                              ? () async {
                                  await g.connect(h);
                                  if (context.mounted &&
                                      g.active?.viewer != null) {
                                    await openGatewayDesktop(context, g);
                                  }
                                }
                              : null,
                          icon: const Icon(
                            Icons.cast_connected_rounded,
                            size: 18,
                          ),
                          label: const Text('Подключиться'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (g.hosts.isEmpty && !g.loading)
          Text(
            'Нет разрешённых компьютеров (или сервер недоступен)',
            style: text.bodySmall,
          ),
      ],
    );
  }
}

class _GatewaySessionPanel extends StatelessWidget {
  const _GatewaySessionPanel({required this.g, required this.a});
  final GatewayRemoteController g;
  final GatewayActive a;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      key: const Key('gw-active'),
      color: AerColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${a.host.name}: ${a.state.label}',
              key: const Key('gw-active-state'),
              style: text.titleSmall,
            ),
            Text(
              a.message,
              key: const Key('gw-active-message'),
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (a.live && a.viewer != null)
                  FilledButton.icon(
                    key: const Key('gw-show-desktop'),
                    onPressed: () => openGatewayDesktop(context, g),
                    icon: const Icon(Icons.desktop_windows_outlined, size: 18),
                    label: const Text('Показать рабочий стол'),
                  ),
                if (a.live)
                  OutlinedButton(
                    key: const Key('gw-reconnect'),
                    onPressed: g.reconnect,
                    child: const Text('Переподключиться'),
                  ),
                if (a.live)
                  FilledButton(
                    key: const Key('gw-end'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AerColors.terracotta,
                    ),
                    onPressed: g.end,
                    child: const Text('Завершить сеанс'),
                  )
                else
                  TextButton(onPressed: g.dismiss, child: const Text('Скрыть')),
              ],
            ),
            if (a.files case final f? when a.live)
              RemoteFilesPanel(files: f, maxBytes: 0),
          ],
        ),
      ),
    );
  }
}

Future<void> openGatewayDesktop(
  BuildContext context,
  GatewayRemoteController g,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => RemoteDesktopScreen(
      listenable: g,
      title: () => g.active == null
          ? 'Удалённый рабочий стол'
          : '${g.active!.host.name} · через Gateway',
      viewer: () => g.active?.viewer,
      status: () {
        final a = g.active;
        if (a == null) return '';
        return '${a.state.label}${a.conn?.grant?.clipboard ?? false ? ' · буфер обмена' : ' · буфер выключен'}';
      },
      live: () => g.active?.live ?? false,
      message: () => g.active?.message ?? '',
      onReconnect: g.reconnect,
      onEnd: g.end,
    ),
  ),
);
