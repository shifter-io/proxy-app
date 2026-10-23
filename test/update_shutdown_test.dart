import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/proxy/proxy_engine.dart';
import 'package:shifter_app/state/app_controller.dart';

class FailingEngine extends MockProxyEngine {
  FailingEngine() : super(delay: Duration.zero);
  bool fail = false;
  int starts = 0;
  @override
  Future<void> clear() async {
    if (fail) throw StateError('restore failed');
  }

  @override
  Future<void> apply(GatewayEndpoint endpoint) async {
    starts++;
    await super.apply(endpoint);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed shutdown propagates and gate releases without installer handoff',
    () async {
      final engine = FailingEngine();
      final app = AppController(engine: engine);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      engine.fail = true;
      var handedOff = false;
      await expectLater(
        app.prepareForUpdate(() async {
          handedOff = true;
        }),
        throwsStateError,
      );
      expect(handedOff, isFalse);
      expect(app.updatePreparing, isFalse);
      await expectLater(app.shutdown(), throwsStateError);
      engine.fail = false;
      app.dispose();
    },
  );
  test('connection gate remains held until the handoff finishes', () async {
    final engine = FailingEngine();
    final app = AppController(engine: engine);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final pending = Completer<void>();
    final prepare = app.prepareForUpdate(() => pending.future);
    await Future<void>.delayed(Duration.zero);
    expect(app.updatePreparing, isTrue);
    expect(app.canConnect, isFalse);
    await app.connect();
    expect(engine.starts, 0);
    pending.complete();
    await prepare;
    expect(app.updatePreparing, isFalse);
    app.dispose();
  });
}
