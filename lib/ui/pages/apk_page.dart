import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/apk_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// APK 工具（反编译/重打包/签名/合并）
class ApkPage extends StatefulWidget {
  const ApkPage({super.key});

  @override
  State<ApkPage> createState() => _ApkPageState();
}

class _ApkPageState extends State<ApkPage> {
  String? _apkPath;
  String? _dirPath;
  bool _busy = false;
  bool _javaReady = false;
  String? _javaVer;
  String? _apktoolVer;
  Map<String, String>? _apkInfo;

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
    final ok = await ApkService.instance.init();
    String? ver;
    if (ok) ver = await ApkService.instance.apktoolVersion();
    if (!mounted) return;
    setState(() {
      _javaReady = ok;
      _javaVer = ApkService.instance.javaVersion;
      _apktoolVer = ver;
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

  Future<void> _pickApk() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 APK',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;

    final path = r.files.single.path!;
    setState(() => _apkPath = path);

    final info = await ApkService.instance.readInfo(path);
    if (!mounted) return;
    setState(() => _apkInfo = info);

    _addLog('══ 选择: ${r.files.single.name}');
  }

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择目录',
    );
    if (d != null) setState(() => _dirPath = d);
  }

  Future<void> _run(String action) async {
    if (_apkPath == null) {
      _addLog('❌ 请先选择 APK');
      return;
    }

    final base = _apkPath!.replaceAll(RegExp(r'\.apk$', caseSensitive: false), '');
    final apkDir = File(_apkPath!).parent.path;

    setState(() {
      _busy = true;
      _log.clear();
    });

    ApkResult r;

    switch (action) {
      case 'decode':
        r = await ApkService.instance.decode(
          apkPath: _apkPath!,
          outputDir: '${base}_decoded',
          onLine: _addLog,
        );

      case 'extract':
        r = await ApkService.instance.extract(
          apkPath: _apkPath!,
          outputDir: '${base}_extracted',
          onLine: _addLog,
        );

      case 'build':
        final src = _dirPath ?? '${base}_decoded';
        r = await ApkService.instance.build(
          srcDir: src,
          outputApk: '${base}_rebuilt.apk',
          onLine: _addLog,
        );

      case 'sign':
        r = await ApkService.instance.sign(
          apkPath: _apkPath!,
          outputDir: apkDir,
          onLine: _addLog,
        );

      case 'merge':
        final src = _dirPath ?? apkDir;
        r = await ApkService.instance.mergeSplit(
          inputDir: src,
          outputApk: '${base}_merged.apk',
          onLine: _addLog,
        );

      default:
        r = ApkResult(false, '未知操作', []);
    }

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
                // 环境状态
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_javaReady ? AppTheme.success : AppTheme.danger)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_javaReady ? AppTheme.success : AppTheme.danger)
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _javaReady ? Icons.check_circle : Icons.error,
                        size: 16,
                        color: _javaReady ? AppTheme.success : AppTheme.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _javaReady
                              ? 'Java $_javaVer  ·  apktool ${_apktoolVer ?? ""}'
                              : '需要 Java 运行时（JRE 8+）',
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 15),
                        color: AppTheme.textMuted,
                        visualDensity: VisualDensity.compact,
                        onPressed: _init,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 选择 APK
                AppCard(
                  title: 'APK 文件',
                  trailing: OutlinedButton(
                    onPressed: _busy ? null : _pickApk,
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
                        _apkPath?.split(Platform.pathSeparator).last ?? '未选择',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: _apkPath != null
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_apkInfo != null && _apkInfo!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        for (final e in _apkInfo!.entries.take(8))
                          InfoRow(label: e.key, value: e.value),
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
                      for (final (id, label, desc, icon) in [
                        ('decode', '反编译（apktool）',
                            '解出 smali + 资源，可修改后重打包', Icons.code),
                        ('extract', '快速解包（APKEditor）',
                            '只解 XML 和资源，比 apktool 快', Icons.unarchive),
                        ('build', '重打包（apktool）',
                            '把修改过的目录打包成 APK', Icons.archive),
                        ('sign', '签名（uber-apk-signer）',
                            '自动 zipalign + v2/v3 签名', Icons.verified_user),
                        ('merge', '合并 split APK',
                            '把 XAPK/APKM/APKS 分包合成单 APK', Icons.merge_type),
                      ])
                        InkWell(
                          onTap: _busy ? null : () => _run(id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Icon(icon, size: 16, color: AppTheme.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(label,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              color: AppTheme.textPrimary)),
                                      Text(desc,
                                          style: const TextStyle(
                                              fontSize: 10.5,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right,
                                    size: 16, color: AppTheme.textMuted),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 目录选择（打包/合并用）
                AppCard(
                  title: '工作目录（打包/合并时用）',
                  trailing: OutlinedButton(
                    onPressed: _busy ? null : _pickDir,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                    child: const Text('选择', style: TextStyle(fontSize: 11.5)),
                  ),
                  child: Text(
                    _dirPath ?? '未选择（默认用反编译输出目录）',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _dirPath != null
                          ? AppTheme.textPrimary
                          : AppTheme.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                if (_busy) ...[
                  const SizedBox(height: 14),
                  const InlineLoader(text: '处理中…'),
                ],
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
                            if (line.contains('❌')) c = AppTheme.danger;
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
}
