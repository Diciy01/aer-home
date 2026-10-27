// TEST DOUBLE ONLY — in-memory Bots API with explicitly fake bots.
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';

final b0 = DateTime.utc(2026, 10, 27, 10);

Bot fakeBot(
  String id,
  String name, {
  String runtime = 'telegram',
  MonStatus status = MonStatus.online,
  String controllerId = '',
  String category = '',
  String lastError = '',
  int revision = 1,
}) => Bot(
  entityId: id,
  name: name,
  type: runtime == 'n8n' ? 'automation' : 'telegram_bot',
  runtime: runtime,
  status: status,
  revision: revision,
  category: category,
  controllerId: controllerId,
  lastError: lastError,
  statusReason: 'тестовая причина',
  heartbeat: BotHeartbeat(
    credentials: 1,
    active: status == MonStatus.online,
    lastSeenAt: b0,
    intervalSec: 15,
    timeoutSec: 60,
  ),
  version: '1.0-test',
  uptimeSec: 3600,
  cpuPercent: 2.5,
  memBytes: 50 * 1024 * 1024,
  runtimeState: controllerId.isEmpty
      ? null
      : const RuntimeState(
          adapter: 'process',
          state: 'running',
          reason: 'тест',
          pid: 4242,
        ),
);

List<BotAction> actionsFor(Bot b) => [
  for (final a in ['start', 'stop', 'restart'])
    BotAction(
      id: a,
      label: {
        'start': 'Запустить',
        'stop': 'Остановить',
        'restart': 'Перезапустить',
      }[a]!,
      available: b.controllerId.isNotEmpty,
      reason: b.controllerId.isEmpty
          ? 'Только мониторинг: управляющий адаптер не выбран'
          : '',
      confirm: true,
      risk: 'тестовый риск',
    ),
  const BotAction(
    id: 'check',
    label: 'Проверить соединение',
    available: true,
    reason: '',
    confirm: false,
    risk: '',
  ),
  BotAction(
    id: 'job.retry',
    label: 'Повторить задание',
    available: b.runtime == 'n8n',
    reason: '',
    confirm: true,
    risk: '',
  ),
];

class FakeBotsApi implements BotsApi {
  final bots = <Bot>[
    fakeBot('bot-1', 'Бот уведомлений (тест)', category: 'дом'),
    fakeBot(
      'bot-2',
      'Скрипт отчётов (тест)',
      runtime: 'python',
      status: MonStatus.degraded,
      controllerId: 'testproc',
      lastError: 'тестовая ошибка API',
    ),
    fakeBot('bot-3', 'n8n (тест)', runtime: 'n8n', status: MonStatus.offline),
  ];
  final confirms = <String>[];
  final executed =
      <(String, String, String, String?)>[]; // id, action, key, token
  final created = <Map<String, Object?>>[];
  final patched = <Map<String, Object?>>[];
  int listCalls = 0;
  String lastArchived = '';

  Bot _bot(String id) => bots.firstWhere(
    (b) => b.entityId == id,
    orElse: () => throw const CoreApiException(
      statusCode: 404,
      code: 'NOT_FOUND',
      message: 'Бот не найден',
    ),
  );

  @override
  Future<List<BotAdapter>> adapters() async => const [
    BotAdapter(
      id: 'process',
      label: 'Процесс под управлением Core',
      description: '',
      capabilities: ['control'],
      status: 'ok',
      reason: '',
      instances: [
        AdapterInstance(
          id: 'testproc',
          label: 'Тестовый процесс',
          target: 'sh -c',
          allow: ['start', 'stop'],
          usedBy: 'Скрипт отчётов (тест)',
        ),
        AdapterInstance(
          id: 'spare',
          label: 'Свободный процесс',
          target: 'python3 bot.py',
          allow: ['restart'],
        ),
      ],
    ),
    BotAdapter(
      id: 'telegram',
      label: 'Telegram',
      description: '',
      capabilities: ['monitor'],
      status: 'ok',
      reason: '',
      instances: [],
    ),
    BotAdapter(
      id: 'n8n',
      label: 'n8n',
      description: '',
      capabilities: ['jobs'],
      status: 'disabled',
      reason: 'не объявлено',
      instances: [],
    ),
  ];

