import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/partition_resize_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 分区扩容（危险操作）
class PartitionResizePage extends StatefulWidget {
  const PartitionResizePage({super.key});

  @override
  State<PartitionResizePage> createState() => _PartitionResizePageState();
}

class _PartitionResizePageState extends State<PartitionResizePage> {
  bool _ready = false;
  bool _busy = false;
  bool _isMtk = false;
  String? _disk;
  List<PartitionInfo> _partitions = [];
  Map<String, String> _freeSpace = {};
  final _targetSizeController = TextEditingController(text: '0');
  int _currentStep = 0;
  String _autoSizeMode = 'max';

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
    _targetSizeController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await PartitionResizeService.instance.init();
    final mtk = await PartitionResizeService.instance.isMtkPlatform();
    final disk = await PartitionResizeService.instance.findStorageDevice();

    if (!mounted) return;
    setState(() {
      _ready = ok;
      _isMtk = mtk;
      _disk = disk;
    });

    if (ok && disk != null) {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_disk == null) return;
    final parts = await PartitionResizeService.instance
        .readPartitions(disk: _disk!, onLine: null);
    final free = await PartitionResizeService.instance.getFreeSpace(disk: _disk!);
    if (!mounted) return;
    setState(() {
      _partitions = parts;
      _freeSpace = free;
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

  Future<void> _run(Future<ResizeResult> Function() action) async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
    await _refresh();
  }

  /// 一键扩容（全自动，带进度显示）
  Future<void> _runAuto() async {
    setState(() {
      _busy = true;
      _log.clear();
    });

    _addLog('════════════════════════════════');
    _addLog('  一键扩容 userdata');
    _addLog('════════════════════════════════');

    final targetGb = _autoSizeMode == 'max' ? 0 : (int.tryParse(_autoSizeMode) ?? 0);
    final r = await PartitionResizeService.instance.expandUserdataAuto(
      targetSizeGb: targetGb,
      onLine: _addLog,
      onProgress: (step, total, label) {
        if (mounted) {
          setState(() => _currentStep = step);
        }
      },
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      _currentStep = 0;
    });

    _addLog('');
    _addLog('════════════════════════════════');
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
    _addLog('════════════════════════════════');

    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final userdata = _partitions.where((p) => p.isUserdata).firstOrNull;

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 警告
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.3)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber,
                              size: 16, color: AppTheme.danger),
                          SizedBox(width: 7),
                          Text('分区扩容',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.danger)),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '调整 userdata（数据分区）大小，腾出空间装多系统。\n\n'
                        '⚠️ 会修改分区表，操作不当会导致数据全丢\n'
                        '⚠️ 必须先备份字库（整个存储芯片）\n'
                        '⚠️ 扩容过程不能断电',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ 一键扩容（最显眼）═══
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppTheme.primary.withValues(alpha: 0.15),
                        AppTheme.accent.withValues(alpha: 0.08),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.4),
                        width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.auto_fix_high,
                              size: 20, color: AppTheme.primary),
                          const SizedBox(width: 8),
                          const Text('一键扩容',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primary)),
                          const Spacer(),
                          if (_freeSpace['free_gb'] != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.accent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '可扩 ${_freeSpace['free_gb']} GB',
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.accent),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '自动把 userdata 扩展到磁盘末尾，不用填任何参数。\n'
                        '自动备份分区表，失败会自动回滚。',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.6),
                      ),
                      const SizedBox(height: 14),

                      // 扩容大小选择
                      Row(
                        children: [
                          const Text('扩容到',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButton<String>(
                              value: _autoSizeMode,
                              isDense: true,
                              isExpanded: true,
                              underline: const SizedBox(),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary),
                              items: [
                                const DropdownMenuItem(
                                  value: 'max',
                                  child: Text('磁盘末尾（最大）'),
                                ),
                                for (final gb in [32, 64, 96, 128, 160, 192, 256])
                                  DropdownMenuItem(
                                    value: '$gb',
                                    child: Text('$gb GB'),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(
                                      () => _autoSizeMode = v ?? 'max'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // 实际会扩多少
                          if (_freeSpace['free_gb'] != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color:
                                    AppTheme.success.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '+${_calcGrowText()}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.success),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed: _busy || _disk == null
                              ? null
                              : () async {
                                  final targetText = _autoSizeMode == 'max'
                                      ? '磁盘末尾（最大）'
                                      : '$_autoSizeMode GB';
                                  final ok = await _confirm(
                                    '⚠️ 一键扩容 userdata',
                                    '目标大小：$targetText\n\n'
                                        '会自动完成：\n'
                                        '  ① 识别设备\n'
                                        '  ② 备份分区表（失败可回滚）\n'
                                        '  ③ 分析分区\n'
                                        '  ④ 删除并重建分区\n'
                                        '  ⑤ 扩容文件系统\n\n'
                                        '⚠️ 过程 5-30 分钟，不要断开 USB\n'
                                        '⚠️ 中断会导致数据丢失',
                                  );
                                  if (ok != true) return;

                                  await _runAuto();
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.rocket_launch, size: 20),
                          label: Text(
                            _busy ? '扩容中…' : '开始一键扩容',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      // 进度条
                      if (_busy && _currentStep > 0) ...[
                        const SizedBox(height: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '步骤 $_currentStep / 7',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.primary),
                                ),
                                const Spacer(),
                                Text(
                                  _stepLabel(_currentStep),
                                  style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppTheme.textSecondary),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: _currentStep / 7,
                                minHeight: 6,
                                backgroundColor:
                                    AppTheme.primary.withValues(alpha: 0.15),
                                valueColor: const AlwaysStoppedAnimation(
                                    AppTheme.primary),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 状态
                AppCard(
                  title: '设备状态',
                  child: Column(
                    children: [
                      InfoRow(
                        label: '工具',
                        value: _ready ? '就绪' : '未就绪',
                        trailing: Icon(
                          _ready ? Icons.check_circle : Icons.error,
                          size: 12,
                          color: _ready ? AppTheme.success : AppTheme.danger,
                        ),
                      ),
                      InfoRow(
                        label: '磁盘',
                        value: _disk ?? '未识别',
                        monospace: true,
                      ),
                      InfoRow(
                        label: '平台',
                        value: _isMtk ? 'MTK（需特殊处理）' : '高通 / 其他',
                        trailing: _isMtk
                            ? const Icon(Icons.warning_amber,
                                size: 12, color: AppTheme.warning)
                            : null,
                      ),
                      if (_freeSpace['total_gb'] != null)
                        InfoRow(
                          label: '总容量',
                          value: '${_freeSpace['total_gb']} GB',
                        ),
                      if (_freeSpace['free_gb'] != null)
                        InfoRow(
                          label: '末尾空闲',
                          value: '${_freeSpace['free_gb']} GB',
                          trailing: const Icon(Icons.arrow_downward,
                              size: 12, color: AppTheme.accent),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // userdata 当前状态
                if (userdata != null)
                  AppCard(
                    title: 'userdata 分区',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('#${userdata.number}',
                          style: const TextStyle(
                              fontSize: 9, color: AppTheme.primary)),
                    ),
                    child: Column(
                      children: [
                        InfoRow(
                            label: '当前大小',
                            value: userdata.size,
                            trailing: const Icon(Icons.storage,
                                size: 12, color: AppTheme.accent)),
                        InfoRow(
                            label: '起始扇区',
                            value: userdata.startSector,
                            monospace: true),
                        InfoRow(
                            label: '结束扇区',
                            value: userdata.endSector,
                            monospace: true),
                        InfoRow(
                            label: '类型码',
                            value: userdata.typeCode,
                            monospace: true),
                      ],
                    ),
                  ),
                if (userdata != null) const SizedBox(height: 14),

                // 扩容操作
                AppCard(
                  title: '扩容操作',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 90,
                            child: Text('目标大小',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.textSecondary)),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _targetSizeController,
                              decoration: const InputDecoration(
                                hintText: '0 = 扩展到磁盘末尾',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                              ),
                              style: const TextStyle(
                                  fontSize: 11, fontFamily: 'monospace'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text('GB',
                              style: TextStyle(
                                  fontSize: 11, color: AppTheme.textMuted)),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 备份分区表
                      OutlinedButton.icon(
                        onPressed: _busy || _disk == null
                            ? null
                            : () => _run(() async {
                                  final save =
                                      await FilePicker.platform.saveFile(
                                    dialogTitle: '保存分区表备份',
                                    fileName:
                                        'gpt-${DateTime.now().millisecondsSinceEpoch}.bin',
                                  );
                                  if (save == null) {
                                    return ResizeResult(false, '已取消', []);
                                  }
                                  return PartitionResizeService.instance
                                      .backupPartitionTable(
                                    disk: _disk!,
                                    outputPath: save,
                                    onLine: _addLog,
                                  );
                                }),
                        icon: const Icon(Icons.save_alt, size: 14),
                        label: const Text('① 备份分区表',
                            style: TextStyle(fontSize: 11.5)),
                      ),
                      const SizedBox(height: 8),

                      // 扩容
                      SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: _busy || _disk == null || userdata == null
                              ? null
                              : () async {
                                  final targetGb =
                                      int.tryParse(_targetSizeController.text) ?? 0;

                                  final ok = await _confirm(
                                    '⚠️ 扩容 userdata',
                                    '将把 userdata 从 ${userdata.size} '
                                    '扩容到 ${targetGb > 0 ? "$targetGb GB" : "磁盘末尾"}。\n\n'
                                    '⚠️ 会删除并重建分区\n'
                                    '⚠️ 操作中断会导致数据丢失\n'
                                    '⚠️ 已备份分区表吗？\n\n'
                                    '确认继续？',
                                  );
                                  if (ok != true) {
                                    return;
                                  }

                                  await _run(() => PartitionResizeService
                                      .instance
                                      .expandUserdata(
                                        disk: _disk!,
                                        targetSizeGb: targetGb,
                                        confirmed: true,
                                        onLine: _addLog,
                                      ));
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.danger,
                          ),
                          icon: const Icon(Icons.open_in_full, size: 16),
                          label: const Text('② 执行扩容',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // 恢复分区表
                      OutlinedButton.icon(
                        onPressed: _busy || _disk == null
                            ? null
                            : () async {
                                final r = await FilePicker.platform.pickFiles(
                                  dialogTitle: '选择分区表备份',
                                  type: FileType.any,
                                );
                                if (r == null ||
                                    r.files.single.path == null) {
                                  return;
                                }
                                final path = r.files.single.path!;

                                final ok = await _confirm(
                                  '🚨 恢复分区表',
                                  '将用备份覆盖当前分区表：\n'
                                  '${path.split(Platform.pathSeparator).last}\n\n'
                                  '🚨 这会撤销所有分区改动',
                                );
                                if (ok != true) return;

                                await _run(() => PartitionResizeService
                                    .instance
                                    .restorePartitionTable(
                                      disk: _disk!,
                                      backupPath: path,
                                      confirmed: true,
                                      onLine: _addLog,
                                    ));
                              },
                        icon: const Icon(Icons.restore, size: 14),
                        label: const Text('③ 回滚分区表',
                            style: TextStyle(fontSize: 11.5)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.danger,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 分区列表
                AppCard(
                  title: '分区列表',
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh, size: 15),
                    color: AppTheme.textMuted,
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy ? null : _refresh,
                  ),
                  child: _partitions.isEmpty
                      ? const Text('无数据',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textMuted))
                      : Column(
                          children: [
                            // 表头
                            const Padding(
                              padding: EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  SizedBox(
                                      width: 36,
                                      child: Text('#',
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: AppTheme.textMuted))),
                                  Expanded(
                                      child: Text('名称',
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: AppTheme.textMuted))),
                                  SizedBox(
                                      width: 80,
                                      child: Text('大小',
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: AppTheme.textMuted))),
                                ],
                              ),
                            ),
                            for (final part in _partitions)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 36,
                                      child: Text('${part.number}',
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              fontFamily: 'monospace',
                                              color: part.isUserdata
                                                  ? AppTheme.accent
                                                  : AppTheme.textMuted)),
                                    ),
                                    Expanded(
                                      child: Text(
                                        part.name,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: part.isUserdata
                                              ? AppTheme.accent
                                              : AppTheme.textSecondary,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    SizedBox(
                                      width: 80,
                                      child: Text(
                                        part.size,
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            fontFamily: 'monospace',
                                            color: AppTheme.textSecondary),
                                      ),
                                    ),
                                  ],
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
                      Text('扩容原理',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary)),
                      SizedBox(height: 8),
                      Text(
                        '① 备份分区表（sgdisk --backup）\n'
                        '② 删除 userdata 分区\n'
                        '③ 用新大小重建（起始不变）\n'
                        '④ 恢复分区名和类型码\n'
                        '⑤ 通知内核重读分区表\n'
                        '⑥ e2fsck 检查文件系统\n'
                        '⑦ resize2fs 扩容文件系统',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            height: 1.7),
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
                            if (line.contains('❌') ||
                                line.contains('⚠️') ||
                                line.contains('🚨')) {
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

  /// 算出实际会扩容多少
  String _calcGrowText() {
    final freeGb = double.tryParse(_freeSpace['free_gb'] ?? '0') ?? 0;
    if (_autoSizeMode == 'max') {
      return '${freeGb.toStringAsFixed(1)} GB';
    }
    final targetGb = int.tryParse(_autoSizeMode) ?? 0;
    final ud = _partitions.where((p) => p.isUserdata).firstOrNull;
    final currentGb = ud == null
        ? 0.0
        : double.tryParse(ud.size.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
    final grow = targetGb - currentGb;
    if (grow <= 0) return '已够大';
    if (grow > freeGb) return '${freeGb.toStringAsFixed(1)} GB（上限）';
    return '${grow.toStringAsFixed(1)} GB';
  }


  String _stepLabel(int step) {
    const labels = [
      '',
      '识别设备',
      '推送工具',
      '备份分区表',
      '分析分区',
      '重建分区',
      '扩容文件系统',
      '完成',
    ];
    return step >= 0 && step < labels.length ? labels[step] : '';
  }


  Future<bool?> _confirm(String title, String warning) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(warning,
              style: const TextStyle(fontSize: 12, height: 1.6)),
        ),
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
