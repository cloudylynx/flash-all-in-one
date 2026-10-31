import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_info.dart';
import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 应用管理
///
/// 列出已安装应用，支持搜索、筛选、启用/禁用/卸载/清数据。
class AppsPage extends StatefulWidget {
  const AppsPage({super.key});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  List<AppInfo> _apps = [];
  List<AppInfo> _filtered = [];
  bool _loading = false;
  String _search = '';
  bool _showSystem = true;
  String? _loadedSerial;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() => _loading = true);

    final packages = await AdbService.instance.listPackages(
      device.serial,
      includeSystem: _showSystem,
    );

    // 获取禁用的包
    final disabledResult = await AdbService.instance.shell(
      device.serial,
      ['pm', 'list', 'packages', '-d'],
    );
    final disabled = disabledResult.output
        .split('\n')
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring(8).trim())
        .toSet();

    final apps = packages.map((p) {
      return AppInfo(
        packageName: p,
        isSystemApp: false,
        isEnabled: !disabled.contains(p),
      );
    }).toList();

    setState(() {
      _apps = apps;
      _loading = false;
      _loadedSerial = device.serial;
      _applyFilter();
    });
  }

  void _applyFilter() {
    var list = _apps;
    if (!_showSystem) {
      // 简单启发式：com.android.* / com.google.* 视为系统
      list = list.where((a) {
        final p = a.packageName;
        return !(p.startsWith('com.android.') ||
            p.startsWith('com.google.') ||
            p.startsWith('android.'));
      }).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((a) =>
              a.packageName.toLowerCase().contains(q) ||
              (a.label?.toLowerCase().contains(q) ?? false))
          .toList();
    }
    setState(() => _filtered = list);
  }

  Future<void> _toggleApp(AppInfo app) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final enable = !app.isEnabled;
    final r = enable
        ? await AdbService.instance.enableApp(device.serial, app.packageName)
        : await AdbService.instance
            .disableApp(device.serial, app.packageName);

    if (!mounted) return;
    if (r.ok) {
      setState(() {
        final idx = _apps.indexWhere((a) => a.packageName == app.packageName);
        if (idx >= 0) {
          _apps[idx] = AppInfo(
            packageName: app.packageName,
            label: app.label,
            versionName: app.versionName,
            versionCode: app.versionCode,
            isSystemApp: app.isSystemApp,
            isEnabled: enable,
          );
        }
        _applyFilter();
      });
      _toast(enable ? '已启用' : '已禁用');
    } else {
      _toast('操作失败：${r.output}', error: true);
    }
  }

  Future<void> _clearData(AppInfo app) async {
    final ok = await _confirm('清除数据', '确定清除 ${app.packageName} 的所有数据？');
    if (!ok) return;

    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final r =
        await AdbService.instance.clearData(device.serial, app.packageName);
    if (!mounted) return;
    _toast(r.ok ? '已清除' : '失败：${r.output}', error: !r.ok);
  }

  Future<void> _forceStop(AppInfo app) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;
    final r =
        await AdbService.instance.forceStop(device.serial, app.packageName);
    if (!mounted) return;
    _toast(r.ok ? '已强制停止' : '失败：${r.output}', error: !r.ok);
  }

  Future<void> _uninstall(AppInfo app) async {
    final ok = await _confirm('卸载', '确定卸载 ${app.packageName}？');
    if (!ok) return;

    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final r =
        await AdbService.instance.uninstall(device.serial, app.packageName);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _apps.removeWhere((a) => a.packageName == app.packageName);
        _applyFilter();
      });
      _toast('已卸载');
    } else {
      _toast('失败：${r.output}', error: true);
    }
  }

  Future<bool> _confirm(String title, String content) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text(title),
        content: Text(content, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    return r ?? false;
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppTheme.danger : AppTheme.bgElevated,
      duration: const Duration(seconds: 2),
    ));
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

    // 设备切换时自动重新加载
    if (_loadedSerial != device.serial && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

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
              SizedBox(
                width: 240,
                height: 34,
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(
                    hintText: '搜索包名…',
                    prefixIcon: Icon(Icons.search, size: 16),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (v) {
                    _search = v;
                    _applyFilter();
                  },
                ),
              ),
              const SizedBox(width: 14),
              FilterChip(
                label: const Text('显示系统应用', style: TextStyle(fontSize: 11.5)),
                selected: _showSystem,
                onSelected: (v) {
                  setState(() => _showSystem = v);
                  _load();
                },
                backgroundColor: AppTheme.bgElevated,
                selectedColor: AppTheme.primary.withValues(alpha: 0.2),
                side: const BorderSide(color: AppTheme.border),
              ),
              const Spacer(),
              Text(
                '${_filtered.length} / ${_apps.length}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
              const SizedBox(width: 12),
              if (_loading)
                const InlineLoader(text: '加载中')
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  color: AppTheme.textSecondary,
                  tooltip: '刷新列表',
                  onPressed: _load,
                ),
            ],
          ),
        ),

        // 列表
        Expanded(
          child: _loading && _apps.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _filtered.isEmpty
                  ? const EmptyState(
                      icon: Icons.apps,
                      title: '没有匹配的应用',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _AppTile(
                        app: _filtered[i],
                        onToggle: () => _toggleApp(_filtered[i]),
                        onClearData: () => _clearData(_filtered[i]),
                        onForceStop: () => _forceStop(_filtered[i]),
                        onUninstall: () => _uninstall(_filtered[i]),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _AppTile extends StatefulWidget {
  final AppInfo app;
  final VoidCallback onToggle;
  final VoidCallback onClearData;
  final VoidCallback onForceStop;
  final VoidCallback onUninstall;

  const _AppTile({
    required this.app,
    required this.onToggle,
    required this.onClearData,
    required this.onForceStop,
    required this.onUninstall,
  });

  @override
  State<_AppTile> createState() => _AppTileState();
}

class _AppTileState extends State<_AppTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover ? AppTheme.bgHover : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            // 启用状态点
            StatusDot(
              color: app.isEnabled ? AppTheme.success : AppTheme.textMuted,
              size: 7,
            ),
            const SizedBox(width: 12),

            // 包名
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.packageName,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'monospace',
                      color: app.isEnabled
                          ? AppTheme.textPrimary
                          : AppTheme.textMuted,
                      decoration: app.isEnabled ? null : TextDecoration.lineThrough,
                    ),
                  ),
                  if (app.versionName != null)
                    Text(
                      'v${app.versionName}',
                      style: const TextStyle(
                          fontSize: 10.5, color: AppTheme.textMuted),
                    ),
                ],
              ),
            ),

            // 操作按钮
            if (_hover) ...[
              _actionBtn(Icons.stop_circle_outlined, '强制停止', widget.onForceStop,
                  AppTheme.warning),
              _actionBtn(Icons.cleaning_services_outlined, '清除数据',
                  widget.onClearData, AppTheme.warning),
              _actionBtn(
                  app.isEnabled ? Icons.block : Icons.check_circle_outline,
                  app.isEnabled ? '禁用' : '启用',
                  widget.onToggle,
                  app.isEnabled ? AppTheme.textSecondary : AppTheme.success),
              _actionBtn(Icons.delete_outline, '卸载', widget.onUninstall,
                  AppTheme.danger),
            ] else
              Text(
                app.isEnabled ? '' : '已禁用',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn(IconData icon, String tip, VoidCallback onTap, Color color) {
    return Tooltip(
      message: tip,
      child: IconButton(
        icon: Icon(icon, size: 16),
        color: color,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      ),
    );
  }
}
