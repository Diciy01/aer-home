import 'package:aer_widgets/aer_widgets.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/material.dart';

import 'controller.dart';
import 'device_view.dart';
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
  final _name = TextEditingController();
  String? _seen, _error;
  bool _confirmed = false, _busy = false;

  /// First run registers this computer (ADR-018); the owner's client
  /// pairing code of earlier releases stays available.
  bool _enroll = true;
  ConnectController get c => widget.c;
  @override
  void initState() {
    super.initState();
    final p = c.preset;
    if (p != null) _address.text = p.address;
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _presetAddress =>
      c.preset != null && _address.text.trim() == c.preset!.address;

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
              if (c.device != null && _busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: AerSpacing.m),
                  child: LinearProgressIndicator(),
                ),
              if (c.device != null)
                ..._device(context)
              else if (c.automaticRegistration)
                ..._automatic(context)
              else if (c.paired && !c.unauthorized)
                ..._paired(context)
              else
                ..._pairing(context),
              if (_busy || c.busy)
                const Padding(
                  padding: EdgeInsets.only(top: AerSpacing.m),
                  child: LinearProgressIndicator(),
                ),
              // Device mode shows connect errors in the «Подключиться» card.
              if (_error != null || (c.error != null && c.device == null))
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
      Text(
        _enroll
            ? 'Регистрация этого компьютера'
            : 'Подключение через собственный Gateway',
        style: text.titleMedium,
      ),
      const SizedBox(height: AerSpacing.xs),
      Text(
        _enroll
            ? 'Один раз: адрес домашнего сервера и код регистрации от его владельца. Дальше — только ID и пароль.'
            : 'Домашний сервер, ваши компьютеры. Адрес и одноразовый код выдаются в AER HOME → Удалённый доступ → Клиенты.',
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
                          final matchesPreset =
                              _presetAddress &&
                              normalizeFingerprint(fp) ==
                                  normalizeFingerprint(c.preset!.fingerprint);
                          if (_presetAddress && !matchesPreset) {
                            throw const PinMismatchException('', '');
                          }
                          if (mounted) {
                            setState(() {
                              _seen = fp;
                              _confirmed = matchesPreset;
                            });
                          }
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
                  _presetAddress
                      ? 'Совпадает с отпечатком из установщика AER Connect.'
                      : 'Сверьте с отпечатком, который владелец сервера показывает в AER HOME или командой aer-remote-gateway -fingerprint.',
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
                if (_enroll) ...[
                  TextField(
                    key: const Key('gw-name'),
                    controller: _name,
                    enabled: _confirmed && !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Имя этого компьютера',
                      hintText: 'Например, Домашний ПК',
                    ),
                  ),
                  const SizedBox(height: AerSpacing.s),
                ],
                TextField(
                  key: const Key('gw-code'),
                  controller: _code,
                  enabled: _confirmed && !_busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: _enroll
                        ? 'Код регистрации (XXXX-XXXX-XXXX)'
                        : 'Код сопряжения (XXXX-XXXX-XXXX)',
                  ),
                ),
                const SizedBox(height: AerSpacing.s),
                Wrap(
                  spacing: AerSpacing.s,
                  children: [
                    if (_enroll)
                      FilledButton(
                        key: const Key('gw-enroll'),
                        onPressed: _busy || !_confirmed
                            ? null
                            : () => _run(() async {
                                await c.enroll(
                                  _address.text,
                                  _seen!,
                                  _code.text,
                                  _name.text,
                                );
                                _code.clear();
                              }),
                        child: const Text('Зарегистрировать'),
                      )
                    else
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
                    TextButton(
                      key: const Key('gw-mode'),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _enroll = !_enroll),
                      child: Text(
                        _enroll
                            ? 'У меня код сопряжения клиента'
                            : 'Регистрация по коду',
                      ),
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

  List<Widget> _automatic(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = switch (c.registrationStatus) {
      'pending' => 'Ждём разрешения владельца сервера',
      'rejected' => 'Владелец отклонил регистрацию',
      'revoked' => 'Регистрация отозвана владельцем',
      'error' => 'Не удалось зарегистрировать компьютер',
      'removed' => 'Регистрация удалена',
      _ => 'Подключаем этот компьютер…',
    };
    return [
      Card(
        key: const Key('automatic-registration'),
        child: Padding(
          padding: const EdgeInsets.all(AerSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.computer_rounded, color: AerColors.accent),
                  const SizedBox(width: AerSpacing.s),
                  Text('Этот компьютер', style: text.titleMedium),
                ],
              ),
              const SizedBox(height: AerSpacing.m),
              Text(
                status,
                key: const Key('registration-status'),
                style: text.bodyMedium,
              ),
              const SizedBox(height: AerSpacing.s),
              Text(
                'ID и временный пароль появятся после регистрации. '
                'Адрес сервера и защита соединения уже настроены.',
                style: text.bodySmall,
              ),
              if (c.registrationStatus == 'pending') ...[
                const SizedBox(height: AerSpacing.s),
                Text(
                  'Владелец разрешает эту установку на своём сервере. '
                  'Это окно можно оставить открытым — всё продолжится автоматически.',
                  style: text.bodySmall,
                ),
              ],
              if (c.registrationFingerprint.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Сведения об устройстве'),
                  children: [
                    SelectableText(
                      c.registrationFingerprint,
                      style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ],
                ),
              if (c.registrationStatus == 'error' ||
                  c.registrationStatus == 'removed')
                TextButton.icon(
                  key: const Key('registration-retry'),
                  onPressed: c.registerAutomatically,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(
                    c.registrationStatus == 'removed'
                        ? 'Зарегистрировать компьютер'
                        : 'Повторить подключение',
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: AerSpacing.m),
      ConnectByIdCard(c: c, enabled: false, onDesktop: () async {}),
    ];
  }

  List<Widget> _device(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cards = [
      ThisComputerCard(c: c, run: _run),
      ConnectByIdCard(c: c, onDesktop: () => _desktop(this.context)),
    ];
    return [
      if (c.deviceRevoked)
        Card(
          key: const Key('device-revoked'),
          child: ListTile(
            leading: const Icon(
              Icons.lock_outline_rounded,
              color: AerColors.terracotta,
            ),
            title: const Text('Регистрация отозвана владельцем сервера'),
            subtitle: Text(
              c.preset != null
                  ? 'Этот компьютер больше не принимает и не устанавливает подключения. Новую установку должен разрешить владелец сервера.'
                  : 'Этот компьютер больше не принимает и не устанавливает подключения. Получите новый код регистрации.',
            ),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await c.forgetDevice();
                      if (c.preset != null) await c.registerAutomatically();
                    }),
              child: const Text('Зарегистрировать заново'),
            ),
          ),
        ),
      LayoutBuilder(
        builder: (context, size) {
          final wide = size.maxWidth >= 760;
          return Wrap(
            spacing: AerSpacing.m,
            runSpacing: AerSpacing.m,
            children: [
              for (final card in cards)
                SizedBox(
                  width: wide
                      ? (size.maxWidth - AerSpacing.m) / 2
                      : size.maxWidth,
                  child: card,
                ),
            ],
          );
        },
      ),
      ..._active(context),
      if (c.hosts.isNotEmpty) ..._hostsSection(context),
      const SizedBox(height: AerSpacing.l),
      Card(
        child: ListTile(
          leading: const Icon(
            Icons.verified_user_outlined,
            color: AerColors.sage,
          ),
          title: Text(c.address, style: text.titleSmall),
          subtitle: SelectableText(
            'Сертификат закреплён · ${c.fingerprint}',
            style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          trailing: TextButton(
            key: const Key('device-forget'),
            onPressed: _busy || c.busy
                ? null
                : () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Удалить регистрацию?'),
                        content: const Text(
                          'ID и учётные данные будут удалены с этого компьютера. Новая регистрация получит другой ID. Отозвать устройство на сервере может владелец.',
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
                    if (yes == true) await _run(c.forgetDevice);
                  },
            child: const Text('Удалить регистрацию'),
          ),
        ),
      ),
    ];
  }

  List<Widget> _paired(BuildContext context) => [
    _serverCard(context),
    ..._active(context),
    ..._hostsSection(context),
  ];

  Widget _serverCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AerSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user_outlined, color: AerColors.sage),
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
    );
  }

  List<Widget> _active(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
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
                  '${c.hostName}: ${sessionLine(c)}',
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
    ];
  }

  List<Widget> _hostsSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      const SizedBox(height: AerSpacing.l),
      Text(
        c.device != null
            ? 'Компьютеры, разрешённые владельцем'
            : 'Ваши компьютеры',
        style: text.titleMedium,
      ),
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
