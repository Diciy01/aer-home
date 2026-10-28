import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core_api/remote_api.dart';
import '../../remote/files_client.dart';
import '../../remote/remote_desktop_view.dart';
import 'gateway_views.dart';

import 'package:aer_remote/aer_remote.dart' show InteractiveRemoteViewer;

import '../../state/remote_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';

/// «Удалённый доступ»: computers, their real readiness, the running
/// session and the history. The desktop opens in the built-in viewer
/// (FreeRDP 3, M14.3) or, as a fallback, in an external RDP client — the
/// UI says which.
class RemoteView extends StatefulWidget {
  const RemoteView({super.key, required this.remote, this.focusEntityId});
  final RemoteController remote;
  final String? focusEntityId;

  @override
  State<RemoteView> createState() => _RemoteViewState();
}

class _RemoteViewState extends State<RemoteView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.remote.start());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.remote,
      builder: (context, _) {
        final r = widget.remote;
        final gw = r.gateway;
        return DefaultTabController(
          length: gw == null ? 3 : 4,
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
                    Text('Удалённый доступ', style: text.headlineSmall),
                    const SizedBox(width: AerSpacing.m),
                    Flexible(child: _Freshness(r: r)),
                    const Spacer(),
                    IconButton(
                      key: const Key('remote-refresh'),
                      tooltip: 'Обновить',
                      onPressed: r.canAct && !r.loading ? r.refresh : null,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              if (r.active case final a?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AerSpacing.l,
                    AerSpacing.s,
                    AerSpacing.l,
                    0,
                  ),
                  child: ActiveSessionPanel(remote: r, active: a),
                ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: AerSpacing.m),
                tabs: [
                  Tab(key: Key('remote-tab-hosts'), text: 'Компьютеры'),
                  Tab(key: Key('remote-tab-history'), text: 'История сеансов'),
                  Tab(key: Key('remote-tab-clients'), text: 'Клиенты'),
                  if (gw != null)
                    Tab(key: Key('remote-tab-gateway'), text: 'Через Gateway'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _Hosts(r: r),
                    _History(r: r),
                    RemoteClientsTab(r: r),
                    if (gw != null) GatewayTab(r: r, g: gw),
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
  const _Freshness({required this.r});
  final RemoteController r;

  @override
  Widget build(BuildContext context) {
    final at = r.updatedAt;
    final (icon, color, label) = r.isStale
        ? (
            Icons.history_rounded,
            AerColors.amber,
            'Нет связи с Core — данные от ${at == null ? '—' : dateTime(at)} устарели, новые сеансы недоступны',
          )
        : (
            Icons.sync_rounded,
            AerColors.sage,
            at == null ? 'Загрузка…' : 'Обновлено в ${clock(at)}',
          );
    return Row(
      key: const Key('remote-freshness'),
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

class _Hosts extends StatelessWidget {
  const _Hosts({required this.r});
  final RemoteController r;

  @override
  Widget build(BuildContext context) {
    if (r.updatedAt == null) {
      if (r.error != null) return Center(child: Text(describeError(r.error!)));
      return const Center(child: CircularProgressIndicator());
    }
    if (r.hosts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AerSpacing.l),
          child: Text(
            'Нет компьютеров с возможностью «Удалённый рабочий стол». Добавьте компьютер в «Устройствах» и установите на нём агент aer-remote-host (docs/REMOTE_CONNECT.md).',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Natural-height cards: the reason text and buttons wrap without overflow.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AerSpacing.l),
      child: Wrap(
        spacing: AerSpacing.m,
        runSpacing: AerSpacing.m,
        children: [
          for (final h in r.hosts)
            SizedBox(
              width: 400,
              child: RemoteHostCard(remote: r, host: h),
            ),
        ],
      ),
    );
  }
}

String _backend(RemoteHostAgent? a) => switch (a?.backend) {
  'gnome-rdp' => 'GNOME (Wayland), RDP',
  'windows-rdp' => 'Windows, встроенный RDP',
  null => 'агент не установлен',
  final b => b,
};

/// Starts a connection after a short settings dialog (clipboard/files).
Future<void> connectWithOptions(
  BuildContext context,
  RemoteController r,
  RemoteHost h,
) async {
  var clipboard = h.effective.clipboard;
  var files = h.effective.files;
  var embedded = r.preferEmbedded && r.embeddedAvailable;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        key: const Key('remote-connect-dialog'),
        title: Text('Подключиться к «${h.name}»?'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r.embeddedAvailable)
                SwitchListTile(
                  key: const Key('remote-embedded-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: embedded,
                  onChanged: (v) => set(() => embedded = v),
                  title: const Text('Встроенный просмотр'),
                  subtitle: Text(
                    embedded
                        ? 'Рабочий стол — внутри AER HOME'
                        : 'Окно ${r.launcher.clientName} (внешний клиент RDP)',
                  ),
                ),
              Text(
                '${embedded ? 'Рабочий стол откроется во встроенном просмотре AER HOME. ' : 'Рабочий стол откроется в окне ${r.launcher.clientName} (внешний клиент RDP). '}'
                'Пароль сеанса одноразовый, сертификат компьютера проверяется.'
                '${h.agent?.approval == 'prompt' ? ' На компьютере попросят подтвердить подключение.' : ''}',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: clipboard,
                onChanged: h.effective.clipboard
                    ? (v) => set(() => clipboard = v)
                    : null,
                title: const Text('Общий буфер обмена (текст)'),
                subtitle: Text(
                  h.effective.clipboard
                      ? 'Через канал RDP'
                      : 'Запрещено политикой или хостом',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: files,
                onChanged: h.effective.files
                    ? (v) => set(() => files = v)
                    : null,
                title: const Text('Передача файлов'),
                subtitle: Text(
                  h.effective.files
                      ? 'Папка обмена на компьютере'
                      : 'Запрещено политикой или хостом',
                ),
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
            key: const Key('remote-connect-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подключиться'),
          ),
        ],
      ),
    ),
  );
  if (go != true) return;
  r.preferEmbedded = embedded;
  await r.connect(h, clipboard: clipboard, files: files);
  if (context.mounted && r.active?.viewer != null) {
    await openRemoteDesktop(context, r);
  }
}

/// Shows the running session's desktop (built-in viewer) full-window.
/// Going back keeps the session; «Завершить» ends it.
Future<void> openRemoteDesktop(BuildContext context, RemoteController r) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RemoteDesktopPage(remote: r)),
    );

class RemoteDesktopPage extends StatelessWidget {
  const RemoteDesktopPage({super.key, required this.remote});
  final RemoteController remote;

  @override
  Widget build(BuildContext context) => RemoteDesktopScreen(
    listenable: remote,
    title: () => remote.active?.host.name ?? 'Удалённый рабочий стол',
    viewer: () => remote.active?.viewer,
    status: () {
      final a = remote.active;
      if (a == null) return '';
      return '${a.session?.state.label ?? ''}'
          '${a.session?.allowed.clipboard ?? false ? ' · буфер обмена' : ' · буфер выключен'}';
    },
    live: () => remote.active?.live ?? false,
    message: () => remote.active?.message ?? '',
    onReconnect: remote.reconnect,
    onEnd: remote.end,
  );
}

/// Full-window remote desktop for any route (LAN direct or via Gateway).
/// Back keeps the session; «Завершить» ends it.
class RemoteDesktopScreen extends StatelessWidget {
  const RemoteDesktopScreen({
    super.key,
    required this.listenable,
    required this.title,
    required this.viewer,
    required this.status,
    required this.live,
    required this.message,
    required this.onReconnect,
    required this.onEnd,
  });

  final Listenable listenable;
  final String Function() title;
  final InteractiveRemoteViewer? Function() viewer;
  final String Function() status;
  final bool Function() live;
  final String Function() message;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onEnd;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: listenable,
    builder: (context, _) {
      final v = viewer();
      return Scaffold(
        key: const Key('remote-desktop-page'),
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(title()),
          leading: IconButton(
            tooltip: 'Свернуть (сеанс продолжается)',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(status(), key: const Key('remote-desktop-status')),
              ),
            ),
            if (live())
              IconButton(
                key: const Key('remote-desktop-reconnect'),
                tooltip: 'Переподключиться',
                onPressed: onReconnect,
                icon: const Icon(Icons.refresh_rounded),
              ),
            if (live())
              TextButton.icon(
                key: const Key('remote-desktop-end'),
                onPressed: () async {
                  await onEnd();
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.call_end_rounded),
                label: const Text('Завершить'),
              ),
          ],
        ),
        body: v == null
            ? Center(
                child: Text(
                  message().isNotEmpty ? message() : 'Сеанс не показывается',
                  key: const Key('remote-desktop-message'),
                  style: const TextStyle(color: Colors.white),
                ),
              )
            : RemoteDesktopView(key: ValueKey(v), viewer: v),
      );
    },
  );
}

