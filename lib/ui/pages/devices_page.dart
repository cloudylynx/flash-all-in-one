import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/android_device.dart';
import '../theme/app_theme.dart';
import '../../services/device_provider.dart';
import '../../services/ios_service.dart';
import '../widgets/common.dart';

/// 设备列表页
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<IosDevice> _iosDevices = [];
  bool _iosScanning = false;
  bool _iosSupported = false;

  @override
  void initState() {
    super.initState();
    _scanIos();
  }

  Future<void> _scanIos() async {
    setState(() {
      _iosScanning = true;
      _iosSupported = !Platform.isWindows;
    });

    if (Platform.isWindows) {
      setState(() => _iosScanning = false);
      return;
    }

    try {
      final devices = await IosService.instance.listDevices();
      if (!mounted) return;
      setState(() => _iosDevices = devices);
    } catch (_) {
      if (!mounted) return;
      setState(() => _iosDevices = []);
    } finally {
      if (mounted) setState(() => _iosScanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();

    final hasAndroid = dp.devices.isNotEmpty;
    final hasIos = _iosDevices.isNotEmpty;

    // 两个系统都没有
    if (!hasAndroid && !hasIos) {
      return EmptyState(
        icon: Icons.usb_off,
        title: '未检测到设备',
        subtitle: '请用 USB 连接设备：\n'
            '· Android：开启「USB 调试」\n'
            '· iOS：信任此电脑（需要 libimobiledevice）',
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                dp.refresh();
                _scanIos();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新扫描'),
            ),
          ],
        ),
      );
    }

    if (!dp.adbReady && !hasIos) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'adb 未就绪',
        subtitle: dp.error ?? '请检查 adb 是否安装',
        action: ElevatedButton.icon(
          onPressed: () => dp.restartAdb(),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重试'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        // ═══ Android 设备 ═══
        if (hasAndroid) ...[
          _sectionHeader('Android 设备', dp.devices.length),
          const SizedBox(height: 10),
          for (final d in dp.devices) ...[
            _DeviceCard(
              device: d,
              selected: d.serial == dp.selectedSerial,
              onTap: () => dp.selectDevice(d.serial),
            ),
            const SizedBox(height: 10),
          ],
        ],

        // ═══ iOS 设备 ═══
        if (_iosSupported && (_iosDevices.isNotEmpty || _iosScanning)) ...[
          const SizedBox(height: 10),
          _sectionHeader('iOS 设备', _iosDevices.length),
          const SizedBox(height: 10),
          if (_iosScanning)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child:
                          CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('正在扫描 iOS 设备…',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textMuted)),
                ],
              ),
            ),
          for (final ios in _iosDevices) ...[
            _IosDeviceCard(device: ios),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('$count',
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }
}

/// iOS 设备卡片
class _IosDeviceCard extends StatelessWidget {
  final IosDevice device;

  const _IosDeviceCard({required this.device});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // 点击跳转到 iOS 设备管理页
        // 通过导航回调（main_shell 提供）
        // 这里用最简单的：提示用户去 iOS 页面
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${device.name} — 请在左侧「iOS 设备管理」查看详情'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppTheme.bgElevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                device.mode == 'recovery' || device.mode == 'dfu'
                    ? Icons.build_circle_outlined
                    : Icons.phone_iphone,
                size: 22,
                color: device.mode == 'normal'
                    ? AppTheme.success
                    : AppTheme.warning,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name,
                      style: const TextStyle(
                          fontSize: 14.5, color: AppTheme.textPrimary)),
                  const SizedBox(height: 3),
                  Text(
                    '${device.model} · iOS ${device.iosVersion}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 3),
                  Text(device.udid,
                      style: const TextStyle(
                          fontSize: 9.5,
                          fontFamily: 'monospace',
                          color: AppTheme.textMuted),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (device.mode == 'normal'
                        ? AppTheme.success
                        : AppTheme.warning)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                device.mode == 'normal'
                    ? '已连接'
                    : (device.mode == 'recovery' ? '恢复模式' : 'DFU'),
                style: TextStyle(
                    fontSize: 10,
                    color: device.mode == 'normal'
                        ? AppTheme.success
                        : AppTheme.warning),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatefulWidget {
  final AndroidDevice device;
  final bool selected;
  final VoidCallback onTap;

  const _DeviceCard({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
  bool _hover = false;

  Color get _stateColor {
    switch (widget.device.state) {
      case 'device':
        return AppTheme.success;
      case 'unauthorized':
        return AppTheme.warning;
      case 'offline':
        return AppTheme.danger;
      default:
        return AppTheme.textMuted;
    }
  }

  String get _stateLabel {
    switch (widget.device.state) {
      case 'device':
        return '已连接';
      case 'unauthorized':
        return '未授权';
      case 'offline':
        return '离线';
      case 'bootloader':
        return 'Fastboot';
      case 'recovery':
        return 'Recovery';
      default:
        return widget.device.state;
    }
  }

  IconData get _deviceIcon {
    if (widget.device.isEmulator) return Icons.desktop_windows;
    return Icons.smartphone;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppTheme.primary.withValues(alpha: 0.08)
                : (_hover ? AppTheme.bgHover : AppTheme.bgSurface),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? AppTheme.primary.withValues(alpha: 0.5)
                  : AppTheme.border,
            ),
          ),
          child: Row(
            children: [
              // 图标
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppTheme.bgElevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_deviceIcon,
                    size: 22, color: AppTheme.textSecondary),
              ),
              const SizedBox(width: 14),

              // 主要信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          d.displayName,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        StatusDot(color: _stateColor, pulse: d.isReady),
                        const SizedBox(width: 5),
                        Text(
                          _stateLabel,
                          style: TextStyle(fontSize: 11.5, color: _stateColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d.subtitle.isNotEmpty ? d.subtitle : d.serial,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                    if (d.screenResolution != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${d.screenResolution} · ${d.screenDensity ?? "?"} dpi'
                        '${d.isRooted == true ? " · 已 root" : ""}',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted),
                      ),
                    ],
                  ],
                ),
              ),

              // 右侧信息
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    d.serial,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.bgElevated,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      d.connectionType.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textMuted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
