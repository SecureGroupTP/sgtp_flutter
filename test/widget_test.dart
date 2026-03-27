import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SgtpApp());
    expect(find.text('SGTP Chat'), findsWidgets);
  });
}
