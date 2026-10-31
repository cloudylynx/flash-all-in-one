import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../../services/scrcpy_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 设备屏幕（截图 + 投屏二合一）
///
/// 两个 Tab：
///   · 截图与按键 —— 纯 adb，无需额外软件
///   · 实时投屏   —— scrcpy，需要 scrcpy.exe
class DeviceScreenPage extends StatefulWidget {
  const DeviceScreenPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<DeviceScreenPage> createState() => _DeviceScreenPageState();
}

class _DeviceScreenPageState extends State<DeviceScreenPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // ═══ 截图 Tab ═══
  String? _screenshotPath;
  bool _capturing = false;
  final List<String> _log = [];

  // ═══ scrcpy Tab ═══
  bool _scrcpyReady = false;
  String? _scrcpyVersion;
  bool _scrcpyRunning = false;
  Map<String, dynamic>? _scrcpyDiag;
  String? _scrcpyInitError;
  String _videoBitRate = '8M';
  int _maxFps = 60;
  bool _noAudio = true;
  bool _stayAwake = true;
  bool _turnScreenOff = false;

  @override
  void initState() {
    super.initState();
    final envTab =
        int.tryParse(Platform.environment['GAOJI_SCREEN_TAB'] ?? '');
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: envTab ?? widget.initialTab,
    );
    _initScrcpy();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _initScrcpy() async {
    final ok = await ScrcpyService.instance.init();
    String? ver;
    if (ok) ver = await ScrcpyService.instance.version();
    if (!mounted) return;
    setState(() {
      _scrcpyReady = ok;
      _scrcpyVersion = ver;
      _scrcpyInitError =
          ok ? null : ScrcpyService.instance.initError;
    });
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
  }

  // ═══ 截图 ═══
  Future<void> _capture() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() => _capturing = true);

    final bytes = await AdbService.instance.screenshot(device.serial);

    if (bytes == null) {
      if (!mounted) return;
      setState(() => _capturing = false);
      _addLog('❌ 截图失败');
      return;
    }

    final dir = Directory.systemTemp;
    final out =
        '${dir.path}${Platform.pathSeparator}screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(out).writeAsBytes(bytes);

    if (!mounted) return;
    setState(() {
      _capturing = false;
      _screenshotPath = out;
    });

    _addLog('✅ 截图已保存 (${(bytes.length / 1024).toStringAsFixed(0)} KB)');
  }

  Future<void> _tap(double x, double y) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;
    await AdbService.instance.tap(device.serial, x.round(), y.round());
    _addLog('👆 点击 ($x, $y)');
  }

  Future<void> _key(String code, String label) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;
    await AdbService.instance.keyevent(device.serial, code);
    _addLog('⌨️ 按键 $label');
  }

  // ═══ scrcpy ═══
  Future<void> _startScrcpy() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() {
      _scrcpyRunning = true;
      _log.clear();
    });

    final err = await ScrcpyService.instance.start(
      serial: device.serial,
      options: ScrcpyOptions(
        bitRateMbps: int.tryParse(_videoBitRate.replaceAll('M', '')) ?? 8,
        maxFps: _maxFps,
        noAudio: _noAudio,
        stayAwake: _stayAwake,
        turnScreenOff: _turnScreenOff,
      ),
      onLine: _addLog,
    );

    if (!mounted) return;
    if (err != null) {
      setState(() => _scrcpyRunning = false);
      _addLog('❌ $err');

      // 自动诊断
      _addLog('🔍 正在诊断…');
      final diag = await ScrcpyService.instance.diagnose();
      if (!mounted) return;
      setState(() => _scrcpyDiag = diag);
      _addLog('诊断: ${diag['diagnosis']}');
    }
  }

  Future<void> _stopScrcpy() async {
    await ScrcpyService.instance.stop();
    if (!mounted) return;
    setState(() => _scrcpyRunning = false);
    _addLog('⏹ 已停止投屏');
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceProvider>().selectedDevice;

    if (device == null) {
      return const EmptyState(
        icon: Icons.developer_board_off,
        title: '未选中设备',
        subtitle: '请先在「设备总览」选择一台设备',
      );
    }

    return Column(
      children: [
        // Tab 栏
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '截图与按键', height: 40),
              Tab(text: '实时投屏（scrcpy）', height: 40),
            ],
            labelStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 12),
            indicatorColor: AppTheme.primary,
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildScreenshotTab(),
              _buildScrcpyTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════ Tab 1: 截图与按键 ═══════════
  Widget _buildScreenshotTab() {
    return Row(
      children: [
        Expanded(
          flex: 3,
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
                    SizedBox(
                      height: 32,
                      child: ElevatedButton.icon(
                        onPressed: _capturing ? null : _capture,
                        icon: Icon(
                            _capturing
                                ? Icons.hourglass_top
                                : Icons.camera_alt,
                            size: 15),
                        label: Text(_capturing ? '截图中…' : '截图',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '无需额外软件，纯 adb',
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _screenshotPath == null
                    ? const EmptyState(
                        icon: Icons.screenshot_monitor,
                        title: '点击「截图」查看设备屏幕',
                        subtitle: '截图后可点击画面任意位置模拟触摸\n'
                            '下方还有常用按键',
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            // 截图预览（点击可模拟触摸）
                            if (File(_screenshotPath!).existsSync())
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  return GestureDetector(
                                    onTapDown: (d) {
                                      final box = context.findRenderObject()
                                          as RenderBox?;
                                      if (box == null) return;
                                      _tap(d.localPosition.dx,
                                          d.localPosition.dy);
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                            color: AppTheme.border),
                                        borderRadius:
                                            BorderRadius.circular(6),
                                      ),
                                      child: Image.file(
                                        File(_screenshotPath!),
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            const SizedBox(height: 12),
                            Text(
                              '点击画面可模拟触摸',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
              ),
              // 按键条
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (code, label, icon) in [
                      ('3', 'Home', Icons.home),
                      ('4', '返回', Icons.arrow_back),
                      ('187', '最近', Icons.apps),
                      ('26', '电源', Icons.power_settings_new),
                      ('24', '音量+', Icons.volume_up),
                      ('25', '音量-', Icons.volume_down),
                      ('82', '菜单', Icons.menu),
                      ('84', '搜索', Icons.search),
                      ('19', '上', Icons.keyboard_arrow_up),
                      ('20', '下', Icons.keyboard_arrow_down),
                      ('21', '左', Icons.keyboard_arrow_left),
                      ('22', '右', Icons.keyboard_arrow_right),
                      ('66', '回车', Icons.keyboard_return),
                      ('111', 'Esc', Icons.close),
                    ])
                      OutlinedButton.icon(
                        onPressed: () => _key(code, label),
                        icon: Icon(icon, size: 13),
                        label: Text(label,
                            style: const TextStyle(fontSize: 10.5)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 日志
        Container(
          width: 300,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal,
                        size: 14, color: AppTheme.accent),
                    const SizedBox(width: 6),
                    const Text('操作日志',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 14),
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
                                  fontSize: 11, color: AppTheme.textMuted)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _log.length,
                          itemBuilder: (context, i) => Text(
                            _log[i],
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: AppTheme.textSecondary,
                                height: 1.45),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════ Tab 2: 实时投屏 ═══════════
  Widget _buildScrcpyTab() {
    if (!_scrcpyReady) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 40),
            const Icon(Icons.cast_connected,
                size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            const Text('scrcpy 未就绪',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text(
              '需要 scrcpy.exe + SDL3.dll + FFmpeg DLL',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            if (_scrcpyInitError != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppTheme.danger.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 15, color: AppTheme.danger),
                        SizedBox(width: 6),
                        Text('提取失败原因',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.danger)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _scrcpyInitError!,
                      style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          color: AppTheme.textSecondary,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _initScrcpy,
              icon: const Icon(Icons.refresh, size: 15),
              label: const Text('重新检测'),
            ),
          ],
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
                    color: (_scrcpyRunning
                            ? AppTheme.success
                            : AppTheme.textMuted)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _scrcpyRunning
                            ? Icons.cast_connected
                            : Icons.cast,
                        size: 15,
                        color: _scrcpyRunning
                            ? AppTheme.success
                            : AppTheme.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _scrcpyRunning
                            ? '投屏中（scrcpy ${_scrcpyVersion ?? ""}）'
                            : 'scrcpy ${_scrcpyVersion ?? ""} 就绪',
                        style: TextStyle(
                            fontSize: 12,
                            color: _scrcpyRunning
                                ? AppTheme.success
                                : AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (_scrcpyDiag != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.bgElevated,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('诊断结果',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary)),
                        const SizedBox(height: 6),
                        Text(
                          _scrcpyDiag!['diagnosis']?.toString() ?? '',
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: AppTheme.warning,
                              height: 1.5),
                        ),
                        if (_scrcpyDiag!['files'] != null) ...[
                          const SizedBox(height: 8),
                          const Text('目录文件：',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: AppTheme.textMuted)),
                          for (final e in (_scrcpyDiag!['files'] as Map)
                              .entries)
                            Text(
                              '  ${e.key}  ${(e.value / 1024).toStringAsFixed(0)} KB',
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: AppTheme.textSecondary),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),

                AppCard(
                  title: '画面',
                  child: Column(
                    children: [
                      _optionRow(
                        '码率',
                        DropdownButton<String>(
                          value: _videoBitRate,
                          isDense: true,
                          underline: const SizedBox(),
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textPrimary),
                          items: const [
                            DropdownMenuItem(value: '2M', child: Text('2 Mbps')),
                            DropdownMenuItem(value: '4M', child: Text('4 Mbps')),
                            DropdownMenuItem(value: '8M', child: Text('8 Mbps')),
                            DropdownMenuItem(value: '16M', child: Text('16 Mbps')),
                            DropdownMenuItem(value: '32M', child: Text('32 Mbps')),
                          ],
                          onChanged: _scrcpyRunning
                              ? null
                              : (v) => setState(
                                  () => _videoBitRate = v ?? '8M'),
                        ),
                      ),
                      _optionRow(
                        '帧率',
                        DropdownButton<int>(
                          value: _maxFps,
                          isDense: true,
                          underline: const SizedBox(),
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textPrimary),
                          items: const [
                            DropdownMenuItem(value: 30, child: Text('30 fps')),
                            DropdownMenuItem(value: 60, child: Text('60 fps')),
                            DropdownMenuItem(value: 90, child: Text('90 fps')),
                            DropdownMenuItem(value: 120, child: Text('120 fps')),
                          ],
                          onChanged: _scrcpyRunning
                              ? null
                              : (v) => setState(() => _maxFps = v ?? 60),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                AppCard(
                  title: '行为',
                  child: Column(
                    children: [
                      _checkRow('关闭设备音频', _noAudio, (v) {
                        setState(() => _noAudio = v);
                      }),
                      _checkRow('保持唤醒', _stayAwake, (v) {
                        setState(() => _stayAwake = v);
                      }),
                      _checkRow('投屏时熄屏（省电）', _turnScreenOff, (v) {
                        setState(() => _turnScreenOff = v);
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: _scrcpyRunning ? _stopScrcpy : _startScrcpy,
                    icon: Icon(
                        _scrcpyRunning ? Icons.stop : Icons.play_arrow,
                        size: 18),
                    label: Text(_scrcpyRunning ? '停止投屏' : '开始投屏'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _scrcpyRunning
                          ? AppTheme.danger
                          : AppTheme.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 日志
        Container(
          width: 320,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal,
                        size: 14, color: AppTheme.accent),
                    const SizedBox(width: 6),
                    const Text('scrcpy 输出',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 14),
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
                          child: Text('等待启动…',
                              style: TextStyle(
                                  fontSize: 11, color: AppTheme.textMuted)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _log.length,
                          itemBuilder: (context, i) => SelectableText(
                            _log[i],
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: AppTheme.textSecondary,
                                height: 1.45),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _optionRow(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }

  Widget _checkRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              onChanged: _scrcpyRunning
                  ? null
                  : (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}
