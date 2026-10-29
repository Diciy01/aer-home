import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class ConnectFilesPanel extends StatefulWidget {
  const ConnectFilesPanel({
    super.key,
    required this.client,
    required this.maxBytes,
  });
  final RemoteFilesClient client;
  final int maxBytes;
  @override
  State<ConnectFilesPanel> createState() => _FilesState();
}

class _FilesState extends State<ConnectFilesPanel> {
  List<RemoteFile> files = [];
  String message = '';
  TransferCancel? cancel;
  double? progress;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    cancel?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final result = await widget.client.list();
      if (mounted) setState(() => files = result);
    } catch (_) {
      if (mounted) setState(() => message = 'Папка обмена недоступна');
    }
  }

  Future<void> transfer(
    Future<void> Function(TransferCancel, void Function(int, int)) action,
  ) async {
    final token = TransferCancel();
    setState(() {
      cancel = token;
      progress = 0;
      message = '';
    });
    try {
      await action(token, (n, total) {
        if (mounted && total > 0) setState(() => progress = n / total);
      });
      if (mounted) setState(() => message = 'Передано · SHA-256 совпала');
    } catch (_) {
      if (mounted) {
        setState(
          () => message = token.cancelled ? 'Передача отменена' : 'Не удалось передать файл. Проверьте права, размер и соединение.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          cancel = null;
          progress = null;
        });
      }
      await refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: AerSpacing.m),
      Text(
        'Файлы · папка обмена',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      Wrap(
        spacing: AerSpacing.s,
        children: [
          TextButton.icon(
            key: const Key('remote-upload'),
            onPressed: cancel != null
                ? null
                : () async {
                    final f = await openFile();
                    if (f == null || !mounted) return;
                    if (widget.maxBytes > 0 &&
                        await f.length() > widget.maxBytes) {
                      setState(
                        () => message = 'Файл превышает разрешённый размер',
                      );
                      return;
                    }
                    await transfer(
                      (c, p) => widget.client.upload(
                        File(f.path),
                        f.name,
                        cancel: c,
                        progress: p,
                      ),
                    );
                  },
            icon: const Icon(Icons.upload_rounded, size: 18),
            label: const Text('Отправить файл'),
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: cancel == null ? refresh : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (cancel != null)
            TextButton(
              onPressed: cancel!.cancel,
              child: const Text('Отменить'),
            ),
        ],
      ),
      if (progress != null) LinearProgressIndicator(value: progress),
      if (message.isNotEmpty)
        Text(message, style: Theme.of(context).textTheme.bodySmall),
      for (final f in files)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: Text(f.name),
          subtitle: Text('${f.size} байт'),
          trailing: IconButton(
            tooltip: 'Скачать',
            icon: const Icon(Icons.download_rounded),
            onPressed: cancel != null
                ? null
                : () async {
                    final path = await getDirectoryPath(
                      confirmButtonText: 'Сохранить сюда',
                    );
                    if (path == null || !mounted) return;
                    await transfer((c, p) async {
                      await widget.client.download(
                        f.name,
                        Directory(path),
                        cancel: c,
                        progress: p,
                      );
                    });
                  },
          ),
        ),
      if (files.isEmpty)
        Text(
          'Папка обмена пуста',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );
}
