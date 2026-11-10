// Run the panel transition regressions on a native Flutter runtime.
// Fixtures are in-memory: no Firebase connection or inventory writes.
import 'package:integration_test/integration_test.dart';

import '../test/catalog/panel_transition_test.dart' as panel_transitions;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  panel_transitions.main();
}
