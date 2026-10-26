import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'src/app.dart';
import 'src/core_api/core_client.dart';
import 'src/core_api/endpoint.dart';
import 'src/core_api/registry_api.dart';
import 'src/scene/repository/scene_repository.dart';
import 'src/scene/scene_controller.dart';
import 'src/state/app_section.dart';
import 'src/state/connection_controller.dart';
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
  final scene = SceneController(
    sceneApi: HttpSceneApi(client),
    registryApi: registryApi,
    connectionController: connection,
    sceneCache: SceneCache.defaultLocation(),
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
    ),
  );
}
