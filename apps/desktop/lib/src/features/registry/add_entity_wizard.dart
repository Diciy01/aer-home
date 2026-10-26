import 'package:flutter/material.dart';

import '../../core_api/core_client.dart';
import '../../core_api/registry_models.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import 'entity_form.dart';
import 'entity_visuals.dart';
import 'error_text.dart';

/// Opens the add wizard. Returns the created entity, or null if cancelled.
Future<RegistryEntity?> showAddEntityWizard(
  BuildContext context,
  RegistryController registry,
) => showDialog<RegistryEntity>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AddEntityWizard(registry: registry),
);

/// Three steps: 1) what, 2) name + minimal fields, 3) confirm and save.
class AddEntityWizard extends StatefulWidget {
  const AddEntityWizard({super.key, required this.registry});

  final RegistryController registry;

  @override
  State<AddEntityWizard> createState() => _AddEntityWizardState();
}

class _AddEntityWizardState extends State<AddEntityWizard> {
  static const _titles = [
    'Что добавляем?',
    'Основные сведения',
    'Подтверждение',
  ];

  int _step = 0;
  EntityType? _type;
  final _form = EntityFormData();
  bool _saving = false;
  String? _saveError;

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _chooseType(EntityType t) => setState(() {
    _type = t;
    _form.errors = {};
    if (!t.hasAddress) _form.address.clear();
    _step = 1;
  });

  void _next() {
    if (!_form.validateLocally(_type!)) {
      setState(() {});
      return;
    }
    setState(() {
      _saveError = null;
      _step = 2;
    });
  }

  EntityDraft get _draft => EntityDraft(
    name: _form.name.text.trim(),
    type: _type!.id,
    address: _type!.hasAddress ? _form.address.text.trim() : null,
    description: _form.description.text.trim(),
    tags: parseTags(_form.tags.text),
    parentId: _form.effectiveParentId,
  );

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final e = await widget.registry.create(_draft);
      if (mounted) Navigator.pop(context, e);
    } on CoreApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.isValidation && e.fieldErrors.isNotEmpty) {
          // Back to the form with messages next to the fields.
          _form.errors = e.fieldErrors;
          _step = 1;
        } else {
          _saveError = describeError(e);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _saveError = describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AerRadii.large),
      ),
      backgroundColor: AerColors.surface,
      child: SizedBox(
        width: 720,
        height: 600,
        child: Padding(
          padding: const EdgeInsets.all(AerSpacing.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Добавить объект', style: text.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: AerSpacing.s),
              _StepIndicator(step: _step, titles: _titles),
              const SizedBox(height: AerSpacing.m),
              Expanded(
                child: switch (_step) {
                  0 => _TypeStep(
                    catalog: widget.registry.catalog!,
                    selected: _type,
                    onSelect: _chooseType,
                  ),
                  1 => SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TypeBanner(type: _type!),
                        const SizedBox(height: AerSpacing.m),
                        EntityFormFields(
                          data: _form,
                          type: _type!,
                          registry: widget.registry,
                          onSubmit: _next,
                        ),
                      ],
                    ),
                  ),
                  _ => _ConfirmStep(
                    draft: _draft,
                    type: _type!,
                    catalog: widget.registry.catalog!,
                    parentName: _form.parent?.name,
                    error: _saveError,
                  ),
                },
              ),
              const SizedBox(height: AerSpacing.m),
              Row(
                children: [
                  if (_step > 0)
                    OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() => _step -= 1),
                      child: const Text('Назад'),
                    ),
                  const Spacer(),
                  if (_step == 1)
                    FilledButton(onPressed: _next, child: const Text('Далее')),
                  if (_step == 2)
                    FilledButton.icon(
                      key: const Key('wizard-save'),
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: const Text('Сохранить'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step, required this.titles});

  final int step;
  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        for (var i = 0; i < titles.length; i++) ...[
          AnimatedContainer(
            duration: AerMotion.short,
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= step ? AerColors.accent : AerColors.surfaceMuted,
            ),
            child: i < step
                ? const Icon(Icons.check, size: 16, color: AerColors.surface)
                : Text(
                    '${i + 1}',
                    style: text.labelMedium?.copyWith(
                      color: i <= step ? AerColors.surface : AerColors.inkMuted,
                    ),
                  ),
          ),
          const SizedBox(width: AerSpacing.s),
          Flexible(
            flex: 3,
            child: Text(
              titles[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelLarge?.copyWith(
                color: i == step ? AerColors.ink : AerColors.inkMuted,
                fontWeight: i == step ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (i < titles.length - 1)
            const Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: AerSpacing.s),
                child: Divider(),
              ),
            ),
        ],
      ],
    );
  }
}

