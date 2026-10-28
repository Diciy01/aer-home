import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'src/app.dart';
import 'src/core_api/bots_api.dart';
import 'src/core_api/core_client.dart';
import 'src/core_api/network_api.dart';
import 'src/core_api/power_api.dart';
import 'src/core_api/remote_api.dart';
import 'src/core_api/endpoint.dart';
import 'src/core_api/registry_api.dart';
import 'src/scene/repository/scene_repository.dart';
import 'src/scene/scene_controller.dart';
import 'src/state/app_section.dart';
import 'src/state/bots_controller.dart';
import 'src/state/network_controller.dart';
import 'src/state/power_controller.dart';
import 'src/state/remote_controller.dart';
import 'src/core_api/monitoring_api.dart';
import 'src/state/connection_controller.dart';
import 'src/state/monitoring_controller.dart';
import 'src/state/registry_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final endpoint = CoreEndpoint.fromEnvironment();
  final client = CoreClient(
    httpClient: http.Client(),
    baseUri: endpoint.baseUri,
    tokenProvider: endpoint.readToken,
  );
  final connection = ConnectionController(client)..start();
  final registryApi = HttpRegistryApi(client);
  final registry = RegistryController(registryApi, connection);
  final sceneCache = SceneCache.defaultLocation();
  final monitoring = MonitoringController(
    HttpMonitoringApi(client),
    connection,
    cache: MonitoringCache.beside(sceneCache.file),
  );
  unawaited(monitoring.start());
  // The house shows bot panels on bound objects, so bots load at startup.
  final bots = BotsController(HttpBotsApi(client), connection);
  unawaited(bots.start());
  final remote = RemoteController(
    HttpRemoteApi(client),
    connection,
    sourceName: 'AER HOME (${Platform.localHostname})',
  );
  unawaited(remote.start());
  // The house shows power state and actions on bound computers.
  final power = PowerController(HttpPowerApi(client), connection);
  unawaited(power.start());
  // Network state shows in the house and on «Обзор», so it loads at startup.
  final network = NetworkController(HttpNetworkApi(client), connection);
  unawaited(network.start());
  final scene = SceneController(
    sceneApi: HttpSceneApi(client),
    registryApi: registryApi,
    connectionController: connection,
    sceneCache: sceneCache,
    liveStatus: (id) => liveStatusOf(monitoring, id),
    liveChanges: monitoring,
    bundledLoader: loadBundledDemo,
    typeLabel: (t) => registry.catalog?.typeLabel(t) ?? t,
    capabilityLabel: (c) => registry.catalog?.capabilityLabel(c) ?? c,
  );
  runApp(
    AerHomeApp(
      connection: connection,
      registry: registry,
      scene: scene,
      section: AppSectionController(),
      monitoring: monitoring,
      bots: bots,
      remote: remote,
      power: power,
      network: network,
    ),
  );
}
