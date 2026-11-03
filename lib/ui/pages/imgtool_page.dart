import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../services/device_provider.dart';
import '../../services/f2fs_service.dart';
import '../../services/image_service.dart';
import '../../services/kernel_inspect_service.dart';
import '../../services/lp_metadata_service.dart';
import '../../services/vbmeta_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 镜像工具（综合）
///
/// 功能：
///   · vbmeta 校验开关（禁用/恢复 AVB 校验）
///   · sparse ↔ raw 转换
///   · EROFS 解包/打包
///   · cust / 分区镜像处理
class ImgtoolPage extends StatefulWidget {
  const ImgtoolPage({super.key});

  @override
  State<ImgtoolPage> createState() => _ImgtoolPageState();
}

class _ImgtoolPageState extends State<ImgtoolPage> {
  String? _imagePath;
  ImageFormat _format = ImageFormat.unknown;
  VbmetaInfo? _vbmetaInfo;

  /// 动态分区元数据（super.img 才有）
  LpMetadata? _lpMeta;

  /// 内核分析结果
  KernelInfo? _kernelInfo;
  bool _busy = false;
  String _mode = 'vbmeta_disable';
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 测试钩子：GAOJI_IMG_PATH=/path/to/super.img 自动加载
    final hook = Platform.environment['GAOJI_IMG_PATH'];
    if (hook != null && hook.isNotEmpty) {
      _loadPath(hook);
    }
  }

  /// 直接从路径加载（给测试钩子用）
  Future<void> _loadPath(String path) async {
    var fmt = await ImageService.instance.detectFormat(path);
    final vb = await VbmetaService.instance.parse(path);
    final lp = await LpMetadataService.instance.parseFile(path);
    final ki = await KernelInspectService.instance.inspect(path);
    if (!mounted) return;
    setState(() {
      _imagePath = path;
      _format = fmt;
      _vbmetaInfo = vb;
      _lpMeta = lp;
      _kernelInfo = ki;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择镜像文件（vbmeta / super / cust / system 等）',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;

    final path = r.files.single.path!;
    var fmt = await ImageService.instance.detectFormat(path);
    final vb = await VbmetaService.instance.parse(path);

    // 动态分区（super.img）
    final lp = await LpMetadataService.instance.parseFile(path);
    // 内核分析
    final ki = await KernelInspectService.instance.inspect(path);

    // 额外检测 F2FS
    if (fmt == ImageFormat.raw || fmt == ImageFormat.unknown) {
      if (await F2fsService.instance.isF2fs(path)) {
        fmt = ImageFormat.raw; // F2FS 归为 raw，但日志会标注
      }
    }

    if (!mounted) return;
    setState(() {
      _imagePath = path;
      _lpMeta = lp;
      _kernelInfo = ki;
      _format = fmt;
      _vbmetaInfo = vb;
    });

    _addLog('══ 选择: ${path.split(Platform.pathSeparator).last}');
    _addLog('  格式: ${fmt.label}');
    if (vb != null) {
      _addLog('  vbmeta 版本: ${(vb.version >> 16)}.${vb.version & 0xFFFF}');
      _addLog('  算法: ${vb.algorithmName}');
      _addLog('  flags: 0x${vb.flags.toRadixString(16).padLeft(8, "0")}');
      _addLog('  状态: ${vb.flagsText}');
    }
  }

  Future<void> _run() async {
    if (_imagePath == null) {
      _addLog('❌ 请先选择镜像');
      return;
    }

    setState(() {
      _busy = true;
      _log.clear();
    });

    final base = _imagePath!.replaceAll(RegExp(r'\.\w+$'), '');

    switch (_mode) {
      case 'vbmeta_disable':
        final out = '${base}_novbmeta.img';
        final r = await VbmetaService.instance.disableVerification(
          imagePath: _imagePath!,
          outputPath: out,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'vbmeta_enable':
        final out = '${base}_vbmeta.img';
        final r = await VbmetaService.instance.enableVerification(
          imagePath: _imagePath!,
          outputPath: out,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'simg2img':
        final out = '$base.raw.img';
        final r = await ImageService.instance.simg2img(
          sparsePath: _imagePath!,
          rawPath: out,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'img2simg':
        final out = '$base.sparse.img';
        final r = await ImageService.instance.img2simg(
          rawPath: _imagePath!,
          sparsePath: out,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'erofs_extract':
        final out = '${base}_unpack';
        final r = await ImageService.instance.extractErofs(
          imagePath: _imagePath!,
          outDir: out,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'erofs_pack':
        final dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择要打包的目录',
        );
        if (dir == null) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        final out = '$base.repacked.img';
        final r = await ImageService.instance.packErofs(
          srcDir: dir,
          outImage: out,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'erofs_check':
        final r = await ImageService.instance.fsckErofs(
          imagePath: _imagePath!,
          onLine: _addLog,
        );
        _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

      case 'pull_vbmeta':
        final dev = context.read<DeviceProvider>().selectedDevice;
        if (dev == null) {
          _addLog('❌ 未选中设备');
          break;
        }
        _addLog('══ 从设备拉取 vbmeta');
        final adb = await AppConfig.adbPath();
        final path =
            await VbmetaService.instance.pullFromDevice(dev.serial, adb);
        if (path != null) {
          _addLog('✅ 已拉取: $path');
          if (mounted) setState(() => _imagePath = path);
        } else {
          _addLog('❌ 拉取失败（需要 root）');
        }
    }

    if (mounted) setState(() => _busy = false);
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
                // 选择镜像
                AppCard(
                  title: '镜像文件',
                  trailing: OutlinedButton(
                    onPressed: _busy ? null : _pick,
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
                            '未选择（支持 vbmeta / super / cust / system 等）',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: _imagePath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_imagePath != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _chip(_format.label, AppTheme.primary),
                            if (_vbmetaInfo != null) ...[
                              const SizedBox(width: 6),
                              _chip(
                                _vbmetaInfo!.verificationDisabled
                                    ? '校验已禁'
                                    : '校验启用',
                                _vbmetaInfo!.verificationDisabled
                                    ? AppTheme.warning
                                    : AppTheme.success,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // vbmeta 信息
                if (_vbmetaInfo != null) ...[
                  AppCard(
                    title: 'vbmeta 详情',
                    child: Column(
                      children: [
                        InfoRow(
                            label: '版本',
                            value:
                                '${_vbmetaInfo!.version >> 16}.${_vbmetaInfo!.version & 0xFFFF}'),
                        InfoRow(
                            label: '算法', value: _vbmetaInfo!.algorithmName),
                        InfoRow(
                            label: 'flags',
                            value:
                                '0x${_vbmetaInfo!.flags.toRadixString(16).padLeft(8, "0")}',
                            monospace: true),
                        InfoRow(
                            label: '状态', value: _vbmetaInfo!.flagsText),
                        InfoRow(
                            label: 'Rollback',
                            value: '${_vbmetaInfo!.rollbackIndex}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // ★ 内核分析（ARM64 入口指令检测）
                if (_kernelInfo != null) ...[
                  AppCard(
                    title: '内核分析',
                    trailing:
                        _chip(_kernelInfo!.format.label, AppTheme.accent),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(
                              _kernelInfo!.canPatch
                                  ? Icons.check_circle
                                  : (_kernelInfo!.alreadyPatched
                                      ? Icons.warning_amber_rounded
                                      : Icons.info_outline),
                              size: 15,
                              color: _kernelInfo!.canPatch
                                  ? AppTheme.success
                                  : AppTheme.warning,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _kernelInfo!.reason,
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.textSecondary,
                                    height: 1.45),
                              ),
                            ),
                          ],
                        ),
                        if (_kernelInfo!.headerOffset > 0) ...[
                          const SizedBox(height: 8),
                          InfoRow(
                              label: '头部偏移',
                              value: '${_kernelInfo!.headerOffset} 字节',
                              monospace: true),
                        ],
                        if (_kernelInfo!.patches.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          for (final patch in _kernelInfo!.patches)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  _chip(patch.kind.label, AppTheme.warning),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '0x${patch.offset.toRadixString(16)}: '
                                      '0x${patch.original.toRadixString(16).padLeft(8, "0")}',
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          fontFamily: 'monospace',
                                          color: AppTheme.textMuted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],


                // ★ 动态分区（super.img）
                if (_lpMeta != null) ...[
                  AppCard(
                    title: '动态分区（super.img）',
                    trailing: _chip('LP 10.${_lpMeta!.minorVersion}',
                        AppTheme.accent),
                    child: Column(
                      children: [
                        InfoRow(
                            label: '元数据版本',
                            value:
                                '${_lpMeta!.majorVersion}.${_lpMeta!.minorVersion}'),
                        if (_lpMeta!.geometry != null) ...[
                          InfoRow(
                              label: '逻辑块大小',
                              value:
                                  '${_lpMeta!.geometry!.logicalBlockSize} 字节'),
                          InfoRow(
                              label: '元数据槽',
                              value: '${_lpMeta!.geometry!.metadataSlotCount}'),
                        ],
                        InfoRow(
                            label: '逻辑分区',
                            value:
                                '${_lpMeta!.partitions.length} 个，共 ${_lpMeta!.totalSizeText}'),
                        const SizedBox(height: 10),
                        // 分区列表
                        for (final part in [..._lpMeta!.partitions]
                          ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes)))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(part.name,
                                      style: const TextStyle(
                                          fontSize: 11.5,
                                          fontFamily: 'monospace',
                                          color: AppTheme.textPrimary)),
                                ),
                                if (part.isReadonly)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: _chip('只读', AppTheme.textMuted),
                                  ),
                                Text(part.sizeText,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textSecondary)),
                                const SizedBox(width: 10),
                                Text('${part.extents.length} 段',
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.textMuted)),
                              ],
                            ),
                          ),
                        if (_lpMeta!.groups.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          for (final g in _lpMeta!.groups)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                        g.name.isEmpty ? '(默认)' : g.name,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                            color: AppTheme.textSecondary)),
                                  ),
                                  Text('上限 ${g.maxSizeText}',
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          color: AppTheme.textMuted)),
                                ],
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // 操作
                AppCard(
                  title: '操作',
                  child: Column(
                    children: [
                      for (final (id, label, desc) in [
                        ('vbmeta_disable', '禁用 vbmeta 校验',
                            '改 flags = 0x03（关 AVB + dm-verity）'),
                        ('vbmeta_enable', '恢复 vbmeta 校验',
                            '改 flags = 0x00'),
                        ('pull_vbmeta', '从设备拉取 vbmeta',
                            '需要 root 权限'),
                        ('simg2img', 'Sparse → Raw',
                            '稀疏镜像转原始镜像'),
                        ('img2simg', 'Raw → Sparse',
                            '原始镜像转稀疏镜像'),
                        ('erofs_extract', '解包 EROFS',
                            '解出文件系统目录（system/cust 等）'),
                        ('erofs_pack', '打包 EROFS',
                            '把目录重新打包成镜像'),
                        ('erofs_check', 'EROFS 完整性检查',
                            '校验镜像是否损坏'),
                        ('f2fs_extract', '解包 F2FS',
                            '/data 及部分 /system 的格式'),
                      ])
                        InkWell(
                          onTap: () => setState(() => _mode = id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(
                              children: [
                                Icon(
                                  _mode == id
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 16,
                                  color: _mode == id
                                      ? AppTheme.primary
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(label,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: _mode == id
                                                ? AppTheme.textPrimary
                                                : AppTheme.textSecondary,
                                          )),
                                      Text(desc,
                                          style: const TextStyle(
                                              fontSize: 10.5,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: (_busy || _imagePath == null) ? null : _run,
                    icon: Icon(_busy ? Icons.hourglass_top : Icons.play_arrow,
                        size: 18),
                    label: Text(_busy ? '处理中…' : '执行'),
                  ),
                ),

                const SizedBox(height: 14),
                // 说明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgElevated,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '关于 cust 分区：\n'
                    'cust 是华为/荣耀的定制分区（ext4 格式），\n'
                    '用「解包 EROFS」不适用，应该用 ext4 工具。\n'
                    '实际上 cust.img 通常是 ext4，可以直接挂载或用 e2fsdroid 处理。\n\n'
                    '关于 vbmeta：\n'
                    '刷入改过的 boot/system 后必须禁用 vbmeta 校验，\n'
                    '否则设备会拒绝启动（红字警告或直接卡 logo）。\n'
                    '禁用方法：fastboot --disable-verity --disable-verification flash vbmeta',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.textMuted,
                        height: 1.7),
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

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}