class RemoteHostCard extends StatelessWidget {
  const RemoteHostCard({super.key, required this.remote, required this.host});
  final RemoteController remote;
  final RemoteHost host;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final h = host;
    final muted = text.labelSmall?.copyWith(color: AerColors.inkMuted);
    final ready =
        h.canConnect && remote.canAct && !(remote.active?.live ?? false);
    return Card(
      key: Key('remote-host-${h.entityId}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.desktop_windows_outlined,
                  color: AerColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        h.name,
                        style: text.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(_backend(h.agent), style: muted),
                    ],
                  ),
                ),
                StatusChip(h.status, stale: remote.isStale, dense: true),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (on, label) in [
                  (h.effective.desktop, 'рабочий стол'),
                  (h.effective.clipboard, 'буфер обмена'),
                  (h.effective.files, 'файлы'),
                ])
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      on ? Icons.check_rounded : Icons.block_rounded,
                      size: 14,
                      color: on ? AerColors.sage : AerColors.inkMuted,
                    ),
                    label: Text(label, style: text.labelSmall),
                  ),
                if (h.agent?.approval == 'prompt')
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('подтверждение на ПК', style: text.labelSmall),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              h.canConnect ? 'Готов к подключению' : h.reason,
              key: Key('remote-reason-${h.entityId}'),
              style: text.bodySmall?.copyWith(
                color: h.canConnect ? AerColors.sage : AerColors.ink,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              [
                'Агент: ${h.lastHelloAt == null ? 'нет' : ago(h.lastHelloAt)}',
                if (h.lastSession case final s?)
                  'последнее подключение ${dateTime(s.createdAt)}',
              ].join(' · '),
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: Key('remote-connect-${h.entityId}'),
                  onPressed: ready
                      ? () => connectWithOptions(context, remote, h)
                      : null,
                  icon: const Icon(Icons.cast_connected_rounded, size: 18),
                  label: const Text('Подключиться'),
                ),
                OutlinedButton(
                  key: Key('remote-policy-${h.entityId}'),
                  onPressed: remote.canAct
                      ? () => showPolicyDialog(context, remote, h)
                      : null,
                  child: const Text('Политика'),
                ),
                if (h.activeSession case final s?) ...[
                  IconButton(
                    tooltip: 'Отозвать текущий сеанс',
                    onPressed: remote.canAct ? () => remote.revoke(s.id) : null,
                    icon: const Icon(
                      Icons.gpp_bad_outlined,
                      color: AerColors.terracotta,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showPolicyDialog(
  BuildContext context,
  RemoteController r,
  RemoteHost h,
) async {
  var p = h.policy;
  final saved = await showDialog<RemotePolicy>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        key: const Key('remote-policy-dialog'),
        title: Text('Политика: ${h.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                key: const Key('policy-enabled'),
                value: p.enabled,
                onChanged: (v) => set(() => p = p.copyWith(enabled: v)),
                title: const Text('Удалённый доступ разрешён'),
                subtitle: const Text(
                  'Выключение сразу отзывает активный сеанс',
                ),
              ),
              SwitchListTile(
                value: p.clipboard,
                onChanged: (v) => set(() => p = p.copyWith(clipboard: v)),
                title: const Text('Буфер обмена'),
              ),
              SwitchListTile(
                key: const Key('policy-files'),
                value: p.files,
                onChanged: (v) => set(() => p = p.copyWith(files: v)),
                title: const Text('Передача файлов'),
              ),
              Row(
                children: [
                  const Text('Сеанс не дольше'),
                  const Spacer(),
                  DropdownButton<int>(
                    value: [15, 30, 60, 120, 240, 480].contains(p.maxMinutes)
                        ? p.maxMinutes
                        : 60,
                    items: [
                      for (final m in [15, 30, 60, 120, 240, 480])
                        DropdownMenuItem(
                          value: m,
                          child: Text(m < 60 ? '$m мин' : '${m ~/ 60} ч'),
                        ),
                    ],
                    onChanged: (v) => set(() => p = p.copyWith(maxMinutes: v)),
                  ),
                ],
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
            key: const Key('policy-save'),
            onPressed: () => Navigator.pop(context, p),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ),
  );
  if (saved == null) return;
  try {
    await r.setPolicy(h.entityId, saved);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }
}

/// The running local session: state, client, latency, clipboard, files.
class ActiveSessionPanel extends StatelessWidget {
  const ActiveSessionPanel({
    super.key,
    required this.remote,
    required this.active,
  });
  final RemoteController remote;
  final ActiveRemote active;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final a = active;
    final s = a.session;
    final (color, icon) = switch (a.phase) {
      RemotePhase.running => (AerColors.sage, Icons.cast_connected_rounded),
      RemotePhase.failed => (AerColors.terracotta, Icons.error_outline),
      RemotePhase.ended => (AerColors.inkMuted, Icons.check_circle_outline),
      RemotePhase.clientClosed => (
        AerColors.amber,
        Icons.desktop_access_disabled_outlined,
      ),
      _ => (AerColors.blue, Icons.hourglass_top_rounded),
    };
    final phaseLabel = switch (a.phase) {
      RemotePhase.requesting => 'Запрашиваем сеанс…',
      RemotePhase.waitingHost =>
        s?.state == RemoteState.awaitingApproval
            ? 'Ждём подтверждения на компьютере…'
            : 'Компьютер готовит сеанс…',
      RemotePhase.launching => 'Открываем ${remote.viewerNameFor(a)}…',
      RemotePhase.running => s?.state.label ?? 'Подключено',
      RemotePhase.clientClosed =>
        a.viewer != null ? 'Просмотр закрыт' : 'Окно клиента закрыто',
      RemotePhase.ended => 'Сеанс завершён',
      RemotePhase.failed => 'Не удалось подключиться',
    };
    return Card(
      key: const Key('remote-active'),
      color: AerColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${a.host.name}: $phaseLabel',
                    key: const Key('remote-phase'),
                    style: text.titleSmall,
                  ),
                ),
                if (a.latency case final l?)
                  Tooltip(
                    message: 'Время TCP-соединения с портом RDP (сеть), не задержка изображения',
                    child: Text(
                      'сеть ${(l.inMicroseconds / 1000).toStringAsFixed(1)} мс',
                      style: text.labelMedium,
                    ),
                  ),
              ],
            ),
            if (a.message.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                a.message,
                key: const Key('remote-message'),
                style: text.bodySmall,
              ),
            ],
            if (s != null && a.live)
              Text(
                'Сеанс до ${clock(s.expiresAt)} · транспорт ${s.transport.toUpperCase()} напрямую с компьютером, Core видео не передаёт'
                '${s.allowed.clipboard ? ' · буфер обмена (текст) — ${a.viewer != null ? 'во встроенном просмотре' : 'в окне клиента'}' : ' · буфер обмена выключен'}',
                style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (a.viewer != null && a.phase == RemotePhase.running)
                  FilledButton.icon(
                    key: const Key('remote-show-desktop'),
                    onPressed: () => openRemoteDesktop(context, remote),
                    icon: const Icon(Icons.desktop_windows_outlined, size: 18),
                    label: const Text('Показать рабочий стол'),
                  ),
                if (a.phase == RemotePhase.clientClosed ||
                    a.phase == RemotePhase.running)
                  OutlinedButton.icon(
                    key: const Key('remote-reconnect'),
                    onPressed: remote.reconnect,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Переподключиться'),
                  ),
                if (a.live)
                  FilledButton.icon(
                    key: const Key('remote-end'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AerColors.terracotta,
                    ),
                    onPressed: remote.end,
                    icon: const Icon(Icons.call_end_rounded, size: 18),
                    label: const Text('Завершить сеанс'),
                  )
                else
                  TextButton(
                    onPressed: remote.dismiss,
                    child: const Text('Скрыть'),
                  ),
              ],
            ),
            if (a.files case final f?
                when a.live && a.phase != RemotePhase.waitingHost)
              RemoteFilesPanel(files: f, maxBytes: 0),
          ],
        ),
      ),
    );
  }
}

