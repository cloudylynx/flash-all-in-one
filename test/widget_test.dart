// 应用级冒烟测试
//
// 原来这里是 Flutter 脚手架的计数器模板（引用不存在的 MyApp），
// 一直编译失败。改成检查真实应用能否构建。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flashallinone/main.dart';
import 'package:flashallinone/services/device_provider.dart';

/// 用 main() 里同样的 Provider 包裹应用
Widget buildApp() {
  return ChangeNotifierProvider(
    create: (_) => DeviceProvider(),
    child: const GaojiApp(),
  );
}

void main() {
  testWidgets('应用能构建出 MaterialApp', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('应用启动不抛异常', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });

  testWidgets('侧栏能渲染出导航项', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump(const Duration(milliseconds: 200));

    // 侧栏应该有「设备总览」这类固定项
    expect(find.textContaining('总览'), findsWidgets);
  });
}
