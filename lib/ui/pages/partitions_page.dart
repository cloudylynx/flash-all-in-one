import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/process_runner.dart';
import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 分区管理
///
/// 数据来源（按可靠性排序）：
/// 1. `/dev/block/by-name/` —— 分区名 → 块设备映射（最可靠）
/// 2. `df -h` —— 挂载点与容量
/// 3. `/proc/mounts` —— 文件系统类型
///
/// 注意：`/proc/partitions` 在 Android 10+ 常被 SELinux 拒绝，不可依赖。
class PartitionsPage extends StatefulWidget {
  const PartitionsPage({super.key});

  @override
  State<PartitionsPage> createState() => _PartitionsPageState();
}

class _PartitionsPageState extends State<PartitionsPage> {
  List<_Partition> _partitions = [];
  bool _loading = false;
  String? _loadedSerial;
  String _search = '';
  String? _error;
  bool _busy = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final adb = AdbService.instance;

    // 1. 块设备映射
    final byName = await adb.shell(
      device.serial,
      ['ls', '-l', '/dev/block/by-name/'],
    );

    final blockMap = <String, String>{}; // 分区名 → 块设备路径
    for (final line in byName.output.split('\n')) {
      final t = line.trim();
      // lrwxrwxrwx 1 root root 15 ... metadata -> /dev/block/vdd1
      final m = RegExp(r'(\S+)\s+->\s+(\S+)$').firstMatch(t);
      if (m != null) {
        blockMap[m.group(1)!] = m.group(2)!;
      }
    }

    // 2. df 容量信息
    final df = await adb.storageInfo(device.serial);
    final dfByDev = <String, Map<String, String>>{};
    for (final d in df) {
      final fs = d['filesystem'] ?? '';
      if (fs.isNotEmpty) dfByDev[fs] = d;
    }

