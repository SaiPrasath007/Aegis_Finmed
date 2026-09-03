import 'package:flutter_test/flutter_test.dart';
import 'package:ble_test_app/main.dart';

void main() {
  testWidgets('BleGatewayApp smoke test', (WidgetTester tester) async {
    // Build app and render initial frame
    await tester.pumpWidget(const BleGatewayApp());

    // Verify Title and core components are present
    expect(find.text('AgeisLink Edge Gateway'), findsOneWidget);
    expect(find.text('8.4 KB Crash Data Buffer'), findsOneWidget);
    expect(find.text('GPS Position Acquisition'), findsOneWidget);
    expect(find.text('Mock Backend Dispatch (HTTP POST)'), findsOneWidget);
  });
}
