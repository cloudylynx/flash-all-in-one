import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/device_provider.dart';
import '../../services/uad_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 系统精简（UAD）
class DebloatPage extends StatefulWidget {
  const DebloatPage({super.key});

  @override
  State<DebloatPage> createState() => _DebloatPageState();
}

class _DebloatPageState extends State<DebloatPage> {
  List<UadPackage> _packages = [];
  final Set<String> _selected = {};
  bool _loading = false;
  bool _busy = false;
  String _filter = 'all';
  String _search = '';
  String? _uadVersion;
  String? _lastSerial;
  final List<String> _log = [];
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await UadService.instance.init();
    String? ver;
    if (ok) ver = await UadService.instance.version();
    if (!mounted) return;
    setState(() => _uadVersion = ver);
    if (ok) _load();
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

  Future<void> _load() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() {
      _loading = true;
      _selected.clear();
    });

    UadRemoval? filter;
    if (_filter != 'all') {
      filter = UadRemoval.values
          .firstWhere((e) => e.id.toLowerCase() == _filter);
    }

    _addLog('══ 加载包列表');
    _addLog('  设备: ${device.serial}');
    _addLog('  筛选: ${_filter == 'all' ? '全部' : _filter}');

    final pkgs = await UadService.instance.listPackages(
      serial: device.serial,
      filterRemoval: filter,
      query: _search.isEmpty ? null : _search,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() {
      _packages = pkgs;
      _loading = false;
    });
    _addLog(pkgs.isEmpty ? '  ⚠️ 未解析到包' : '  ✅ 解析出 ${pkgs.length} 个包');
  }

  Future<void> _doAction(String action) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null || _selected.isEmpty) return;

    final label = {'disable': '禁用', 'uninstall': '卸载', 'enable': '恢复'}[action]!;

    // 确认
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text('$label ${_selected.length} 个包'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('即将$label以下包：',
                  style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 8),
              for (final p in _selected.take(15))
                Text('  · $p',
                    style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppTheme.textSecondary)),
              if (_selected.length > 15)
                Text('  …还有 ${_selected.length - 15} 个',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
              const SizedBox(height: 12),
              const Text(
                '⚠️ 卸载系统应用可能导致系统异常\n'
                '建议先用「禁用」测试，确认无影响再卸载',
                style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.warning,
                    height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  action == 'enable' ? AppTheme.primary : AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: Text(label),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await switch (action) {
      'disable' => UadService.instance.disable(
          serial: device.serial,
          packages: _selected.toList(),
          onLine: _addLog,
        ),
      'uninstall' => UadService.instance.uninstall(
          serial: device.serial,
          packages: _selected.toList(),
          onLine: _addLog,
        ),
      _ => UadService.instance.enable(
          serial: device.serial,
          packages: _selected.toList(),
          onLine: _addLog,
        ),
    };

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
    if (r.ok) _load();
  }

  Color _removalColor(UadRemoval r) {
    switch (r) {
      case UadRemoval.recommended:
        return AppTheme.success;
      case UadRemoval.advanced:
        return AppTheme.primary;
      case UadRemoval.expert:
        return AppTheme.warning;
      case UadRemoval.unsafe:
        return AppTheme.danger;
      case UadRemoval.unlisted:
        return AppTheme.textMuted;
    }
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

    // 设备变化时自动加载（initState 时 DeviceProvider 可能还没就绪）
    if (_lastSerial != device.serial) {
      _lastSerial = device.serial;
      if (!_loading && _packages.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }

    final filtered = _packages.where((p) {
      if (_search.isEmpty) return true;
      final q = _search.toLowerCase();
      return p.name.toLowerCase().contains(q) ||
          (p.description?.toLowerCase().contains(q) ?? false);
    }).toList();

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Column(
            children: [
              // 工具条
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cleaning_services,
                        size: 16, color: AppTheme.accent),
                    const SizedBox(width: 8),
                    Text(
                      '系统精简${_uadVersion != null ? "（UAD $_uadVersion）" : ""}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                    const SizedBox(width: 12),
                    Text('${filtered.length} 个包',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 16),
                      color: AppTheme.textSecondary,
                      visualDensity: VisualDensity.compact,
                      onPressed: _loading ? null : _load,
                    ),
                  ],
                ),
              ),

              // 过滤 + 搜索
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 200,
                      height: 30,
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(fontSize: 11.5),
                        decoration: const InputDecoration(
                          hintText: '搜索包名…',
                          prefixIcon: Icon(Icons.search, size: 14),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                        ),
                        onChanged: (v) => setState(() => _search = v.trim()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    for (final (id, label) in [
                      ('all', '全部'),
                      ('recommended', '推荐'),
                      ('advanced', '高级'),
                      ('expert', '专家'),
                      ('unsafe', '危险'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(label,
                              style: const TextStyle(fontSize: 10.5)),
                          selected: _filter == id,
                          onSelected: (_) {
                            setState(() => _filter = id);
                            _load();
                          },
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),

              // 列表
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : filtered.isEmpty
                        ? const EmptyState(
                            icon: Icons.inbox,
                            title: '没有包',
                            subtitle: '换个筛选条件试试',
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final p = filtered[i];
                              final sel = _selected.contains(p.name);
                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    if (sel) {
                                      _selected.remove(p.name);
                                    } else {
                                      _selected.add(p.name);
                                    }
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  color: sel
                                      ? AppTheme.primary.withValues(alpha: 0.08)
                                      : Colors.transparent,
                                  child: Row(
                                    children: [
                                      Checkbox(
                                        value: sel,
                                        onChanged: (_) {
                                          setState(() {
                                            if (sel) {
                                              _selected.remove(p.name);
                                            } else {
                                              _selected.add(p.name);
                                            }
                                          });
                                        },
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _removalColor(p.removal)
                                              .withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(3),
                                        ),
                                        child: Text(
                                          p.removal.label,
                                          style: TextStyle(
                                              fontSize: 9.5,
                                              color:
                                                  _removalColor(p.removal)),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              p.name,
                                              style: const TextStyle(
                                                  fontSize: 11.5,
                                                  fontFamily: 'monospace',
                                                  color:
                                                      AppTheme.textPrimary),
                                            ),
                                            if (p.description != null &&
                                                p.description!.isNotEmpty)
                                              Text(
                                                p.description!,
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    color:
                                                        AppTheme.textMuted),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (!p.enabled)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: AppTheme.bgElevated,
                                            borderRadius:
                                                BorderRadius.circular(3),
                                          ),
                                          child: const Text('已禁用',
                                              style: TextStyle(
                                                  fontSize: 9,
                                                  color:
                                                      AppTheme.textMuted)),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
              ),

              // 底部操作栏
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    Text(
                      '已选 ${_selected.length} 个',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                    const SizedBox(width: 12),
                    if (_selected.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(() => _selected.clear()),
                        child: const Text('清空',
                            style: TextStyle(fontSize: 11)),
                      ),
                    const Spacer(),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    OutlinedButton(
                      onPressed: (_busy || _selected.isEmpty)
                          ? null
                          : () => _doAction('enable'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      child: const Text('恢复',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: (_busy || _selected.isEmpty)
                          ? null
                          : () => _doAction('disable'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      child: const Text('禁用',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: (_busy || _selected.isEmpty)
                          ? null
                          : () => _doAction('uninstall'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.danger,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                      ),
                      child: const Text('卸载',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 日志
        Container(
          width: 340,
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
                    const Icon(Icons.terminal, size: 15, color: AppTheme.accent),
                    const SizedBox(width: 8),
                    const Text('操作日志',
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
                            if (line.contains('❌')) c = AppTheme.danger;
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
