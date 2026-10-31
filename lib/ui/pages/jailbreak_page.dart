import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ios_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// iOS 越狱
class JailbreakPage extends StatefulWidget {
  const JailbreakPage({super.key});

  @override
  State<JailbreakPage> createState() => _JailbreakPageState();
}

class _JailbreakPageState extends State<JailbreakPage> {
  bool _busy = false;
  String? _palera1nVer;
  bool _usbmuxdOk = false;

  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await IosService.instance.init();
    final pv = await IosService.instance.palera1nVersion();
    final muxd = await IosService.instance.isUsbmuxdRunning();
    if (!mounted) return;
    setState(() {
      _palera1nVer = pv;
      _usbmuxdOk = muxd;
    });
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run(Future<IosResult> Function() action) async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 状态
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_palera1nVer != null
                            ? AppTheme.success
                            : AppTheme.danger)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _palera1nVer != null
                            ? Icons.check_circle
                            : Icons.error,
                        size: 15,
                        color: _palera1nVer != null
                            ? AppTheme.success
                            : AppTheme.danger,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _palera1nVer != null
                            ? 'palera1n v$_palera1nVer'
                            : 'palera1n 未就绪',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                      const Spacer(),
                      // usbmuxd 状态
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (_usbmuxdOk
                                  ? AppTheme.success
                                  : AppTheme.warning)
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _usbmuxdOk ? 'usbmuxd ✓' : 'usbmuxd ✗',
                          style: TextStyle(
                              fontSize: 9,
                              color: _usbmuxdOk
                                  ? AppTheme.success
                                  : AppTheme.warning),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 警告
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.25)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber,
                              size: 15, color: AppTheme.danger),
                          SizedBox(width: 6),
                          Text('越狱前必读',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.danger)),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '· 越狱会使保修失效\n'
                        '· 银行 App / Apple Pay 可能无法使用\n'
                        '· 部分游戏反作弊会拒绝运行\n'
                        '· 操作不当可能导致设备无法启动\n'
                        '· 请先完整备份设备数据',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 支持设备
                AppCard(
                  title: 'palera1n 支持的设备',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('checkm8',
                        style: TextStyle(
                            fontSize: 9, color: AppTheme.accent)),
                  ),
                  child: Column(
                    children: [
                      for (final d in IosService.supportedDevices)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                child: Text(d['chip']!,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                        color: AppTheme.accent)),
                              ),
                              Expanded(
                                child: Text(
                                  d['models']!,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textSecondary),
                                ),
                              ),
                              Text(
                                d['support']!,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: d['support']!.startsWith('✅')
                                        ? AppTheme.success
                                        : AppTheme.danger),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // palera1n 操作
                AppCard(
                  title: 'palera1n 操作',
                  child: Column(
                    children: [
                      _action(Icons.info_outline, '读设备信息（含 DFU）',
                          'palera1n -I',
                          () => _run(() => IosService.instance
                              .deviceInfoJailbreak(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.usb, '进入 DFU 模式', 'palera1n -D',
                          () => _run(() => IosService.instance
                              .enterDfu(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.lock_open, '执行越狱（rootless）',
                          'palera1n -l', () => _run(() async {
                            final ok = await _confirm(
                                '执行越狱',
                                '将对设备执行 palera1n 越狱。\n\n'
                                '⚠️ 设备会多次重启，不要断开 USB\n'
                                '⚠️ 仅支持 A8-A11（iPhone 6s~X）\n'
                                '⚠️ iOS 15.0+');
                            if (ok != true) {
                              return IosResult(false, '已取消', []);
                            }
                            return IosService.instance.jailbreak(
                              confirmed: true,
                              onLine: _addLog,
                            );
                          })),
                      const Divider(height: 16),
                      _action(Icons.exit_to_app, '退出恢复模式', 'palera1n -n',
                          () => _run(() => IosService.instance
                              .exitRecovery(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.delete_forever, '移除越狱',
                          'palera1n --force-revert', () => _run(() async {
                            final ok = await _confirm('移除越狱',
                                '会清除 fakefs 和越狱环境，恢复原状。');
                            if (ok != true) {
                              return IosResult(false, '已取消', []);
                            }
                            return IosService.instance.removeJailbreak(
                              confirmed: true,
                              onLine: _addLog,
                            );
                          })),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Dopamine
                AppCard(
                  title: 'Dopamine 越狱',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('iOS 15-26',
                        style: TextStyle(
                            fontSize: 9, color: AppTheme.primary)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Dopamine 3.0.12（7147★，MIT）\n\n'
                        'semi-untethered 越狱，支持 A12-A16\n'
                        '（iPhone XS ~ iPhone 14 系列）\n\n'
                        '需要先安装到设备上，在设备上运行',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                      const SizedBox(height: 12),
                      _action(Icons.install_mobile, '安装 Dopamine 到设备',
                          '推送 IPA 并安装',
                          () => _run(() async {
                                final devices =
                                    await IosService.instance.listDevices();
                                if (devices.isEmpty) {
                                  _addLog('❌ 未检测到 iOS 设备');
                                  return IosResult(
                                      false, '未检测到设备', []);
                                }
                                return IosService.instance.installDopamine(
                                  udid: devices.first.udid,
                                  onLine: _addLog,
                                );
                              })),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Windows 越狱
                if (Platform.isWindows)
                  AppCard(
                    title: 'Windows 越狱（checkm8）',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Windows 原生链路：\n\n'
                          '  gaster.exe   → 置入 pwned DFU\n'
                          '  openra1n.exe → 加载 PongoOS\n\n'
                          '⚠️ 需要先用 zadig 装 libusb 驱动',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                              height: 1.7),
                        ),
                        const SizedBox(height: 12),
                        _action(Icons.flash_on, '置入 pwned DFU',
                            'gaster pwn',
                            () => _run(() => IosService.instance
                                .windowsPwnDfu(onLine: _addLog))),
                        const Divider(height: 16),
                        _action(Icons.upload, '加载 PongoOS', 'openra1n',
                            () => _run(() => IosService.instance
                                .windowsLoadPongo(onLine: _addLog))),
                      ],
                    ),
                  ),
                if (Platform.isWindows) const SizedBox(height: 14),

                // 其他工具
                AppCard(
                  title: '其他越狱工具',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final jb in IosService.jailbreakTools)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            onTap: () async {
                              final uri = Uri.parse(jb['url']!);
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri,
                                    mode: LaunchMode.externalApplication);
                              }
                            },
                            child: Row(
                              children: [
                                const Icon(Icons.open_in_new,
                                    size: 12, color: AppTheme.accent),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(jb['name']!,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.textPrimary)),
                                      Text(jb['desc']!,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // 日志
        Container(
          width: 380,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal,
                        size: 15, color: AppTheme.accent),
                    const SizedBox(width: 8),
                    const Text('输出',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 15),
                      color: AppTheme.textMuted,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _log.clear()),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFF0A0C10),
                  child: _log.isEmpty
                      ? const Center(
                          child: Text('等待操作…',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textMuted)))
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(10),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final line = _log[i];
                            Color c = AppTheme.textSecondary;
                            if (line.contains('✅')) c = AppTheme.success;
                            if (line.contains('❌') || line.contains('⚠️')) {
                              c = AppTheme.danger;
                            }
                            if (line.startsWith('══')) c = AppTheme.accent;
                            return SelectableText(line,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: c,
                                    height: 1.45));
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _action(IconData icon, String label, String desc,
      Future<void> Function() onTap) {
    final enabled = !_busy;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon,
                size: 16,
                color: enabled ? AppTheme.primary : AppTheme.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: enabled
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted)),
                  Text(desc,
                      style: const TextStyle(
                          fontSize: 10.5, color: AppTheme.textMuted)),
                ],
              ),
            ),
            if (enabled)
              const Icon(Icons.chevron_right,
                  size: 16, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirm(String title, String warning) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(warning,
            style: const TextStyle(fontSize: 12, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }
}
