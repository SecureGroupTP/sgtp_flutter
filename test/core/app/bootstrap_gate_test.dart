import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sgtp_flutter/core/app/bootstrap_gate.dart';

void main() {
  testWidgets('shows startup failure instead of a blank window', (
    tester,
  ) async {
    await tester.pumpWidget(
      BootstrapGate(
        bootstrap: () => Future.error(StateError('native asset missing')),
        appBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pump();

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.textContaining('native asset missing'), findsOneWidget);
  });
}
