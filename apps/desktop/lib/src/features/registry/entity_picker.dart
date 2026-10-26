import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/registry_models.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import 'entity_visuals.dart';
import 'error_text.dart';

/// Dialog to pick an active entity by search. Returns the chosen entity.
Future<RegistryEntity?> pickEntity(
  BuildContext context,
  RegistryController registry, {
  required String title,
  Set<String> exclude = const {},
}) => showDialog<RegistryEntity>(
  context: context,
  builder: (_) =>
      _EntityPicker(registry: registry, title: title, exclude: exclude),
);

class _EntityPicker extends StatefulWidget {
  const _EntityPicker({
    required this.registry,
    required this.title,
    required this.exclude,
  });

  final RegistryController registry;
  final String title;
  final Set<String> exclude;

  @override
  State<_EntityPicker> createState() => _EntityPickerState();
}

class _EntityPickerState extends State<_EntityPicker> {
  List<RegistryEntity> _results = const [];
  Object? _error;
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_search(''));
  }

  Future<void> _search(String text) async {
    setState(() => _loading = true);
    try {
      final r = await widget.registry.searchActive(text);
      if (!mounted) return;
      setState(() {
        _results = r.where((e) => !widget.exclude.contains(e.id)).toList();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.registry.catalog;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        height: 380,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск по названию, адресу, тегам',
              ),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(
                  const Duration(milliseconds: 250),
                  () => unawaited(_search(v)),
                );
              },
            ),
            const SizedBox(height: AerSpacing.s),
            if (_loading) const LinearProgressIndicator(),
            Expanded(
              child: _error != null
                  ? Center(child: Text(describeError(_error!)))
                  : _results.isEmpty && !_loading
                  ? const Center(child: Text('Ничего не найдено'))
                  : ListView(
                      children: [
                        for (final e in _results)
                          ListTile(
                            leading: EntityIconTile(
                              icon: e.icon,
                              group: catalog?.type(e.type)?.group,
                              size: 36,
                            ),
                            title: Text(e.name),
                            subtitle: Text(
                              catalog?.typeLabel(e.type) ?? e.type,
                            ),
                            onTap: () => Navigator.pop(context, e),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
