import 'dart:async';

import 'package:flutter/material.dart';

import '../../shell/status_presentation.dart';
import '../../state/connection_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import 'add_entity_wizard.dart';
import 'entity_card.dart';
import 'entity_details.dart';
import 'error_text.dart';

/// "Устройства": searchable, filterable card grid with a details panel.
class RegistryView extends StatefulWidget {
  const RegistryView({
    super.key,
    required this.registry,
    required this.connection,
  });

  final RegistryController registry;
  final ConnectionController connection;

  @override
  State<RegistryView> createState() => _RegistryViewState();
}

class _RegistryViewState extends State<RegistryView> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    final created = await showAddEntityWizard(context, widget.registry);
    if (created != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('«${created.name}» добавлен')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.registry, widget.connection]),
      builder: (context, _) {
        final r = widget.registry;
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(registry: r, search: _search, onAdd: _add),
                  if (r.isStale && r.items.isNotEmpty)
                    _StaleBanner(registry: r, connection: widget.connection),
                  Expanded(child: _body(context, r)),
                ],
              ),
            ),
            if (r.selected != null && r.catalog != null)
              SizedBox(width: 420, child: EntityDetails(registry: r)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, RegistryController r) {
    if (r.catalog == null || (r.items.isEmpty && r.error != null)) {
      if (r.loading) return const Center(child: CircularProgressIndicator());
      return _Unavailable(registry: r, connection: widget.connection);
    }
    if (r.items.isEmpty) {
      if (r.loading) return const Center(child: CircularProgressIndicator());
      return _Empty(registry: r, onAdd: _add);
    }
    return Column(
      children: [
        if (r.loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AerSpacing.l,
                  AerSpacing.s,
                  AerSpacing.l,
                  AerSpacing.l,
                ),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 320,
                    mainAxisExtent: 136,
                    crossAxisSpacing: AerSpacing.m,
                    mainAxisSpacing: AerSpacing.m,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    childCount: r.items.length,
                    (context, i) {
                      final e = r.items[i];
                      return EntityCard(
                        entity: e,
                        catalog: r.catalog!,
                        selected: r.selected?.id == e.id,
                        onTap: () => unawaited(r.select(e)),
                      );
                    },
                  ),
                ),
              ),
              if (r.hasMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AerSpacing.l),
                    child: Center(
                      child: OutlinedButton(
                        onPressed: r.loadingMore ? null : r.loadMore,
                        child: Text(
                          'Показать ещё (${r.items.length} из ${r.total})',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.registry,
    required this.search,
    required this.onAdd,
  });

  final RegistryController registry;
  final TextEditingController search;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = registry;
    final catalog = r.catalog;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AerSpacing.l,
        AerSpacing.l,
        AerSpacing.l,
        AerSpacing.s,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Устройства и сервисы',
                        style: text.headlineSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AerSpacing.m),
                    if (r.loadedAt != null)
                      Text(
                        r.query.archived
                            ? 'в архиве: ${r.total}'
                            : 'всего: ${r.total}',
                        style: text.bodyMedium?.copyWith(
                          color: AerColors.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
              Tooltip(
                message: r.canEdit ? '' : 'Нужна связь с AER Core',
                child: FilledButton.icon(
                  key: const Key('action-add'),
                  onPressed: r.canEdit ? onAdd : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AerSpacing.m),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('registry-search'),
                  controller: search,
                  onChanged: r.setSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Поиск: название, адрес, тег, описание',
                    isDense: true,
                    filled: true,
                    fillColor: AerColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AerRadii.medium),
                      borderSide: const BorderSide(color: AerColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AerRadii.medium),
                      borderSide: const BorderSide(color: AerColors.border),
                    ),
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить',
                            onPressed: () {
                              search.clear();
                              r.setSearch('');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: AerSpacing.m),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  key: const Key('registry-type-filter'),
                  initialValue: r.query.type,
                  isDense: true,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AerColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AerRadii.medium),
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Все типы'),
                    ),
                    if (catalog != null)
                      for (final t in catalog.types)
                        DropdownMenuItem(value: t.id, child: Text(t.label)),
                  ],
                  onChanged: catalog == null ? null : r.setTypeFilter,
                ),
              ),
              const SizedBox(width: AerSpacing.m),
              SegmentedButton<bool>(
                key: const Key('registry-archive-toggle'),
                segments: const [
                  ButtonSegment(value: false, label: Text('Активные')),
                  ButtonSegment(
                    value: true,
                    label: Text('Архив'),
                    icon: Icon(Icons.inventory_2_outlined, size: 16),
                  ),
                ],
                selected: {r.query.archived},
                onSelectionChanged: (s) => r.setArchivedView(s.first),
                showSelectedIcon: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.registry, required this.connection});

  final RegistryController registry;
  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final age = formatAge(registry.loadedAt, DateTime.now());
    final reason = registry.error != null
        ? describeError(registry.error!)
        : LinkPresentation.of(connection.link).label;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AerSpacing.l),
      padding: const EdgeInsets.symmetric(
        horizontal: AerSpacing.m,
        vertical: AerSpacing.s,
      ),
      decoration: BoxDecoration(
        color: AerColors.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_rounded, size: 18, color: AerColors.ink),
          const SizedBox(width: AerSpacing.s),
          Expanded(
            child: Text(
              'Показаны данные, загруженные $age. $reason. Изменения заблокированы.',
            ),
          ),
          TextButton(
            onPressed: registry.reload,
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.registry, required this.connection});

  final RegistryController registry;
  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final p = LinkPresentation.of(connection.link);
    final reason = registry.error != null
        ? describeError(registry.error!)
        : p.explanation;
    return _CenteredMessage(
      icon: p.icon,
      color: p.color,
      title: 'Список устройств недоступен',
      body: reason,
      action: OutlinedButton.icon(
        onPressed: registry.reload,
        icon: const Icon(Icons.refresh),
        label: const Text('Повторить'),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.registry, required this.onAdd});

  final RegistryController registry;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final q = registry.query;
    final filtered = q.text.isNotEmpty || q.type != null;
    if (q.archived) {
      return const _CenteredMessage(
        icon: Icons.inventory_2_outlined,
        color: AerColors.inkMuted,
        title: 'Архив пуст',
        body: 'Сюда попадают объекты, которые вы убрали из основного списка.',
      );
    }
    if (filtered) {
      return const _CenteredMessage(
        icon: Icons.search_off,
        color: AerColors.inkMuted,
        title: 'Ничего не найдено',
        body: 'Измените запрос или фильтр по типу.',
      );
    }
    return _CenteredMessage(
      icon: Icons.cottage_outlined,
      color: AerColors.accent,
      title: 'Пока ничего не добавлено',
      body:
          'Добавьте компьютер, роутер, бота или сервис — '
          'это займёт не больше трёх шагов.',
      action: FilledButton.icon(
        onPressed: registry.canEdit ? onAdd : null,
        icon: const Icon(Icons.add),
        label: const Text('Добавить первый объект'),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: AerSpacing.m),
            Text(title, style: text.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: AerSpacing.s),
            Text(
              body,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
            ),
            if (action != null) ...[
              const SizedBox(height: AerSpacing.m),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
