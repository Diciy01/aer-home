import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:flutter/material.dart';

import 'controller.dart';

class TrustDeviceDialog extends StatefulWidget {
  const TrustDeviceDialog({super.key, required this.c});
  final ConnectController c;
  @override
  State<TrustDeviceDialog> createState() => _TrustDeviceDialogState();
}

class _TrustDeviceDialogState extends State<TrustDeviceDialog> {
  final number = TextEditingController();
  TrustedDevice? candidate;
  bool confirmed = false, busy = false;
  String? problem;
  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  Future<void> lookup() async {
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      final found = await widget.c.trustCandidate(number.text);
      if (mounted) setState(() => candidate = found);
    } catch (e) {
      if (mounted) setState(() => problem = ConnectController.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> grant() async {
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      await widget.c.grantTrust(candidate!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          problem = ConnectController.describe(e);
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Доверить устройство'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('trust-number'),
              controller: number,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'ID рабочего компьютера',
              ),
              onChanged: (_) => setState(() {
                candidate = null;
                confirmed = false;
              }),
            ),
            const SizedBox(height: AerSpacing.s),
            if (candidate != null) ...[
              Text(
                '${candidate!.name} · ${formatDeviceNumber(candidate!.number)}',
              ),
              const SizedBox(height: AerSpacing.s),
              const Text('Ключ установки SHA-256'),
              SelectableText(
                candidate!.fingerprint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              CheckboxListTile(
                key: const Key('trust-key-confirm'),
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                title: const Text(
                  'Отпечаток совпадает с ключом в разделе «Этот компьютер» рабочего ПК',
                ),
                onChanged: busy
                    ? null
                    : (v) => setState(() => confirmed = v == true),
              ),
            ],
            if (problem != null)
              Text(
                problem!,
                style: const TextStyle(color: AerColors.terracotta),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      if (candidate == null)
        FilledButton(
          key: const Key('trust-lookup'),
          onPressed: busy ? null : lookup,
          child: const Text('Проверить устройство'),
        ),
      if (candidate != null)
        FilledButton(
          key: const Key('trust-grant'),
          onPressed: busy || !confirmed ? null : grant,
          child: const Text('Разрешить постоянный доступ'),
        ),
    ],
  );
}
