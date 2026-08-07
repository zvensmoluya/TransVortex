import 'models.dart';
import 'transport.dart';

const Object _preserveFallback = Object();

class AppServiceClient {
  AppServiceClient(this._transport);

  final AppServiceTransport _transport;

  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    return _transport.call(method, params, timeout);
  }

  Future<ServiceInfo> info() async {
    return ServiceInfo.fromJson(await _transport.call('service.info'));
  }

  Future<ServiceHealth> health() async {
    return ServiceHealth.fromJson(await _transport.call('service.health'));
  }

  Future<AgentEntryInfo> agentEntry() async {
    return AgentEntryInfo.fromJson(await _transport.call('agent.entry.get'));
  }

  Future<AgentClientInfo> agentClient() async {
    return AgentClientInfo.fromJson(await _transport.call('agent.client.get'));
  }

  Future<AgentLaunchResult> openAgentClient() async {
    return AgentLaunchResult.fromJson(
      await _transport.call('agent.client.open'),
    );
  }

  Future<AgentLaunchResult> launchAsrAgentHandoff(String scope) async {
    return AgentLaunchResult.fromJson(
      await _transport.call('agent.handoff.launch', {
        'workflow': 'asr_environment',
        'scope': scope,
      }),
    );
  }

  Future<DesktopSnapshot> desktopSnapshot() async {
    return DesktopSnapshot.fromJson(await _transport.call('desktop.snapshot'));
  }

  Future<RuntimeSnapshot> runtimeSnapshot() async {
    return RuntimeSnapshot.fromJson(await _transport.call('runtime.snapshot'));
  }

  Future<TaskSubmissionResult> submitRun(Map<String, Object?> request) async {
    return TaskSubmissionResult.fromJson(
      await _transport.call('runtime.submitRun', {'request': request}),
    );
  }

  Future<TaskSubmissionResult> submitResume(
    Map<String, Object?> request,
  ) async {
    return TaskSubmissionResult.fromJson(
      await _transport.call('runtime.submitResume', {'request': request}),
    );
  }

  Future<TaskSubmissionResult> retranslate(
    String taskId, {
    String? provider,
    String? model,
    Map<String, Object?>? routing,
    Map<String, Object?>? overrides,
  }) async {
    return TaskSubmissionResult.fromJson(
      await _transport.call('runtime.retranslate', {
        'task_id': taskId,
        'provider': ?provider,
        'model': ?model,
        'routing': ?routing,
        'overrides': ?overrides,
      }),
    );
  }

  Future<TaskSummary> cancel(String taskId, {bool force = false}) async {
    return TaskSummary.fromJson(
      await _transport.call('runtime.cancel', {
        'task_id': taskId,
        'force': force,
      }),
    );
  }

  Future<TaskEventsPage> taskEvents(
    String taskId, {
    int cursor = 0,
    int limit = 200,
  }) async {
    return TaskEventsPage.fromJson(
      await _transport.call('tasks.events', {
        'task_id': taskId,
        'cursor': cursor,
        'limit': limit,
      }),
    );
  }

  Future<List<TaskSummary>> taskList() async {
    return parseTaskSummaries(await _transport.call('tasks.list'));
  }

  Future<Map<String, Object?>> authSet(String credentialId, String apiKey) {
    return call('auth.set', {
      'credential_id': credentialId,
      'api_key': apiKey,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> networkSettingsSave({
    required String mode,
    required int proxyPort,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('network.settings.save', {
      'mode': mode,
      'proxy_port': proxyPort,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerSave({
    required Map<String, Object?> providerDraft,
    String? apiKey,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('provider.save', {
      'provider_draft': providerDraft,
      'api_key': ?apiKey,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerDelete({
    required String name,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('provider.delete', {
      'name': name,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerModels({
    required Map<String, Object?> providerDraft,
    String? apiKey,
  }) {
    return call('provider.models', {
      'provider_draft': providerDraft,
      'api_key': ?apiKey,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerTest({
    required Map<String, Object?> providerDraft,
    required String model,
    String reasoningEffort = 'auto',
    String? apiKey,
  }) {
    return call('provider.test', {
      'provider_draft': providerDraft,
      'model': model,
      'reasoning_effort': reasoningEffort,
      'api_key': ?apiKey,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> saveTranslationRouting({
    required String provider,
    required String model,
    Object? fallback = _preserveFallback,
    Map<String, Object?>? expectedVersion,
  }) {
    final params = <String, Object?>{
      'primary': {'provider': provider, 'model': model},
      'expected_version': ?expectedVersion,
    };
    if (!identical(fallback, _preserveFallback)) {
      params['fallback'] = fallback;
    }
    return call('provider.routing.save', params).then(_stringMap);
  }

  Future<Map<String, Object?>> saveTranslationRoutingProfiles({
    required List<Object?> profiles,
    required String activeProfile,
    int? nextProfileSeq,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('provider.routing.save', {
      'profiles': profiles,
      'active_profile': activeProfile,
      'next_profile_seq': ?nextProfileSeq,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> asrProviderSave({
    required Map<String, Object?> providerDraft,
    String? apiKey,
    Map<String, Object?>? expectedVersion,
    bool setDefault = true,
  }) {
    return call('asr.provider.save', {
      'provider_draft': providerDraft,
      'api_key': ?apiKey,
      'expected_version': ?expectedVersion,
      'set_default': setDefault,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> asrProviderTest({
    String? provider,
    Map<String, Object?>? providerDraft,
    String? apiKey,
    String sourceLang = 'en',
  }) {
    return call('asr.provider.test', {
      'provider': ?provider,
      'provider_draft': ?providerDraft,
      'api_key': ?apiKey,
      'source_lang': sourceLang,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> asrProviderUsage({
    String? provider,
    Map<String, Object?>? providerDraft,
    String? apiKey,
  }) {
    return call('asr.provider.usage', {
      'provider': ?provider,
      'provider_draft': ?providerDraft,
      'api_key': ?apiKey,
    }).then(_stringMap);
  }

  Future<AsrOperationStatus> asrSetupStart(
    String modelId, {
    bool activateOnComplete = false,
    String? provider,
    String? managedAcceleratorId,
    String? acceleratorRegistrationId,
    String device = 'auto',
    String computeType = 'auto',
  }) async {
    final params = <String, Object?>{'model_id': modelId};
    if (activateOnComplete) {
      params.addAll({
        'activate_on_complete': true,
        'provider': ?provider,
        'managed_accelerator_id': ?managedAcceleratorId,
        'accelerator_registration_id': ?acceleratorRegistrationId,
        'device': device,
        'compute_type': computeType,
      });
    }
    return AsrOperationStatus.fromJson(await call('asr.setup.start', params));
  }

  Future<AsrStorageOption> asrStorageSet(String storageRoot) async {
    return AsrStorageOption.fromJson(
      await call('asr.storage.set', {'storage_root': storageRoot}),
    );
  }

  Future<AsrOperationStatus> asrComponentInstall(
    String kind, {
    String? itemId,
  }) async {
    return AsrOperationStatus.fromJson(
      await call('asr.component.install', {'kind': kind, 'item_id': ?itemId}),
    );
  }

  Future<Map<String, Object?>> asrComponentRemove(
    String kind, {
    String? itemId,
  }) {
    return call('asr.component.remove', {
      'kind': kind,
      'item_id': ?itemId,
    }).then(_stringMap);
  }

  Future<AsrOperationStatus> asrOperation(String operationId) async {
    return AsrOperationStatus.fromJson(
      await call('asr.operation.get', {'operation_id': operationId}),
    );
  }

  Future<AsrOperationStatus> asrOperationCancel(String operationId) async {
    return AsrOperationStatus.fromJson(
      await call('asr.operation.cancel', {'operation_id': operationId}),
    );
  }

  Future<Map<String, Object?>> probeAsrHardware() {
    return call('asr.hardware.probe').then(_stringMap);
  }

  Future<AsrModelDiscovery> discoverExternalAsrModels(String searchRoot) async {
    return AsrModelDiscovery.fromJson(
      await call('asr.model.discover', {'search_root': searchRoot}),
    );
  }

  Future<Map<String, Object?>> probeExternalAsrModel({
    required String modelPath,
    String device = 'auto',
    String computeType = 'auto',
    String? acceleratorRoot,
    String? userLabel,
  }) {
    return call('asr.model.probe', {
      'model_path': modelPath,
      'device': device,
      'compute_type': computeType,
      'accelerator_root': ?acceleratorRoot,
      'user_label': ?userLabel,
    }, const Duration(minutes: 3)).then(_stringMap);
  }

  Future<Map<String, Object?>> setExternalAsrModelLabel({
    required String registrationId,
    required String userLabel,
  }) {
    return call('asr.model.label.set', {
      'registration_id': registrationId,
      'user_label': userLabel,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> activateAsrResources({
    String? provider,
    String? managedModelId,
    String? modelRegistrationId,
    String? managedAcceleratorId,
    String? acceleratorRegistrationId,
    String? device,
    String? computeType,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('asr.resources.activate', {
      'provider': ?provider,
      'managed_model_id': ?managedModelId,
      'model_registration_id': ?modelRegistrationId,
      'managed_accelerator_id': ?managedAcceleratorId,
      'accelerator_registration_id': ?acceleratorRegistrationId,
      'device': ?device,
      'compute_type': ?computeType,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<List<PythonEnvironmentOption>> discoverAsrEnvironments() async {
    final payload = _stringMap(await call('asr.environment.discover'));
    return _objectList(payload['environments'])
        .map(PythonEnvironmentOption.fromJson)
        .where((item) => item.pythonExecutable.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, Object?>> probeAsrEnvironment({
    required String pythonExecutable,
    String? modelId,
    String? modelPath,
    String device = 'auto',
    String computeType = 'auto',
    bool save = true,
  }) {
    return call('asr.environment.probe', {
      'python_executable': pythonExecutable,
      'model_id': ?modelId,
      'model_path': ?modelPath,
      'device': device,
      'compute_type': computeType,
      'save': save,
    }, const Duration(minutes: 3)).then(_stringMap);
  }

  Future<MediaInspection> inspectMedia({
    required String input,
    String sourceLang = 'auto',
    String sourceMode = 'auto',
    String subtitleTrack = 'auto',
  }) async {
    return MediaInspection.fromJson(
      await call('media.inspect', {
        'input': input,
        'source_lang': sourceLang,
        'source_mode': sourceMode,
        'subtitle_track': subtitleTrack,
      }, const Duration(seconds: 30)),
    );
  }

  Future<Map<String, Object?>> resultOpen(String taskId) async {
    return _stringMap(
      await _transport.call('result.open', {'task_id': taskId}),
    );
  }

  Future<TaskResultWorkspace> openTaskResult(String taskId) async {
    return TaskResultWorkspace.fromJson(await resultOpen(taskId));
  }

  Future<TaskResultWorkspace> resultSegmentsSave(
    String taskId,
    List<Map<String, Object?>> segments,
  ) async {
    return TaskResultWorkspace.fromJson(
      await _transport.call('result.segments.save', {
        'task_id': taskId,
        'segments': segments,
      }),
    );
  }

  Future<Map<String, Object?>> resultReexport(
    String taskId, {
    String outputFormat = 'both',
    String? outputDir,
    bool bilingual = true,
    String? subtitleBilingualOrder,
    bool? subtitlePreferSingleLine,
  }) async {
    final params = <String, Object?>{
      'task_id': taskId,
      'output_format': outputFormat,
      'output_dir': ?outputDir,
      'bilingual': bilingual,
      'subtitle_bilingual_order': ?subtitleBilingualOrder,
      'subtitle_prefer_single_line': ?subtitlePreferSingleLine,
    };
    return _stringMap(await _transport.call('result.reexport', params));
  }

  Future<void> shutdown() async {
    await _transport.call(
      'service.shutdown',
      const {},
      const Duration(seconds: 2),
    );
  }

  Future<Map<String, Object?>> setWorkspaceStorage(String workspaceRoot) async {
    return _stringMap(
      await _transport.call('workspace.storage.set', {
        'workspace_root': workspaceRoot,
      }),
    );
  }
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

List<Object?> _objectList(Object? value) {
  if (value is List) return value;
  return const <Object?>[];
}