class _TypeStep extends StatelessWidget {
  const _TypeStep({
    required this.catalog,
    required this.selected,
    required this.onSelect,
  });

  final RegistryCatalog catalog;
  final EntityType? selected;
  final ValueChanged<EntityType> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final groups = <String, List<EntityType>>{};
    for (final t in catalog.types) {
      groups.putIfAbsent(t.group, () => []).add(t);
    }
    return ListView(
      children: [
        for (final g in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: AerSpacing.s,
              bottom: AerSpacing.s,
            ),
            child: Text(
              groupLabels[g.key] ?? g.key,
              style: text.labelLarge?.copyWith(color: AerColors.inkMuted),
            ),
          ),
          Wrap(
            spacing: AerSpacing.s,
            runSpacing: AerSpacing.s,
            children: [
              for (final t in g.value)
                _TypeTile(
                  type: t,
                  selected: selected?.id == t.id,
                  onTap: () => onSelect(t),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final EntityType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Tooltip(
      message: type.description,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: selected ? AerColors.accentSoft : AerColors.background,
        borderRadius: BorderRadius.circular(AerRadii.medium),
        child: InkWell(
          key: Key('type-${type.id}'),
          borderRadius: BorderRadius.circular(AerRadii.medium),
          onTap: onTap,
          child: Container(
            width: 124,
            height: 104,
            padding: const EdgeInsets.all(AerSpacing.s),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AerRadii.medium),
              border: Border.all(
                color: selected ? AerColors.accent : AerColors.border,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                EntityIconTile(icon: type.icon, group: type.group, size: 36),
                const SizedBox(height: AerSpacing.xs),
                Text(
                  type.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TypeBanner extends StatelessWidget {
  const _TypeBanner({required this.type});

  final EntityType type;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AerSpacing.m),
      decoration: BoxDecoration(
        color: AerColors.background,
        borderRadius: BorderRadius.circular(AerRadii.medium),
      ),
      child: Row(
        children: [
          EntityIconTile(icon: type.icon, group: type.group),
          const SizedBox(width: AerSpacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.label, style: text.titleMedium),
                Text(
                  type.description,
                  style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmStep extends StatelessWidget {
  const _ConfirmStep({
    required this.draft,
    required this.type,
    required this.catalog,
    required this.parentName,
    required this.error,
  });

  final EntityDraft draft;
  final EntityType type;
  final RegistryCatalog catalog;
  final String? parentName;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AerSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
            ),
          ),
          Expanded(child: Text(value, style: text.bodyMedium)),
        ],
      ),
    );
    return ListView(
      children: [
        _TypeBanner(type: type),
        const SizedBox(height: AerSpacing.m),
        row('Название', draft.name),
        if (type.hasAddress)
          row(
            'Адрес',
            draft.address?.isNotEmpty == true ? draft.address! : '—',
          ),
        if (draft.description.isNotEmpty) row('Описание', draft.description),
        if (draft.tags.isNotEmpty) row('Теги', draft.tags.join(', ')),
        if (parentName != null) row('Находится внутри', parentName!),
        row(
          'Возможности',
          type.defaultCapabilities.isEmpty
              ? 'не заданы'
              : type.defaultCapabilities
                    .map(catalog.capabilityLabel)
                    .join(', '),
        ),
        const SizedBox(height: AerSpacing.s),
        Text(
          'Возможности подставлены по типу и описывают, что объект умеет. '
          'Их можно изменить позже; выполнять действия будут модули Monitoring, '
          'Remote, Power и другие.',
          style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
        ),
        if (error != null) ...[
          const SizedBox(height: AerSpacing.m),
          ErrorBanner(message: error!),
        ],
      ],
    );
  }
}

/// Inline error message with icon and text (never colour alone).
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AerSpacing.m),
      decoration: BoxDecoration(
        color: AerColors.terracotta.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AerRadii.small),
        border: Border.all(color: AerColors.terracotta.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AerColors.terracotta),
          const SizedBox(width: AerSpacing.s),
          Expanded(child: Text(message)),
          ?action,
        ],
      ),
    );
  }
}