class RemoteFilesPanel extends StatefulWidget {
  const RemoteFilesPanel({super.key, required this.files, required this.maxBytes});
  final RemoteFilesClient files;
  final int maxBytes;

  @override
  State<RemoteFilesPanel> createState() => RemoteFilesPanelState();
}

class RemoteFilesPanelState extends State<RemoteFilesPanel> {
  List<RemoteFile> _list = const [];
  String _status = '';
  double? _progress;
  TransferCancel? _cancel;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final l = await widget.files.list();
      if (mounted) setState(() => _list = l);
    } catch (e) {
      if (mounted) setState(() => _status = 'Папка обмена недоступна: $e');
    }
  }

  Future<void> _run(
    String label,
    Future<String> Function(TransferCancel c, void Function(int, int) p) job,
  ) async {
    final c = TransferCancel();
    setState(() {
      _cancel = c;
      _progress = 0;
      _status = label;
    });
    try {
      final done = await job(c, (n, total) {
        if (mounted && total > 0) setState(() => _progress = n / total);
      });
      if (mounted) setState(() => _status = done);
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: $e');
    } finally {
      if (mounted) {
        setState(() {
          _cancel = null;
          _progress = null;
        });
      }
      await _load();
    }
  }

  Future<void> _upload() async {
    final x = await openFile();
    if (x == null) return;
    final file = File(x.path);
    final name = x.name;
    await _run('Отправляем «$name»…', (c, p) async {
      await widget.files.upload(file, name, progress: p, cancel: c);
      return '«$name» отправлен, контрольная сумма совпала';
    });
  }

  Future<void> _download(RemoteFile f) async {
    await _run('Скачиваем «${f.name}»…', (c, p) async {
      final saved = await widget.files.download(
        f.name,
        RemoteController.downloadsDir(),
        progress: p,
        cancel: c,
      );
      return 'Сохранено: ${saved.path} (SHA-256 совпала)';
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        key: const Key('remote-files'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Файлы — папка обмена на компьютере',
                style: text.labelLarge,
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('remote-upload'),
                onPressed: _cancel == null ? _upload : null,
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: const Text('Отправить файл'),
              ),
              IconButton(
                tooltip: 'Обновить',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          if (_progress != null)
            Row(
              children: [
                Expanded(child: LinearProgressIndicator(value: _progress)),
                TextButton(
                  key: const Key('remote-cancel'),
                  onPressed: _cancel?.cancel,
                  child: const Text('Отменить'),
                ),
              ],
            ),
          if (_status.isNotEmpty)
            Text(
              _status,
              key: const Key('remote-files-status'),
              style: text.bodySmall,
            ),
          for (final f in _list.take(6))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(f.name),
              subtitle: Text(
                '${fmtBytes(f.size.toDouble())} · ${dateTime(f.modified)}',
              ),
              trailing: IconButton(
                tooltip: 'Скачать',
                onPressed: _cancel == null ? () => _download(f) : null,
                icon: const Icon(Icons.download_rounded),
              ),
            ),
          if (_list.isEmpty && _status.isEmpty)
            Text(
              'Папка обмена пуста',
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
        ],
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.r});
  final RemoteController r;

  @override
  Widget build(BuildContext context) {
    if (r.history.isEmpty) {
      return const Center(child: Text('Сеансов ещё не было'));
    }
    return ListView(
      key: const Key('remote-history'),
      padding: const EdgeInsets.all(AerSpacing.m),
      children: [for (final s in r.history) RemoteSessionTile(remote: r, s: s)],
    );
  }
}

