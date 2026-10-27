import 'package:flutter/material.dart';

import '../../core_api/bots_api.dart';
import '../../core_api/core_client.dart';
import '../../state/bots_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import '../registry/entity_picker.dart';
import '../registry/entity_visuals.dart';
import '../registry/error_text.dart';
import 'bot_details.dart';
import 'bot_widgets.dart';

/// Opens the add (or, with [existing], edit) wizard. Returns the bot's
/// entity id when saved, null when cancelled.
Future<String?> showAddBotWizard(
  BuildContext context, {
  required BotsController bots,
  required RegistryController registry,
  Bot? existing,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      AddBotWizard(bots: bots, registry: registry, existing: existing),
);

/// Four steps: what → where it runs → monitoring → management and summary.
class AddBotWizard extends StatefulWidget {
  const AddBotWizard({
    super.key,
    required this.bots,
    required this.registry,
    this.existing,
  });

  final BotsController bots;
  final RegistryController registry;
  final Bot? existing;

  @override
  State<AddBotWizard> createState() => _AddBotWizardState();
}

class _AddBotWizardState extends State<AddBotWizard> {
  static const _titles = [
    'Что добавляем',
    'Где работает',
    'Мониторинг',
    'Управление и итог',
  ];

  int _step = 0;
  late final BotDraft _d = widget.existing == null
      ? BotDraft()
      : BotDraft.of(widget.existing!);
  late final _name = TextEditingController(text: _d.name);
  late final _desc = TextEditingController(text: _d.description);
  late final _category = TextEditingController(text: _d.category);
  late final _tags = TextEditingController(text: _d.tags.join(', '));
  late final _container = TextEditingController(text: _d.container);
  late final _workflows = TextEditingController(
    text: _d.n8nWorkflowIds.join(', '),
  );
  late final _interval = TextEditingController(
    text: '${_d.heartbeatIntervalSec}',
  );
  late final _timeout = TextEditingController(
    text: '${_d.heartbeatTimeoutSec}',
  );
  final Map<String, String> _names = {}; // entity id → name for chips
  bool _linkExisting = false;
  bool _saving = false;
  String? _error;
  Map<String, String> _fieldErrors = {};

  bool get _edit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (widget.existing?.host case final h?) _names[h.id] = h.name;
    if (widget.bots.adapters.isEmpty) widget.bots.refresh();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _desc,
      _category,
      _tags,
      _container,
      _workflows,
      _interval,
      _timeout,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _type(String t) => widget.registry.catalog?.typeLabel(t) ?? t;

  List<String> _split(String s) => [
    for (final x in s.split(','))
      if (x.trim().isNotEmpty) x.trim(),
  ];

  void _collect() {
    _d
      ..name = _name.text
      ..description = _desc.text
      ..category = _category.text
      ..tags = _split(_tags.text)
      ..container = _container.text
      ..n8nWorkflowIds = _split(_workflows.text)
      ..heartbeatIntervalSec = int.tryParse(_interval.text.trim()) ?? 0
      ..heartbeatTimeoutSec = int.tryParse(_timeout.text.trim()) ?? 0;
  }

  String? _localError() {
    _collect();
    switch (_step) {
      case 0:
        if (_linkExisting && _d.entityId == null) {
          return 'Выберите объект Registry';
        }
        if (!_linkExisting && _d.name.trim().isEmpty) return 'Укажите название';
      case 2:
        if (_d.heartbeatIntervalSec < 5 || _d.heartbeatIntervalSec > 3600) {
          return 'Интервал heartbeat: 5–3600 секунд';
        }
        if (_d.heartbeatTimeoutSec < 2 * _d.heartbeatIntervalSec) {
          return 'Тайм-аут должен быть не меньше двух интервалов';
        }
    }
    return null;
  }

  void _next() {
    final e = _localError();
    setState(() {
      _error = e;
      if (e == null) _step++;
    });
  }

  Future<void> _save() async {
    if (_localError() case final e?) {
      setState(() => _error = e);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _fieldErrors = {};
    });
    try {
      if (_edit) {
        final r = await widget.bots.update(
          widget.existing!.entityId,
          _d,
          widget.existing!.revision,
        );
        if (mounted) Navigator.pop(context, r.bot.entityId);
        return;
      }
      final (bot, token) = await widget.bots.create(_d);
      if (!mounted) return;
      if (token.isNotEmpty) await showHeartbeatToken(context, token);
      if (mounted) Navigator.pop(context, bot.bot.entityId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeError(e);
        if (e is CoreApiException) _fieldErrors = e.fieldErrors;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _pick(String title, Set<String> exclude) async {
    final e = await pickEntity(
      context,
      widget.registry,
      title: title,
      exclude: exclude,
    );
    if (e == null) return null;
    _names[e.id] = e.name;
    return e.id;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      key: const Key('bot-wizard'),
      title: Row(
        children: [
          Expanded(
            child: Text(
              _edit
                  ? 'Настройки бота · ${_titles[_step]}'
                  : 'Новый бот · ${_titles[_step]}',
            ),
          ),
          Text('${_step + 1} / 4', style: text.labelMedium),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 470,
        child: ListenableBuilder(
          listenable: widget.bots,
          builder: (context, _) => SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...switch (_step) {
                  0 => _what(context),
                  1 => _where(context),
                  2 => _monitoring(context),
                  _ => _control(context),
                },
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    key: const Key('bot-wizard-error'),
                    style: text.bodyMedium?.copyWith(
                      color: AerColors.terracotta,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        if (_step > 0)
          OutlinedButton(
            onPressed: _saving ? null : () => setState(() => _step--),
            child: const Text('Назад'),
          ),
        if (_step < 3)
          FilledButton(
            key: const Key('bot-wizard-next'),
            onPressed: _next,
            child: const Text('Далее'),
          )
        else
          FilledButton(
            key: const Key('bot-wizard-save'),
            onPressed: _saving || !widget.bots.canAct ? null : _save,
            child: Text(_edit ? 'Сохранить' : 'Добавить'),
          ),
      ],
    );
  }

  InputDecoration _dec(String label, {String? field, String? hint}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: field == null ? null : _fieldErrors[field],
      );

  List<Widget> _what(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      if (!_edit) ...[
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Новый объект')),
            ButtonSegment(value: true, label: Text('Уже есть в Registry')),
          ],
          selected: {_linkExisting},
          onSelectionChanged: (s) => setState(() {
            _linkExisting = s.first;
            if (!_linkExisting) _d.entityId = null;
          }),
        ),
        const SizedBox(height: 12),
      ],
      if (_linkExisting) ...[
        Text(
          'Бот привязывается к объекту Registry — второй реестр не создаётся.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('bot-wizard-pick-entity'),
          onPressed: () async {
            final id = await _pick('Объект для бота', const {});
            if (id != null) setState(() => _d.entityId = id);
          },
          icon: const Icon(Icons.link_rounded),
          label: Text(
            _d.entityId == null
                ? 'Выбрать объект'
                : (_names[_d.entityId] ?? _d.entityId!),
          ),
        ),
      ] else ...[
        if (!_edit) ...[
          Text('Тип объекта', style: text.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in botTypes)
                ChoiceChip(
                  key: Key('bot-type-$t'),
                  avatar: Icon(entityIcon(t), size: 16),
                  label: Text(_type(t)),
                  selected: _d.type == t,
                  onSelected: (_) => setState(() {
                    _d.type = t;
                    _d.runtime = null; // re-derived by Core from the type
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const Key('bot-wizard-name'),
          controller: _name,
          decoration: _dec('Название', field: 'name'),
        ),
        TextField(
          controller: _desc,
          decoration: _dec('Описание', field: 'description'),
        ),
      ],
      TextField(
        key: const Key('bot-wizard-category'),
        controller: _category,
        decoration: _dec(
          'Категория',
          field: 'category',
          hint: 'например: уведомления, дом, работа',
        ),
      ),
      if (!_linkExisting)
        TextField(
          controller: _tags,
          decoration: _dec('Теги через запятую', field: 'tags'),
        ),
    ];
  }

  List<Widget> _where(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      DropdownButtonFormField<String?>(
        key: const Key('bot-wizard-runtime'),
        initialValue: _d.runtime,
        decoration: _dec('Среда исполнения', field: 'runtime'),
        items: [
          const DropdownMenuItem(
            value: null,
            child: Text('Определить по типу'),
          ),
          for (final r in botRuntimes)
            DropdownMenuItem(value: r, child: Text(runtimeLabel(r))),
        ],
        onChanged: (v) => setState(() => _d.runtime = v),
      ),
      const SizedBox(height: 12),
      Text('Сервер (связь «работает на» в Registry)', style: text.labelLarge),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('bot-wizard-host'),
            onPressed: () async {
              final id = await _pick('Где работает бот', {?_d.entityId});
              if (id != null) setState(() => _d.hostId = id);
            },
            icon: const Icon(Icons.dns_outlined),
            label: Text(
              _d.hostId == null
                  ? 'Выбрать сервер'
                  : (_names[_d.hostId] ?? 'выбран'),
            ),
          ),
          if (_d.hostId != null)
            TextButton(
              onPressed: () => setState(() => _d.hostId = null),
              child: const Text('Убрать'),
            ),
        ],
      ),
      if (_fieldErrors['hostId'] case final e?)
        Text(e, style: const TextStyle(color: AerColors.terracotta)),
      const SizedBox(height: 12),
      Text('Зависимости (связь «зависит от»)', style: text.labelLarge),
      const SizedBox(height: 4),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final id in _d.dependsOn)
            InputChip(
              label: Text(_names[id] ?? id.substring(0, 8)),
              onDeleted: () =>
                  setState(() => _d.dependsOn = [..._d.dependsOn]..remove(id)),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 16),
            label: const Text('Добавить'),
            onPressed: () async {
              final id = await _pick('Зависимость бота', {
                ?_d.entityId,
                ..._d.dependsOn,
              });
              if (id != null) {
                setState(() => _d.dependsOn = [..._d.dependsOn, id]);
              }
            },
          ),
        ],
      ),
      if (_edit)
        Text(
          'Зависимости меняются в Registry (Устройства → связи).',
          style: text.bodySmall,
        ),
      const SizedBox(height: 12),
      TextField(
        controller: _container,
        decoration: _dec(
          'Docker-контейнер (если бот в контейнере)',
          field: 'container',
          hint: 'имя контейнера; состояние берётся из Docker в Мониторинге',
        ),
      ),
    ];
  }

  List<Widget> _monitoring(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tg = widget.bots.adapter('telegram')?.instances ?? const [];
    final n8n = widget.bots.adapter('n8n')?.instances ?? const [];
    return [
      Text(
        'Heartbeat — сигнал «я жив» от самого бота. Без него AER HOME не делает вид, что бот работает: статус будет «нет данных».',
        style: text.bodySmall,
      ),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('bot-wizard-interval'),
              controller: _interval,
              keyboardType: TextInputType.number,
              decoration: _dec('Интервал, с', field: 'heartbeatIntervalSec'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('bot-wizard-timeout'),
              controller: _timeout,
              keyboardType: TextInputType.number,
              decoration: _dec(
                'Нет связи после, с',
                field: 'heartbeatTimeoutSec',
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        initialValue: _d.logSource,
        decoration: _dec('Источник логов', field: 'logSource'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Автоматически')),
          for (final e in logSourceLabels.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) => setState(() => _d.logSource = v),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _d.telegramTokenId,
        decoration: _dec(
          'Проверка API Telegram (getMe)',
          field: 'telegramTokenId',
        ),
        items: [
          const DropdownMenuItem(
            value: '',
            child: Text('Не нужна — хватает heartbeat'),
          ),
          for (final t in tg)
            DropdownMenuItem(
              value: t.id,
              child: Text('Файл токена «${t.id}» на сервере'),
            ),
        ],
        onChanged: (v) => setState(() => _d.telegramTokenId = v ?? ''),
      ),
      Text(
        'Токены не вводятся в интерфейсе: файлы токенов объявляются в конфигурации Core.',
        style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _d.n8nInstanceId,
        decoration: _dec('n8n', field: 'n8nInstanceId'),
        items: [
          const DropdownMenuItem(value: '', child: Text('Не n8n')),
          for (final n in n8n)
            DropdownMenuItem(
              value: n.id,
              child: Text('${n.label} (${n.target})'),
            ),
        ],
        onChanged: n8n.isEmpty
            ? null
            : (v) => setState(() => _d.n8nInstanceId = v ?? ''),
      ),
      if (_d.n8nInstanceId.isNotEmpty)
        TextField(
          controller: _workflows,
          decoration: _dec(
            'ID workflows через запятую (пусто — все)',
            field: 'n8nWorkflowIds',
          ),
        ),
    ];
  }

  List<Widget> _control(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ctls = [
      for (final a in widget.bots.adapters.where((a) => a.controls))
        for (final i in a.instances) (a, i),
    ];
    final self = widget.existing?.name;
    return [
      Text('Управляющий адаптер', style: text.labelLarge),
      const SizedBox(height: 4),
      Text(
        'Запуск, остановка и перезапуск возможны только через адаптеры, объявленные в конфигурации Core. '
        'Произвольные команды из интерфейса не выполняются.',
        style: text.bodySmall,
      ),
      const SizedBox(height: 8),
      RadioGroup<String>(
        groupValue: _d.controllerId,
        onChanged: (v) => setState(() => _d.controllerId = v ?? ''),
        child: Column(
          children: [
            const RadioListTile<String>(
              key: Key('bot-ctl-none'),
              value: '',
              dense: true,
              title: Text('Без управления — только мониторинг'),
            ),
            for (final (a, i) in ctls)
              RadioListTile<String>(
                key: Key('bot-ctl-${i.id}'),
                value: i.id,
                dense: true,
                enabled: i.usedBy.isEmpty || i.usedBy == self,
                title: Text('${i.label} · ${a.label}'),
                subtitle: Text(
                  [
                    i.target,
                    if (i.allow.isNotEmpty) 'разрешено: ${i.allow.join(', ')}',
                    if (i.usedBy.isNotEmpty && i.usedBy != self)
                      'занят ботом «${i.usedBy}»',
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ),
      if (_fieldErrors['controllerId'] case final e?)
        Text(e, style: const TextStyle(color: AerColors.terracotta)),
      if (ctls.isEmpty)
        Text(
          'В конфигурации Core нет управляющих адаптеров (раздел bots.controllers).',
          style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
        ),
      if (!_edit)
        CheckboxListTile(
          key: const Key('bot-wizard-credential'),
          contentPadding: EdgeInsets.zero,
          value: _d.createCredential,
          onChanged: (v) => setState(() => _d.createCredential = v ?? false),
          title: const Text('Выдать токен heartbeat'),
          subtitle: const Text('Покажется один раз после сохранения'),
        ),
      const Divider(),
      Text('Итог', style: text.labelLarge),
      const SizedBox(height: 4),
      Text(
        [
          if (_d.entityId != null && !_edit)
            'Объект Registry: ${_names[_d.entityId] ?? _d.entityId}'
          else
            '${_type(_d.type)} «${_name.text.trim()}»',
          'среда: ${_d.runtime == null ? 'по типу' : runtimeLabel(_d.runtime!)}',
          if (_d.category.trim().isNotEmpty) 'категория: ${_d.category.trim()}',
          'heartbeat: каждые ${_interval.text} с, тревога после ${_timeout.text} с',
          _d.controllerId.isEmpty
              ? 'управление: нет'
              : 'управление: ${_d.controllerId}',
        ].join('\n'),
        key: const Key('bot-wizard-summary'),
        style: text.bodyMedium,
      ),
    ];
  }
}
