import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// ADB Sideload 刷机
///
/// 在 recovery 模式下通过 USB 刷入刷机包。
/// 适用：OTA 升级包 / 完整 ROM zip / 官方救砖包
class SideloadPage extends StatefulWidget {
  const SideloadPage({super.key});

  @override
  State<SideloadPage> createState() => _SideloadPageState();
}

class _SideloadPageState extends State<SideloadPage> {
  final List<String> _zips = [];
  final List<String> _log = [];
  bool _sideloading = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择刷机包（OTA/ROM zip）',
      type: FileType.custom,
      allowedExtensions: ['zip'],
      allowMultiple: true,
    );
    if (r == null) return;
    setState(() {
      for (final f in r.files) {
        if (f.path != null && !_zips.contains(f.path)) {
          _zips.add(f.path!);
        }
      }
    });
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sideloadAll() async {
    // 找 recovery 模式的设备
    final dp = context.read<DeviceProvider>();
    final device = dp.devices.where((d) => d.isRecovery).firstOrNull;

    if (device == null) {
      _snack('没有检测到 recovery 模式的设备\n请先在设备上进入 recovery 模式');
      return;
    }
    if (_zips.isEmpty) {
      _snack('请先选择刷机包');
      return;
    }

    setState(() {
      _sideloading = true;
      _log.clear();
    });

    _addLog('══ ADB Sideload');
    _addLog('  设备: ${device.serial}');
    _addLog('  刷机包数量: ${_zips.length}');
    _addLog('');

    var ok = 0;
    var fail = 0;
    for (var i = 0; i < _zips.length; i++) {
      final path = _zips[i];
      final name = path.split(Platform.pathSeparator).last;
      _addLog('══ [${i + 1}/${_zips.length}] $name');

      final code = await AdbService.instance.sideload(
        device.serial,
        path,
        onLine: _addLog,
      );

      if (code == 0) {
        ok++;
        _addLog('✅ 成功');
      } else {
        fail++;
        _addLog('❌ 失败（退出码 $code）');
      }
      _addLog('');
    }

    _addLog('════════════════════════');
    _addLog('✅ 完成：成功 $ok，失败 $fail');
    if (!mounted) return;
    setState(() => _sideloading = false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();
    final recoveryDevices = dp.devices.where((d) => d.isRecovery).toList();

    return Row(
      children: [
        // 左：设置区
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 设备状态
                AppCard(
                  title: '目标设备',
                  child: Column(
                    children: [
                      if (recoveryDevices.isNotEmpty)
                        for (final d in recoveryDevices)
                          InfoRow(
                            label: 'Recovery',
                            value: d.serial,
                            monospace: true,
                          )
                      else
                        const Row(
                          children: [
                            Icon(Icons.warning_amber,
                                size: 16, color: AppTheme.warning),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '未检测到 recovery 模式的设备\n'
                                '请先在设备上进入 recovery：\n'
                                'adb reboot recovery 或 关机后音量加+电源键',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.textSecondary,
                                    height: 1.6),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 刷机包
                AppCard(
                  title: '刷机包（zip）',
                  trailing: OutlinedButton.icon(
                    onPressed: _sideloading ? null : _pickFiles,
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('添加', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                  ),
                  child: _zips.isEmpty
                      ? const Text(
                          '点击「添加」选择 OTA/ROM zip\n支持多选，按顺序逐个刷入',
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textMuted),
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < _zips.length; i++)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.archive,
                                    size: 16, color: AppTheme.accent),
                                title: Text(
                                  _zips[i].split(Platform.pathSeparator).last,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  '${(File(_zips[i]).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB',
                                  style: const TextStyle(fontSize: 10.5),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close, size: 15),
                                  color: AppTheme.textMuted,
                                  onPressed: _sideloading
                                      ? null
                                      : () => setState(() {
                                            _zips.removeAt(i);
                                          }),
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 14),

                // 说明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.2)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ADB Sideload 是什么',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary)),
                      SizedBox(height: 8),
                      Text(
                        'Sideload 是 recovery 模式下的刷机方式，\n'
                        '通过 USB 线直接推送 zip 刷机包。\n\n'
                        '适用场景：\n'
                        '  · 官方 OTA 升级包\n'
                        '  · 完整 ROM 卡刷包\n'
                        '  · 救砖包（进不了系统时）\n\n'
                        '注意：\n'
                        '  · 设备必须处于 recovery 模式\n'
                        '  · 刷机包必须是对应机型的 zip\n'
                        '  · 刷机过程不能断电、不能拔线',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 执行按钮
                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: _sideloading ? null : _sideloadAll,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.white,
                    ),
                    icon: _sideloading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.system_update, size: 18),
                    label: Text(
                      _sideloading ? '刷入中…' : '开始 Sideload',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 右：日志
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
                                  fontSize: 12, color: AppTheme.textMuted)))
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
}
