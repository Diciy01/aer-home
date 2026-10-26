import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'src/app.dart';
import 'src/core_api/core_client.dart';
import 'src/core_api/endpoint.dart';
import 'src/state/connection_controller.dart';
import 'src/state/view_mode.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final endpoint = CoreEndpoint.fromEnvironment();
  final client = CoreClient(
    httpClient: http.Client(),
    baseUri: endpoint.baseUri,
    tokenProvider: endpoint.readToken,
  );
  final connection = ConnectionController(client)..start();
  runApp(AerHomeApp(connection: connection, viewMode: ViewModeController()));
}
