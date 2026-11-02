import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';
import '../../services/device_provider.dart';
import '../../services/windows_tweak_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/disclaimer_gate.dart';

/// 设置
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _autoRefresh = true;
  int _refreshInterval = 3;
  bool _disclaimerAccepted = false;
  String? _adbPath;
  String? _fastbootPath;
  String _adbVersion = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = await DisclaimerGate.isAccepted();
    final adb = await AppConfig.adbPath();
    final fb = await AppConfig.fastbootPath();

    String ver = '';
    try {
      final r = await Process.run(adb, ['version']);
      final m = RegExp(r'Android Debug Bridge version ([\d.]+)')
          .firstMatch(r.stdout as String);
      if (m != null) ver = m.group(1)!;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _autoRefresh = prefs.getBool('auto_refresh') ?? true;
      _refreshInterval = prefs.getInt('refresh_interval') ?? 3;
      _disclaimerAccepted = accepted;
      _adbPath = adb;
      _fastbootPath = fb;
      _adbVersion = ver;
    });
  }

  Future<void> _savePref(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is int) await prefs.setInt(key, value);
    if (value is String) await prefs.setString(key, value);
  }

  Future<void> _resetDisclaimer() async {
    await DisclaimerGate.reset();
    if (!mounted) return;
    setState(() => _disclaimerAccepted = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('协议确认已重置，下次进入高级功能需重新确认')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 关于
          AppCard(
            title: '关于',
            child: Column(
              children: [
                const InfoRow(label: '名称', value: AppConfig.appName),
                const InfoRow(label: '版本', value: AppConfig.appVersion),
                InfoRow(
                    label: '平台',
                    value:
                        '${Platform.operatingSystem} ${Platform.version.split(" ").first}'),
                InfoRow(label: 'Dart', value: Platform.version),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 工具路径
          AppCard(
            title: '内置工具',
            trailing: IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              color: AppTheme.textSecondary,
              visualDensity: VisualDensity.compact,
              onPressed: _load,
            ),
            child: Column(
              children: [
                InfoRow(
                  label: 'adb',
                  value: _adbPath != null
                      ? '${_adbPath!.split(Platform.pathSeparator).last}'
                          '${_adbVersion.isNotEmpty ? " ($_adbVersion)" : ""}'
                      : '未找到',
                  monospace: true,
                ),
                InfoRow(
                  label: 'fastboot',
                  value: _fastbootPath?.split(Platform.pathSeparator).last ??
                      '未找到',
                  monospace: true,
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.bgElevated,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '工具会自动从 assets 提取到应用数据目录，\n'
                    '也可以手动放到应用目录的 tools/ 下覆盖。',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.textMuted,
                        height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 设备刷新
          AppCard(
            title: '设备刷新',
            child: Column(
              children: [
                SwitchListTile(
                  dense: true,
                  value: _autoRefresh,
                  onChanged: (v) {
                    setState(() => _autoRefresh = v);
                    _savePref('auto_refresh', v);
                    dp.setAutoRefresh(v);
                  },
                  title: const Text('自动刷新设备列表',
                      style: TextStyle(fontSize: 12.5)),
                  contentPadding: EdgeInsets.zero,
                ),
                Row(
                  children: [
                    const SizedBox(
                      width: 110,
                      child: Text('刷新间隔',
                          style: TextStyle(
                              fontSize: 12.5, color: AppTheme.textSecondary)),
                    ),
                    Expanded(
                      child: Slider(
                        value: _refreshInterval.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        label: '$_refreshInterval 秒',
                        onChanged: _autoRefresh
                            ? (v) {
                                setState(
                                    () => _refreshInterval = v.round());
                                _savePref('refresh_interval', v.round());
                                dp.setRefreshInterval(v.round());
                              }
                            : null,
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text('$_refreshInterval 秒',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textPrimary)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 安全
          AppCard(
            title: '安全与协议',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      _disclaimerAccepted
                          ? Icons.verified_user
                          : Icons.shield_outlined,
                      size: 18,
                      color: _disclaimerAccepted
                          ? AppTheme.success
                          : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _disclaimerAccepted
                            ? '高级功能协议：已确认'
                            : '高级功能协议：未确认',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _disclaimerAccepted
                              ? AppTheme.success
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    if (_disclaimerAccepted)
                      OutlinedButton(
                        onPressed: _resetDisclaimer,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                        ),
                        child: const Text('重置',
                            style: TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppTheme.warning.withValues(alpha: 0.25)),
                  ),
                  child: const Text(
                    '高级功能包含 Bootloader 解锁、分区读写、EDL 刷机等操作，\n'
                    '可能导致设备变砖或数据永久丢失。\n'
                    '首次进入需完整阅读并输入确认短语。',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                        height: 1.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 快捷操作
          AppCard(
            title: '快捷操作',
            child: Column(
              children: [
                _actionRow(
                  icon: Icons.restart_alt,
                  label: '重启 adb 服务',
                  desc: '杀掉 adb server 并重启',
                  onTap: () async {
                    await dp.restartAdb();
                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('adb 服务已重启')),
                    );
                  },
                ),
                _actionRow(
                  icon: Icons.cleaning_services,
                  label: '清理工具缓存',
                  desc: '删除提取的工具，下次启动重新提取',
                  onTap: () async {
                    final dir = await AppConfig.toolPath('adb');
                    final toolsDir = File(dir).parent;
                    if (toolsDir.existsSync()) {
                      try {
                        toolsDir.deleteSync(recursive: true);
                      } catch (_) {}
                    }
                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('已清理，重启应用后重新提取')),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // USB 连接修复（仅 Windows 主机）
          if (Platform.isWindows) ...[
            AppCard(
              title: 'USB 连接',
              child: Column(
                children: [
                  _actionRow(
                    icon: Icons.usb_off,
                    label: '修复 USB 3.0 连接不稳',
                    desc: '手机插 USB3 口时 adb/fastboot 频繁断连时用',
                    onTap: () => _fixUsb3(),
                  ),
                  _actionRow(
                    icon: Icons.undo,
                    label: '撤销 USB 3.0 修复',
                    desc: '删除上面写入的三条 usbflags 注册表',
                    onTap: () => _undoUsb3(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // 数据源致谢
          AppCard(
            title: '数据来源与致谢',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (name, desc, star) in [
                  ('bkerler/mtkclient', 'MTK 刷机内核', '1402★'),
                  ('bkerler/edl', '高通 EDL 协议', '2669★'),
                  ('R0rt1z2/lkpatcher', 'LK 镜像补丁', '406★'),
                  ('kitsuned/PotatoNV', '华为麒麟解锁', '1701★'),
                  ('Maikyxd/val-protocol', '摩托罗拉解锁', '96★'),
                  ('zenfyrdev/wall-of-shame', '解锁可行性数据', '5613★'),
                  ('AdaUnlocked/2026-BL-Status', '全网解锁现状', '583★'),
                  ('MlgmXyysd/HyperOS-Bypass', '小米机型状态', '4813★'),
                  ('Genymobile/scrcpy', '投屏引擎', '10万+★'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.favorite,
                            size: 10, color: AppTheme.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: AppTheme.textPrimary),
                          ),
                        ),
                        Text(desc,
                            style: const TextStyle(
                                fontSize: 10.5, color: AppTheme.textMuted)),
                        const SizedBox(width: 10),
                        Text(star,
                            style: const TextStyle(
                                fontSize: 10.5, color: AppTheme.warning)),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                const Text(
                  '本软件以开源协议发布，感谢以上项目作者的无私贡献。',
                  style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 修复 USB 3.0 连接不稳
  Future<void> _fixUsb3() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修复 USB 3.0 连接不稳'),
        content: const Text(
          '会往注册表写三条 USB 标志位，让 Windows 跳过对 Android 设备的\n'
          'BOS 描述符和容器 ID 查询。\n\n'
          '适用于：手机插 USB3 口时 adb/fastboot 频繁断连、识别不到。\n\n'
          '随时可以用下面的「撤销」恢复。',
          style: TextStyle(fontSize: 12.5, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用')),
        ],
      ),
    );
    if (ok != true) return;

    final r = await WindowsTweakService.instance.fixUsb3Stability();
    if (!mounted) return;

    // 详细日志用弹窗展示
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.ok ? '✅ ${r.message}' : '❌ ${r.message}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              r.log.join('\n'),
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了')),
        ],
      ),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text(r.ok
            ? '已应用，请拔插 USB 线让设备重新枚举'
            : '失败：${r.message}'),
      ),
    );
  }

  /// 撤销 USB 3.0 修复
  Future<void> _undoUsb3() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销 USB 3.0 修复'),
        content: const Text('会删除之前写入的三条 usbflags 注册表值。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true) return;

    final r = await WindowsTweakService.instance.undoUsb3Fix();
    if (!mounted) return;
    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(content: Text(r.ok ? '✅ ${r.message}' : '❌ ${r.message}')),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required String desc,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12.5, color: AppTheme.textPrimary)),
                  Text(desc,
                      style: const TextStyle(
                          fontSize: 10.5, color: AppTheme.textMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 16, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }
}
