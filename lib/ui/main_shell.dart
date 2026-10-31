import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../services/device_provider.dart';
import 'pages/apk_page.dart';
import 'pages/apps_page.dart';
import 'pages/batch_page.dart';
import 'pages/bl_unlock_page.dart';
import 'pages/devices_page.dart';
import 'pages/debloat_page.dart';
import 'pages/diagnose_page.dart';
import 'pages/edl_page.dart';
import 'pages/fastboot_page.dart';
import 'pages/files_page.dart';
import 'pages/install_page.dart';
import 'pages/logcat_page.dart';
import 'pages/mtk_page.dart';
import 'pages/overview_page.dart';
import 'pages/partitions_page.dart';
import 'pages/perfetto_page.dart';
import 'pages/imgtool_page.dart';
import 'pages/root_page.dart';
import 'pages/scripts_page.dart';
import 'pages/device_screen_page.dart';
import 'pages/settings_page.dart';
import 'pages/shell_page.dart';
import 'pages/vendor_page.dart';
import 'pages/wireless_page.dart';
import 'theme/app_theme.dart';
import 'widgets/common.dart';
import 'widgets/disclaimer_gate.dart';
import 'widgets/side_nav.dart';

/// 主框架
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  String _selected = 'overview';
  /// 是否已通过高级功能协议
  bool _advancedUnlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DeviceProvider>().init();
    });
    // 测试用：通过环境变量指定初始页面
    final page = Platform.environment['GAOJI_PAGE'];
    if (page != null && page.isNotEmpty) {
      _selected = page;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();

    return Scaffold(
      backgroundColor: AppTheme.bgDeep,
      body: Row(
        children: [
          SideNav(
            selected: _selected,
            onSelect: _handleSelect,
            adbVersion: dp.adbVersion ?? '',
            deviceCount: dp.devices.length,
          ),
          Expanded(
            child: Column(
              children: [
                _TopBar(title: _titleFor(_selected)),
                Expanded(child: _buildPage(_selected)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 导航选择处理
  ///
  /// 高级功能需要先通过协议确认门
  Future<void> _handleSelect(String id) async {
    if (!SideNav.isAdvanced(id) || _advancedUnlocked) {
      setState(() => _selected = id);
      return;
    }

    // 检查是否已接受过协议
    final accepted = await DisclaimerGate.isAccepted();
    if (!mounted) return;

    if (accepted) {
      setState(() {
        _advancedUnlocked = true;
        _selected = id;
      });
      return;
    }

    // 显示协议确认门
    setState(() => _selected = '__disclaimer__');
  }

  String _titleFor(String id) {
    if (id == '__disclaimer__') return '高级功能 · 风险告知';
    for (final item in SideNav.items) {
      if (item.id == id) return item.label;
    }
    return AppConfig.appName;
  }

  Widget _buildPage(String id) {
    // 协议确认门
    if (id == '__disclaimer__') {
      return DisclaimerGate(
        onAccepted: () {
          setState(() {
            _advancedUnlocked = true;
            // 返回到设备总览（用户需重新点击高级功能）
            _selected = 'overview';
          });
        },
      );
    }

    switch (id) {
      case 'overview':
        return const OverviewPage();
      case 'devices':
        return const DevicesPage(); // 兼容旧 id
      case 'device_info':
      case 'system':
        return const OverviewPage(); // 兼容旧 id
      case 'screen':
        return const DeviceScreenPage();
      case 'scrcpy':
        // 兼容旧 id，默认打开投屏 Tab
        return const DeviceScreenPage(initialTab: 1);
      case 'shell':
        return const ShellPage();
      case 'wireless':
        return const WirelessPage();
      case 'apps':
        return const AppsPage();
      case 'install':
        return const InstallPage();
      case 'apk':
        return const ApkPage();
      case 'app_detail':
        return const AppsPage(); // 兼容旧 id
      case 'debloat':
        return const DebloatPage();
      case 'batch':
        return const BatchPage();
      case 'root':
        return const RootPage();
      case 'imgtool':
        return const ImgtoolPage();
      case 'files':
        return const FilesPage();
      case 'fastboot':
        return const FastbootPage();
      case 'edl':
        return const EdlPage();
      case 'mtk':
        return const MtkPage();
      case 'vendor':
        return const VendorPage();
      case 'partitions':
        return const PartitionsPage();
      case 'bl_unlock':
        return const BlUnlockPage();
      case 'diagnose':
        return const DiagnosePage();
      case 'perfetto':
        return const PerfettoPage();
      case 'logcat':
        return const LogcatPage();
      case 'scripts':
        return const ScriptsPage();
      case 'settings':
        return const SettingsPage();
      default:
        return const OverviewPage();
    }
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  const _TopBar({required this.title});

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();
    final device = dp.selectedDevice;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: AppTheme.bgSurface,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const Spacer(),
          if (device != null) ...[
            StatusDot(
                color: device.isReady ? AppTheme.success : AppTheme.warning),
            const SizedBox(width: 7),
            Text(
              device.displayName,
              style: const TextStyle(
                  fontSize: 11.5, color: AppTheme.textSecondary),
            ),
            const SizedBox(width: 16),
          ],
          Text(
            '${dp.devices.length} 台设备',
            style:
                const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
