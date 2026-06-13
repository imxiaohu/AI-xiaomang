// Widget 回归测试：TripoModelViewer 在不同 state 下渲染正确的 UI 元素
//
// 修 bug #1：生成成功时 modelUrl 必须是带 scheme 的绝对 URL
// 修 bug #2：市场选用后 modelUrl 仍然要渲染（不再退回 Ai3DBall）
// 新增功能：取消按钮 + 下载 GLB 按钮
//
// 注意：model_viewer_plus 在 widget test 中无法实际加载 WebView（需要
// WebViewPlatform mock），所以本测试只覆盖**不会**触发 ModelViewer.build() 的场景。
// 涉及 modelUrl != null 的 case 由 AppState 单元测试覆盖（见
// test/providers/app_state_active_glb_url_test.dart）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video/widgets/tripo_model_viewer.dart';

void main() {
  Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('空状态：modelUrl=null + isGenerating=false → 不显示任何按钮',
      (tester) async {
    await tester.pumpWidget(_wrap(const TripoModelViewer()));
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
  });

  testWidgets('isGenerating=true + canCancel=true + onCancel 存在 → 显示取消按钮',
      (tester) async {
    await tester.pumpWidget(_wrap(TripoModelViewer(
      isGenerating: true,
      canCancel: true,
      onCancel: () {},
    )));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('isGenerating=true + canCancel=false → 不显示取消按钮',
      (tester) async {
    await tester.pumpWidget(_wrap(TripoModelViewer(
      isGenerating: true,
      canCancel: false,
      onCancel: () {},
    )));
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('isGenerating=true + onCancel 为 null → 不显示取消按钮',
      (tester) async {
    await tester.pumpWidget(_wrap(const TripoModelViewer(
      isGenerating: true,
      canCancel: true,
      // onCancel 缺省
    )));
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('点击取消按钮 → 调用 onCancel', (tester) async {
    int cancelCount = 0;
    await tester.pumpWidget(_wrap(TripoModelViewer(
      isGenerating: true,
      canCancel: true,
      onCancel: () => cancelCount++,
    )));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(cancelCount, 1);
  });
}
