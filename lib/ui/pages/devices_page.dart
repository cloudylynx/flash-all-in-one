import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/android_device.dart';
import '../theme/app_theme.dart';
import '../../services/device_provider.dart';
import '../widgets/common.dart';

/// 设备列表页
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();

    if (!dp.adbReady) {
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

    if (dp.devices.isEmpty) {
      return EmptyState(
        icon: Icons.usb_off,
        title: '未检测到设备',
        subtitle: '请用 USB 连接手机，并在手机上开启「USB 调试」',
        action: OutlinedButton.icon(
          onPressed: () => dp.refresh(),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重新扫描'),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(18),
      itemCount: dp.devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final d = dp.devices[i];
        return _DeviceCard(
          device: d,
          selected: d.serial == dp.selectedSerial,
          onTap: () => dp.selectDevice(d.serial),
        );
      },
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
