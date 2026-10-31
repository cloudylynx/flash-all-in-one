import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/recovery_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 数据恢复与分区修复
class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key});

  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  bool _busy = false;
  String? _testdiskVer;
  String? _photorecVer;

  String? _imagePath;
  Map<String, dynamic>? _fsInfo;

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
    super.dispose();
  }

  Future<void> _init() async {
    await RecoveryService.instance.init();
    final tv = await RecoveryService.instance.testdiskVersion();
    final pv = await RecoveryService.instance.photorecVersion();
    if (!mounted) return;
    setState(() {
      _testdiskVer = tv;
      _photorecVer = pv;
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

  Future<void> _pickImage() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择磁盘镜像（.img / .bin / .dd）',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;

    setState(() => _imagePath = r.files.single.path);

    // 自动检测文件系统
    final fs = await RecoveryService.instance
        .detectFilesystem(r.files.single.path!);
    if (!mounted) return;
    setState(() => _fsInfo = fs);
  }

  Future<void> _scan() async {
    if (_imagePath == null) return;
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await RecoveryService.instance
        .scanPartitionTable(imagePath: _imagePath!, onLine: _addLog);
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _backup() async {
    if (_imagePath == null) return;
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择备份输出目录',
    );
    if (dir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await RecoveryService.instance.backupPartitionTable(
      imagePath: _imagePath!,
      outputDir: dir,
      onLine: _addLog,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _recover() async {
    if (_imagePath == null) return;
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择恢复输出目录（必须在另一块盘）',
    );
    if (dir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await RecoveryService.instance.recoverFiles(
      imagePath: _imagePath!,
      outputDir: dir,
      onLine: _addLog,
    );
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 状态
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_testdiskVer != null
                            ? AppTheme.success
                            : AppTheme.danger)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _testdiskVer != null
                            ? Icons.check_circle
                            : Icons.error,
                        size: 15,
                        color: _testdiskVer != null
                            ? AppTheme.success
                            : AppTheme.danger,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _testdiskVer != null
                            ? 'TestDisk $_testdiskVer  ·  PhotoRec $_photorecVer'
                            : '工具未就绪',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 说明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.25)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '能解决什么',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '① 刷错机型 GPT → 容量错位 / 无法识别分区\n'
                        '② 误删文件 → 按签名雕刻恢复\n'
                        '③ 分区表损坏但数据还在',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.7),
                      ),
                      SizedBox(height: 10),
                      Text(
                        '✅ PhotoRec 是唯一能救 F2FS 的方案\n'
                        '   （sleuthkit 不支持 F2FS）',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.success,
                            height: 1.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 选择镜像
                AppCard(
                  title: '磁盘镜像',
                  trailing: OutlinedButton(
                    onPressed: _busy ? null : _pickImage,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                    child:
                        const Text('选择', style: TextStyle(fontSize: 11.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _imagePath?.split(Platform.pathSeparator).last ??
                            '未选择（可以是 .img / .bin / .dd 或整个磁盘）',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: _imagePath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_fsInfo != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgElevated,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    '文件系统: ${_fsInfo!['fs'] ?? "未知"}',
                                    style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(width: 8),
                                  if (_fsInfo!['supportedBySleuthkit'] == true)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: AppTheme.success
                                            .withValues(alpha: 0.15),
                                        borderRadius:
                                            BorderRadius.circular(3),
                                      ),
                                      child: const Text('sleuthkit 可读',
                                          style: TextStyle(
                                              fontSize: 9,
                                              color: AppTheme.success)),
                                    ),
                                ],
                              ),
                              if (_fsInfo!['note'] != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  _fsInfo!['note'].toString(),
                                  style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppTheme.textMuted,
                                      height: 1.4),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 操作
                AppCard(
                  title: '操作',
                  child: Column(
                    children: [
                      _action(
                        icon: Icons.search,
                        label: '扫描分区表',
                        desc: '只读，不修改任何数据',
                        color: AppTheme.primary,
                        onTap: _imagePath == null ? null : _scan,
                      ),
                      const Divider(height: 16),
                      _action(
                        icon: Icons.save_alt,
                        label: '备份分区表',
                        desc: '修复前的必备步骤',
                        color: AppTheme.success,
                        onTap: _imagePath == null ? null : _backup,
                      ),
                      const Divider(height: 16),
                      _action(
                        icon: Icons.restore,
                        label: '雕刻恢复文件',
                        desc: '按签名恢复，能救 F2FS',
                        color: AppTheme.accent,
                        onTap: _imagePath == null ? null : _recover,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 警告
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.warning.withValues(alpha: 0.25)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber,
                              size: 15, color: AppTheme.warning),
                          SizedBox(width: 6),
                          Text('重要提醒',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.warning)),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '· 恢复输出目录必须在另一块盘\n'
                        '· 写操作不可逆，务必先备份\n'
                        '· 分区表修复建议先在镜像副本上试\n'
                        '· 设备已 Root 时可直接操作 /dev/block/',
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

  Widget _action({
    required IconData icon,
    required String label,
    required String desc,
    required Color color,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null && !_busy;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: enabled ? color : AppTheme.textMuted),
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
}
