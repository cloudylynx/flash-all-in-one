import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 文件管理
///
/// 浏览设备文件系统、上传/下载、删除、新建目录
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String _currentPath =
      Platform.environment['GAOJI_FILES_PATH'] ?? '/sdcard';
  List<_FileEntry> _entries = [];
  final List<String> _history = [];
  bool _loading = false;
  String? _loadedSerial;
  String? _error;
  bool _showHidden = false;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    // ls -la 输出解析
    // ⚠️ 必须加尾部斜杠：/sdcard 本身是符号链接，
    //    `ls -la /sdcard` 只返回链接本身而不列内容
    final pathArg =
        _currentPath.endsWith('/') ? _currentPath : '$_currentPath/';
    final r = await AdbService.instance.shell(
      device.serial,
      ['ls', '-la', pathArg],
    );

    if (!r.ok || r.output.contains('No such file')) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法访问 $_currentPath';
        _entries = [];
      });
      return;
    }

    final entries = <_FileEntry>[];
    for (final line in r.output.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty || t.startsWith('total')) continue;

        // 权限字段可能含 s/S/t/T（setuid/setgid/sticky）
        // 例：drwxrws--- 2 u0_a183 media_rw 4096 2026-10-31 09:40 Alarms
        //     lrw-r--r-- 1 root   root      21 2024-07-12 02:27 name -> target
        final m = RegExp(
                r'^([dlbcps-][rwxsStT-]{9})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
                r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}|\d{2}:\d{2})\s+(.+)$')
            .firstMatch(t);
      if (m == null) continue;

      final perms = m.group(1)!;
      final size = int.tryParse(m.group(2)!) ?? 0;
      final date = m.group(3)!;
      var name = m.group(4)!;

      if (name == '.' || name == '..') continue;
      if (!_showHidden && name.startsWith('.')) continue;

      // 处理符号链接 "name -> target"
      String? linkTarget;
      if (name.contains(' -> ')) {
        final parts = name.split(' -> ');
        name = parts[0];
        linkTarget = parts[1];
      }

      final isDir = perms.startsWith('d');
      final isLink = perms.startsWith('l');

      entries.add(_FileEntry(
        name: name,
        isDir: isDir,
        isLink: isLink,
        linkTarget: linkTarget,
        size: size,
        date: date,
        perms: perms,
      ));
    }

    // 目录在前，按名称排序
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
      _loadedSerial = device.serial;
    });
  }

  void _enter(_FileEntry e) {
    // 符号链接也允许进入（很多目录是链接，如 /sdcard -> /storage/self/primary）
    if (!e.isDir && !e.isLink) return;
    _history.add(_currentPath);
    setState(() => _currentPath = _joinPath(_currentPath, e.name));
    _load();
  }

  void _goUp() {
    if (_currentPath == '/') return;
    _history.add(_currentPath);
    final parts = _currentPath.split('/')..removeWhere((s) => s.isEmpty);
    parts.removeLast();
    setState(() => _currentPath = parts.isEmpty ? '/' : '/${parts.join("/")}');
    _load();
  }

  void _goBack() {
    if (_history.isEmpty) return;
    setState(() => _currentPath = _history.removeLast());
    _load();
  }

  String _joinPath(String base, String name) {
    if (base == '/') return '/$name';
    return '$base/$name';
  }

  String _sizeText(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<void> _download(_FileEntry e) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dir == null) return;

    final remote = _joinPath(_currentPath, e.name);
    final local = '$dir${Platform.pathSeparator}${e.name}';

    setState(() => _loading = true);
    final r = await AdbService.instance.pull(device.serial, remote, local);
    if (!mounted) return;
    setState(() => _loading = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? '已下载到 $local' : '下载失败: ${r.output}'),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _upload() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null) return;

    setState(() => _loading = true);
    var ok = 0;
    for (final f in r.files) {
      if (f.path == null) continue;
      final remote = _joinPath(_currentPath, f.name);
      final res = await AdbService.instance.push(device.serial, f.path!, remote);
      if (res.ok) ok++;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已上传 $ok / ${r.files.length} 个文件'),
    ));
    _load();
  }

  Future<void> _delete(_FileEntry e) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('确认删除'),
        content: Text('删除 ${e.name}？\n\n${e.isDir ? "目录及其内容" : "文件"}将被永久删除。'),
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final path = _joinPath(_currentPath, e.name);
    setState(() => _loading = true);
    // 需要 root 才能删系统文件
    final r = await AdbService.instance.shell(
      device.serial,
      ['rm', '-rf', path],
    );
    if (!mounted) return;
    setState(() => _loading = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? '已删除' : '删除失败: ${r.output}'),
    ));
    _load();
  }

  Future<void> _newDir() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('新建目录'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '目录名'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;

    final path = _joinPath(_currentPath, name);
    final r = await AdbService.instance.shell(
      device.serial,
      ['mkdir', '-p', path],
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? '已创建 $name' : '创建失败: ${r.output}'),
    ));
    _load();
  }

  void _jumpTo(String path) {
    _history.add(_currentPath);
    setState(() => _currentPath = path);
    _load();
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

    if (_loadedSerial != device.serial && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    return Column(
      children: [
        // 路径栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 17),
                color: _history.isEmpty
                    ? AppTheme.textMuted
                    : AppTheme.textSecondary,
                visualDensity: VisualDensity.compact,
                tooltip: '后退',
                onPressed: _history.isEmpty ? null : _goBack,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 17),
                color: AppTheme.textSecondary,
                visualDensity: VisualDensity.compact,
                tooltip: '上级目录',
                onPressed: _currentPath == '/' ? null : _goUp,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppTheme.bgElevated,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: SelectableText(
                    _currentPath,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_loading)
                const InlineLoader()
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 17),
                  color: AppTheme.textSecondary,
                  visualDensity: VisualDensity.compact,
                  onPressed: _load,
                ),
              IconButton(
                icon: Icon(
                  _showHidden ? Icons.visibility : Icons.visibility_off,
                  size: 16,
                ),
                color: _showHidden ? AppTheme.primary : AppTheme.textMuted,
                visualDensity: VisualDensity.compact,
                tooltip: _showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
                onPressed: () {
                  setState(() => _showHidden = !_showHidden);
                  _load();
                },
              ),
            ],
          ),
        ),

        // 快捷路径
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (label, path) in [
                  ('内部存储', '/sdcard'),
                  ('下载', '/sdcard/Download'),
                  ('图片', '/sdcard/DCIM'),
                  ('系统', '/system'),
                  ('数据', '/data'),
                  ('根目录', '/'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(label,
                          style: const TextStyle(fontSize: 10.5)),
                      onPressed: () => _jumpTo(path),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
          ),
        ),

        // 操作按钮
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _loading ? null : _upload,
                icon: const Icon(Icons.upload, size: 14),
                label: const Text('上传', style: TextStyle(fontSize: 11.5)),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: _loading ? null : _newDir,
                icon: const Icon(Icons.create_new_folder, size: 14),
                label: const Text('新建目录',
                    style: TextStyle(fontSize: 11.5)),
              ),
              const Spacer(),
              Text('${_entries.length} 项',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textMuted)),
            ],
          ),
        ),

        // 错误
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

        // 文件列表
        Expanded(
          child: _loading && _entries.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _entries.isEmpty
                  ? const EmptyState(
                      icon: Icons.folder_open, title: '目录为空')
                  : ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final e = _entries[i];
                        return _FileTile(
                          entry: e,
                          sizeText: _sizeText(e.size),
                          onTap: e.isDir ? () => _enter(e) : null,
                          onDownload:
                              e.isDir ? null : () => _download(e),
                          onDelete: () => _delete(e),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _FileEntry {
  final String name;
  final bool isDir;
  final bool isLink;
  final String? linkTarget;
  final int size;
  final String date;
  final String perms;

  _FileEntry({
    required this.name,
    required this.isDir,
    required this.isLink,
    this.linkTarget,
    required this.size,
    required this.date,
    required this.perms,
  });
}

class _FileTile extends StatefulWidget {
  final _FileEntry entry;
  final String sizeText;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;
  final VoidCallback onDelete;

  const _FileTile({
    required this.entry,
    required this.sizeText,
    this.onTap,
    this.onDownload,
    required this.onDelete,
  });

  @override
  State<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<_FileTile> {
  bool _hover = false;

  IconData get _icon {
    final e = widget.entry;
    if (e.isDir) return Icons.folder;
    if (e.isLink) return Icons.link;
    final n = e.name.toLowerCase();
    if (n.endsWith('.apk')) return Icons.android;
    if (n.endsWith('.img')) return Icons.storage;
    if (n.endsWith('.zip') || n.endsWith('.tar') || n.endsWith('.gz')) {
      return Icons.folder_zip;
    }
    if (n.endsWith('.jpg') || n.endsWith('.png') || n.endsWith('.webp')) {
      return Icons.image;
    }
    if (n.endsWith('.mp4') || n.endsWith('.mkv')) return Icons.videocam;
    if (n.endsWith('.log') || n.endsWith('.txt')) return Icons.description;
    if (n.endsWith('.so') || n.endsWith('.bin')) return Icons.memory;
    return Icons.insert_drive_file;
  }

  Color get _iconColor {
    final e = widget.entry;
    if (e.isDir) return AppTheme.warning;
    if (e.isLink) return AppTheme.accent;
    return AppTheme.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return MouseRegion(
      cursor: e.isDir ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          color: _hover ? AppTheme.bgHover : Colors.transparent,
          child: Row(
            children: [
              Icon(_icon, size: 17, color: _iconColor),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      style: const TextStyle(
                          fontSize: 12.5, color: AppTheme.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (e.linkTarget != null)
                      Text(
                        '→ ${e.linkTarget}',
                        style: const TextStyle(
                            fontSize: 10, color: AppTheme.textMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  e.isDir ? '—' : widget.sizeText,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: Text(
                  e.date,
                  style: const TextStyle(
                      fontSize: 10.5, color: AppTheme.textMuted),
                ),
              ),
              if (_hover) ...[
                const SizedBox(width: 8),
                if (widget.onDownload != null)
                  IconButton(
                    icon: const Icon(Icons.download, size: 15),
                    color: AppTheme.primary,
                    visualDensity: VisualDensity.compact,
                    tooltip: '下载',
                    onPressed: widget.onDownload,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 15),
                  color: AppTheme.danger,
                  visualDensity: VisualDensity.compact,
                  tooltip: '删除',
                  onPressed: widget.onDelete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
