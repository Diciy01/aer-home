// Driver for performance runs: writes build/integration_response_data.json.
//   AER_WINDOW_SIZE=1920x1080 flutter drive --profile \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/scene_perf_test.dart -d linux
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
