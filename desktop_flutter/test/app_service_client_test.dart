import 'app_service/bridge_tests.dart' as bridge_tests;
import 'app_service/client_tests.dart' as client_tests;
import 'app_service/model_tests.dart' as model_tests;
import 'app_service/supervisor_tests.dart' as supervisor_tests;
import 'app_service/transport_tests.dart' as transport_tests;

void main() {
  transport_tests.main();
  model_tests.main();
  client_tests.main();
  supervisor_tests.main();
  bridge_tests.main();
}
