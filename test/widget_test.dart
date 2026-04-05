import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sgtp_flutter/core/app/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SgtpApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
