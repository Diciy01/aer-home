/// Data types mirroring contracts/openapi.yaml 0.2.0.
library;

/// Payload of `GET /health`.
class Health {
  const Health({
    required this.status,
    required this.timestamp,
    required this.apiVersion,
  });

  factory Health.fromJson(Map<String, dynamic> json) => Health(
    status: json['status'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
    apiVersion: json['apiVersion'] as String,
  );

  /// `ok` or `degraded`.
  final String status;
  final DateTime timestamp;
  final String apiVersion;

  bool get isOk => status == 'ok';
}

class SchemaVersion {
  const SchemaVersion(this.module, this.version);

  factory SchemaVersion.fromJson(Map<String, dynamic> json) =>
      SchemaVersion(json['module'] as String, json['version'] as int);

  final String module;
  final int version;
}

class ModuleStatus {
  const ModuleStatus({required this.name, required this.enabled, this.error});

  factory ModuleStatus.fromJson(Map<String, dynamic> json) => ModuleStatus(
    name: json['name'] as String,
    enabled: json['enabled'] as bool,
    error: json['error'] as String?,
  );

  final String name;
  final bool enabled;

  /// Set when the module is enabled but failed to start.
  final String? error;
}

/// Payload of `GET /system/info`.
class SystemInfo {
  const SystemInfo({
    required this.coreVersion,
    required this.apiVersion,
    required this.mode,
    required this.demo,
    required this.instanceId,
    required this.startedAt,
    required this.uptimeSeconds,
    required this.schema,
    required this.modules,
  });

  factory SystemInfo.fromJson(Map<String, dynamic> json) => SystemInfo(
    coreVersion: json['coreVersion'] as String,
    apiVersion: json['apiVersion'] as String,
    mode: json['mode'] as String,
    demo: json['demo'] as bool,
    instanceId: json['instanceId'] as String,
    startedAt: DateTime.parse(json['startedAt'] as String),
    uptimeSeconds: json['uptimeSeconds'] as int,
    schema: [
      for (final s in json['schema'] as List<dynamic>)
        SchemaVersion.fromJson(s as Map<String, dynamic>),
    ],
    modules: [
      for (final m in json['modules'] as List<dynamic>)
        ModuleStatus.fromJson(m as Map<String, dynamic>),
    ],
  );

  final String coreVersion;
  final String apiVersion;
  final String mode;

  /// True when Core may hold demo data; the UI must label it.
  final bool demo;
  final String instanceId;
  final DateTime startedAt;
  final int uptimeSeconds;
  final List<SchemaVersion> schema;
  final List<ModuleStatus> modules;
}
