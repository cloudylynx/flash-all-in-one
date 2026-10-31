import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 批量操作
class BatchPage extends StatefulWidget {
  const BatchPage({super.key});

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  final List<String> _selected = [];
  List<String> _packages = [];
  bool _loading = false;
  bool _running = false;
  String? _loadedSerial;
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;
    setState(() => _loading = true);
    final pkgs = await AdbService.instance.listPackages(device.serial,
        includeSystem: false);
    if (!mounted) return;
    setState(() {
      _packages = pkgs;
      _loading = false;
      _loadedSerial = device.serial;
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

  Future<void> _run(String action) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null || _selected.isEmpty) return;

    setState(() {
      _running = true;
      _log.clear();
    });

    final adb = AdbService.instance;
    for (final pkg in _selected) {
      _addLog('══ $action: $pkg');
      switch (action) {
        case '冻结':
          final r = await adb.disableApp(device.serial, pkg);
          _addLog(r.ok ? '  ✅' : '  ❌ ${r.output}');
        case '解冻':
          final r = await adb.enableApp(device.serial, pkg);
          _addLog(r.ok ? '  ✅' : '  ❌ ${r.output}');
        case '停止':
          final r = await adb.forceStop(device.serial, pkg);
          _addLog(r.ok ? '  ✅' : '  ❌ ${r.output}');
        case '清数据':
          final r = await adb.clearData(device.serial, pkg);
          _addLog(r.ok ? '  ✅' : '  ❌ ${r.output}');
        case '卸载':
          final r = await adb.uninstall(device.serial, pkg);
          _addLog(r.ok ? '  ✅' : '  ❌ ${r.output}');
      }
    }

    _addLog('══ 完成（${_selected.length} 个）');
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceProvider>().selectedDevice;

    if (device == null) {
      return const EmptyState(
        icon: Icons.developer_board_off,
        title: '未选中设备',
        subtitle: '请先在「设备」页面选择一台设备',
      );
    }

    if (_loadedSerial != device.serial && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    Text('已选 ${_selected.length} 个',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.textSecondary)),
                    const Spacer(),
                    if (_running)
                      const InlineLoader(text: '执行中')
                    else
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 17),
                        color: AppTheme.textSecondary,
                        onPressed: _load,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _packages.length,
                        itemBuilder: (context, i) {
                          final pkg = _packages[i];
                          final sel = _selected.contains(pkg);
                          return CheckboxListTile(
                            dense: true,
                            value: sel,
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _selected.add(pkg);
                                } else {
                                  _selected.remove(pkg);
                                }
                              });
                            },
                            title: Text(pkg,
                                style: const TextStyle(
                                    fontSize: 11.5, fontFamily: 'monospace')),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final a in ['冻结', '解冻', '停止', '清数据', '卸载'])
                      OutlinedButton(
                        onPressed: (_running || _selected.isEmpty)
                            ? null
                            : () => _run(a),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                        ),
                        child: Text(a, style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 340,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Container(
            color: const Color(0xFF0A0C10),
            child: _log.isEmpty
                ? const Center(
                    child: Text('选择应用后点操作按钮',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(10),
                    itemCount: _log.length,
                    itemBuilder: (context, i) => SelectableText(_log[i],
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            color: AppTheme.textSecondary,
                            height: 1.45)),
                  ),
          ),
        ),
      ],
    );
  }
}
