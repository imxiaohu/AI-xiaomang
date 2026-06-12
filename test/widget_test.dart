import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video/main.dart';

void main() {
  testWidgets('AIVideoApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AIVideoApp());
    expect(find.text('按住麦克风提问'), findsOneWidget);
  });
}
