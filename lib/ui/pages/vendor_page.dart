import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/heimdall_service.dart';
import '../../services/payload_service.dart';
import '../../services/samloader_service.dart';
import '../../services/sprd_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 厂商专用刷机
///
/// · 三星（Heimdall，Odin 替代）
/// · OTA payload 提取（全品牌通用）
/// · cust 分区处理（华为/荣耀）
class VendorPage extends StatefulWidget {
  const VendorPage({super.key});

  @override
  State<VendorPage> createState() => _VendorPageState();
}

class _VendorPageState extends State<VendorPage> {
  String _tab = Platform.environment['GAOJI_VENDOR_TAB'] ?? 'samsung';
  bool _busy = false;
  String? _heimdallVersion;
  bool _heimdallReady = false;

  // 三星
  final Map<String, String> _samsungFiles = {};
  String? _pitOutput;
  bool _samReady = false;
  String? _samVersion;
  final _samModelController = TextEditingController(text: 'SM-');
  final _samRegionController = TextEditingController(text: 'DBT');
  String? _samLatestFirmware;

  // payload
  String? _payloadPath;
  List<String> _payloadPartitions = [];

  // cust
  String? _custPath;

  // 紫光展锐
  String? _pacPath;
  String? _fdl1Path;
  String? _fdl2Path;
  final _sprdPartController = TextEditingController();
  String? _sprdImageDir;

  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initHeimdall();
    _initSamloader();
  }

  Future<void> _initSamloader() async {
    final ok = await SamloaderService.instance.init();
    String? ver;
    if (ok) ver = await SamloaderService.instance.version();
    if (!mounted) return;
    setState(() {
      _samReady = ok;
      _samVersion = ver;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _sprdPartController.dispose();
    _samModelController.dispose();
    _samRegionController.dispose();
    super.dispose();
  }

  Future<void> _initHeimdall() async {
    final ok = await HeimdallService.instance.init();
    String? ver;
    if (ok) ver = await HeimdallService.instance.version();
    if (!mounted) return;
    setState(() {
      _heimdallReady = ok;
      _heimdallVersion = ver;
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

  Future<void> _heimdallDetect() async {
    setState(() => _busy = true);
    final r = await HeimdallService.instance.detect();
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _heimdallPit() async {
    setState(() => _busy = true);
    final r = await HeimdallService.instance.printPit();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pitOutput = r.message;
    });
    _addLog(r.ok ? '✅ 已读取 PIT' : '❌ 读取失败');
  }

  Future<void> _heimdallFlash() async {
    if (_samsungFiles.isEmpty) {
      _addLog('❌ 请先选择要刷的文件');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('确认刷入'),
        content: Text(
            '将刷入 ${_samsungFiles.length} 个分区：\n\n'
            '${_samsungFiles.entries.map((e) => "${e.key} ← ${e.value.split(Platform.pathSeparator).last}").join("\n")}\n\n'
            '⚠️ 请确认设备处于下载模式（音量下+Home+电源）\n'
            '⚠️ 刷机有变砖风险\n\n'
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

    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await HeimdallService.instance.flashMultiple(
      partitions: _samsungFiles,
      onLine: _addLog,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _pickSamsungFiles() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择三星固件文件（可多选）',
      allowMultiple: true,
    );
    if (r == null) return;

    setState(() {
      for (final f in r.files) {
        if (f.path == null) continue;
        final name = f.name.toLowerCase();
        // 按文件名推断分区
        String? part;
        if (name.startsWith('boot')) {
          part = 'BOOT';
        } else if (name.startsWith('recovery')) {
          part = 'RECOVERY';
        } else if (name.startsWith('system')) {
          part = 'SYSTEM';
        } else if (name.startsWith('vendor')) {
          part = 'VENDOR';
        } else if (name.startsWith('dtbo')) {
          part = 'DTBO';
        } else if (name.startsWith('vbmeta')) {
          part = 'VBMETA';
        } else if (name.startsWith('modem')) {
          part = 'RADIO';
        } else if (name.startsWith('abl')) {
          part = 'ABL';
        } else if (name.startsWith('xbl')) {
          part = 'XBL';
        } else if (name.startsWith('tz')) {
          part = 'TZ';
        } else if (name.startsWith('hyp')) {
          part = 'HYP';
        }

        if (part != null) {
          _samsungFiles[part] = f.path!;
        }
      }
    });
  }

  Future<void> _pickPayload() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 payload.bin',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;

    final path = r.files.single.path!;
    setState(() => _payloadPath = path);
    _addLog('══ 解析 payload.bin');

    final header = await PayloadService.instance.parseHeader(path);
    if (header == null) {
      _addLog('❌ 不是有效的 payload.bin（magic 不是 CrAU）');
      return;
    }
    _addLog('  版本: ${header['version']}');
    _addLog('  manifest: ${header['manifestSize']} B');

    final parts =
        await PayloadService.instance.extractPartitionNames(path);
    if (!mounted) return;
    setState(() => _payloadPartitions = parts);
    _addLog('  发现 ${parts.length} 个分区: ${parts.take(10).join(", ")}'
        '${parts.length > 10 ? "…" : ""}');
  }

  /// 提取 payload 全部分区
  Future<void> _extractPayload() async {
    if (_payloadPath == null) return;

    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择输出目录',
    );
    if (dir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await PayloadService.instance.extractWithDumperGo(
      payloadPath: _payloadPath!,
      outputDir: dir,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _pickCust() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 cust.img（华为/荣耀）',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;
    setState(() => _custPath = r.files.single.path);
    _addLog('══ 选择 cust: ${r.files.single.name}');

    // 检测格式
    final f = File(r.files.single.path!);
    final raf = await f.open();
    final head = await raf.read(2048);
    await raf.close();

    if (head.length > 1082) {
      if (head[1080] == 0x53 && head[1081] == 0xEF) {
        _addLog('  ✅ 检测到 ext4 格式');
      } else if (head[1024] == 0xE2 &&
          head[1025] == 0xE1 &&
          head[1026] == 0xF5 &&
          head[1027] == 0xE0) {
        _addLog('  ✅ 检测到 EROFS 格式');
      } else if (head[0] == 0x3A &&
          head[1] == 0xFF &&
          head[2] == 0x26 &&
          head[3] == 0xED) {
        _addLog('  ⚠️ 检测到 Android Sparse 格式（需先转 raw）');
      } else {
        _addLog('  ⚠️ 未识别格式');
      }
    }
  }



  // ═══ samloader 方法 ═══
  Future<void> _samCheckUpdate() async {
    final model = _samModelController.text.trim();
    final region = _samRegionController.text.trim();
    if (model.isEmpty || model == 'SM-' || region.isEmpty) {
      _addLog('❌ 请输入型号和区域');
      return;
    }

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await SamloaderService.instance.checkUpdate(
      model: model,
      region: region,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      // 从日志里找固件版本
      for (final line in r.log) {
        if (line.contains('/') && line.contains('.')) {
          _samLatestFirmware = line.trim();
          break;
        }
      }
    });
  }

  Future<void> _samDownload() async {
    if (_samLatestFirmware == null) return;

    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择固件保存目录',
    );
    if (dir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await SamloaderService.instance.download(
      model: _samModelController.text.trim(),
      region: _samRegionController.text.trim(),
      firmware: _samLatestFirmware!,
      outputDir: dir,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  // ═══ 紫光展锐处理方法 ═══
  Future<void> _pickPac() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 PAC 固件',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;
    setState(() => _pacPath = r.files.single.path);
    _addLog('══ 选择 PAC: ${r.files.single.name}');
  }

  Future<void> _unpackPac() async {
    if (_pacPath == null) return;
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择解包输出目录',
    );
    if (dir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await SprdService.instance.unpackPac(
      pacPath: _pacPath!,
      outputDir: dir,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _pickFdl1() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 FDL1（fdl1-sign.bin）',
      type: FileType.any,
    );
    if (r != null && r.files.single.path != null) {
      setState(() => _fdl1Path = r.files.single.path);
    }
  }

  Future<void> _pickFdl2() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 FDL2（fdl2-sign.bin）',
      type: FileType.any,
    );
    if (r != null && r.files.single.path != null) {
      setState(() => _fdl2Path = r.files.single.path);
    }
  }

  Future<void> _sprdReadPartition() async {
    final part = _sprdPartController.text.trim();
    if (part.isEmpty) {
      _addLog('❌ 请输入分区名');
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dir == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final out = '$dir${Platform.pathSeparator}$part.img';
    final r = await SprdService.instance.readPartition(
      fdl1Path: _fdl1Path!,
      fdl2Path: _fdl2Path!,
      partition: part,
      outputPath: out,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _sprdWritePartition() async {
    final part = _sprdPartController.text.trim();
    if (part.isEmpty) {
      _addLog('❌ 请输入分区名');
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择要写入的镜像',
      type: FileType.any,
    );
    if (picked == null || picked.files.single.path == null) return;

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text('写入 $part'),
        content: Text(
            '将把镜像写入分区 $part\n\n'
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
            child: const Text('写入'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await SprdService.instance.writePartition(
      fdl1Path: _fdl1Path!,
      fdl2Path: _fdl2Path!,
      partition: part,
      imagePath: picked.files.single.path!,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _sprdErasePartition() async {
    final part = _sprdPartController.text.trim();
    if (part.isEmpty) {
      _addLog('❌ 请输入分区名');
      return;
    }

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text('擦除 $part'),
        content: Text('将清空分区 $part 的所有数据。\n\n'
            '⚠️ 不可恢复！\n\n'
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

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await SprdService.instance.erasePartition(
      fdl1Path: _fdl1Path!,
      fdl2Path: _fdl2Path!,
      partition: part,
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
          child: Column(
            children: [
              // Tab
              Container(
                decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    for (final (id, label) in [
                      ('samsung', '三星'),
                      ('sprd', '紫光展锐'),
                      ('payload', 'OTA payload'),
                      ('cust', 'cust 分区'),
                    ])
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _tab = id),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: _tab == id
                                      ? AppTheme.primary
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Text(
                              label,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: _tab == id
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: _tab == id
                                    ? AppTheme.primary
                                    : AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: _tab == 'samsung'
                      ? _buildSamsung()
                      : _tab == 'sprd'
                          ? _buildSprd()
                          : _tab == 'payload'
                              ? _buildPayload()
                              : _buildCust(),
                ),
              ),
            ],
          ),
        ),

        // 日志
        Container(
          width: 360,
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

  Widget _buildSamsung() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Heimdall 状态
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (_heimdallReady ? AppTheme.success : AppTheme.warning)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: (_heimdallReady ? AppTheme.success : AppTheme.warning)
                    .withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(
                _heimdallReady ? Icons.check_circle : Icons.warning_amber,
                size: 16,
                color: _heimdallReady ? AppTheme.success : AppTheme.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _heimdallReady
                      ? 'Heimdall ${_heimdallVersion ?? "就绪"}（Odin 替代）'
                      : 'Heimdall 未找到（需放到 tools/heimdall/ 或系统 PATH）',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary),
                ),
              ),
              if (!_heimdallReady)
                TextButton(
                  onPressed: _initHeimdall,
                  child: const Text('重试',
                      style: TextStyle(fontSize: 11.5)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // samloader（固件下载 + 刷机）
        AppCard(
          title: '固件下载（samloader）',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: (_samReady ? AppTheme.success : AppTheme.textMuted)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _samReady ? 'v${_samVersion ?? ""} 就绪' : '未就绪',
              style: TextStyle(
                  fontSize: 9.5,
                  color: _samReady ? AppTheme.success : AppTheme.textMuted),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    height: 30,
                    child: TextField(
                      controller: _samModelController,
                      style: const TextStyle(
                          fontSize: 11.5, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: 'SM-G998B',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    height: 30,
                    child: TextField(
                      controller: _samRegionController,
                      style: const TextStyle(
                          fontSize: 11.5, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: 'DBT',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: (_busy || !_samReady) ? null : _samCheckUpdate,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    child: const Text('查询版本',
                        style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              if (_samLatestFirmware != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.download,
                          size: 13, color: AppTheme.success),
                      const SizedBox(width: 7),
                      Expanded(
                        child: SelectableText(
                          _samLatestFirmware!,
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: AppTheme.success),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _samDownload,
                        child: const Text('下载',
                            style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                '区域代码：DBT（德）/ XAA（美）/ CHC（中）/ TGY（港）\n'
                '型号格式：SM-G998B（带 SM- 前缀）',
                style: TextStyle(
                    fontSize: 10, color: AppTheme.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '设备操作',
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: (_busy || !_heimdallReady) ? null : _heimdallDetect,
                icon: const Icon(Icons.usb, size: 15),
                label: const Text('检测设备',
                    style: TextStyle(fontSize: 11.5)),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: (_busy || !_heimdallReady) ? null : _heimdallPit,
                icon: const Icon(Icons.table_chart, size: 15),
                label: const Text('读取 PIT',
                    style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '固件文件',
          trailing: OutlinedButton(
            onPressed: _busy ? null : _pickSamsungFiles,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: _samsungFiles.isEmpty
              ? const Text(
                  '未选择文件\n\n'
                  '自动按文件名识别分区：\n'
                  '  boot*.img → BOOT\n'
                  '  recovery*.img → RECOVERY\n'
                  '  system*.img → SYSTEM\n'
                  '  vendor*.img → VENDOR\n'
                  '  modem*.bin → RADIO',
                  style: TextStyle(
                      fontSize: 11, color: AppTheme.textMuted, height: 1.6),
                )
              : Column(
                  children: [
                    for (final e in _samsungFiles.entries)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.android,
                            size: 15, color: AppTheme.success),
                        title: Text(e.key,
                            style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace')),
                        subtitle: Text(
                          e.value.split(Platform.pathSeparator).last,
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 14),
                          color: AppTheme.textMuted,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(
                              () => _samsungFiles.remove(e.key)),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 18),

        SizedBox(
          height: 46,
          child: ElevatedButton.icon(
            onPressed: (_busy || _samsungFiles.isEmpty) ? null : _heimdallFlash,
            icon: Icon(_busy ? Icons.hourglass_top : Icons.flash_on,
                size: 18),
            label: Text(_busy
                ? '刷入中…'
                : '刷入 ${_samsungFiles.length} 个分区'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
          ),
        ),

        if (_pitOutput != null) ...[
          const SizedBox(height: 14),
          AppCard(
            title: 'PIT 分区表',
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.bgElevated,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                _pitOutput!,
                style: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: AppTheme.textSecondary,
                    height: 1.5),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPayload() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
          ),
          child: const Text(
            'payload.bin 是 A/B OTA 的容器格式（全品牌通用）。\n'
            '从官方 OTA 包里解出来，可以提取其中的分区镜像。\n\n'
            '格式：magic "CrAU" + version + manifest(protobuf) + data blobs',
            style: TextStyle(
                fontSize: 11.5, color: AppTheme.textSecondary, height: 1.6),
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: 'payload.bin',
          trailing: OutlinedButton(
            onPressed: _busy ? null : _pickPayload,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _payloadPath?.split(Platform.pathSeparator).last ??
                    '未选择',
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: _payloadPath != null
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted,
                ),
              ),
              if (_payloadPartitions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in _payloadPartitions)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.bgElevated,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Text(p,
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: AppTheme.textSecondary)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        if (_payloadPath != null)
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _extractPayload,
              icon: Icon(
                  _busy ? Icons.hourglass_top : Icons.download,
                  size: 18),
              label: Text(_busy ? '提取中…' : '提取全部分区'),
            ),
          ),

        const SizedBox(height: 14),
        AppCard(
          title: '说明',
          child: const Text(
            'payload-dumper-go（3582★, Apache-2.0）已内置\n\n'
            '支持：\n'
            '  · 全部分区提取\n'
            '  · 指定分区提取（-p）\n'
            '  · 多线程并发（-c）\n\n'
            'payload.bin 是 A/B OTA 的标准格式，\n'
            '从官方 OTA 包里解出来即可提取各分区镜像。',
            style: TextStyle(
                fontSize: 11, color: AppTheme.textMuted, height: 1.7),
          ),
        ),
      ],
    );
  }


  // ═══ 紫光展锐 ═══

  /// 展锐操作行
  Widget _sprdAction({
    required IconData icon,
    required String label,
    required String desc,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? AppTheme.danger : AppTheme.primary;
    return InkWell(
      onTap: _busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: danger
                              ? AppTheme.danger
                              : AppTheme.textPrimary)),
                  Text(desc,
                      style: const TextStyle(
                          fontSize: 10.5, color: AppTheme.textMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 16, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  Future<void> _sprdReadPartTable() async {
    final save = await FilePicker.platform.saveFile(
      dialogTitle: '保存分区表',
      fileName: 'partition_table.xml',
    );
    if (save == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await SprdService.instance.readPartitionTable(
      outputPath: save,
      onLine: _addLog,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _sprdReadInfo() async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await SprdService.instance.readDeviceInfo(onLine: _addLog);
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Future<void> _sprdPickAndRestore() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择包含 .img 的目录',
    );
    if (dir == null) return;

    setState(() => _sprdImageDir = dir);

    setState(() {
      _busy = true;
      _log.clear();
    });

    // 第一次调用：只扫描列出，不执行
    final preview = await SprdService.instance.restoreFromFolder(
      imageDir: dir,
      confirmed: false,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);

    if (!preview.ok) {
      _addLog('⚠️ ${preview.message}');
      // 弹确认框
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认批量刷入'),
          content: SingleChildScrollView(
            child: Text(
              '即将把 ${dir.split(Platform.pathSeparator).last} 里的所有 .img 刷入设备。\n\n'
              '⚠️ 这是危险操作：\n'
              '  · 刷错分区可能导致设备无法启动\n'
              '  · 请确认目录里的镜像与设备型号匹配\n\n'
              '分区列表见右侧输出面板。',
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.danger,
              ),
              child: const Text('确认刷入'),
            ),
          ],
        ),
      );

      if (ok != true || !mounted) return;

      setState(() => _busy = true);
      final r = await SprdService.instance.restoreFromFolder(
        imageDir: dir,
        confirmed: true,
        onLine: _addLog,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
    }
  }

  Future<void> _sprdDisableAvb() async {
    // 强确认：必须输入短语
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ 关闭 AVB / dm-verity'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '关闭后设备将失去系统完整性保护：',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '· 银行 App / Google Pay 无法使用\n'
                '· 微信/支付宝支付可能失败\n'
                '· Netflix HD 等 DRM 内容无法播放\n'
                '· 反作弊游戏（原神/PUBG）可能拒绝运行\n'
                '· 恶意软件可随意修改系统',
                style: TextStyle(fontSize: 11.5, height: 1.7),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text(
                  '安全设计：执行前会自动备份 trustos 分区。\n'
                  '如果备份失败，操作会立即中止。',
                  style: TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              const Text('请输入「我知道风险」确认：',
                  style: TextStyle(fontSize: 11.5)),
              const SizedBox(height: 6),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: '我知道风险',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim() == '我知道风险') {
                Navigator.pop(ctx, true);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
            ),
            child: const Text('确认执行'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    final backupDir = p.join(
      (await getApplicationSupportDirectory()).path,
      'sprd-backup',
    );

    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await SprdService.instance.disableAvbSafely(
      backupDir: backupDir,
      confirmed: true,
      onLine: _addLog,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  Widget _buildSprd() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.success.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.success.withValues(alpha: 0.25)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '紫光展锐（Unisoc / Spreadtrum）',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.success),
              ),
              SizedBox(height: 6),
              Text(
                '基于 spreadtrum_flash（232★，Unlicense 公有领域）\n\n'
                '覆盖设备：\n'
                '  · 传音全系（Tecno / Infinix / itel）\n'
                '  · 部分三星/诺基亚/摩托低端机\n'
                '  · 其他展锐 SoC 设备',
                style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                    height: 1.6),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: 'PAC 固件解包',
          trailing: OutlinedButton(
            onPressed: _busy ? null : _pickPac,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择 PAC',
                style: TextStyle(fontSize: 11.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _pacPath?.split(Platform.pathSeparator).last ?? '未选择',
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: _pacPath != null
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted,
                ),
              ),
              if (_pacPath != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _unpackPac,
                    icon: const Icon(Icons.unarchive, size: 15),
                    label: const Text('解包',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ═══ 借鉴 sfd_tool 的高级功能 ═══
        AppCard(
          title: '高级维护',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('借鉴 sfd_tool',
                style: TextStyle(fontSize: 9, color: AppTheme.accent)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sprdAction(
                icon: Icons.table_chart,
                label: '读取分区表',
                desc: '导出设备当前分区表到文件',
                onTap: _sprdReadPartTable,
              ),
              const Divider(height: 16),
              _sprdAction(
                icon: Icons.memory,
                label: '读取设备信息',
                desc: '芯片型号 / Flash 类型 / UID / eMMC CID',
                onTap: _sprdReadInfo,
              ),
              const Divider(height: 16),
              _sprdAction(
                icon: Icons.folder_copy,
                label: '批量恢复分区',
                desc: _sprdImageDir == null
                    ? '从文件夹一次性刷入多个分区'
                    : '已选: ${_sprdImageDir!.split(Platform.pathSeparator).last}',
                onTap: _sprdPickAndRestore,
              ),
              const Divider(height: 16),
              _sprdAction(
                icon: Icons.shield_outlined,
                label: '关闭 AVB / dm-verity',
                desc: '自动先备份 trustos 再关闭（降低风险）',
                danger: true,
                onTap: _sprdDisableAvb,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),


        AppCard(
          title: '分区操作（需 FDL 文件）',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _fileRow('FDL1', _fdl1Path, 'fdl1-sign.bin', _pickFdl1),
              const SizedBox(height: 10),
              _fileRow('FDL2', _fdl2Path, 'fdl2-sign.bin', _pickFdl2),
              const SizedBox(height: 10),
              const Text(
                'FDL 文件从 PAC 固件里解出来（解包后找 fdl1-sign.bin / fdl2-sign.bin）\n'
                '\n'
                '分区操作命令（需设备进展锐下载模式）：\n'
                '  读分区 / 写分区 / 擦除分区 / 关机',
                style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.6),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        if (_fdl1Path != null && _fdl2Path != null) ...[
          AppCard(
            title: '分区名',
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: TextField(
                      controller: _sprdPartController,
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: '如 boot / recovery / system',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _sprdReadPartition,
                    icon: const Icon(Icons.download, size: 15),
                    label: const Text('读取',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _sprdWritePartition,
                    icon: const Icon(Icons.upload, size: 15),
                    label: const Text('写入',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _sprdErasePartition,
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('擦除',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _fileRow(
      String label, String? value, String hint, VoidCallback onPick) {
    final name = value?.split(Platform.pathSeparator).last;
    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: AppTheme.bgElevated,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              name ?? hint,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color:
                    name != null ? AppTheme.textPrimary : AppTheme.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton(
          onPressed: onPick,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          child: const Text('选择', style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  Widget _buildCust() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warning.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.warning.withValues(alpha: 0.25)),
          ),
          child: const Text(
            'cust 是华为/荣耀的定制分区，通常为 ext4 或 EROFS 格式。\n'
            '存放运营商定制内容、预装应用、主题资源等。\n\n'
            '处理方式：\n'
            '  · ext4 → 用 e2fsdroid / debugfs 处理\n'
            '  · EROFS → 用 extract.erofs / mkfs.erofs 处理\n'
            '  · Sparse → 先用 simg2img 转 raw',
            style: TextStyle(
                fontSize: 11.5, color: AppTheme.textSecondary, height: 1.6),
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: 'cust 镜像',
          trailing: OutlinedButton(
            onPressed: _busy ? null : _pickCust,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: Text(
            _custPath?.split(Platform.pathSeparator).last ?? '未选择',
            style: TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: _custPath != null
                  ? AppTheme.textPrimary
                  : AppTheme.textMuted,
            ),
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '推荐流程',
          child: const Text(
            '1. 检测格式（选择文件后自动识别）\n\n'
            '2. 如果是 Sparse：\n'
            '   → 去「镜像工具」用 Sparse → Raw 转换\n\n'
            '3. 如果是 EROFS：\n'
            '   → 去「镜像工具」用「解包 EROFS」\n\n'
            '4. 如果是 ext4：\n'
            '   → Linux 下 mount -o loop cust.img /mnt\n'
            '   → 或 e2fsdroid -f cust.img -a /system/etc\n\n'
            '5. 修改后重新打包，刷回 cust 分区',
            style: TextStyle(
                fontSize: 11, color: AppTheme.textMuted, height: 1.75),
          ),
        ),
      ],
    );
  }
}
