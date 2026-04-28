import 'package:flutter_test/flutter_test.dart';

import 'package:sgtp_flutter/core/app/app_runner.dart';

void main() {
  test('registers push background handling before running the app', () async {
    final calls = <String>[];

    await runSgtpApp(
      ensureBinding: () => calls.add('binding'),
      configurePushBackgroundHandling: () async {
        calls.add('push');
      },
      runApp: () => calls.add('runApp'),
    );

    expect(calls, <String>['binding', 'push', 'runApp']);
  });
}
