import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/splash_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 开机 Logo 编辑（splash.img）
///
/// 高通机型开机第一屏存在 splash 分区，格式带 "SPLASH!!" magic，
/// 内含多张图片（通常 3~5 张：开机/充电/解锁/警告等）。
///
/// 本页支持：
///   · 解析并预览所有内嵌图片
///   · 全部解包成 PNG
///   · 从 PNG 目录重新打包
///   · 单独替换某一张
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  String? _splashPath;
  List<SplashImage> _images = [];
  bool _busy = false;
  bool _compress = true;
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 测试钩子：GAOJI_SPLASH_PATH 直接加载指定文件
    final testPath = Platform.environment['GAOJI_SPLASH_PATH'];
    if (testPath != null && testPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        setState(() => _splashPath = testPath);
        _addLog('══ [测试钩子] 加载 $testPath');
        await _parse();
      });
    }
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

  Future<void> _pickSplash() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 splash.img / logo.img',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;

    setState(() {
      _splashPath = r.files.single.path;
      _images = [];
      _log.clear();
    });
    _addLog('══ 选择文件');
    _addLog('   ${p.basename(_splashPath!)}');
    _addLog('   ${_splashPath!}');
    await _parse();
  }

  Future<void> _parse() async {
    if (_splashPath == null) return;
    setState(() => _busy = true);
    final (images, r) = await SplashService.instance.list(_splashPath!);
    if (!mounted) return;
    setState(() {
      _images = images;
      _busy = false;
    });
    for (final l in r.log) {
      _addLog(l);
    }
  }

  Future<void> _unpack() async {
    if (_splashPath == null) return;
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择解包输出目录',
    );
    if (dir == null) return;

    setState(() => _busy = true);
    final r = await SplashService.instance.unpack(_splashPath!, dir);
    if (!mounted) return;
    setState(() => _busy = false);
    for (final l in r.log.skip(_log.isNotEmpty ? _images.length + 6 : 0)) {
      _addLog(l);
    }
  }

  Future<void> _repack() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择图片目录（png/jpg 按文件名排序）',
    );
    if (dir == null) return;

    final save = await FilePicker.platform.saveFile(
      dialogTitle: '保存为 splash.img',
      fileName: 'splash.img',
      type: FileType.any,
    );
    if (save == null) return;

    setState(() => _busy = true);
    _addLog('');
    final r = await SplashService.instance.repack(
      imageDir: dir,
      outputPath: save,
      compress: _compress,
      onLine: _addLog,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      setState(() => _splashPath = save);
      await _parse();
    }
  }

  Future<void> _replace(int index) async {
    if (_splashPath == null) return;

    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择替换用的图片',
      type: FileType.image,
    );
    if (r == null || r.files.single.path == null) return;

    final save = await FilePicker.platform.saveFile(
      dialogTitle: '保存新的 splash.img',
      fileName: 'splash-new.img',
      type: FileType.any,
    );
    if (save == null) return;

    setState(() => _busy = true);
    _addLog('');
    final result = await SplashService.instance.replaceOne(
      splashPath: _splashPath!,
      newImagePath: r.files.single.path!,
      targetIndex: index,
      outputPath: save,
      onLine: _addLog,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      setState(() => _splashPath = save);
      await _parse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: _buildLeft()),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: _buildLog()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.image, size: 18, color: AppTheme.primary),
          const SizedBox(width: 8),
          const Text(
            '开机 Logo 编辑',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 12),
          if (_splashPath != null)
            Flexible(
              child: Text(
                p.basename(_splashPath!),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textMuted,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Spacer(),
          if (_busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildLeft() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 选择文件
          AppCard(
            title: 'splash 镜像',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _splashPath ?? '未选择文件',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: _splashPath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickSplash,
                      icon: const Icon(Icons.folder_open, size: 14),
                      label: const Text('选择'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          (_busy || _splashPath == null) ? null : _parse,
                      icon: const Icon(Icons.refresh, size: 14),
                      label: const Text('重新解析'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  '高通机型位置：/dev/block/bootdevice/by-name/splash\n'
                  '读取命令：adb shell su -c "dd if=/dev/block/by-name/splash of=/sdcard/splash.img"',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 内嵌图片列表
          if (_images.isNotEmpty) ...[
            AppCard(
              title: '内嵌图片（${_images.length} 张）',
              child: Column(
                children: [
                  for (final im in _images) ...[
                    _imageRow(im),
                    if (im != _images.last) const Divider(height: 12),
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        icon: Icons.unarchive,
                        label: '全部解包成 PNG',
                        color: AppTheme.primary,
                        enabled: _splashPath != null && _images.isNotEmpty,
                        onTap: _unpack,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        icon: Icons.folder_zip,
                        label: '从 PNG 目录打包',
                        color: AppTheme.accent,
                        enabled: true,
                        onTap: _repack,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Checkbox(
                      value: _compress,
                      onChanged: (v) =>
                          setState(() => _compress = v ?? true),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        'RLE 压缩（体积小，推荐）\n取消勾选则用原始 RGB，兼容性更好但文件大很多',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.textMuted,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageRow(SplashImage im) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppTheme.bgElevated,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(
            '${im.index}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${im.width} × ${im.height}',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.textPrimary,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${im.typeName} · ${(im.size / 1024).toStringAsFixed(1)} KB',
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _replace(im.index),
          icon: const Icon(Icons.swap_horiz, size: 13),
          label: const Text('替换'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: (enabled && !_busy) ? onTap : null,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }

  Widget _buildLog() {
    return Container(
      color: AppTheme.bgDeep,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 14,
                    color: AppTheme.accent),
                const SizedBox(width: 6),
                const Text(
                  '输出',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const Spacer(),
                if (_log.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 14),
                    visualDensity: VisualDensity.compact,
                    color: AppTheme.textMuted,
                    tooltip: '清空',
                    onPressed: () => setState(_log.clear),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _log.isEmpty
                ? const Center(
                    child: Text(
                      '等待操作…',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _log.join('\n'),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.55,
                        fontFamily: 'monospace',
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
