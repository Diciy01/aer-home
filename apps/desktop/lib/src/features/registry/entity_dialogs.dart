import 'package:flutter/material.dart';

import '../../core_api/core_client.dart';
import '../../core_api/registry_models.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import 'add_entity_wizard.dart' show ErrorBanner;
import 'entity_form.dart';
import 'entity_picker.dart';
import 'error_text.dart';

/// Edit dialog. Sends only changed fields with the current revision.
Future<RegistryEntity?> showEditEntityDialog(
  BuildContext context,
  RegistryController registry,
  RegistryEntity entity,
) => showDialog<RegistryEntity>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _EditEntityDialog(registry: registry, entity: entity),
);

class _EditEntityDialog extends StatefulWidget {
  const _EditEntityDialog({required this.registry, required this.entity});

  final RegistryController registry;
  final RegistryEntity entity;

  @override
  State<_EditEntityDialog> createState() => _EditEntityDialogState();
}

class _EditEntityDialogState extends State<_EditEntityDialog> {
  late RegistryEntity _entity;
  late EntityFormData _form;
  late String _typeId;
  bool _saving = false;
  String? _error;
  bool _conflict = false;

  @override
  void initState() {
    super.initState();
    _reset(widget.entity);
  }

  void _reset(RegistryEntity e) {
    _entity = e;
    _typeId = e.type;
    _form = EntityFormData(
      name: e.name,
      address: e.address ?? '',
      description: e.description,
      tags: e.tags,
      parent: widget.registry.selectedParent?.id == e.parentId
          ? widget.registry.selectedParent
          : null,
      parentId: e.parentId,
    );
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  EntityType get _type =>
      widget.registry.catalog!.type(_typeId) ??
      EntityType(
        id: _typeId,
        label: _typeId,
        description: '',
        group: 'virtual',
        icon: 'custom',
        addressMode: 'optional',
        defaultCapabilities: const [],
      );

  Map<String, Object?> _changes() {
    final e = _entity;
    final c = <String, Object?>{};
    final name = _form.name.text.trim();
    if (name != e.name) c['name'] = name;
    if (_typeId != e.type) c['type'] = _typeId;
    final address = _type.hasAddress ? _form.address.text.trim() : '';
    if (address != (e.address ?? '')) {
      c['address'] = address.isEmpty ? null : address;
    }
    final desc = _form.description.text.trim();
    if (desc != e.description) c['description'] = desc;
    final tags = parseTags(_form.tags.text)..sort();
    if (tags.join(',') != ([...e.tags]..sort()).join(',')) c['tags'] = tags;
    if (_form.effectiveParentId != e.parentId) {
      c['parentId'] = _form.effectiveParentId;
    }
    return c;
  }

  Future<void> _save() async {
    if (!_form.validateLocally(_type)) {
      setState(() {});
      return;
    }
    final changes = _changes();
    if (changes.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _conflict = false;
    });
    try {
      final saved = await widget.registry.update(_entity, changes);
      if (mounted) Navigator.pop(context, saved);
    } on CoreApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.isValidation && e.fieldErrors.isNotEmpty) {
          _form.errors = e.fieldErrors;
        } else {
          _error = describeError(e);
          _conflict = e.isConflict && e.conflictReason == 'revision_mismatch';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reload() async {
    try {
      final fresh = await widget.registry.refreshEntity(_entity.id);
      if (!mounted) return;
      setState(() {
        _form.dispose();
        _reset(fresh);
        _error = null;
        _conflict = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.registry.catalog!;
    return AlertDialog(
      title: Text('Изменить «${_entity.name}»'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: const Key('field-type'),
                initialValue: catalog.type(_typeId) == null ? null : _typeId,
                decoration: const InputDecoration(labelText: 'Тип'),
                items: [
                  for (final t in catalog.types)
                    DropdownMenuItem(value: t.id, child: Text(t.label)),
                ],
                onChanged: (v) => setState(() => _typeId = v ?? _typeId),
              ),
              const SizedBox(height: AerSpacing.m),
              EntityFormFields(
                key: ValueKey(_entity.revision),
                data: _form,
                type: _type,
                registry: widget.registry,
                excludeFromParent: {_entity.id},
                onSubmit: _save,
              ),
              if (_error != null) ...[
                const SizedBox(height: AerSpacing.m),
                ErrorBanner(
                  message: _error!,
                  action: _conflict
                      ? TextButton(
                          onPressed: _reload,
                          child: const Text('Обновить данные'),
                        )
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('edit-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Asks before archiving. Returns true when confirmed.
Future<bool> confirmArchive(BuildContext context, RegistryEntity e) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Архивировать «${e.name}»?'),
        content: const Text(
          'Объект скроется из основного списка. Данные и связи сохранятся, '
          'восстановить можно в разделе «Архив».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('confirm-archive'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Архивировать'),
          ),
        ],
      ),
    ) ??
    false;

/// Checkbox list of catalog capabilities grouped by executing module.
Future<void> showCapabilitiesDialog(
  BuildContext context,
  RegistryController registry,
  RegistryEntity entity,
) => showDialog<void>(
  context: context,
  builder: (_) => _CapabilitiesDialog(registry: registry, entity: entity),
);

class _CapabilitiesDialog extends StatefulWidget {
  const _CapabilitiesDialog({required this.registry, required this.entity});

  final RegistryController registry;
  final RegistryEntity entity;

  @override
  State<_CapabilitiesDialog> createState() => _CapabilitiesDialogState();
}

class _CapabilitiesDialogState extends State<_CapabilitiesDialog> {
  late final Set<String> _selected = {...widget.entity.capabilities};
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.registry.setCapabilities(
        widget.entity,
        _selected.toList()..sort(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.registry.catalog!;
    final byModule = <String, List<CapabilityInfo>>{};
    for (final c in catalog.capabilities) {
      byModule.putIfAbsent(c.module, () => []).add(c);
    }
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Возможности объекта'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: ListView(
          children: [
            Text(
              'Отметьте, что объект умеет. Registry только хранит описание; '
              'выполнять действия будут профильные модули после подтверждения.',
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
            for (final m in byModule.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: AerSpacing.m),
                child: Text(
                  m.key,
                  style: text.labelLarge?.copyWith(color: AerColors.inkMuted),
                ),
              ),
              for (final c in m.value)
                CheckboxListTile(
                  key: Key('cap-${c.id}'),
                  dense: true,
                  value: _selected.contains(c.id),
                  title: Text(c.label),
                  subtitle: Text(c.description),
                  onChanged: (v) => setState(
                    () => v == true
                        ? _selected.add(c.id)
                        : _selected.remove(c.id),
                  ),
                ),
            ],
            if (_error != null) ErrorBanner(message: _error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('caps-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Adds a relation from [entity] to a picked target.
Future<void> showAddRelationDialog(
  BuildContext context,
  RegistryController registry,
  RegistryEntity entity,
) => showDialog<void>(
  context: context,
  builder: (_) => _AddRelationDialog(registry: registry, entity: entity),
);

class _AddRelationDialog extends StatefulWidget {
  const _AddRelationDialog({required this.registry, required this.entity});

  final RegistryController registry;
  final RegistryEntity entity;

  @override
  State<_AddRelationDialog> createState() => _AddRelationDialogState();
}

class _AddRelationDialogState extends State<_AddRelationDialog> {
  String _kind = 'runs_on';
  RegistryEntity? _target;
  final _label = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_target == null) {
      setState(() => _error = 'Выберите объект для связи');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.registry.addRelation(
        widget.entity,
        _kind,
        _target!.id,
        label: _label.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.registry.catalog!;
    final kind = catalog.relationKind(_kind);
    return AlertDialog(
      title: Text('Связь для «${widget.entity.name}»'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: const Key('relation-kind'),
              initialValue: _kind,
              decoration: InputDecoration(
                labelText: '«${widget.entity.name}» …',
                helperText: kind?.description,
              ),
              items: [
                for (final k in catalog.relationKinds)
                  DropdownMenuItem(value: k.id, child: Text(k.label)),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: AerSpacing.m),
            InputDecorator(
              decoration: const InputDecoration(labelText: '… с объектом'),
              child: Row(
                children: [
                  Expanded(child: Text(_target?.name ?? 'не выбран')),
                  TextButton(
                    key: const Key('relation-pick'),
                    onPressed: () async {
                      final picked = await pickEntity(
                        context,
                        widget.registry,
                        title: 'Связать с…',
                        exclude: {widget.entity.id},
                      );
                      if (picked != null) setState(() => _target = picked);
                    },
                    child: const Text('Выбрать…'),
                  ),
                ],
              ),
            ),
            if (kind?.needsLabel ?? false) ...[
              const SizedBox(height: AerSpacing.m),
              TextField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Подпись связи *'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AerSpacing.m),
              ErrorBanner(message: _error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('relation-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}
