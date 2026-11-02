import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/modem_backup_service.dart';
import '../../services/multiboot_service.dart';
import '../../services/windows_tweak_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 多系统工具箱（危险操作）
class MultibootPage extends StatefulWidget {
  const MultibootPage({super.key});

  @override
  State<MultibootPage> createState() => _MultibootPageState();
}

class _MultibootPageState extends State<MultibootPage> {
  bool _busy = false;
  Map<String, String> _storageInfo = {};

  final _diskController = TextEditingController(text: '/dev/block/sda');
  final _targetController = TextEditingController();
  final _mountController = TextEditingController(text: '/mnt/win');
  final _wimIndexController = TextEditingController(text: '1');
  final _winDirController = TextEditingController();
  String? _wimPath;
  List<ModemPartition> _modemParts = [];
  bool _modemScanning = false;

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
    _diskController.dispose();
    _targetController.dispose();
    _mountController.dispose();
    _wimIndexController.dispose();
    _winDirController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await MultibootService.instance.init();
    if (!mounted) return;
    // ready 状态由后续扫描体现

    if (ok) {
      final info = await MultibootService.instance.getStorageInfo();
      if (!mounted) return;
      setState(() {
        _storageInfo = info;
        if (info['device'] != null) {
          _diskController.text = info['device']!;
        }
      });
    }

