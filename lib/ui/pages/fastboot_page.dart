import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/fastboot_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Fastboot 刷机
class FastbootPage extends StatefulWidget {
  const FastbootPage({super.key});

  @override
  State<FastbootPage> createState() => _FastbootPageState();
}

class _FastbootPageState extends State<FastbootPage> {
  List<FastbootDevice> _devices = [];
  String? _selected;
  Map<String, String> _vars = {};
  List<String> _partitions = [];
  final List<String> _log = [];
  bool _loading = false;
  bool _flashing = false;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _loading = true);
    final list = await FastbootService.instance.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _loading = false;
      if (_selected == null && list.isNotEmpty) {
        _selected = list.first.serial;
        _loadVars();
      }
    });
  }

  Future<void> _loadVars() async {
    if (_selected == null) return;
    final vars = await FastbootService.instance.getVars(_selected!);
    final parts = <String>[];
    for (final k in vars.keys) {
      if (k.startsWith('partition-type:')) {
        parts.add(k.substring('partition-type:'.length));
      }
    }
    if (!mounted) return;
    setState(() {
      _vars = vars;
      _partitions = parts;
    });
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController
            .jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _flash(String partition) async {
    if (_selected == null) return;

    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 $partition 镜像',
      type: FileType.any,
    );
    if (result == null || result.files.single.path == null) return;

    final path = result.files.single.path!;
    setState(() => _flashing = true);
    _addLog('══ 刷入 $partition ← $path');

    final code = await FastbootService.instance.flash(
      _selected!,
      partition,
      path,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _flashing = false);
    _addLog(code == 0 ? '✅ 刷入成功' : '❌ 刷入失败（退出码 $code）');
  }

  Future<void> _reboot(String target) async {
    if (_selected == null) return;
    _addLog('══ 重启到 $target');
    await FastbootService.instance.reboot(_selected!, target: target);
    _addLog('命令已发送');
    await Future.delayed(const Duration(seconds: 2));
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 工具条
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              const Icon(Icons.flash_on, size: 16, color: AppTheme.warning),
              const SizedBox(width: 8),
              Text(
                _devices.isEmpty
                    ? '未检测到 fastboot 设备'
                    : '${_devices.length} 台设备',
                style: const TextStyle(
                    fontSize: 12.5, color: AppTheme.textSecondary),
              ),
              if (_devices.length > 1) ...[
                const SizedBox(width: 14),
                DropdownButton<String>(
                  value: _selected,
                  underline: const SizedBox(),
                  dropdownColor: AppTheme.bgElevated,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textPrimary),
                  items: _devices
                      .map((d) => DropdownMenuItem(
                            value: d.serial,
                            child: Text(d.serial,
                                style: const TextStyle(fontSize: 12)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    setState(() => _selected = v);
                    _loadVars();
                  },
                ),
              ],
              const Spacer(),
              if (_flashing)
                const InlineLoader(text: '刷入中')
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  color: AppTheme.textSecondary,
                  tooltip: '重新扫描',
                  onPressed: _scan,
                ),
            ],
          ),
        ),

        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _devices.isEmpty
                  ? EmptyState(
                      icon: Icons.usb_off,
                      title: '未检测到 fastboot 设备',
                      subtitle: '请让设备进入 fastboot 模式：\n'
                          'adb reboot bootloader\n'
                          '或关机后按住音量减 + 电源键',
                      action: OutlinedButton.icon(
                        onPressed: _scan,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重新扫描'),
                      ),
                    )
                  : Row(
                      children: [
                        // 左：操作区
                        Expanded(
                          flex: 3,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // 重启
                                AppCard(
                                  title: '重启',
                                  child: Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      _btn('系统', Icons.android,
                                          () => _reboot('')),
                                      _btn('Bootloader', Icons.settings,
                                          () => _reboot('bootloader')),
                                      _btn('Recovery', Icons.healing,
                                          () => _reboot('recovery')),
                                      _btn('Fastbootd', Icons.flash_on,
                                          () => _reboot('fastboot')),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),

                                // 分区刷入
                                AppCard(
                                  title: '分区刷入',
                                  trailing: Text(
                                    '${_partitions.length} 个分区',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textMuted),
                                  ),
                                  child: _partitions.isEmpty
                                      ? const Text('未读取到分区列表',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.textMuted))
                                      : Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            for (final p in _partitions)
                                              _partitionChip(p),
                                          ],
                                        ),
                                ),
                                const SizedBox(height: 14),

                                // 设备变量
                                if (_vars.isNotEmpty)
                                  AppCard(
                                    title: '设备变量',
                                    child: Column(
                                      children: [
                                        for (final e in _vars.entries.take(15))
                                          InfoRow(
                                            label: e.key,
                                            value: e.value,
                                            monospace: true,
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),

                        // 右：日志
                        Container(
                          width: 340,
                          decoration: const BoxDecoration(
                            border:
                                Border(left: BorderSide(color: AppTheme.border)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: const BoxDecoration(
                                  border: Border(
                                      bottom:
                                          BorderSide(color: AppTheme.border)),
                                ),
                                child: Row(
                                  children: [
                                    const Text('输出',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.textSecondary)),
                                    const Spacer(),
                                    IconButton(
                                      icon: const Icon(Icons.delete_sweep,
                                          size: 15),
                                      color: AppTheme.textMuted,
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () =>
                                          setState(() => _log.clear()),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  color: const Color(0xFF0A0C10),
                                  child: ListView.builder(
                                    controller: _scrollController,
                                    padding: const EdgeInsets.all(10),
                                    itemCount: _log.length,
                                    itemBuilder: (context, i) => SelectableText(
                                      _log[i],
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontFamily: 'monospace',
                                        color: AppTheme.textSecondary,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: _flashing ? null : onTap,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );
  }

  Widget _partitionChip(String partition) {
    return InkWell(
      onTap: _flashing ? null : () => _flash(partition),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.bgElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.border),
        ),
        child: Text(
          partition,
          style: const TextStyle(
            fontSize: 11.5,
            fontFamily: 'monospace',
            color: AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}
