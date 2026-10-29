import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:flutter/material.dart';

import 'controller.dart';
import 'trust_dialog.dart';

/// The receiving computer's explicit allow-list. Uses the existing AER theme.
class DeviceTrustView extends StatelessWidget {
  const DeviceTrustView({super.key, required this.c, required this.run});
  final ConnectController c;
  final Future<void> Function(Future<void> Function()) run;

  Future<void> _enable(BuildContext context, bool enabled) async {
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Постоянный доступ доверенным устройствам'),
          content: const Text(
            'Разрешённые вами компьютеры смогут подключаться без подтверждения на этом экране. Пароль и ключ установки всё равно проверяются. Добавляйте только свои устройства и сверяйте их отпечаток. Временный пароль продолжит меняться; для повторных подключений задайте постоянный пароль отдельно. Индикатор сеанса и кнопка «Остановить» сохраняются.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('trust-enable-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Включить'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await run(() => c.setUnattended(enabled));
  }

  Future<void> _add(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => TrustDeviceDialog(c: c),
  );

  @override
  Widget build(BuildContext context) {
    final state = c.trust;
    final text = Theme.of(context).textTheme;
    return ExpansionTile(
      key: const Key('host-trust'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text('Доверенные устройства', style: text.titleSmall),
      subtitle: Text(
        state == null
            ? 'Параметры недоступны'
            : state.enabled
            ? 'Постоянный доступ включён'
            : 'Постоянный доступ выключен',
      ),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.identityFingerprint.isNotEmpty) ...[
              const SizedBox(height: AerSpacing.xs),
              Text('Ключ этой установки SHA-256', style: text.bodySmall),
              SelectableText(
                c.identityFingerprint,
                key: const Key('installation-fingerprint'),
                style: text.bodySmall,
              ),
            ],
            SwitchListTile(
              key: const Key('host-unattended'),
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Разрешить постоянный доступ доверенным устройствам',
              ),
              subtitle: const Text(
                'Без подтверждения только для выбранных ниже установок. Пароль остаётся обязательным.',
              ),
              value: state?.enabled ?? false,
              onChanged: state == null || c.deviceRevoked
                  ? null
                  : (v) => _enable(context, v),
            ),
            if (state == null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.trustError.isEmpty
                          ? 'Загрузка параметров доверия…'
                          : 'Параметры доверия недоступны: ${c.trustError}',
                      style: text.bodySmall,
                    ),
                  ),
                  IconButton(
                    key: const Key('trust-refresh'),
                    tooltip: 'Повторить',
                    onPressed: () => run(c.refreshTrust),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            if (state != null) ...[
              for (final peer in state.devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    peer.revoked
                        ? Icons.block_rounded
                        : Icons.verified_user_outlined,
                    color: peer.revoked ? AerColors.terracotta : AerColors.sage,
                  ),
                  title: Text(
                    '${peer.name} · ${formatDeviceNumber(peer.number)}',
                  ),
                  subtitle: Text(
                    peer.revoked
                        ? 'Доступ отозван'
                        : state.enabled
                        ? 'Доверено · без подтверждения'
                        : 'Доверено · требуется подтверждение',
                  ),
                  trailing: peer.revoked
                      ? null
                      : TextButton(
                          key: Key('trust-revoke-${peer.number}'),
                          onPressed: () async {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Отозвать доступ?'),
                                content: Text(
                                  'Сеансы ${peer.name} будут завершены. Новые подключения запрещены до повторного разрешения владельцем.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Отмена'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Отозвать доступ'),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true) {
                              await run(() => c.revokeTrust(peer.number));
                            }
                          },
                          child: const Text('Отозвать доступ'),
                        ),
                ),
              if (state.devices.isEmpty)
                Text('Доверенных устройств пока нет.', style: text.bodySmall),
              Wrap(
                spacing: AerSpacing.s,
                children: [
                  OutlinedButton.icon(
                    key: const Key('trust-add'),
                    onPressed: c.deviceRevoked ? null : () => _add(context),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Доверить устройство'),
                  ),
                  if (state.enabled)
                    TextButton(
                      key: const Key('trust-disable'),
                      onPressed: () => _enable(context, false),
                      child: const Text('Отключить постоянный доступ'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}
