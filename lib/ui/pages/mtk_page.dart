import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/mtk_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// MTK 刷机（联发科）
///
/// 基于 penumbra (antumbra)。
/// 支持刷机/读回/擦除/解锁。
class MtkPage extends StatefulWidget {
  const MtkPage({super.key});

  @override
  State<MtkPage> createState() => _MtkPageState();
}

class _MtkPageState extends State<MtkPage> {
  List<MtkDevice> _devices = [];
  List<MtkPartition> _partitions = [];
  String? _scatterPath;
  String? _imageDir;
  String? _toolVersion;
  bool _toolReady = false;
  bool _scanning = false;
  bool _flashing = false;
  String? _selectedPartition;

  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initTool();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initTool() async {
    final ok = await MtkService.instance.init();
    String? ver;
    if (ok) ver = await MtkService.instance.version();
    if (!mounted) return;
    setState(() {
      _toolReady = ok;
      _toolVersion = ver;
    });
    if (ok) _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final list = await MtkService.instance.scanDevices();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _scanning = false;
    });
  }

  Future<void> _pickScatter() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 scatter 文件',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (r == null || r.files.single.path == null) return;

    final path = r.files.single.path!;
    setState(() {
      _scatterPath = path;
      _imageDir = File(path).parent.path;
    });

    final parts = await MtkService.instance.parseScatter(path);
    if (!mounted) return;
    setState(() => _partitions = parts);

    _addLog('══ 解析 scatter：${parts.length} 个分区');
    for (final p in parts.take(10)) {
      _addLog('  ${p.name.padRight(20)} ${p.sizeText}');
    }
    if (parts.length > 10) _addLog('  ... 还有 ${parts.length - 10} 个');
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

  Future<void> _flashScatter() async {
    if (_scatterPath == null || _imageDir == null) {
      _snack('请先选择 scatter 文件');
      return;
    }
    final ok = await _confirm('全量刷机', '按 scatter 刷入所有分区\n\n'
        'scatter: ${_scatterPath!.split(Platform.pathSeparator).last}\n'
        '目录: $_imageDir\n\n'
        '刷机过程中请勿断开 USB！');
    if (!ok) return;

    setState(() {
      _flashing = true;
      _log.clear();
    });

    await MtkService.instance.flashScatter(
      scatterPath: _scatterPath!,
      imageDir: _imageDir!,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _flashing = false);
  }

  Future<void> _flashSingle(MtkPartition part) async {
    if (part.file == null) {
      _snack('该分区没有关联文件');
      return;
    }
    final imgPath = '$_imageDir${Platform.pathSeparator}${part.file}';
    if (!File(imgPath).existsSync()) {
      _snack('文件不存在：${part.file}');
      return;
    }

    final ok = await _confirm('刷入分区', '分区: ${part.name}\n文件: ${part.file}');
    if (!ok) return;

    setState(() {
      _flashing = true;
      _log.clear();
    });

    await MtkService.instance.flashPartition(
      partitionName: part.name,
      imagePath: imgPath,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _flashing = false);
  }

  Future<void> _unlock() async {
    final ok = await _confirm('解锁 Bootloader',
        '仅对存在漏洞的 MTK 设备有效。\n解锁会清空数据，且可能失去保修。\n\n继续？');
    if (!ok) return;

    setState(() {
      _flashing = true;
      _log.clear();
    });
    await MtkService.instance.unlockBootloader(onLine: _addLog);
    if (!mounted) return;
    setState(() => _flashing = false);
  }

  Future<bool> _confirm(String title, String content) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text(title),
        content:
            Text(content, style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始')),
        ],
      ),
    );
    return r ?? false;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_toolReady) {
      return EmptyState(
        icon: Icons.extension_off,
        title: 'antumbra 未就绪',
        subtitle: 'MTK 刷机需要 penumbra (antumbra) 二进制。\n'
            '请将 antumbra 放到应用目录 tools/ 下，\n'
            '或安装到系统 PATH。',
        action: ElevatedButton.icon(
          onPressed: _initTool,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重新检测'),
        ),
      );
    }

    return Row(
      children: [
        // 左侧配置
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 工具状态
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.success.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle,
                          size: 16, color: AppTheme.success),
                      const SizedBox(width: 8),
                      Text(
                        'antumbra ${_toolVersion ?? ""}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _scanning ? null : _scan,
                        child: const Text('扫描设备'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 设备
                AppCard(
                  title: 'MTK 设备',
                  child: _scanning
                      ? const InlineLoader(text: '扫描中')
                      : _devices.isEmpty
                          ? const Text(
                              '未检测到 MTK 设备\n\n'
                              '进入方式：\n'
                              '· 关机后按住音量键插 USB（BROM 模式）\n'
                              '· 或 adb reboot edl\n'
                              '· Windows 需装 MediaTek VCOM 驱动\n'
                              '· 漏洞利用需 libusb/WinUSB 驱动（Zadig）',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textMuted,
                                  height: 1.7),
                            )
                          : Column(
                              children: [
                                for (final d in _devices)
                                  ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.memory,
                                        size: 16, color: AppTheme.accent),
                                    title: Text(d.port,
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            fontFamily: 'monospace')),
                                    subtitle: Text(d.mode,
                                        style:
                                            const TextStyle(fontSize: 11)),
                                  ),
                              ],
                            ),
                ),
                const SizedBox(height: 14),

                // Scatter
                AppCard(
                  title: 'Scatter 刷机包',
                  trailing: OutlinedButton(
                    onPressed: _pickScatter,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                    child: const Text('选择', style: TextStyle(fontSize: 11.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _scatterPath?.split(Platform.pathSeparator).last ??
                            '未选择 scatter 文件（MTxxxx_Android_scatter.txt）',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: _scatterPath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                      ),
                      if (_partitions.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('${_partitions.length} 个分区',
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textMuted)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 分区列表
                if (_partitions.isNotEmpty)
                  AppCard(
                    title: '分区',
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _partitions.length,
                        itemBuilder: (context, i) {
                          final part = _partitions[i];
                          final canFlash =
                              part.file != null && part.isDownload;
                          return ListTile(
                            dense: true,
                            selected: _selectedPartition == part.name,
                            leading: Icon(
                              canFlash ? Icons.sd_storage : Icons.block,
                              size: 15,
                              color: canFlash
                                  ? AppTheme.textSecondary
                                  : AppTheme.textMuted,
                            ),
                            title: Text(part.name,
                                style: const TextStyle(
                                    fontSize: 12, fontFamily: 'monospace')),
                            subtitle: Text(
                              '${part.file ?? "—"}  ${part.sizeText}',
                              style: const TextStyle(fontSize: 10.5),
                            ),
                            trailing: canFlash
                                ? IconButton(
                                    icon: const Icon(Icons.play_arrow, size: 16),
                                    color: AppTheme.primary,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _flashing
                                        ? null
                                        : () => _flashSingle(part),
                                  )
                                : null,
                            onTap: () =>
                                setState(() => _selectedPartition = part.name),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 18),

                // 操作按钮
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed:
                              _flashing ? null : _flashScatter,
                          icon: Icon(
                              _flashing ? Icons.hourglass_top : Icons.flash_on,
                              size: 18),
                          label: Text(_flashing ? '刷机中…' : '全量刷机'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.danger,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 46,
                      child: OutlinedButton.icon(
                        onPressed: _flashing ? null : _unlock,
                        icon: const Icon(Icons.lock_open, size: 16),
                        label: const Text('解锁 BL'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // 右侧日志
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
                    const Icon(Icons.article_outlined,
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
                                  fontSize: 12, color: AppTheme.textMuted)),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(10),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final line = _log[i];
                            Color color = AppTheme.textSecondary;
                            if (line.contains('✅') || line.contains('成功')) {
                              color = AppTheme.success;
                            }
                            if (line.contains('❌') || line.contains('错误')) {
                              color = AppTheme.danger;
                            }
                            if (line.startsWith('══')) color = AppTheme.accent;
                            return SelectableText(
                              line,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: color,
                                height: 1.45,
                              ),
                            );
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
