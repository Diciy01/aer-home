import 'package:aer_widgets/aer_widgets.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/material.dart';

import 'controller.dart';
import 'files_panel.dart';

class ConnectApp extends StatelessWidget {
  const ConnectApp({super.key, required this.controller, this.desktopBuilder});
  final ConnectController controller;
  final Widget Function(InteractiveRemoteViewer)? desktopBuilder;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AER Connect',
    debugShowCheckedModeBanner: false,
    theme: buildAerTheme(),
    home: ConnectHome(c: controller, desktopBuilder: desktopBuilder),
  );
}

class ConnectHome extends StatefulWidget {
  const ConnectHome({super.key, required this.c, this.desktopBuilder});
  final ConnectController c;
  final Widget Function(InteractiveRemoteViewer)? desktopBuilder;
  @override
  State<ConnectHome> createState() => _ConnectHomeState();
}

class _ConnectHomeState extends State<ConnectHome> {
  final _address = TextEditingController(), _code = TextEditingController();
  String? _seen, _error;
  bool _confirmed = false, _busy = false;
  ConnectController get c => widget.c;
  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = ConnectController.describe(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.home_outlined, color: AerColors.accent),
            SizedBox(width: AerSpacing.s),
            Text('AER Connect'),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(AerSpacing.l),
            children: [
              if (c.paired && !c.unauthorized)
                ..._paired(context)
              else
                ..._pairing(context),
              if (_busy || c.busy)
                const Padding(
                  padding: EdgeInsets.only(top: AerSpacing.m),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null || c.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AerSpacing.m),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.error_outline_rounded,
                        color: AerColors.terracotta,
                      ),
                      title: Text(
                        _error ?? c.error!,
                        key: const Key('connect-error'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _pairing(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      if (c.unauthorized)
        Card(
          child: ListTile(
            leading: const Icon(
              Icons.lock_outline_rounded,
              color: AerColors.terracotta,
            ),
            title: const Text('Доступ отозван владельцем'),
            subtitle: const Text(
              'Чтобы подключиться снова, получите новый код в AER HOME.',
            ),
            trailing: TextButton(
              onPressed: _busy ? null : () => _run(c.forget),
              child: const Text('Удалить сервер'),
            ),
          ),
        ),
      Text('Подключение через собственный Gateway', style: text.titleMedium),
      const SizedBox(height: AerSpacing.xs),
      Text(
        'Домашний сервер, ваши компьютеры. Адрес и одноразовый код выдаются в AER HOME → Удалённый доступ → Клиенты.',
        style: text.bodySmall,
      ),
      const SizedBox(height: AerSpacing.m),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AerSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('gw-address'),
                controller: _address,
                enabled: _seen == null && !_busy,
                decoration: const InputDecoration(
                  labelText: 'Адрес сервера',
                  hintText: 'home.example.net или 203.0.113.5:443',
                ),
              ),
              const SizedBox(height: AerSpacing.s),
              if (_seen == null)
                FilledButton.icon(
                  key: const Key('gw-probe'),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final fp = await c.probe(_address.text);
                          if (mounted) setState(() => _seen = fp);
                        }),
                  icon: const Icon(Icons.shield_outlined, size: 18),
                  label: const Text('Проверить сертификат'),
                )
              else ...[
                Text('Отпечаток сертификата SHA-256', style: text.labelLarge),
                const SizedBox(height: AerSpacing.s),
                SelectableText(
                  _seen!,
                  key: const Key('gw-fingerprint'),
                  style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
                const SizedBox(height: AerSpacing.s),
                Text(
                  'Сверьте с отпечатком, показанным дома в разделе «Клиенты».',
                  style: text.bodySmall,
                ),
                CheckboxListTile(
                  key: const Key('gw-confirm'),
                  contentPadding: EdgeInsets.zero,
                  value: _confirmed,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _confirmed = v!),
                  title: const Text(
                    'Отпечаток совпадает — закрепить этот сертификат',
                  ),
                ),
                TextField(
                  key: const Key('gw-code'),
                  controller: _code,
                  enabled: _confirmed && !_busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Код сопряжения (XXXX-XXXX-XXXX)',
                  ),
                ),
                const SizedBox(height: AerSpacing.s),
                Wrap(
                  spacing: AerSpacing.s,
                  children: [
                    FilledButton(
                      key: const Key('gw-pair'),
                      onPressed: _busy || !_confirmed
                          ? null
                          : () => _run(() async {
                              await c.pair(_address.text, _seen!, _code.text);
                              _code.clear();
                            }),
                      child: const Text('Сопрячь'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _seen = null;
                              _confirmed = false;
                              _code.clear();
                            }),
                      child: const Text('Другой адрес'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _paired(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AerSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.verified_user_outlined,
                    color: AerColors.sage,
                  ),
                  const SizedBox(width: AerSpacing.s),
                  Expanded(child: Text(c.address, style: text.titleSmall)),
                  IconButton(
                    key: const Key('gw-refresh'),
                    tooltip: 'Обновить',
                    onPressed: _busy ? null : () => _run(c.refresh),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              Text(
                'Клиент «${c.clientName}» · сертификат закреплён · защищённое хранилище ОС',
                style: text.bodySmall,
              ),
              const SizedBox(height: AerSpacing.s),
              SelectableText(
                c.fingerprint,
                style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
              TextButton(
                key: const Key('gw-forget'),
                onPressed: _busy || c.busy
                    ? null
                    : () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Удалить сервер?'),
                            content: const Text(
                              'Сеанс завершится, учётные данные будут удалены с этого компьютера. Отозвать клиент можно в AER HOME.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Отмена'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Удалить'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true) await _run(c.forget);
                      },
                child: const Text('Удалить сервер'),
              ),
            ],
          ),
        ),
      ),
      if (c.hostName.isNotEmpty) ...[
        const SizedBox(height: AerSpacing.m),
        Card(
          key: const Key('gw-active'),
          child: Padding(
            padding: const EdgeInsets.all(AerSpacing.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.hostName}: ${c.state.label}',
                  key: const Key('gw-active-state'),
                  style: text.titleSmall,
                ),
                Text(c.message, style: text.bodySmall),
                const SizedBox(height: AerSpacing.s),
                Wrap(
                  spacing: AerSpacing.s,
                  runSpacing: AerSpacing.s,
                  children: [
                    if (c.viewer != null)
                      FilledButton.icon(
                        key: const Key('gw-show-desktop'),
                        onPressed: () => _desktop(context),
                        icon: const Icon(
                          Icons.desktop_windows_outlined,
                          size: 18,
                        ),
                        label: const Text('Показать рабочий стол'),
                      ),
                    if (c.live)
                      OutlinedButton(
                        key: const Key('gw-reconnect'),
                        onPressed: c.busy ? null : () => _run(c.reconnect),
                        child: const Text('Переподключиться'),
                      ),
                    if (c.live || c.busy)
                      FilledButton(
                        key: const Key('gw-end'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AerColors.terracotta,
                        ),
                        onPressed: () => _run(c.end),
                        child: const Text('Завершить сеанс'),
                      ),
                  ],
                ),
                if (c.files != null && c.live)
                  ConnectFilesPanel(
                    key: ValueKey(c.files),
                    client: c.files!,
                    maxBytes: c.connection!.grant!.filesMaxBytes,
                  ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: AerSpacing.l),
      Text('Ваши компьютеры', style: text.titleMedium),
      const SizedBox(height: AerSpacing.s),
      LayoutBuilder(
        builder: (context, size) => Wrap(
          spacing: AerSpacing.m,
          runSpacing: AerSpacing.m,
          children: [
            for (final host in c.hosts)
              SizedBox(
                width: size.maxWidth < 700
                    ? size.maxWidth
                    : (size.maxWidth - AerSpacing.m) / 2,
                child: Card(
                  key: Key('gw-host-${host.entityId}'),
                  child: Padding(
                    padding: const EdgeInsets.all(AerSpacing.m),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.computer_rounded,
                              color: host.canConnect
                                  ? AerColors.sage
                                  : AerColors.inkMuted,
                            ),
                            const SizedBox(width: AerSpacing.s),
                            Expanded(
                              child: Text(host.name, style: text.titleSmall),
                            ),
                          ],
                        ),
                        const SizedBox(height: AerSpacing.s),
                        Text(
                          host.canConnect
                              ? 'Готов · буфер ${host.effective.clipboard ? 'да' : 'нет'} · файлы ${host.effective.files ? 'да' : 'нет'}'
                              : host.reason,
                          style: text.bodySmall,
                        ),
                        const SizedBox(height: AerSpacing.s),
                        FilledButton.icon(
                          key: Key('gw-connect-${host.entityId}'),
                          onPressed: !host.canConnect || c.live || c.busy
                              ? null
                              : () async {
                                  await c.connect(host);
                                  if (mounted && c.viewer != null) {
                                    // The active-session card inserts before the
                                    // hosts and may replace this tile's context.
                                    await _desktop(this.context);
                                  }
                                },
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
      ),
      if (c.hosts.isEmpty && !c.busy)
        Text(
          'Нет разрешённых компьютеров. Проверьте права клиента в AER HOME.',
          style: text.bodySmall,
        ),
    ];
  }

  Future<void> _desktop(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(c.hostName),
            actions: [
              Center(
                child: Text(
                  c.connection?.grant?.clipboard ?? false
                      ? 'Буфер обмена'
                      : 'Буфер выключен',
                ),
              ),
              IconButton(
                tooltip: 'Переподключиться',
                onPressed: c.live && !c.busy ? c.reconnect : null,
                icon: const Icon(Icons.refresh_rounded),
              ),
              TextButton.icon(
                onPressed: () async {
                  await c.end();
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.call_end_rounded),
                label: const Text('Завершить'),
              ),
            ],
          ),
          body: c.viewer != null
              ? widget.desktopBuilder?.call(c.viewer!) ??
                    RemoteDesktopView(
                      key: ValueKey(c.viewer),
                      viewer: c.viewer!,
                    )
              : Center(
                  child: Text(
                    c.message,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
        ),
      ),
    ),
  );
}