class RemoteSessionTile extends StatelessWidget {
  const RemoteSessionTile({super.key, required this.remote, required this.s});
  final RemoteController remote;
  final RemoteSession s;

  @override
  Widget build(BuildContext context) {
    final color = switch (s.state) {
      RemoteState.connected => AerColors.sage,
      RemoteState.failed || RemoteState.revoked => AerColors.terracotta,
      RemoteState.disconnected || RemoteState.expired => AerColors.inkMuted,
      _ => AerColors.blue,
    };
    final dur = s.connectedAt == null
        ? ''
        : ' · ${fmtDuration(((s.endedAt ?? DateTime.now()).difference(s.connectedAt!)).inSeconds.toDouble())}';
    return ListTile(
      dense: true,
      leading: Icon(Icons.circle, size: 12, color: color),
      title: Text('${s.hostName} · ${s.state.label}'),
      subtitle: Text(
        '${dateTime(s.createdAt)} · с «${s.sourceName.isEmpty ? '—' : s.sourceName}» · ${s.transport.toUpperCase()}$dur'
        '${s.reason.isEmpty ? '' : ' · ${s.reason}'}',
      ),
      trailing: s.state.terminal
          ? null
          : TextButton(
              onPressed: remote.canAct ? () => remote.revoke(s.id) : null,
              child: const Text('Отозвать'),
            ),
    );
  }
}

