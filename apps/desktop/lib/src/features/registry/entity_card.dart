import 'package:flutter/material.dart';

import '../../core_api/registry_models.dart';
import '../../theme/tokens.dart';
import 'entity_visuals.dart';

/// Compact card for one entity in the Registry grid.
class EntityCard extends StatelessWidget {
  const EntityCard({
    super.key,
    required this.entity,
    required this.catalog,
    required this.selected,
    required this.onTap,
  });

  final RegistryEntity entity;
  final RegistryCatalog catalog;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final type = catalog.type(entity.type);
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${entity.name}, ${catalog.typeLabel(entity.type)}'
          '${entity.archived ? ', в архиве' : ''}',
      child: AnimatedContainer(
        duration: AerMotion.short,
        decoration: BoxDecoration(
          color: AerColors.surface,
          borderRadius: BorderRadius.circular(AerRadii.medium),
          border: Border.all(
            color: selected ? AerColors.accent : AerColors.border,
            width: selected ? 2 : 1,
          ),
          boxShadow: [
            if (selected)
              BoxShadow(
                color: AerColors.accent.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: Key('entity-${entity.id}'),
            borderRadius: BorderRadius.circular(AerRadii.medium),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(AerSpacing.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      EntityIconTile(icon: entity.icon, group: type?.group),
                      const SizedBox(width: AerSpacing.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entity.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              catalog.typeLabel(entity.type),
                              style: text.bodySmall?.copyWith(
                                color: AerColors.inkMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (entity.archived)
                        const Tooltip(
                          message: 'В архиве',
                          child: Icon(
                            Icons.inventory_2_outlined,
                            size: 18,
                            color: AerColors.inkMuted,
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    entity.address ?? 'без адреса',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: AerColors.inkMuted,
                      fontFamily: entity.address == null ? null : 'monospace',
                    ),
                  ),
                  const SizedBox(height: AerSpacing.xs),
                  Row(
                    children: [
                      // Tags scroll out of view instead of overflowing the card.
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const NeverScrollableScrollPhysics(),
                          child: Row(
                            children: [
                              for (final t in entity.tags.take(3))
                                Padding(
                                  padding: const EdgeInsets.only(
                                    right: AerSpacing.xs,
                                  ),
                                  child: _TagPill(t),
                                ),
                              if (entity.tags.length > 3)
                                Text(
                                  '+${entity.tags.length - 3}',
                                  style: text.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: AerSpacing.s),
                      Tooltip(
                        message: 'Заявленные возможности',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.bolt_outlined,
                              size: 16,
                              color: AerColors.inkMuted,
                            ),
                            Text(
                              '${entity.capabilities.length}',
                              style: text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  const _TagPill(this.tag);

  final String tag;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AerSpacing.s, vertical: 2),
    decoration: BoxDecoration(
      color: AerColors.surfaceMuted,
      borderRadius: BorderRadius.circular(AerRadii.small),
    ),
    child: Text(tag, style: Theme.of(context).textTheme.labelSmall),
  );
}