  @override
  Future<List<Bot>> list({String archived = 'false'}) async {
    listCalls++;
    lastArchived = archived;
    return archived == 'true' ? const [] : List.of(bots);
  }

  @override
  Future<BotDetail> get(String id) async {
    final b = _bot(id);
    return BotDetail(
      bot: b,
      actions: actionsFor(b),
      dependencies: const [
        EntityRef(
          id: 'dep',
          name: 'База (тест)',
          type: 'database',
          relation: 'depends_on',
        ),
      ],
      integration: b.runtime == 'n8n'
          ? const BotIntegration(
              kind: 'n8n',
              label: 'n8n (тест)',
              status: 'unavailable',
              reason: 'Сервис n8n не отвечает (тест)',
            )
          : null,
    );
  }

  @override
  Future<(BotDetail, String)> create(BotDraft d) async {
    final j = d.toCreateJson();
    created.add(j);
    final b = fakeBot('bot-new', '${j['name']}', category: '${j['category']}');
    bots.add(b);
    return (
      await get('bot-new'),
      d.createCredential ? 'aer1.test-token-not-a-secret' : '',
    );
  }

  @override
  Future<BotDetail> update(String id, BotDraft d, int revision) async {
    patched.add(d.toPatchJson(revision));
    return get(id);
  }

  @override
  Future<BotDetail> setArchived(String id, bool archived) => get(id);

  @override
  Future<String> issueCredential(String id) async =>
      'aer1.test-token-not-a-secret';

  @override
  Future<JobPage> jobs(String id, {String? status, String? before}) async =>
      JobPage(
        [
          BotJob(
            id: 'j1',
            name: 'Рассылка (тест)',
            status: JobStatus.success,
            source: 'heartbeat',
            startedAt: b0,
            finishedAt: b0,
            durationMs: 1200,
          ),
          BotJob(
            id: 'j2',
            name: 'Workflow (тест)',
            status: JobStatus.failed,
            source: 'n8n',
            startedAt: b0,
            error: 'ошибка (тест)',
            retryable: id == 'bot-3',
          ),
        ],
        null,
        2,
      );

  @override
  Future<LogPage> logs(
    String id, {
    String? level,
    String q = '',
    int? before,
  }) async => LogPage([
    LogEntry(
      id: 1,
      at: b0,
      source: 'process:testproc',
      level: 'error',
      message: 'Traceback (тест)',
      correlationId: '',
    ),
  ], null);

  @override
  Future<List<MonEvent>> activity(String id) async => [
    MonEvent(
      id: 1,
      at: b0,
      kind: 'bot_started',
      severity: MonSeverity.info,
      message: 'Процесс запущен (тест)',
    ),
  ];

  @override
  Future<BotConfirmation> confirm(
    String id,
    String action, {
    String? jobId,
  }) async {
    confirms.add('$id/$action/${jobId ?? ''}');
    return BotConfirmation(
      token: 'confirm-$action',
      action: action,
      summary: 'Действие «$action» (тест)',
      risks: const ['Бот будет недоступен (тест)'],
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      jobId: jobId ?? '',
    );
  }

  @override
  Future<BotActionRecord> execute(
    String id,
    String action, {
    required String idempotencyKey,
    String? confirmationToken,
    String? jobId,
  }) async {
    executed.add((id, action, idempotencyKey, confirmationToken));
    return BotActionRecord(
      id: 'rec-${executed.length}',
      action: action,
      status: 'succeeded',
      message: 'Выполнено (тест)',
      requestedAt: b0,
    );
  }

  @override
  Future<List<BotActionRecord>> audit(String id) async => [
    BotActionRecord(
      id: 'r1',
      action: 'restart',
      status: 'rejected',
      message: 'Нужно подтверждение (тест)',
      requestedAt: b0,
    ),
  ];
}
