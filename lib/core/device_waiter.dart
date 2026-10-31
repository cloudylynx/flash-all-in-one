import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/android_device.dart';
import '../services/device_provider.dart';

/// 设备就绪等待器
///
/// 解决的问题：页面的 initState 里读 DeviceProvider 时，
/// 设备列表往往还没加载完（selectedDevice == null），
/// 导致页面卡在"检测中"或空白状态，用户必须手动点刷新。
///
/// 用法：
///   final device = await DeviceWaiter.wait(context);
///   if (device == null) return;
class DeviceWaiter {
  DeviceWaiter._();

  /// 等待设备就绪（最多 [timeout]）
  ///
  /// 返回选中设备，超时返回 null
  static Future<AndroidDevice?> wait(
    BuildContext context, {
    Duration timeout = const Duration(seconds: 8),
    bool Function(AndroidDevice?)? accept,
  }) async {
    if (!context.mounted) return null;

    var device = context.read<DeviceProvider>().selectedDevice;
    if (device != null && (accept == null || accept(device))) {
      return device;
    }

    final steps = (timeout.inMilliseconds / 400).ceil();
    for (var i = 0; i < steps; i++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!context.mounted) return null;
      device = context.read<DeviceProvider>().selectedDevice;
      if (device != null && (accept == null || accept(device))) {
        return device;
      }
    }
    return null;
  }

  /// 在 postFrameCallback 里自动执行（用于 build 中触发一次性检测）
  ///
  /// [key] 用于防重复触发，通常是 `_xxxDone` 布尔字段
  static void autoRun(
    BuildContext context, {
    required bool Function() isDone,
    required VoidCallback markRunning,
    required Future<void> Function() action,
  }) {
    if (isDone()) return;
    markRunning();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await action();
    });
  }
}