    // 扫描基带分区
    await _scanModem();
  }

  Future<void> _scanModem() async {
    setState(() => _modemScanning = true);
    final parts = await ModemBackupService.instance.scanPartitions(
      onLine: (s) => _addLog(s),
    );
    if (!mounted) return;
    setState(() {
      _modemParts = parts;
      _modemScanning = false;
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

  Future<void> _run(Future<MultibootResult> Function() action) async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _runModem(Future<ModemResult> Function() action) async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
    await _scanModem();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 顶部警告
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: AppTheme.danger.withValues(alpha: 0.3)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber,
                              size: 16, color: AppTheme.danger),
                          SizedBox(width: 7),
                          Text('多系统工具箱',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.danger)),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '在安卓设备上安装 Windows / Linux 等多系统。\n\n'
                        '⚠️ 这会修改分区表，操作不当会导致设备变砖\n'
                        '⚠️ 刷机前必须先备份字库（整个存储芯片）',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 存储信息
                if (_storageInfo.isNotEmpty)
                  AppCard(
                    title: '存储信息',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('已识别',
                          style: TextStyle(
                              fontSize: 9, color: AppTheme.success)),
                    ),
                    child: Column(
                      children: [
                        InfoRow(
                          label: '设备',
                          value: _storageInfo['device'] ?? '-',
                          monospace: true,
                        ),
                        if (_storageInfo['name'] != null)
                          InfoRow(
                            label: '型号',
                            value: _storageInfo['name']!,
                            monospace: true,
                          ),
                        if (_storageInfo['size_gb'] != null)
                          InfoRow(
                            label: '容量',
                            value: '${_storageInfo['size_gb']} GB',
                          ),
                      ],
                    ),
                  ),
                if (_storageInfo.isNotEmpty) const SizedBox(height: 14),

                // ═══ 字库备份（最重要）═══
                AppCard(
                  title: '字库备份（刷机前必做）',
                  trailing: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('重要',
                        style: TextStyle(
                            fontSize: 9, color: AppTheme.primary)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '字库 = eMMC/UFS 存储芯片。备份整个芯片内容，\n'
                        '变砖时可以用它恢复。这是刷机前最重要的一步。',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            height: 1.6),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const SizedBox(
                            width: 70,
                            child: Text('磁盘',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.textSecondary)),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _diskController,
                              decoration: const InputDecoration(
                                hintText: '/dev/block/sda',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                              ),
                              style: const TextStyle(
                                  fontSize: 11, fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _run(() => MultibootService.instance
                                      .backupPartitionTable(
                                        outputPath:
                                            '/tmp/gpt-${DateTime.now().millisecondsSinceEpoch}.bin',
                                        disk: _diskController.text.trim(),
                                        onLine: _addLog,
                                      )),
                              icon: const Icon(Icons.table_chart, size: 14),
                              label: const Text('备份分区表',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final save =
                                          await FilePicker.platform.saveFile(
                                        dialogTitle: '保存字库备份',
                                        fileName:
                                            'storage-backup-${DateTime.now().millisecondsSinceEpoch}.img.zst',
                                      );
                                      if (save == null) return;

                                      final ok = await _confirm(
                                        '备份字库',
                                        '将备份整个存储芯片到：\n$save\n\n'
                                            '⚠️ 文件可能很大（10-256 GB）\n'
                                            '⚠️ 需要 10-60 分钟\n'
                                            '⚠️ 确保磁盘有足够空间',
                                      );
                                      if (ok != true) return;

                                      await _run(() => MultibootService.instance
                                          .backupStorage(
                                            outputPath: save,
                                            disk: _diskController.text.trim(),
                                            compress: true,
                                            confirmed: true,
                                            onLine: _addLog,
                                          ));
                                    },
                              icon: const Icon(Icons.save_alt, size: 14),
                              label: const Text('备份字库',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final r =
                                          await FilePicker.platform.pickFiles(
                                        dialogTitle: '选择字库备份文件',
                                        type: FileType.any,
                                      );
                                      if (r == null ||
                                          r.files.single.path == null) {
                                        return;
                                      }
                                      final path = r.files.single.path!;

                                      final ok = await _confirm(
                                        '🚨 恢复字库',
                                        '将用以下备份覆盖整个存储芯片：\n'
                                            '${path.split(Platform.pathSeparator).last}\n\n'
                                            '🚨 极度危险：\n'
                                            '· 会覆盖所有数据\n'
                                            '· 中断会导致设备变砖\n'
                                            '· 请确认备份文件与设备匹配',
                                      );
                                      if (ok != true) return;

                                      await _run(() => MultibootService.instance
                                          .restoreStorage(
                                            backupPath: path,
                                            disk: _diskController.text.trim(),
                                            compressed:
                                                path.endsWith('.zst'),
                                            confirmed: true,
                                            onLine: _addLog,
                                          ));
                                    },
                              icon: const Icon(Icons.restore, size: 14),
                              label: const Text('恢复字库',
                                  style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.danger,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ 基带备份 ═══
                AppCard(
                  title: '基带备份',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('重要',
                        style: TextStyle(
                            fontSize: 9, color: AppTheme.warning)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '基带（modem）刷丢了会没信号、IMEI 归零，\n'
                        '比变砖还麻烦。刷机前必须备份。',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            height: 1.6),
                      ),
                      const SizedBox(height: 12),

                      // 扫描结果
                      if (_modemScanning)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                    strokeWidth: 1.5),
                              ),
                              SizedBox(width: 8),
                              Text('正在扫描基带分区…',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textMuted)),
                            ],
                          ),
                        )
                      else if (_modemParts.isEmpty)
                        Row(
                          children: [
                            const Icon(Icons.info_outline,
                                size: 13, color: AppTheme.textMuted),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text('未检测到基带分区（需要 root）',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textMuted)),
                            ),
                            TextButton(
                              onPressed: _busy ? null : _scanModem,
                              child: const Text('重新扫描',
                                  style: TextStyle(fontSize: 10)),
                            ),
                          ],
                        )
                      else ...[
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgElevated,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Column(
                            children: [
                              for (final part in _modemParts)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.check_circle,
                                          size: 11,
                                          color: AppTheme.success),
                                      const SizedBox(width: 6),
                                      SizedBox(
                                        width: 90,
                                        child: Text(part.name,
                                            style: const TextStyle(
                                                fontSize: 10.5,
                                                fontFamily: 'monospace',
                                                color:
                                                    AppTheme.textPrimary)),
                                      ),
                                      Expanded(
                                        child: Text(part.description,
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: AppTheme.textMuted),
                                            overflow:
                                                TextOverflow.ellipsis),
                                      ),
                                      Text(part.sizeText,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              fontFamily: 'monospace',
                                              color: AppTheme.accent)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        final dir = await FilePicker.platform
                                            .getDirectoryPath(
                                                dialogTitle: '选择基带备份保存目录');
                                        if (dir == null) return;

                                        final ok = await _confirm(
                                          '备份全部基带分区',
                                          '将备份 ${_modemParts.length} 个基带分区到：\n'
                                          '$dir\n\n'
                                          '⚠️ 需要 root\n'
                                          '⚠️ 文件不大（通常几 MB 到几十 MB）',
                                        );
                                        if (ok != true) return;

                                        await _runModem(() =>
                                            ModemBackupService.instance
                                                .backupAll(
                                              outputDir: dir,
                                              onLine: _addLog,
                                            ));
                                      },
                                icon: const Icon(Icons.save_alt, size: 14),
                                label: Text(
                                    '备份全部（${_modemParts.length} 个）',
                                    style: const TextStyle(fontSize: 11)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed:
                                  _busy ? null : () async {
                                    final r = await FilePicker.platform
                                        .pickFiles(
                                      dialogTitle: '选择基带镜像',
                                      type: FileType.any,
                                    );
                                    if (r == null ||
                                        r.files.single.path == null) {
                                      return;
                                    }
                                    final path = r.files.single.path!;
                                    final name = path
                                        .split(Platform.pathSeparator)
                                        .last
                                        .replaceAll('.img', '');

                                    final ok = await _confirm(
                                      '🚨 恢复基带分区',
                                      '将用以下镜像覆盖设备上的 $name 分区：\n'
                                      '${path.split(Platform.pathSeparator).last}\n\n'
                                      '🚨 镜像与设备不匹配会导致没信号',
                                    );
                                    if (ok != true) return;

                                    await _runModem(() => ModemBackupService
                                        .instance
                                        .restorePartition(
                                          partitionName: name,
                                          imagePath: path,
                                          confirmed: true,
                                          onLine: _addLog,
                                        ));
                                  },
                              icon: const Icon(Icons.restore, size: 14),
                              label: const Text('恢复',
                                  style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.danger,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ 分区操作 ═══
                AppCard(
                  title: '分区操作',
                  child: Column(
                    children: [
                      _action(Icons.list, '查看所有分区', 'parted -l',
                          () => _run(() => MultibootService.instance
                              .listPartitions(onLine: _addLog))),
                      const Divider(height: 16),
                      _action(Icons.table_chart, '查看磁盘分区表', 'parted print',
                          () => _run(() => MultibootService.instance.printDisk(
                                disk: _diskController.text.trim(),
                                onLine: _addLog,
                              ))),
                      const Divider(height: 16),
                      _action(Icons.security, '备份 BBP 分区',
                          '高通 Bootloader 备份分区', () async {
                        final save = await FilePicker.platform.saveFile(
                          dialogTitle: '保存 BBP 备份',
                          fileName:
                              'bbp-${DateTime.now().millisecondsSinceEpoch}.img',
                        );
                        if (save == null) {
                          return;
                        }
                        await _run(() => MultibootService.instance.backupBbp(
                              outputPath: save,
                              onLine: _addLog,
                            ));
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ 格式化分区 ═══
                AppCard(
                  title: '格式化分区',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '支持 NTFS / exFAT / FAT32 / ext4。\n'
                        '装多系统时，Windows 分区需要 NTFS。',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            height: 1.6),
                      ),
                      const SizedBox(height: 12),
                      _fieldRow('目标分区', _targetController,
                          hint: '/dev/block/sda25'),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _doFormat('ntfs'),
                              child: const Text('格式化为 NTFS',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _doFormat('fat32'),
                              child: const Text('FAT32',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _doFormat('ext4'),
                              child: const Text('ext4',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                final ok = await _confirm(
                                  '🚨 TWRP 格式化 data',
                                  '会卸载 /data 并重新创建 ext4 文件系统。\n\n'
                                      '⚠️ 所有应用数据、照片、设置全部丢失\n'
                                      '⚠️ 但能彻底解决加密问题',
                                );
                                if (ok != true) return;

                                await _run(() => MultibootService.instance
                                    .twrpFormatData(
                                      confirmed: true,
                                      onLine: _addLog,
                                    ));
                              },
                        icon: const Icon(Icons.delete_forever, size: 14),
                        label: const Text('TWRP 格式化 data（绕过加密）',
                            style: TextStyle(fontSize: 11)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.danger,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ 安装 Windows ═══
                AppCard(
                  title: '安装 Windows',
                  trailing: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final r = await FilePicker.platform.pickFiles(
                              dialogTitle: '选择 Windows 镜像（install.wim）',
                              type: FileType.any,
                            );
                            if (r != null && r.files.single.path != null) {
                              setState(() => _wimPath = r.files.single.path);
                            }
                          },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                    child: const Text('选择 WIM',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _wimPath?.split(Platform.pathSeparator).last ??
                            '未选择 install.wim',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: _wimPath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      _fieldRow('目标分区', _targetController,
                          hint: '/dev/block/sda25'),
                      const SizedBox(height: 8),
                      _fieldRow('挂载点', _mountController, hint: '/mnt/win'),
                      const SizedBox(height: 8),
                      _fieldRow('WIM 分卷', _wimIndexController, hint: '1'),
                      const SizedBox(height: 12),
                      const Text(
                        '流程：格式化分区 → 挂载 → 解压 WIM → 创建启动项',
                        style: TextStyle(
                            fontSize: 10.5, color: AppTheme.textMuted),
                      ),

                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      const Text(
                        '大容量模式（把手机变成 USB 移动硬盘）',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '合成一个特殊 boot，刷进去后开机会把分区通过 USB '
                        '暴露给电脑，电脑上直接读写分区（慎用 dd）。\n'
                        '⚠️ 刷这个 boot 后设备不能正常进系统，用完要刷回原 boot。',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: AppTheme.textMuted,
                            height: 1.5),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _makeMsmBoot,
                        icon: const Icon(Icons.usb, size: 15),
                        label: const Text('合成大容量 Boot（msm.img）',
                            style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.warning,
                          side: BorderSide(
                              color: AppTheme.warning.withValues(alpha: 0.4)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ═══ Windows 系统调整 ═══
                if (Platform.isWindows)
                  AppCard(
                    title: 'Windows 系统调整',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('离线注册表',
                          style: TextStyle(
                              fontSize: 9, color: AppTheme.accent)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '装完 Windows 后，系统还没启动时，\n'
                          '直接改注册表文件。需要填 Windows 盘符。',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                              height: 1.6),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const SizedBox(
                              width: 70,
                              child: Text('Windows',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: AppTheme.textSecondary)),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _winDirController,
                                decoration: const InputDecoration(
                                  hintText: '例如 D: 或 E:',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                                style: const TextStyle(
                                    fontSize: 11, fontFamily: 'monospace'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _winAction(Icons.wifi_off, '跳过 Win11 联网激活',
                            'BypassNRO = 1',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance
                                    .skipWin11Online(
                                        winDir: dir, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.skip_next, '跳过开机向导',
                            '启用 Administrator 账户',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance.skipOobe(
                                    winDir: dir, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.disc_full, '关闭磁盘检查',
                            'BootExecute 清空',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance.disableDiskCheck(
                                    winDir: dir, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.healing, '禁用自动修复',
                            '关闭 WinRE',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance.disableAutoRepair(
                                    winDir: dir, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.usb, 'USB 模式 → Host',
                            '当电脑用（外接键鼠）',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance.setUsbMode(
                                    winDir: dir, mode: 1, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.usb, 'USB 模式 → Device',
                            '当 U 盘用',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance.setUsbMode(
                                    winDir: dir, mode: 3, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.usb, 'USB 模式 → 双角色',
                            '自动切换（推荐）',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance.setUsbMode(
                                    winDir: dir, mode: 6, onLine: _addLog))),

                        const Divider(height: 14),
                        _winAction(Icons.branding_watermark, '去除测试模式水印',
                            '改 3 个 .mui 资源文件',
                            () => _runWinTweak((dir) =>
                                WindowsTweakService.instance
                                    .removeTestModeWatermark(
                                        winDir: dir, onLine: _addLog))),
                        const Divider(height: 14),
                        _winAction(Icons.image, '从 ISO 提取 install.wim',
                            '选 ISO → 解出系统镜像',
                            () => _extractWimFromIso()),
                      ],
                    ),
                  ),
                if (Platform.isWindows) const SizedBox(height: 14),

                // ═══ 支持设备 ═══
                AppCard(
                  title: '已知支持的设备',
                  child: Column(
                    children: [
                      for (final d in MultibootService.supportedDevices)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 130,
                                child: Text(d['device']!,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textPrimary)),
                              ),
                              Expanded(
                                child: Text(d['codename']!,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        fontFamily: 'monospace',
                                        color: AppTheme.textMuted)),
                              ),
                              Text(d['support']!,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: d['support']!.startsWith('✅')
                                          ? AppTheme.success
                                          : AppTheme.warning)),
                            ],
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

  Future<void> _runWinTweak(
      Future<WinTweakResult> Function(String winDir) action) async {
    final dir = _winDirController.text.trim();
    if (dir.isEmpty) {
      _addLog('❌ 请先填写 Windows 盘符（如 D: 或 E:）');
      return;
    }

    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await action(dir);
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  /// 合成大容量 Boot（msm.img）
  Future<void> _makeMsmBoot() async {
    // 1. 选源 boot.img
    final src = await FilePicker.platform.pickFiles(
      dialogTitle: '选择要修改的 boot.img（原厂 boot 或已 root 的）',
      type: FileType.any,
    );
    if (src == null || src.files.single.path == null) return;

    // 2. 选输出位置
    final save = await FilePicker.platform.saveFile(
      dialogTitle: '保存 msm.img',
      fileName: 'msm.img',
      type: FileType.any,
    );
    if (save == null) return;

    // 3. 确认（这是危险操作）
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ 合成大容量 Boot'),
        content: const Text(
          '会生成一个特殊的 boot.img，刷进去后：\n'
          '· 开机会把 /dev/sda 通过 USB 暴露成移动硬盘\n'
          '· 电脑上可直接读写分区（慎用 dd）\n'
          '· 设备不能正常进系统\n\n'
          '用完必须刷回原来的 boot.img 才能正常开机。\n\n'
          '确定继续？',
          style: TextStyle(fontSize: 12.5, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.warning),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('生成')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await MultibootService.instance.makeMsmBoot(
      bootImage: src.files.single.path!,
      outputPath: save,
      blockDevice: '/dev/sda',
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  /// 从 ISO 提取 install.wim
  Future<void> _extractWimFromIso() async {
    // 1. 选 ISO
    final iso = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 Windows ISO 文件',
      type: FileType.any,
    );
    if (iso == null || iso.files.single.path == null) return;
    final isoPath = iso.files.single.path!;

    // 2. 选输出目录
    final outDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 install.wim 保存目录',
    );
    if (outDir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await WindowsTweakService.instance.extractWimFromIso(
      isoPath: isoPath,
      outputDir: outDir,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Widget _winAction(IconData icon, String label, String desc,
      Future<void> Function() onTap) {
    final enabled = !_busy;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon,
                size: 15,
                color: enabled ? AppTheme.accent : AppTheme.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          color: enabled
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted)),
                  Text(desc,
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textMuted)),
                ],
              ),
            ),
            if (enabled)
              const Icon(Icons.chevron_right,
                  size: 15, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }


  Future<void> _doFormat(String fsType) async {
    final target = _targetController.text.trim();
    if (target.isEmpty) {
      _addLog('❌ 请先填写目标分区');
      return;
    }

    final ok = await _confirm(
      '格式化 $fsType',
      '将把 $target 格式化为 $fsType。\n\n'
          '⚠️ 此分区数据将全部丢失',
    );
    if (ok != true) return;

    await _run(() => MultibootService.instance.formatPartition(
          partition: target,
          fsType: fsType,
          confirmed: true,
          onLine: _addLog,
        ));
  }


  Widget _fieldRow(String label, TextEditingController c, {String? hint}) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 11.5, color: AppTheme.textSecondary)),
        ),
        Expanded(
          child: TextField(
            controller: c,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
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