/// The remote part of the house quick card (shown for bound computers).
class RemoteScenePanel extends StatelessWidget {
  const RemoteScenePanel({
    super.key,
    required this.remote,
    required this.host,
    required this.onOpen,
  });
  final RemoteController remote;
  final RemoteHost host;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final h = host;
    final last = h.lastSession;
    return Container(
      key: const Key('scene-remote-panel'),
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
                Icons.cast_connected_rounded,
                size: 16,
                color: AerColors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Удалённый доступ · ${_backend(h.agent)}',
                  style: text.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            h.canConnect ? 'Готов к подключению' : h.reason,
            style: text.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (last != null)
            Text(
              'Последний сеанс: ${dateTime(last.createdAt)} · ${last.state.label}',
              style: text.labelSmall,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              // Only offered when the host is really ready and policy allows.
              if (h.canConnect && remote.canAct)
                FilledButton.icon(
                  key: const Key('scene-remote-connect'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => connectWithOptions(
                    context,
                    remote,
                    h,
                  ).then((_) => onOpen()),
                  icon: const Icon(Icons.cast_connected_rounded, size: 16),
                  label: const Text('Подключиться'),
                ),
              OutlinedButton(
                key: const Key('scene-remote-open'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onOpen,
                child: const Text('Открыть Remote и историю'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
