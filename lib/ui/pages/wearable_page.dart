import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/wearable_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 智能穿戴 / 开发板
class WearablePage extends StatefulWidget {
  const WearablePage({super.key});

  @override
  State<WearablePage> createState() => _WearablePageState();
}

class _WearablePageState extends State<WearablePage> {
  String _platform = 'esp';
  bool _busy = false;
  bool _ready = false;

  String? _espVer;
  String? _arduinoVer;

  // ESP
  final _portController = TextEditingController(text: '/dev/ttyUSB0');
  String _chip = 'esp32';
  String _address = '0x10000';
  int _baud = 460800;
  String? _firmwarePath;

  // Arduino
  String? _sketchPath;

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
    _portController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await WearableService.instance.init();
    final ev = await WearableService.instance.esptoolVersion();
    final av = await WearableService.instance.arduinoVersion();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _espVer = ev;
      _arduinoVer = av;
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

  Future<void> _run(Future<WearableResult> Function() action) async {
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
          child: Column(
            children: [
              // 平台 Tab
              Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    for (final (id, label, sub) in [
                      ('esp', 'ESP32/ESP8266', 'esptool 5.6.0'),
                      ('rpi', '树莓派', 'rpiboot'),
                      ('arduino', 'Arduino', 'arduino-cli'),
                      ('astro', '小米穿戴', 'AstroBox 外链'),
                    ])
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _platform = id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: _platform == id
                                      ? AppTheme.primary
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: _platform == id
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: _platform == id
                                        ? AppTheme.primary
                                        : AppTheme.textSecondary,
                                  ),
                                ),
                                Text(sub,
                                    style: const TextStyle(
                                        fontSize: 9,
                                        color: AppTheme.textMuted)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: _platform == 'esp'
                      ? _buildEsp()
                      : _platform == 'rpi'
                          ? _buildRpi()
                          : _platform == 'arduino'
                              ? _buildArduino()
                              : _buildAstro(),
                ),
              ),
            ],
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

  Widget _buildEsp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (_espVer != null ? AppTheme.success : AppTheme.danger)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(_espVer != null ? Icons.check_circle : Icons.error,
                  size: 15,
                  color:
                      _espVer != null ? AppTheme.success : AppTheme.danger),
              const SizedBox(width: 8),
              Text(
                _espVer != null ? 'esptool $_espVer' : 'esptool 未就绪',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 串口 + 芯片
        AppCard(
          title: '连接设置',
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 70,
                    child: Text('串口',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        hintText: '/dev/ttyUSB0 或 COM3',
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      style: const TextStyle(
                          fontSize: 11.5, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                    width: 70,
                    child: Text('芯片',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _chip,
                      isDense: true,
                      isExpanded: true,
                      underline: const SizedBox(),
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textPrimary),
                      items: [
                        for (final c in WearableService.espChips)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) => setState(() => _chip = v ?? 'esp32'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 检测
        AppCard(
          title: '设备检测',
          child: Column(
            children: [
              _action(Icons.memory, '检测芯片', 'chip-id',
                  () => _run(() => WearableService.instance.espDetectChip(
                      port: _portController.text.trim(), onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.wifi, '读取 MAC', 'read-mac',
                  () => _run(() => WearableService.instance.espReadMac(
                      port: _portController.text.trim(), onLine: _addLog))),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 刷写
        AppCard(
          title: '刷写固件',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final r = await FilePicker.platform.pickFiles(
                      dialogTitle: '选择固件（*.bin）',
                      type: FileType.any,
                    );
                    if (r != null && r.files.single.path != null) {
                      setState(() => _firmwarePath = r.files.single.path);
                    }
                  },
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _firmwarePath?.split(Platform.pathSeparator).last ??
                    '未选择 .bin 固件',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: _firmwarePath != null
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                    width: 70,
                    child: Text('地址',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: TextEditingController(text: _address),
                      onChanged: (v) => _address = v,
                      decoration: const InputDecoration(
                        hintText: '0x10000',
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Text('波特率',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _baud,
                    isDense: true,
                    underline: const SizedBox(),
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.textPrimary),
                    items: const [
                      DropdownMenuItem(value: 115200, child: Text('115200')),
                      DropdownMenuItem(value: 460800, child: Text('460800')),
                      DropdownMenuItem(value: 921600, child: Text('921600')),
                    ],
                    onChanged: (v) => setState(() => _baud = v ?? 460800),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 38,
                child: ElevatedButton.icon(
                  onPressed: (_busy || _firmwarePath == null)
                      ? null
                      : () => _run(() async {
                            final ok = await _confirm('刷写 ESP 固件',
                                '将把 ${_firmwarePath!.split(Platform.pathSeparator).last} 写入 $_chip 的 $_address。\n\n刷错地址或芯片会导致设备无法启动。');
                            if (ok != true) {
                              return WearableResult(false, '已取消', []);
                            }
                            return WearableService.instance.espFlash(
                              port: _portController.text.trim(),
                              chip: _chip,
                              firmwarePath: _firmwarePath!,
                              address: _address,
                              baud: _baud,
                              confirmed: true,
                              onLine: _addLog,
                            );
                          }),
                  icon: const Icon(Icons.flash_on, size: 16),
                  label: const Text('刷写',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 擦除
        AppCard(
          title: '擦除 Flash',
          child: SizedBox(
            height: 36,
            child: OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        final ok = await _confirm('擦除 Flash',
                            '擦除后设备将无法启动，必须先准备好可刷的固件。');
                        if (ok != true) {
                          return WearableResult(false, '已取消', []);
                        }
                        return WearableService.instance.espEraseFlash(
                          port: _portController.text.trim(),
                          chip: _chip,
                          confirmed: true,
                          onLine: _addLog,
                        );
                      }),
              icon: const Icon(Icons.delete_forever, size: 15),
              label: const Text('擦除（危险）',
                  style: TextStyle(fontSize: 11.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRpi() {
    if (Platform.isWindows) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Text(
            'rpiboot 目前仅支持 Linux\n\n'
            'Windows 用户请用官方 rpiboot_setup.exe',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: AppTheme.textMuted, height: 1.7),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('树莓派 USB Boot 模式',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary)),
              SizedBox(height: 8),
              Text(
                'rpiboot 把 bootcode 推送到 Pi 的内存，\n'
                '让 Pi 变成一个 U 盘，然后可以写镜像。\n\n'
                '进入方式：\n'
                '  · eMMC 机型（CM4/Pi5）：按住 boot 键上电\n'
                '  · SD 卡机型：拔掉 SD 卡，USB 连电脑',
                style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textSecondary,
                    height: 1.7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '操作',
          child: _action(Icons.usb, '引导到 U 盘模式', 'rpiboot',
              () => _run(() => WearableService.instance
                  .rpiBootToMassStorage(onLine: _addLog))),
        ),
        const SizedBox(height: 14),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warning.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.warning.withValues(alpha: 0.25)),
          ),
          child: const Text(
            '⚠️ 进入 U 盘模式后，用系统的 dd / balenaEtcher\n'
            '   写镜像，不要在本软件里写。\n\n'
            '   rpiboot 只负责引导，不负责写镜像。',
            style: TextStyle(
                fontSize: 11, color: AppTheme.textSecondary, height: 1.7),
          ),
        ),
      ],
    );
  }

  Widget _buildArduino() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color:
                (_arduinoVer != null ? AppTheme.success : AppTheme.danger)
                    .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                  _arduinoVer != null ? Icons.check_circle : Icons.error,
                  size: 15,
                  color: _arduinoVer != null
                      ? AppTheme.success
                      : AppTheme.danger),
              const SizedBox(width: 8),
              Text(
                _arduinoVer != null
                    ? 'arduino-cli $_arduinoVer'
                    : 'arduino-cli 未就绪',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '检测',
          child: Column(
            children: [
              _action(Icons.usb, '列出板子', 'board list',
                  () => _run(() => WearableService.instance
                      .arduinoListBoards(onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.extension, '已装核心', 'core list',
                  () => _run(() => WearableService.instance
                      .arduinoListCores(onLine: _addLog))),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '编译并上传',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final r = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: '选择 Arduino 草图目录',
                    );
                    if (r != null) setState(() => _sketchPath = r);
                  },
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _sketchPath?.split(Platform.pathSeparator).last ??
                    '未选择草图目录',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: _sketchPath != null
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              const Text(
                '需要先安装对应核心：\n'
                '  arduino-cli core install arduino:avr\n'
                '  arduino-cli core install esp32:esp32',
                style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.6,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAstro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.accent.withValues(alpha: 0.25)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('小米穿戴（Vela 系统）',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accent)),
              SizedBox(height: 8),
              Text(
                '小米手环/手表用的是 Vela 系统，\n'
                '不是安卓，技术栈完全不同：\n\n'
                '  · 经典蓝牙 SPP 通信（不是 ADB）\n'
                '  · 快应用（rpk）而非 APK\n'
                '  · 需要专门的协议栈还原',
                style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textSecondary,
                    height: 1.7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: 'AstroBox-NG（推荐）',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('外部工具',
                style: TextStyle(fontSize: 9, color: AppTheme.warning)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '340★ · Rust + Tauri · AGPL-3.0\n\n'
                '全球首个在 PC 与 iOS 上实现小米穿戴设备连接\n'
                '及第三方资源安装的项目。\n\n'
                '支持：Windows / macOS / Linux / Android / iOS',
                style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                    height: 1.7),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse(
                        'https://github.com/AstralSightStudios/AstroBox-NG/releases');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  },
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('前往下载',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '⚠️ 为什么不在软件里集成：\n'
                '  · 173 MB 的纯 GUI 应用，没有 CLI\n'
                '  · 无法通过命令行调用\n'
                '  · AGPL-3.0 传染性强',
                style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.6),
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
