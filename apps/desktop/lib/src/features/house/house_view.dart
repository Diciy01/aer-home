import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Isometric house mode. The scene module (Flame) arrives in M03; until then
/// this view says so plainly instead of showing a fake scene.
class HouseView extends StatelessWidget {
  const HouseView({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(AerSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AerColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(AerRadii.large),
                  ),
                  child: const Icon(
                    Icons.cottage_outlined,
                    size: 36,
                    color: AerColors.accent,
                  ),
                ),
                const SizedBox(height: AerSpacing.m),
                Text('Изометрический дом', style: text.titleLarge),
                const SizedBox(height: AerSpacing.s),
                Text(
                  'Ещё не реализовано. Сцена с комнатами и предметами появится '
                  'в модуле M03. Все данные уже доступны в режиме «Классика».',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
