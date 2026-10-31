import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ios_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// iOS 设备管理
class IosPage extends StatefulWidget {
  const IosPage({super.key});

  @override
  State<IosPage> createState() => _IosPageState();
}

class _IosPageState extends State<IosPage> {
  bool _ready = false;
  String? _version;
  String? _palera1nVer;
  bool _usbmuxdOk = false;
  bool _busy = false;
  String? _ipswPath;

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
    final ok = await IosService.instance.init();
    final ver = await IosService.instance.version();
    final pv = await IosService.instance.palera1nVersion();
    final muxd = await IosService.instance.isUsbmuxdRunning();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _version = ver;
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
    if (Platform.isWindows) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Text(
            'iOS 工具目前仅支持 Linux\n\n'
            'Windows 用户请用 iTunes 或 3uTools',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: AppTheme.textMuted, height: 1.7),
          ),
        ),
      );
    }

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
                    color: (_ready ? AppTheme.success : AppTheme.danger)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(_ready ? Icons.check_circle : Icons.error,
                          size: 15,
                          color:
                              _ready ? AppTheme.success : AppTheme.danger),
                      const SizedBox(width: 8),
                      Text(
                        _ready
                            ? 'libimobiledevice + idevicerestore $_version'
                            : 'iOS 工具未就绪',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 说明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.25)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('iOS 设备管理',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary)),
                      SizedBox(height: 8),
                      Text(
                        '基于 libimobiledevice（8300★，LGPL-2.1）\n'
                        '和 idevicerestore（2001★，LGPL-3.0）\n\n'
                        '能做：读设备信息 / 刷 IPSW / 进恢复模式 /\n'
                        '     备份 / 看日志 / 截图 / 诊断',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 设备信息
                AppCard(
                  title: '设备信息',
                  child: Column(
                    children: [
                      _action(Icons.info_outline, '读取设备信息', 'ideviceinfo',
                          () => _run(() => IosService.instance
                              .readInfo(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.monitor_heart, '诊断信息', 'idevicediagnostics',
                          () => _run(() => IosService.instance
                              .diagnostics(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.camera_alt, '截图', 'idevicescreenshot',
                          () => _run(() => IosService.instance.screenshot(
                              outputPath: '/tmp/ios-screenshot.png',
                              onLine: _addLog))),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 刷机
                AppCard(
                  title: '刷写 IPSW 固件',
                  trailing: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final r = await FilePicker.platform.pickFiles(
                              dialogTitle: '选择 IPSW 固件',
                              type: FileType.any,
                            );
                            if (r != null && r.files.single.path != null) {
                              setState(() => _ipswPath = r.files.single.path);
                            }
                          },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                    child:
                        const Text('选择', style: TextStyle(fontSize: 11.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _ipswPath?.split(Platform.pathSeparator).last ??
                            '未选择 .ipsw 固件',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: _ipswPath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_ipswPath != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
                                          final ok = await _confirm(
                                              '升级（保留数据）',
                                              '会保留用户数据，但建议先备份。');
                                          if (ok != true) {
                                            return IosResult(
                                                false, '已取消', []);
                                          }
                                          return IosService.instance.flashIpsw(
                                            ipswPath: _ipswPath!,
                                            erase: false,
                                            confirmed: true,
                                            onLine: _addLog,
                                          );
                                        }),
                                child: const Text('升级（保留数据）',
                                    style: TextStyle(fontSize: 11)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
                                          final ok = await _confirm(
                                              '全新刷机（清空数据）',
                                              '会清空设备所有数据！请先备份。\n\n此操作不可逆。');
                                          if (ok != true) {
                                            return IosResult(
                                                false, '已取消', []);
                                          }
                                          return IosService.instance.flashIpsw(
                                            ipswPath: _ipswPath!,
                                            erase: true,
                                            confirmed: true,
                                            onLine: _addLog,
                                          );
                                        }),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.danger,
                                ),
                                child: const Text('全新刷机',
                                    style: TextStyle(fontSize: 11)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 其他操作
                AppCard(
                  title: '其他操作',
                  child: Column(
                    children: [
                      _action(Icons.restart_alt, '进入恢复模式',
                          'ideviceenterrecovery',
                          () => _run(() => IosService.instance
                              .enterRecovery(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.backup, '备份设备', 'idevicebackup2',
                          () => _run(() => IosService.instance.backup(
                              outputDir: '/tmp/ios-backup',
                              onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.article, '系统日志', 'idevicesyslog',
                          () => _run(() => IosService.instance
                              .syslog(onLine: _addLog))),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ 越狱（palera1n）═══
                AppCard(
                  title: '越狱（palera1n）',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (_palera1nVer != null
                              ? AppTheme.success
                              : AppTheme.danger)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _palera1nVer != null ? 'v$_palera1nVer' : '未就绪',
                      style: TextStyle(
                          fontSize: 9,
                          color: _palera1nVer != null
                              ? AppTheme.success
                              : AppTheme.danger),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // usbmuxd 状态
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: (_usbmuxdOk
                                  ? AppTheme.success
                                  : AppTheme.warning)
                              .withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _usbmuxdOk
                                  ? Icons.check_circle
                                  : Icons.warning_amber,
                              size: 13,
                              color: _usbmuxdOk
                                  ? AppTheme.success
                                  : AppTheme.warning,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _usbmuxdOk
                                    ? 'usbmuxd 运行中'
                                    : 'usbmuxd 未运行（越狱时会自动尝试启动）',
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppTheme.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 支持设备
                      const Text('支持的设备',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary)),
                      const SizedBox(height: 6),
                      for (final d in IosService.supportedDevices)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                child: Text(d['chip']!,
                                    style: const TextStyle(
                                        fontSize: 10.5,
                                        fontFamily: 'monospace',
                                        color: AppTheme.accent)),
                              ),
                              Expanded(
                                child: Text(
                                  d['models']!,
                                  style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppTheme.textSecondary),
                                ),
                              ),
                              Text(
                                d['support']!,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: d['support']!.startsWith('✅')
                                        ? AppTheme.success
                                        : AppTheme.danger),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 14),

                      // 操作
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
                                '⚠️ 越狱后部分银行 App 可能无法使用\n'
                                '⚠️ 仅支持 A8-A11 设备（iPhone 6s~X）\n'
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

                // 其他越狱工具（外链）
                AppCard(
                  title: '其他越狱工具',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'palera1n 只支持 A8-A11。以下工具支持更新的设备：',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                            height: 1.6),
                      ),
                      const SizedBox(height: 12),
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
