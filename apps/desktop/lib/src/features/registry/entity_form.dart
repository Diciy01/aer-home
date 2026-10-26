import 'package:flutter/material.dart';

import '../../core_api/registry_models.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import 'entity_picker.dart';

/// Editable values shared by the add wizard and the edit dialog.
class EntityFormData {
  EntityFormData({
    String name = '',
    String address = '',
    String description = '',
    List<String> tags = const [],
    this.parent,
    this.parentId,
  }) : name = TextEditingController(text: name),
       address = TextEditingController(text: address),
       description = TextEditingController(text: description),
       tags = TextEditingController(text: tags.join(', '));

  final TextEditingController name;
  final TextEditingController address;
  final TextEditingController description;
  final TextEditingController tags;

  /// Selected parent; [parentId] alone is used when the parent is not loaded.
  RegistryEntity? parent;
  String? parentId;

  /// Server-side (or local) per-field errors.
  Map<String, String> errors = {};

  String? get effectiveParentId => parent?.id ?? parentId;

  /// Local checks before calling Core; Core validates again.
  bool validateLocally(EntityType type) {
    errors = {};
    if (name.text.trim().isEmpty) errors['name'] = 'Укажите название';
    if (type.addressRequired && address.text.trim().isEmpty) {
      errors['address'] = 'Для этого типа нужен адрес';
    }
    return errors.isEmpty;
  }

  void dispose() {
    name.dispose();
    address.dispose();
    description.dispose();
    tags.dispose();
  }
}

/// Main fields (name, address) plus an "advanced" section.
class EntityFormFields extends StatefulWidget {
  const EntityFormFields({
    super.key,
    required this.data,
    required this.type,
    required this.registry,
    this.excludeFromParent = const {},
    this.advancedInitiallyExpanded = false,
    this.onSubmit,
  });

  final EntityFormData data;
  final EntityType type;
  final RegistryController registry;
  final Set<String> excludeFromParent;
  final bool advancedInitiallyExpanded;
  final VoidCallback? onSubmit;

  @override
  State<EntityFormFields> createState() => _EntityFormFieldsState();
}

class _EntityFormFieldsState extends State<EntityFormFields> {
  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final t = widget.type;
    final parentName =
        d.parent?.name ?? (d.parentId == null ? null : 'выбранный объект');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('field-name'),
          controller: d.name,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Название *',
            hintText: 'Например: ${_example(t.id)}',
            errorText: d.errors['name'],
          ),
        ),
        if (t.hasAddress) ...[
          const SizedBox(height: AerSpacing.m),
          TextField(
            key: const Key('field-address'),
            controller: d.address,
            onSubmitted: (_) => widget.onSubmit?.call(),
            decoration: InputDecoration(
              labelText: t.addressRequired
                  ? 'Адрес *'
                  : 'Адрес (необязательно)',
              hintText: t.addressHint,
              helperText: 'Без логина и пароля — секреты хранятся отдельно',
              errorText: d.errors['address'],
            ),
          ),
        ],
        const SizedBox(height: AerSpacing.m),
        ExpansionTile(
          key: const Key('advanced'),
          title: const Text('Расширенные настройки'),
          initiallyExpanded:
              widget.advancedInitiallyExpanded ||
              d.errors.keys.any(
                (k) => {'description', 'tags', 'parentId'}.contains(k),
              ),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: AerSpacing.s),
          shape: const Border(),
          collapsedShape: const Border(),
          children: [
            TextField(
              key: const Key('field-description'),
              controller: d.description,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Описание',
                errorText: d.errors['description'],
              ),
            ),
            const SizedBox(height: AerSpacing.m),
            TextField(
              key: const Key('field-tags'),
              controller: d.tags,
              decoration: InputDecoration(
                labelText: 'Теги',
                hintText: 'через запятую: home, media',
                errorText: d.errors['tags'],
              ),
            ),
            const SizedBox(height: AerSpacing.m),
            InputDecorator(
              decoration: InputDecoration(
                labelText: 'Находится внутри (родитель)',
                errorText: d.errors['parentId'],
                helperText: 'Например, ОС принадлежит физическому компьютеру',
              ),
              child: Row(
                children: [
                  Expanded(child: Text(parentName ?? 'не задан')),
                  TextButton(
                    onPressed: () async {
                      final picked = await pickEntity(
                        context,
                        widget.registry,
                        title: 'Родительский объект',
                        exclude: widget.excludeFromParent,
                      );
                      if (picked != null) {
                        setState(() {
                          d.parent = picked;
                          d.parentId = picked.id;
                        });
                      }
                    },
                    child: const Text('Выбрать…'),
                  ),
                  if (parentName != null)
                    IconButton(
                      tooltip: 'Убрать родителя',
                      onPressed: () => setState(() {
                        d.parent = null;
                        d.parentId = null;
                      }),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _example(String type) => switch (type) {
    'computer' => 'Основной ПК',
    'server' => 'Домашний сервер',
    'router' => 'Домашний роутер',
    'television' => 'Mini TV',
    'telegram_bot' => 'PICO',
    'docker_container' => 'n8n',
    'database' => 'PostgreSQL',
    'website' => 'Мой сайт',
    _ => 'понятное имя',
  };
}
