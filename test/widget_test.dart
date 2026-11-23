import 'package:anker_recorder/main.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('doumic boots to standalone mic home', (tester) async {
    final controller = RecorderController();
    await tester.pumpWidget(DouMicApp(controller: controller));
    await tester.pump();

    expect(find.text('豆麦'), findsWidgets);
    expect(find.textContaining('系统虚拟麦克风'), findsOneWidget);
    expect(find.text('首页'), findsNothing);
    expect(find.text('设置'), findsNothing);
  });
}
