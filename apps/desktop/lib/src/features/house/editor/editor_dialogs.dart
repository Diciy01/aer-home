import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core_api/core_client.dart';
import '../../../core_api/registry_api.dart';
import '../../../core_api/registry_models.dart';
import '../../../scene/catalog/scene_catalog.dart';
import '../../../scene/editor/editor_controller.dart';
import '../../../scene/editor/placement.dart';
import '../../../scene/model/scene_document.dart';
import '../../../theme/tokens.dart';
import '../../registry/entity_visuals.dart';
import '../../registry/error_text.dart';
import '../scene_overlays.dart' show roomIcon;

enum UnsavedChoice { save, keepEditing, discard }

enum ConflictChoice { reload, saveCopy, keepEditing }

/// Leaving build mode with unsaved changes.
Future<UnsavedChoice> askUnsaved(
  BuildContext context, {
  required bool canSave,
}) async =>
    await showDialog<UnsavedChoice>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('editor-unsaved-dialog'),
        icon: const Icon(Icons.edit_note_rounded, color: AerColors.accent),
        title: const Text('Есть несохранённые изменения'),
        content: Text(
          canSave
              ? 'Сохранить планировку перед выходом из режима строительства?'
              : 'Нет связи с Core: сохранить сейчас нельзя. Изменения останутся в локальном черновике, '
                    'если продолжить редактирование.',
        ),
        actions: [
          TextButton(
            key: const Key('unsaved-discard'),
            onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
            style: TextButton.styleFrom(foregroundColor: AerColors.terracotta),
            child: const Text('Отменить изменения'),
          ),
          OutlinedButton(
            key: const Key('unsaved-keep'),
            onPressed: () => Navigator.pop(context, UnsavedChoice.keepEditing),
            child: const Text('Продолжить редактирование'),
          ),
          FilledButton(
            key: const Key('unsaved-save'),
            onPressed: canSave
                ? () => Navigator.pop(context, UnsavedChoice.save)
                : null,
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ) ??
    UnsavedChoice.keepEditing;

/// Save failed with HTTP 409: the scene changed elsewhere. Never overwrite silently.
Future<ConflictChoice> askConflict(BuildContext context) async =>
    await showDialog<ConflictChoice>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('editor-conflict-dialog'),
        icon: const Icon(Icons.call_split_rounded, color: AerColors.amber),
        title: const Text('Планировку изменили в другом месте'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'В Core уже есть более новая версия сцены. Ваши изменения не записаны поверх неё. '
            'Можно загрузить актуальную версию (ваши правки будут отброшены), сохранить ваши '
            'изменения отдельной копией дома или продолжить редактирование — черновик сохранён локально.',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('conflict-reload'),
            onPressed: () => Navigator.pop(context, ConflictChoice.reload),
            child: const Text('Загрузить актуальную'),
          ),
          OutlinedButton(
            key: const Key('conflict-copy'),
            onPressed: () => Navigator.pop(context, ConflictChoice.saveCopy),
            child: const Text('Сохранить как копию'),
          ),
          FilledButton(
            key: const Key('conflict-keep'),
            onPressed: () => Navigator.pop(context, ConflictChoice.keepEditing),
            child: const Text('Продолжить редактирование'),
          ),
        ],
      ),
    ) ??
    ConflictChoice.keepEditing;

Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String body,
  String action = 'Удалить',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('editor-delete-dialog'),
        title: Text(title),
        content: SizedBox(width: 420, child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: AerColors.terracotta,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// «Новая комната»: name, kind, start size and materials.
Future<RoomTemplate?> askNewRoom(BuildContext context, SceneCatalog catalog) =>
    showDialog<RoomTemplate>(
      context: context,
      builder: (_) => _NewRoomDialog(catalog: catalog),
    );

class _NewRoomDialog extends StatefulWidget {
  const _NewRoomDialog({required this.catalog});
  final SceneCatalog catalog;

  @override
  State<_NewRoomDialog> createState() => _NewRoomDialogState();
}

class _NewRoomDialogState extends State<_NewRoomDialog> {
  final _name = TextEditingController(text: 'Новая комната');
  String _kind = 'custom';
  Size2 _size = const Size2(8, 8);
  String _floor = 'oak';
  String _wall = 'milk';

  static const _presets = [
    ('Маленькая', Size2(6, 6)),
    ('Средняя', Size2(8, 8)),
    ('Большая', Size2(12, 8)),
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      RoomTemplate(
        name: name,
        kind: _kind,
        size: _size,
        floor: _floor,
        wall: _wall,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = widget.catalog;
    return AlertDialog(
      key: const Key('new-room-dialog'),
      title: const Text('Новая комната'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('new-room-name'),
                controller: _name,
                autofocus: true,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Название'),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AerSpacing.s),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Назначение'),
                items: [
                  for (final k in c.roomKinds)
                    DropdownMenuItem(
                      value: k.id,
                      child: Row(
                        children: [
                          Icon(
                            roomIcon(k.id),
                            size: 18,
                            color: AerColors.accent,
                          ),
                          const SizedBox(width: AerSpacing.s),
                          Text(k.label),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
              const SizedBox(height: AerSpacing.m),
              Text('Размер', style: text.titleSmall),
              const SizedBox(height: AerSpacing.xs),
              Wrap(
                spacing: AerSpacing.s,
                runSpacing: AerSpacing.xs,
                children: [
                  for (final (label, s) in _presets)
                    ChoiceChip(
                      label: Text(
                        '$label · ${metersLabel(s.w)} × ${metersLabel(s.d)}',
                      ),
                      selected: _size.w == s.w && _size.d == s.d,
                      onSelected: (_) => setState(() => _size = s),
                    ),
                ],
              ),
              const SizedBox(height: AerSpacing.s),
              Row(
                children: [
                  Expanded(
                    child: SizeStepper(
                      label: 'Ширина',
                      tiles: _size.w,
                      onChanged: (v) =>
                          setState(() => _size = Size2(v, _size.d)),
                    ),
                  ),
                  const SizedBox(width: AerSpacing.m),
                  Expanded(
                    child: SizeStepper(
                      label: 'Длина',
                      tiles: _size.d,
                      onChanged: (v) =>
                          setState(() => _size = Size2(_size.w, v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AerSpacing.m),
              Text('Пол', style: text.titleSmall),
              const SizedBox(height: AerSpacing.xs),
              MaterialSwatches(
                options: [
                  for (final f in c.floors.values) (f.id, f.label, f.color),
                ],
                selected: _floor,
                onSelected: (v) => setState(() => _floor = v),
                keyPrefix: 'new-floor',
              ),
              const SizedBox(height: AerSpacing.m),
              Text('Стены', style: text.titleSmall),
              const SizedBox(height: AerSpacing.xs),
              MaterialSwatches(
                options: [
                  for (final w in c.walls.values) (w.id, w.label, w.color),
                ],
                selected: _wall,
                onSelected: (v) => setState(() => _wall = v),
                keyPrefix: 'new-wall',
              ),
              const SizedBox(height: AerSpacing.m),
              Text(
                'После «Разместить» комната появится рядом с курсором: выберите место кликом '
                'или нажмите Enter, чтобы поставить её в предложенное место.',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          key: const Key('new-room-place'),
          onPressed: _submit,
          icon: const Icon(Icons.add_home_outlined, size: 18),
          label: const Text('Разместить'),
        ),
      ],
    );
  }
}

/// − value + stepper for room sides (1 tile = 0.5 m, step 1 tile).
class SizeStepper extends StatelessWidget {
  const SizeStepper({
    super.key,
    required this.label,
    required this.tiles,
    required this.onChanged,
    this.min = EditorLimits.minRoomSide,
    this.max = EditorLimits.maxRoomSide,
  });

  final String label;
  final double tiles;
  final ValueChanged<double> onChanged;
  final double min, max;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AerColors.background,
        borderRadius: BorderRadius.circular(AerRadii.small),
        border: Border.all(color: AerColors.border),
      ),
      child: Row(
        children: [
          IconButton(
            key: Key('$label-minus'),
            tooltip: 'Меньше',
            visualDensity: VisualDensity.compact,
            onPressed: tiles - 1 >= min ? () => onChanged(tiles - 1) : null,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
                ),
                Text(metersLabel(tiles), style: text.titleSmall),
              ],
            ),
          ),
          IconButton(
            key: Key('$label-plus'),
            tooltip: 'Больше',
            visualDensity: VisualDensity.compact,
            onPressed: tiles + 1 <= max ? () => onChanged(tiles + 1) : null,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Round colour swatches for materials (data-defined, see the catalog).
class MaterialSwatches extends StatelessWidget {
  const MaterialSwatches({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
  });

  final List<(String, String, Color)> options;
  final String? selected;
  final ValueChanged<String> onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final (id, label, color) in options)
        Tooltip(
          message: label,
          child: InkWell(
            key: Key('$keyPrefix-$id'),
            customBorder: const CircleBorder(),
            onTap: () => onSelected(id),
            child: AnimatedContainer(
              duration: AerMotion.short,
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: id == selected ? AerColors.accent : AerColors.border,
                  width: id == selected ? 3 : 1,
                ),
              ),
              child: id == selected
                  ? const Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: AerColors.ink,
                    )
                  : null,
            ),
          ),
        ),
    ],
  );
}

/// Device binding wizard: search Registry, pick, confirm. Bindings are
/// UUIDs only; nothing from Registry is copied into the scene.
Future<RegistryEntity?> pickDeviceForBinding(
  BuildContext context, {
  required RegistryApi api,
  required String objectTitle,
  String? currentEntityId,
  String Function(String type)? typeLabel,
}) => showDialog<RegistryEntity>(
  context: context,
  builder: (_) => _BindDialog(
    api: api,
    objectTitle: objectTitle,
    current: currentEntityId,
    typeLabel: typeLabel ?? (t) => t,
  ),
);

class _BindDialog extends StatefulWidget {
  const _BindDialog({
    required this.api,
    required this.objectTitle,
    required this.typeLabel,
    this.current,
  });
  final RegistryApi api;
  final String Function(String) typeLabel;
  final String objectTitle;
  final String? current;

  @override
  State<_BindDialog> createState() => _BindDialogState();
}

class _BindDialogState extends State<_BindDialog> {
  final _query = TextEditingController();
  List<RegistryEntity> _items = const [];
  RegistryEntity? _chosen;
  bool _archived = false;
  bool _loading = true;
  bool _confirming = false;
  Object? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final page = await widget.api.list(
        EntityQuery(text: _query.text, archived: _archived, limit: 50),
      );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Re-reads the entity right before binding: it may have been deleted or
  /// archived since the list was loaded.
  Future<void> _confirm() async {
    final c = _chosen;
    if (c == null) return;
    setState(() => _confirming = true);
    try {
      final fresh = await widget.api.get(c.id);
      if (mounted) Navigator.pop(context, fresh);
    } on CoreApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _chosen = null;
        _error = e.isNotFound
            ? 'Объект «${c.name}» больше не существует в Registry — выберите другой'
            : describeError(e);
      });
      unawaited(_load());
    } catch (e) {
      if (mounted) {
        setState(() {
          _confirming = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      key: const Key('bind-dialog'),
      title: Text('Привязать «${widget.objectTitle}»'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Выберите устройство из Registry. В сцене сохраняется только ссылка (UUID): '
              'название и состояние всегда берутся из Registry.',
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
            const SizedBox(height: AerSpacing.s),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('bind-search'),
                    controller: _query,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Поиск по названию, адресу, тегам',
                    ),
                    onChanged: (_) {
                      _debounce?.cancel();
                      _debounce = Timer(
                        const Duration(milliseconds: 250),
                        () => unawaited(_load()),
                      );
                    },
                  ),
                ),
                const SizedBox(width: AerSpacing.s),
                FilterChip(
                  key: const Key('bind-archived'),
                  label: const Text('Архив'),
                  selected: _archived,
                  onSelected: (v) {
                    setState(() {
                      _archived = v;
                      _chosen = null;
                    });
                    unawaited(_load());
                  },
                ),
              ],
            ),
            const SizedBox(height: AerSpacing.s),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AerSpacing.s),
                child: Text(
                  _error is String ? _error! as String : describeError(_error!),
                  style: text.bodySmall?.copyWith(color: AerColors.terracotta),
                ),
              ),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                  ? Center(
                      child: Text(
                        _archived
                            ? 'В архиве ничего не найдено'
                            : 'Ничего не найдено',
                        style: text.bodyMedium?.copyWith(
                          color: AerColors.inkMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final e = _items[i];
                        final selected = _chosen?.id == e.id;
                        return ListTile(
                          key: Key('bind-item-${e.id}'),
                          selected: selected,
                          selectedTileColor: AerColors.accentSoft.withValues(
                            alpha: 0.45,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AerRadii.small),
                          ),
                          leading: Icon(
                            entityIcon(e.type),
                            color: AerColors.accent,
                          ),
                          title: Text(
                            e.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              widget.typeLabel(e.type),
                              if (e.archived) 'в архиве',
                              if (e.id == widget.current) 'уже привязан',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? const Icon(
                                  Icons.check_circle_rounded,
                                  color: AerColors.sage,
                                )
                              : null,
                          onTap: () => setState(() => _chosen = e),
                        );
                      },
                    ),
            ),
            if (_chosen?.archived ?? false)
              Text(
                'Объект в архиве: предмет будет показан приглушённым со значком «В архиве».',
                style: text.bodySmall?.copyWith(color: AerColors.amber),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          key: const Key('bind-confirm'),
          onPressed: _chosen == null || _confirming ? null : _confirm,
          icon: const Icon(Icons.link_rounded, size: 18),
          label: Text(
            _chosen == null ? 'Привязать' : 'Привязать к «${_chosen!.name}»',
          ),
        ),
      ],
    );
  }
}
