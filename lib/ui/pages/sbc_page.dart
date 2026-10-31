import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/sbc_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 单板电脑固件刷写（Rockchip / Allwinner）
class SbcPage extends StatefulWidget {
  const SbcPage({super.key});

  @override
  State<SbcPage> createState() => _SbcPageState();
}

class _SbcPageState extends State<SbcPage> {
  String _vendor = 'rockchip';
  bool _busy = false;
  String? _rkVer;
  bool _ready = false;

  String? _loaderPath;
  String? _imagePath;
  String? _gptPath;
  String? _ubootPath;
  final _sectorController = TextEditingController(text: '0x8000');

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
    _sectorController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await SbcService.instance.init();
    final ver = await SbcService.instance.rkVersion();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _rkVer = ver;
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

  Future<void> _run(Future<SbcResult> Function() action) async {
    setState(() {
      _busy = true;
      _log.clear();
    });
    final r = await action();
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
              // 厂商 Tab
              Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    for (final (id, label, sub) in [
                      ('rockchip', 'Rockchip', '瑞芯微 RK3399/RK3588/RK3568'),
                      ('allwinner', 'Allwinner', '全志 H3/H6/A64/T507'),
                    ])
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _vendor = id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: _vendor == id
                                      ? AppTheme.primary
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: _vendor == id
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: _vendor == id
                                        ? AppTheme.primary
                                        : AppTheme.textSecondary,
                                  ),
                                ),
                                Text(
                                  sub,
                                  style: const TextStyle(
                                      fontSize: 9,
                                      color: AppTheme.textMuted),
                                ),
                              ],
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
                  child: _vendor == 'rockchip'
                      ? _buildRockchip()
                      : _buildAllwinner(),
                ),
              ),
            ],
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

  Widget _buildRockchip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 状态
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (_ready ? AppTheme.success : AppTheme.danger)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(_ready ? Icons.check_circle : Icons.error,
                  size: 15,
                  color: _ready ? AppTheme.success : AppTheme.danger),
              const SizedBox(width: 8),
              Text(
                _ready
                    ? 'rkdeveloptool ${_rkVer ?? ""}'
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
            border:
                Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('刷机流程',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary)),
              SizedBox(height: 8),
              Text(
                '① 设备进 Maskrom 模式（按住 Recovery 键上电）\n'
                '② 下载 Loader（db）→ 进入 Loader 模式\n'
                '③ 打印分区表（ppt）确认\n'
                '④ 写 GPT（gpt）或写镜像（wl）\n'
                '⑤ 重启（rd）',
                style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textSecondary,
                    height: 1.8),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 检测
        AppCard(
          title: '设备检测',
          child: Column(
            children: [
              _action(Icons.usb, '列出设备', 'Maskrom / Loader 模式均可',
                  () => _run(() => SbcService.instance.rkListDevices(onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.memory, 'Flash 信息', '芯片型号 + 容量',
                  () => _run(() => SbcService.instance.rkFlashInfo(onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.developer_board, '芯片信息', 'SoC 型号',
                  () => _run(() => SbcService.instance.rkChipInfo(onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.table_chart, '打印分区表', 'ppt',
                  () => _run(() => SbcService.instance.rkPrintPartitions(onLine: _addLog))),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Loader
        AppCard(
          title: 'Loader（Maskrom 必须）',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final r = await FilePicker.platform.pickFiles(
                      dialogTitle: '选择 Loader 文件（*.bin）',
                      type: FileType.any,
                    );
                    if (r != null && r.files.single.path != null) {
                      setState(() => _loaderPath = r.files.single.path);
                    }
                  },
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
                _loaderPath?.split(Platform.pathSeparator).last ??
                    '未选择（RK3588Loader.bin 等）',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: _loaderPath != null
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (_loaderPath != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() => SbcService.instance
                            .rkDownloadLoader(
                                loaderPath: _loaderPath!, onLine: _addLog)),
                    icon: const Icon(Icons.download, size: 15),
                    label: const Text('下载并运行 Loader',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 写入
        AppCard(
          title: '写入操作',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // GPT
              Row(
                children: [
                  const Expanded(
                    child: Text('写 GPT 分区表',
                        style: TextStyle(fontSize: 12)),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final r = await FilePicker.platform.pickFiles(
                              dialogTitle: '选择 GPT 文件',
                              type: FileType.any,
                            );
                            if (r != null && r.files.single.path != null) {
                              setState(() => _gptPath = r.files.single.path);
                            }
                          },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                    ),
                    child: Text(
                      _gptPath == null ? '选择' : '已选',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: (_busy || _gptPath == null)
                        ? null
                        : () => _run(() async {
                              final ok = await _confirm('写 GPT 分区表',
                                  'GPT 写错会导致所有分区丢失，设备无法启动。');
                              if (ok != true) {
                                return SbcResult(false, '已取消', []);
                              }
                              return SbcService.instance.rkWriteGpt(
                                  gptPath: _gptPath!,
                                  confirmed: true,
                                  onLine: _addLog);
                            }),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      backgroundColor: AppTheme.danger,
                    ),
                    child:
                        const Text('写入', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              const Divider(height: 20),
              // 镜像
              Row(
                children: [
                  const Expanded(
                    child: Text('写镜像到 LBA',
                        style: TextStyle(fontSize: 12)),
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _sectorController,
                      decoration: const InputDecoration(
                        hintText: '起始扇区',
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final r = await FilePicker.platform.pickFiles(
                              dialogTitle: '选择镜像文件',
                              type: FileType.any,
                            );
                            if (r != null && r.files.single.path != null) {
                              setState(() => _imagePath = r.files.single.path);
                            }
                          },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                    ),
                    child: Text(
                      _imagePath == null ? '选择' : '已选',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: (_busy || _imagePath == null)
                        ? null
                        : () => _run(() async {
                              final sector = int.tryParse(
                                  _sectorController.text.replaceAll('0x', ''),
                                  radix: 16);
                              if (sector == null) {
                                return SbcResult(false, '扇区号无效', []);
                              }
                              final ok = await _confirm('写镜像',
                                  '将写入扇区 $sector，写错位置会导致设备无法启动。');
                              if (ok != true) {
                                return SbcResult(false, '已取消', []);
                              }
                              return SbcService.instance.rkWriteLba(
                                  beginSector: sector,
                                  imagePath: _imagePath!,
                                  confirmed: true,
                                  onLine: _addLog);
                            }),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      backgroundColor: AppTheme.danger,
                    ),
                    child:
                        const Text('写入', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 其他
        AppCard(
          title: '其他',
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('切换存储', style: TextStyle(fontSize: 12)),
                  ),
                  for (final (id, label) in [(1, 'eMMC'), (2, 'SD'), (9, 'SPI')])
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() => SbcService.instance
                                .rkChangeStorage(
                                    storage: id, onLine: _addLog)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          minimumSize: Size.zero,
                        ),
                        child: Text(label,
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                ],
              ),
              const Divider(height: 16),
              _action(Icons.restart_alt, '重启设备', 'rd',
                  () => _run(() => SbcService.instance.rkReset(onLine: _addLog))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAllwinner() {
    if (Platform.isWindows) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 60),
            const Icon(Icons.info_outline,
                size: 44, color: AppTheme.textMuted),
            const SizedBox(height: 14),
            const Text('全志工具目前仅支持 Linux',
                style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text(
              'sunxi-tools 需要 libusb 和 libfdt，\n'
              'Windows 版需自行交叉编译',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11, color: AppTheme.textMuted, height: 1.6),
            ),
          ],
        ),
      );
    }

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
              Text('全志 FEL 模式',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.success)),
              SizedBox(height: 8),
              Text(
                'FEL 是 CPU 内置的 USB 引导模式，\n'
                '即使 Flash 全空也能进。\n\n'
                '进入方式：按住 FEL 键（或短接 NAND）上电',
                style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textSecondary,
                    height: 1.7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '设备检测',
          child: Column(
            children: [
              _action(Icons.usb, '列出 FEL 设备', 'sunxi-fel -l',
                  () => _run(() => SbcService.instance
                      .sunxiListDevices(onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.fingerprint, '读取 SID', '芯片唯一序列号',
                  () => _run(() =>
                      SbcService.instance.sunxiReadSid(onLine: _addLog))),
              const Divider(height: 16),
              _action(Icons.storage, 'SPI Flash 信息', 'spiflash-info',
                  () => _run(() =>
                      SbcService.instance.sunxiSpiInfo(onLine: _addLog))),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '引导 U-Boot（救砖核心）',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final r = await FilePicker.platform.pickFiles(
                      dialogTitle: '选择 u-boot-sunxi-with-spl.bin',
                      type: FileType.any,
                    );
                    if (r != null && r.files.single.path != null) {
                      setState(() => _ubootPath = r.files.single.path);
                    }
                  },
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
                _ubootPath?.split(Platform.pathSeparator).last ??
                    '未选择（u-boot-sunxi-with-spl.bin）',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: _ubootPath != null
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (_ubootPath != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                              final ok = await _confirm('引导 U-Boot',
                                  '会从内存运行 U-Boot，不写 Flash。确认文件与板子匹配。');
                              if (ok != true) {
                                return SbcResult(false, '已取消', []);
                              }
                              return SbcService.instance.sunxiBootUboot(
                                  ubootPath: _ubootPath!,
                                  confirmed: true,
                                  onLine: _addLog);
                            }),
                    icon: const Icon(Icons.play_arrow, size: 15),
                    label: const Text('引导 U-Boot',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ],
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
        content: Text(warning,
            style: const TextStyle(fontSize: 12, height: 1.6)),
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
