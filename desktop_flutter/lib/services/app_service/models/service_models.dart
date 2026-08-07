part of '../models.dart';

class ServiceInfo {
  const ServiceInfo({
    required this.service,
    required this.protocolVersion,
    required this.appVersion,
    required this.capabilities,
  });

  final String service;
  final int protocolVersion;
  final String appVersion;
  final List<String> capabilities;

  factory ServiceInfo.fromJson(Object? value) {
    final map = _stringMap(value);
    return ServiceInfo(
      service: _stringValue(map['service']) ?? 'unknown',
      protocolVersion: _intValue(map['protocol_version']) ?? 0,
      appVersion: _stringValue(map['app_version']) ?? 'unknown',
      capabilities: _stringList(map['capabilities']),
    );
  }
}

class AgentEntryInfo {
  const AgentEntryInfo({
    required this.schemaVersion,
    required this.appVersion,
    required this.protocolVersion,
    required this.registered,
    required this.installRoot,
    required this.configRoot,
    required this.entryDocument,
    required this.entryState,
    required this.docsRoot,
    required this.documents,
    required this.cliArgvPrefix,
    required this.capabilitiesArgv,
    required this.handoffText,
    required this.asrEnvironmentHandoffText,
    required this.asrEnvironmentHandoffs,
  });

  final int schemaVersion;
  final String appVersion;
  final String protocolVersion;
  final bool registered;
  final String installRoot;
  final String configRoot;
  final String entryDocument;
  final String entryState;
  final String docsRoot;
  final Map<String, Object?> documents;
  final List<String> cliArgvPrefix;
  final List<String> capabilitiesArgv;
  final String handoffText;
  final String asrEnvironmentHandoffText;
  final Map<String, String> asrEnvironmentHandoffs;

  factory AgentEntryInfo.fromJson(Object? value) {
    final map = _stringMap(value);
    return AgentEntryInfo(
      schemaVersion: _intValue(map['schema_version']) ?? 0,
      appVersion: _stringValue(map['app_version']) ?? '',
      protocolVersion: _stringValue(map['protocol_version']) ?? '',
      registered: map['registered'] == true,
      installRoot: _stringValue(map['install_root']) ?? '',
      configRoot: _stringValue(map['config_root']) ?? '',
      entryDocument: _stringValue(map['agent_entry_document']) ?? '',
      entryState: _stringValue(map['agent_entry_state']) ?? '',
      docsRoot: _stringValue(map['agent_docs_root']) ?? '',
      documents: _stringMap(map['documents']),
      cliArgvPrefix: _stringList(map['cli_argv_prefix']),
      capabilitiesArgv: _stringList(map['capabilities_argv']),
      handoffText: _stringValue(map['handoff_text']) ?? '',
      asrEnvironmentHandoffText:
          _stringValue(map['asr_environment_handoff_text']) ?? '',
      asrEnvironmentHandoffs: _stringMap(
        map['asr_environment_handoffs'],
      ).map((key, value) => MapEntry(key, _stringValue(value) ?? '')),
    );
  }

  String documentPath(String name) => _stringValue(documents[name]) ?? '';
}

class AgentClientInfo {
  const AgentClientInfo({
    required this.schemaVersion,
    required this.id,
    required this.name,
    required this.isDefault,
    required this.detected,
    required this.ready,
    required this.launchSupported,
    required this.executable,
    required this.version,
    required this.versionLabel,
    required this.statusCode,
    required this.message,
  });

  final int schemaVersion;
  final String id;
  final String name;
  final bool isDefault;
  final bool detected;
  final bool ready;
  final bool launchSupported;
  final String executable;
  final String version;
  final String versionLabel;
  final String statusCode;
  final String message;

  factory AgentClientInfo.fromJson(Object? value) {
    final map = _stringMap(value);
    return AgentClientInfo(
      schemaVersion: _intValue(map['schema_version']) ?? 0,
      id: _stringValue(map['id']) ?? '',
      name: _stringValue(map['name']) ?? 'Codex CLI',
      isDefault: map['default'] == true,
      detected: map['detected'] == true,
      ready: map['ready'] == true,
      launchSupported: map['launch_supported'] == true,
      executable: _stringValue(map['executable']) ?? '',
      version: _stringValue(map['version']) ?? '',
      versionLabel: _stringValue(map['version_label']) ?? '',
      statusCode: _stringValue(map['status_code']) ?? 'unknown',
      message: _stringValue(map['message']) ?? '',
    );
  }
}

class AgentLaunchResult {
  const AgentLaunchResult({
    required this.launched,
    required this.pid,
    required this.workspace,
    required this.handoffId,
    required this.handoffDocument,
    required this.workflow,
    required this.scope,
    required this.client,
  });

  final bool launched;
  final int? pid;
  final String workspace;
  final String handoffId;
  final String handoffDocument;
  final String workflow;
  final String scope;
  final AgentClientInfo client;

  factory AgentLaunchResult.fromJson(Object? value) {
    final map = _stringMap(value);
    return AgentLaunchResult(
      launched: map['launched'] == true,
      pid: _intValue(map['pid']),
      workspace: _stringValue(map['workspace']) ?? '',
      handoffId: _stringValue(map['handoff_id']) ?? '',
      handoffDocument: _stringValue(map['handoff_document']) ?? '',
      workflow: _stringValue(map['workflow']) ?? '',
      scope: _stringValue(map['scope']) ?? '',
      client: AgentClientInfo.fromJson(map['client']),
    );
  }
}

class ServiceHealth {
  const ServiceHealth({
    required this.service,
    required this.status,
    required this.runtime,
    required this.pump,
    this.error,
  });

  final String service;
  final String status;
  final Map<String, Object?> runtime;
  final Map<String, Object?> pump;
  final String? error;

  factory ServiceHealth.fromJson(Object? value) {
    final map = _stringMap(value);
    return ServiceHealth(
      service: _stringValue(map['service']) ?? 'unknown',
      status: _stringValue(map['status']) ?? 'unknown',
      runtime: _stringMap(map['runtime']),
      pump: _stringMap(map['pump']),
      error: _stringValue(map['error']),
    );
  }

  bool get degraded {
    final lastError = _stringValue(pump['last_error']);
    return status == 'degraded' || (lastError != null && lastError.isNotEmpty);
  }

  Map<String, Object?> get active {
    return _stringMap(runtime['active']);
  }

  String get activeTaskLabel {
    final taskId =
        _stringValue(active['task_id']) ?? _stringValue(active['taskId']);
    final status = _stringValue(active['status']);
    if (taskId == null || taskId.isEmpty) return '无活动任务';
    final taskLabel = shortTaskIdLabel(taskId);
    if (status == null || status.trim().isEmpty) return taskLabel;
    return '$taskLabel · ${taskStatusLabel(status)}';
  }

  String get pumpLabel {
    final enabled = pump['enabled'] == true;
    final lastError = _stringValue(pump['last_error']);
    if (!enabled) return 'disabled';
    if (lastError != null && lastError.isNotEmpty) return 'degraded';
    return 'running';
  }
}
