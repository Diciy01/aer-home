import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'device.dart';

/// «Этот компьютер»: ID, temporary password, Gateway status, incoming
/// session with Stop, permanent access and host permissions (ADR-018).
class ThisComputerCard extends StatelessWidget {
  const ThisComputerCard({super.key, required this.c, required this.run});
  final ConnectController c;
  final Future<void> Function(Future<void> Function()) run;

  static (Color, IconData) _linkStyle(HostLink l) => switch (l) {
    HostLink.online => (AerColors.sage, Icons.cloud_done_outlined),
    HostLink.connecting ||
    HostLink.starting ||
    HostLink.reconnecting => (AerColors.amber, Icons.cloud_sync_outlined),
    HostLink.revoked => (AerColors.terracotta, Icons.block_rounded),
    HostLink.stopped ||
    HostLink.unavailable => (AerColors.inkMuted, Icons.cloud_off_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = c.device!, h = c.host;
    final (color, icon) = _linkStyle(h.link);
    final mono = text.headlineSmall?.copyWith(
      fontFamily: 'monospace',
      letterSpacing: 1.5,
      color: AerColors.ink,
    );
    final session = h.session;
    return Card(
      key: const Key('this-pc'),
      child: Padding(
        padding: const EdgeInsets.all(AerSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.computer_rounded, color: AerColors.accent),
                const SizedBox(width: AerSpacing.s),
                Expanded(
                  child: Text('Этот компьютер', style: text.titleMedium),
                ),
                Icon(icon, size: 18, color: color),
                const SizedBox(width: AerSpacing.xs),
                Text(
                  h.link.label,
                  key: const Key('host-link'),
                  style: text.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
            Text(d.name, style: text.bodySmall),
            if (h.error.isNotEmpty && h.link != HostLink.online)
              Padding(
                padding: const EdgeInsets.only(top: AerSpacing.xs),
                child: Text(h.error, style: text.bodySmall),
              ),
            const SizedBox(height: AerSpacing.m),
            Text('ID', style: text.labelLarge),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    formatDeviceNumber(d.number),
                    key: const Key('host-id'),
                    style: mono,
                  ),
                ),
                IconButton(
                  tooltip: 'Скопировать ID',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: d.number)),
                  icon: const Icon(Icons.copy_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: AerSpacing.s),
            Text('Временный пароль', style: text.labelLarge),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    !d.allowIncoming
                        ? '— входящие выключены —'
                        : h.link == HostLink.unavailable ||
                              h.link == HostLink.revoked
                        ? '— недоступен —'
                        : h.tempPassword.isEmpty
                        ? '…'
                        : h.tempPassword,
                    key: const Key('host-password'),
                    style: d.allowIncoming && h.tempPassword.isNotEmpty
                        ? mono
                        : text.bodySmall,
                  ),
                ),
                IconButton(
                  key: const Key('host-copy-password'),
                  tooltip: 'Скопировать пароль',
                  onPressed: h.tempPassword.isEmpty || !d.allowIncoming
                      ? null
                      : () => Clipboard.setData(
                          ClipboardData(text: h.tempPassword),
                        ),
                  icon: const Icon(Icons.copy_rounded, size: 20),
                ),
                IconButton(
                  key: const Key('host-rotate'),
                  tooltip: 'Новый пароль',
                  onPressed: h.link == HostLink.unavailable
                      ? null
                      : c.rotatePassword,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            Text(
              'Пароль меняется после каждого сеанса. Каждое подключение нужно подтвердить на этом компьютере.',
              style: text.bodySmall,
            ),
            if (h.lockedUntil != null)
              Padding(
                padding: const EdgeInsets.only(top: AerSpacing.s),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lock_clock_outlined,
                      size: 18,
                      color: AerColors.terracotta,
                    ),
                    const SizedBox(width: AerSpacing.s),
                    Expanded(
                      child: Text(
                        'После неверных паролей вход закрыт до ${_hm(h.lockedUntil!)}',
                        style: text.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (session != null) ...[
              const SizedBox(height: AerSpacing.m),
              Container(
                key: const Key('host-session'),
                padding: const EdgeInsets.all(AerSpacing.m),
                decoration: BoxDecoration(
                  color: AerColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(AerRadii.small),
                  border: Border.all(
                    color: session.active
                        ? AerColors.terracotta
                        : AerColors.border,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          session.active
                              ? Icons.screen_share_outlined
                              : Icons.hourglass_top_rounded,
                          color: session.active
                              ? AerColors.terracotta
                              : AerColors.amber,
                        ),
                        const SizedBox(width: AerSpacing.s),
                        Expanded(
                          child: Text(
                            session.active
                                ? 'Удалённое управление'
                                : 'Входящее подключение',
                            style: text.titleSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AerSpacing.xs),
                    Text(
                      '${session.viewer} · ${session.label} · с ${_hm(session.since)}',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: AerSpacing.s),
                    FilledButton.icon(
                      key: const Key('host-stop'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AerColors.terracotta,
                      ),
                      onPressed: c.stopIncoming,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('Остановить'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AerSpacing.s),
            SwitchListTile(
              key: const Key('host-incoming'),
              contentPadding: EdgeInsets.zero,
              value: d.allowIncoming,
              onChanged: (v) => run(() => c.setIncoming(v)),
              title: const Text('Разрешить входящие подключения'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.key_rounded,
                color: d.permanent != null
                    ? AerColors.accent
                    : AerColors.inkMuted,
              ),
              title: Text(
                d.permanent != null
                    ? 'Постоянный пароль включён'
                    : 'Постоянный пароль выключен',
              ),
              subtitle: const Text(
                'Свой пароль вместо временного. Подтверждение на экране сохраняется.',
              ),
              trailing: TextButton(
                key: const Key('host-permanent'),
                onPressed: () => _permanentDialog(context),
                child: Text(d.permanent != null ? 'Изменить' : 'Включить'),
              ),
            ),
            ExpansionTile(
              key: const Key('host-options'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('Права удалённого доступа', style: text.titleSmall),
              children: [
                SwitchListTile(
                  key: const Key('host-viewonly'),
                  contentPadding: EdgeInsets.zero,
                  value: !d.viewOnly,
                  onChanged: (v) => run(() => c.setHostOptions(viewOnly: !v)),
                  title: const Text('Разрешать мышь и клавиатуру'),
                ),
                SwitchListTile(
                  key: const Key('host-clipboard'),
                  contentPadding: EdgeInsets.zero,
                  value: d.clipboard,
                  onChanged: (v) => run(() => c.setHostOptions(clipboard: v)),
                  title: const Text('Разрешать текстовый буфер обмена'),
                ),
                SwitchListTile(
                  key: const Key('host-files'),
                  contentPadding: EdgeInsets.zero,
                  value: d.files && d.filesDir.isNotEmpty,
                  onChanged: (v) => run(() async {
                    if (!v) return c.setHostOptions(files: false);
                    final dir = await getDirectoryPath(
                      confirmButtonText: 'Папка обмена',
                    );
                    if (dir != null) {
                      await c.setHostOptions(files: true, filesDir: dir);
                    }
                  }),
                  title: const Text('Разрешать файлы через папку обмена'),
                  subtitle: d.files && d.filesDir.isNotEmpty
                      ? Text(d.filesDir)
                      : null,
                ),
                SwitchListTile(
                  key: const Key('host-autostart'),
                  contentPadding: EdgeInsets.zero,
                  value: c.autostart,
                  onChanged: (v) => run(() => c.setAutostart(v)),
                  title: const Text(
                    'Запускать AER Connect при входе в Windows',
                  ),
                  subtitle: const Text(
                    'Входящие подключения работают, пока приложение открыто.',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _permanentDialog(BuildContext context) async {
    final ctrl = TextEditingController(), again = TextEditingController();
    String? problem;
    var saving = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Постоянный пароль'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Не меньше 10 символов. Пароль не хранится: на компьютере остаётся только его проверочный хэш.',
                ),
                const SizedBox(height: AerSpacing.s),
                TextField(
                  key: const Key('permanent-1'),
                  controller: ctrl,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Новый пароль'),
                ),
                const SizedBox(height: AerSpacing.s),
                TextField(
                  key: const Key('permanent-2'),
                  controller: again,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Ещё раз'),
                ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AerSpacing.s),
                    child: Text(
                      problem!,
                      key: const Key('permanent-problem'),
                      style: const TextStyle(color: AerColors.terracotta),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (c.device?.permanent != null)
              TextButton(
                key: const Key('permanent-off'),
                onPressed: saving
                    ? null
                    : () async {
                        await c.clearPermanent();
                        if (context.mounted) Navigator.pop(context);
                      },
                child: const Text('Выключить'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('permanent-save'),
              onPressed: saving
                  ? null
                  : () async {
                      if (ctrl.text != again.text) {
                        set(() => problem = 'Пароли не совпадают');
                        return;
                      }
                      set(() => saving = true);
                      final p = await c.setPermanent(ctrl.text);
                      if (!context.mounted) return;
                      if (p == null) {
                        Navigator.pop(context);
                      } else {
                        set(() {
                          problem = p;
                          saving = false;
                        });
                      }
                    },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    again.dispose();
  }
}

/// «Подключиться»: ID and password of the other computer.
class ConnectByIdCard extends StatefulWidget {
  const ConnectByIdCard({super.key, required this.c, required this.onDesktop});
  final ConnectController c;
  final Future<void> Function() onDesktop;
  @override
  State<ConnectByIdCard> createState() => _ConnectByIdCardState();
}

class _ConnectByIdCardState extends State<ConnectByIdCard> {
  final _id = TextEditingController(), _password = TextEditingController();
  ConnectController get c => widget.c;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  final _passwordFocus = FocusNode();

  Future<void> _connect() async {
    await c.connectById(_id.text, _password.text);
    if (!mounted) return;
    if (c.viewer != null) {
      _password.clear();
      await widget.onDesktop();
    } else if (c.error != null) {
      // Never resend a refused password: ask for it again.
      _password.clear();
      _passwordFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final waiting = c.busy && c.connection != null;
    return Card(
      key: const Key('connect-by-id'),
      child: Padding(
        padding: const EdgeInsets.all(AerSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.cast_connected_rounded,
                  color: AerColors.accent,
                ),
                const SizedBox(width: AerSpacing.s),
                Text('Подключиться', style: text.titleMedium),
              ],
            ),
            const SizedBox(height: AerSpacing.xs),
            Text(
              'Введите ID и пароль, которые показывает AER Connect на другом компьютере.',
              style: text.bodySmall,
            ),
            const SizedBox(height: AerSpacing.m),
            TextField(
              key: const Key('remote-id'),
              controller: _id,
              enabled: !c.busy && !c.live,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                LengthLimitingTextInputFormatter(11),
              ],
              decoration: const InputDecoration(
                labelText: 'ID удалённого компьютера',
                hintText: '123 456 789',
              ),
            ),
            const SizedBox(height: AerSpacing.s),
            TextField(
              key: const Key('remote-password'),
              controller: _password,
              focusNode: _passwordFocus,
              enabled: !c.busy && !c.live,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onSubmitted: (_) => _connect(),
              decoration: const InputDecoration(labelText: 'Пароль'),
            ),
            const SizedBox(height: AerSpacing.m),
            FilledButton.icon(
              key: const Key('remote-connect'),
              onPressed: c.busy || c.live ? null : _connect,
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('Подключиться'),
            ),
            if (c.error != null) ...[
              const SizedBox(height: AerSpacing.s),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: AerColors.terracotta,
                  ),
                  const SizedBox(width: AerSpacing.s),
                  Expanded(
                    child: Text(
                      c.error!,
                      key: const Key('connect-error'),
                      style: text.bodyMedium,
                    ),
                  ),
                ],
              ),
            ],
            if (waiting) ...[
              const SizedBox(height: AerSpacing.s),
              Text(
                c.message,
                key: const Key('remote-waiting'),
                style: text.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Labels of a remote session state for the outgoing session card.
String sessionLine(ConnectController c) =>
    c.state == RemoteState.awaitingApproval
    ? 'Ждём подтверждения на удалённом компьютере'
    : c.state.label;
