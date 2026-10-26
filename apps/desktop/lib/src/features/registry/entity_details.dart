import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core_api/registry_models.dart';
import '../../shell/status_presentation.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import 'entity_dialogs.dart';
import 'entity_visuals.dart';
import 'error_text.dart';

/// Side panel with everything Registry knows about the selected entity.
class EntityDetails extends StatelessWidget {
  const EntityDetails({super.key, required this.registry});

  final RegistryController registry;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() op,
    String done,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = registry.selected!;
    final catalog = registry.catalog!;
    final type = catalog.type(e.type);
    final text = Theme.of(context).textTheme;
    final canEdit = registry.canEdit;
    final now = DateTime.now();

    return Container(
      decoration: const BoxDecoration(
        color: AerColors.surface,
        border: Border(left: BorderSide(color: AerColors.border)),
      ),
      child: ListView(
        key: const Key('entity-details'),
        padding: const EdgeInsets.all(AerSpacing.l),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EntityIconTile(icon: e.icon, group: type?.group, size: 52),
              const SizedBox(width: AerSpacing.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(e.name, style: text.titleLarge),
                    Text(
                      catalog.typeLabel(e.type),
                      style: text.bodyMedium?.copyWith(
                        color: AerColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Закрыть',
                onPressed: registry.clearSelection,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (e.archived) ...[
            const SizedBox(height: AerSpacing.s),
            _Notice(
              icon: Icons.inventory_2_outlined,
              text:
                  'В архиве с ${formatAge(e.archivedAt, now)}. '
                  'Изменения недоступны, пока объект не восстановлен.',
            ),
          ],
          const SizedBox(height: AerSpacing.m),
          Wrap(
            spacing: AerSpacing.s,
            runSpacing: AerSpacing.s,
            children: [
              if (!e.archived) ...[
                OutlinedButton.icon(
                  key: const Key('action-edit'),
                  onPressed: canEdit
                      ? () => showEditEntityDialog(context, registry, e)
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Изменить'),
                ),
                OutlinedButton.icon(
                  key: const Key('action-archive'),
                  onPressed: canEdit
                      ? () async {
                          if (await confirmArchive(context, e) &&
                              context.mounted) {
                            await _run(
                              context,
                              () => registry.archive(e),
                              '«${e.name}» перемещён в архив',
                            );
                          }
                        }
                      : null,
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: const Text('В архив'),
                ),
              ] else
                FilledButton.icon(
                  key: const Key('action-restore'),
                  onPressed: canEdit
                      ? () => _run(
                          context,
                          () => registry.restore(e),
                          '«${e.name}» восстановлен',
                        )
                      : null,
                  icon: const Icon(Icons.unarchive_outlined, size: 18),
                  label: const Text('Восстановить'),
                ),
            ],
          ),
          if (!canEdit && !e.archived)
            Padding(
              padding: const EdgeInsets.only(top: AerSpacing.s),
              child: Text(
                'Изменения недоступны: нет связи с AER Core.',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ),
          _Section(
            title: 'Сведения',
            children: [
              if (e.description.isNotEmpty) _Line('Описание', e.description),
              _Line('Адрес', e.address ?? '—', mono: e.address != null),
              _Line(
                'Находится внутри',
                e.parentId == null
                    ? '—'
                    : registry.selectedParent?.name ?? 'загрузка…',
              ),
              _Line('Теги', e.tags.isEmpty ? '—' : e.tags.join(', ')),
              const _Line(
                'Состояние',
                'не отслеживается — появится с модулем Monitoring',
              ),
            ],
          ),
          _Section(
            title: 'Возможности',
            trailing: e.archived
                ? null
                : TextButton(
                    key: const Key('action-capabilities'),
                    onPressed: canEdit
                        ? () => showCapabilitiesDialog(context, registry, e)
                        : null,
                    child: const Text('Изменить'),
                  ),
            children: [
              if (e.capabilities.isEmpty)
                Text('Не заданы', style: text.bodyMedium)
              else
                Wrap(
                  spacing: AerSpacing.xs,
                  runSpacing: AerSpacing.xs,
                  children: [
                    for (final c in e.capabilities)
                      Tooltip(
                        message: catalog.capability(c)?.description ?? c,
                        child: Chip(
                          avatar: const Icon(Icons.bolt_outlined, size: 16),
                          label: Text(catalog.capabilityLabel(c)),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: AerColors.background,
                          side: const BorderSide(color: AerColors.border),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: AerSpacing.xs),
              Text(
                'Описание того, что объект умеет; выполнение — в других модулях.',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
          _Section(
            title: 'Связи',
            trailing: e.archived
                ? null
                : TextButton(
                    key: const Key('action-add-relation'),
                    onPressed: canEdit
                        ? () => showAddRelationDialog(context, registry, e)
                        : null,
                    child: const Text('Добавить'),
                  ),
            children: [
              if (registry.relationsLoading) const LinearProgressIndicator(),
              if (registry.relationsError != null)
                Text(describeError(registry.relationsError!))
              else if (registry.relations.isEmpty && !registry.relationsLoading)
                Text('Связей нет', style: text.bodyMedium)
              else
                for (final r in registry.relations)
                  _RelationTile(
                    view: r,
                    selfName: e.name,
                    catalog: catalog,
                    onDelete: canEdit
                        ? () => _run(
                            context,
                            () => registry.deleteRelation(r.relation.id),
                            'Связь удалена',
                          )
                        : null,
                  ),
            ],
          ),
          if (e.secretRefs.isNotEmpty)
            _Section(
              title: 'Ссылки на секреты',
              children: [
                for (final s in e.secretRefs) _Line(s.name, s.ref, mono: true),
                Text(
                  'Хранятся только ссылки; сами секреты — в окружении или хранилище ОС.',
                  style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
                ),
              ],
            ),
          if (e.attributes.isNotEmpty)
            _Section(
              title: 'Дополнительные параметры',
              children: [
                for (final a in e.attributes.entries)
                  _Line(
                    a.key,
                    a.value is String ? a.value as String : jsonEncode(a.value),
                    mono: true,
                  ),
              ],
            ),
          _Section(
            title: 'Служебное',
            children: [
              _Line('UUID', e.id, mono: true),
              _Line('Версия записи', '${e.revision}'),
              _Line('Обнаружение', discoveryLabels[e.discovery] ?? e.discovery),
              _Line('Создан', formatAge(e.createdAt, now)),
              _Line('Изменён', formatAge(e.updatedAt, now)),
            ],
          ),
        ],
      ),
    );
  }
}

class _RelationTile extends StatelessWidget {
  const _RelationTile({
    required this.view,
    required this.selfName,
    required this.catalog,
    required this.onDelete,
  });

  final RelationView view;
  final String selfName;
  final RegistryCatalog catalog;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final kind = catalog.relationLabel(view.relation.kind);
    final label = view.relation.label.isEmpty
        ? kind
        : '${view.relation.label} ($kind)';
    final sentence = view.outgoing
        ? '$label → ${view.peer.name}'
        : '${view.peer.name} → $label';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            view.outgoing ? Icons.north_east_rounded : Icons.south_west_rounded,
            size: 16,
            color: AerColors.inkMuted,
            semanticLabel: view.outgoing ? 'исходящая' : 'входящая',
          ),
          const SizedBox(width: AerSpacing.s),
          Expanded(
            child: Text(
              sentence + (view.peer.archived ? ' (в архиве)' : ''),
              style: text.bodyMedium,
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Удалить связь',
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
              icon: const Icon(Icons.link_off, size: 18),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AerSpacing.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?trailing,
            ],
          ),
          const Divider(),
          ...children,
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? text.bodyMedium?.copyWith(fontFamily: 'monospace')
                  : text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AerSpacing.s),
    decoration: BoxDecoration(
      color: AerColors.amber.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(AerRadii.small),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AerColors.ink),
        const SizedBox(width: AerSpacing.s),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