    // 3. /proc/mounts 文件系统类型
    final mounts = await adb.shell(device.serial, ['cat', '/proc/mounts']);
    final fsTypeByDev = <String, String>{};
    for (final line in mounts.output.split('\n')) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length >= 3 && f[0].startsWith('/dev/')) {
        fsTypeByDev[f[0]] = f[2];
      }
    }

    // 组装
    final list = <_Partition>[];
    if (blockMap.isNotEmpty) {
      for (final e in blockMap.entries) {
        final dev = e.value;
        final dfInfo = dfByDev[dev];
        list.add(_Partition(
          name: e.key,
          device: dev,
          fsType: fsTypeByDev[dev],
          size: dfInfo?['size'],
          used: dfInfo?['used'],
          avail: dfInfo?['avail'],
          usePercent: dfInfo?['usePercent'],
          mounted: dfInfo?['mounted'],
        ));
      }
    } else {
      // 回退：只用 df
      for (final d in df) {
        final fs = d['filesystem'] ?? '';
        if (fs.startsWith('/dev/block/')) {
          list.add(_Partition(
            name: fs.split('/').last,
            device: fs,
            fsType: fsTypeByDev[fs],
            size: d['size'],
            used: d['used'],
            avail: d['avail'],
            usePercent: d['usePercent'],
            mounted: d['mounted'],
          ));
        }
      }
      if (list.isEmpty) {
        _error = '无法读取分区信息（可能被 SELinux 限制）';
      }
    }

    list.sort((a, b) => a.name.compareTo(b.name));

    if (!mounted) return;
    setState(() {
      _partitions = list;
      _loading = false;
      _loadedSerial = device.serial;
    });
  }

  List<_Partition> get _filtered {
    if (_search.isEmpty) return _partitions;
    final q = _search.toLowerCase();
    return _partitions
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            (p.mounted?.toLowerCase().contains(q) ?? false))
        .toList();
  }

  /// 分区操作
  Future<void> _onAction(String action, _Partition part) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final adb = await AppConfig.adbPath();
    final devPath = part.device;

    switch (action) {
      case 'dump':
        // 导出分区
        final dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择保存目录',
        );
        if (dir == null) return;

        setState(() => _busy = true);
        final tmp = '/data/local/tmp/${part.name}.img';
        var r = await ProcessRunner.run(
            adb, ['-s', device.serial, 'shell', 'su -c "dd if=$devPath of=$tmp"'],
            timeout: const Duration(minutes: 5));
        if (r.exitCode != 0) {
          // 试不带 su
          r = await ProcessRunner.run(
              adb, ['-s', device.serial, 'shell', 'dd if=$devPath of=$tmp'],
              timeout: const Duration(minutes: 5));
        }
        final local =
            '$dir${Platform.pathSeparator}${part.name}.img';
        r = await ProcessRunner.run(
            adb, ['-s', device.serial, 'pull', tmp, local],
            timeout: const Duration(minutes: 10));
        if (mounted) setState(() => _busy = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r.exitCode == 0
                ? '已导出到 $local'
                : '导出失败: ${r.stderr}'),
          ));
        }

      case 'flash':
        // 刷入分区
        final picked = await FilePicker.platform.pickFiles(
          dialogTitle: '选择要刷入的镜像',
          type: FileType.any,
        );
        if (picked == null || picked.files.single.path == null) return;
        final imgPath = picked.files.single.path!;

        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.bgElevated,
            title: Text('刷入 ${part.name}'),
            content: Text(
                '将把\n${imgPath.split(Platform.pathSeparator).last}\n'
                '写入分区 ${part.name}（$devPath）\n\n'
                '⚠️ 操作有变砖风险！\n'
                '⚠️ 请确认镜像与分区匹配\n\n'
                '继续？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.danger,
                  foregroundColor: Colors.white,
                ),
                child: const Text('刷入'),
              ),
            ],
          ),
        );
        if (ok != true) return;

        setState(() => _busy = true);
        final tmp = '/data/local/tmp/${part.name}_flash.img';
        await ProcessRunner.run(
            adb, ['-s', device.serial, 'push', imgPath, tmp],
            timeout: const Duration(minutes: 10));
        final r = await ProcessRunner.run(
            adb,
            ['-s', device.serial, 'shell',
             'su -c "dd if=$tmp of=$devPath"'],
            timeout: const Duration(minutes: 5));
        if (mounted) setState(() => _busy = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r.exitCode == 0
                ? '✅ 已刷入 ${part.name}'
                : '❌ 刷入失败: ${r.stderr}'),
          ));
        }

      case 'erase':
        // 擦除分区
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.bgElevated,
            title: Text('擦除 ${part.name}'),
            content: Text(
                '将清空分区 ${part.name} 的所有数据。\n\n'
                '⚠️ 此操作不可恢复！\n'
                '⚠️ 擦除系统分区可能导致无法开机\n\n'
                '继续？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.danger,
                  foregroundColor: Colors.white,
                ),
                child: const Text('擦除'),
              ),
            ],
          ),
        );
        if (ok != true) return;

        setState(() => _busy = true);
        final r = await ProcessRunner.run(
            adb,
            ['-s', device.serial, 'shell',
             'su -c "dd if=/dev/zero of=$devPath bs=4096 count=1"'],
            timeout: const Duration(minutes: 2));
        if (mounted) setState(() => _busy = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r.exitCode == 0
                ? '✅ 已擦除 ${part.name}'
                : '❌ 擦除失败: ${r.stderr}'),
          ));
        }
    }
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

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 220,
                height: 32,
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(
                    hintText: '搜索分区名 / 挂载点…',
                    prefixIcon: Icon(Icons.search, size: 15),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: 14),
              Text('${_filtered.length} 个分区',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textMuted)),
              const Spacer(),
              if (_loading)
                const InlineLoader(text: '读取中')
              else if (_busy)
                const InlineLoader(text: '操作中')
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  color: AppTheme.textSecondary,
                  onPressed: _load,
                ),
            ],
          ),
        ),
        if (_error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: AppTheme.warning.withValues(alpha: 0.1),
            child: Row(
              children: [
                const Icon(Icons.warning_amber,
                    size: 15, color: AppTheme.warning),
                const SizedBox(width: 8),
                Text(_error!,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.textSecondary)),
              ],
            ),
          ),
        Expanded(
          child: _loading && _partitions.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _filtered.isEmpty
                  ? const EmptyState(
                      icon: Icons.grid_view, title: '没有分区')
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _PartitionTile(
                        part: _filtered[i],
                        onAction: _onAction,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _Partition {
  final String name;
  final String device;
  final String? fsType;
  final String? size;
  final String? used;
  final String? avail;
  final String? usePercent;
  final String? mounted;

  _Partition({
    required this.name,
    required this.device,
    this.fsType,
    this.size,
    this.used,
    this.avail,
    this.usePercent,
    this.mounted,
  });
}

class _PartitionTile extends StatefulWidget {
  final _Partition part;
  final void Function(String action, _Partition p)? onAction;
  const _PartitionTile({required this.part, this.onAction});

  @override
  State<_PartitionTile> createState() => _PartitionTileState();
}

class _PartitionTileState extends State<_PartitionTile> {
  bool _hover = false;

  _Partition get part => widget.part;

  @override
  Widget build(BuildContext context) {
    final pct = int.tryParse((part.usePercent ?? '').replaceAll('%', '')) ?? 0;
    final isFull = pct >= 90;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Icon(
            part.mounted != null ? Icons.folder_open : Icons.sd_storage,
            size: 16,
            color: part.mounted != null
                ? AppTheme.success
                : AppTheme.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(part.name,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: 'monospace',
                        color: AppTheme.textPrimary)),
                Text(
                  part.device,
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: part.mounted != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(part.mounted!,
                          style: const TextStyle(
                              fontSize: 11.5, color: AppTheme.textSecondary)),
                      Text(
                        '${part.used} / ${part.size}  (${part.usePercent})',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: isFull
                                ? AppTheme.danger
                                : AppTheme.textMuted),
                      ),
                    ],
                  )
                : const Text('—',
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
          ),
          if (part.fsType != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.bgElevated,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(part.fsType!,
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textMuted)),
            ),
          if (_hover && widget.onAction != null) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.download, size: 14),
              color: AppTheme.primary,
              visualDensity: VisualDensity.compact,
              tooltip: '导出分区',
              onPressed: () => widget.onAction!('dump', part),
            ),
            IconButton(
              icon: const Icon(Icons.upload, size: 14),
              color: AppTheme.warning,
              visualDensity: VisualDensity.compact,
              tooltip: '刷入分区',
              onPressed: () => widget.onAction!('flash', part),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 14),
              color: AppTheme.danger,
              visualDensity: VisualDensity.compact,
              tooltip: '擦除分区',
              onPressed: () => widget.onAction!('erase', part),
            ),
          ],
        ],
      ),
      ),
    );
  }
}
