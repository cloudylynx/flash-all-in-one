import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/ota_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// OTA 造包与重签
class OtaPage extends StatefulWidget {
  const OtaPage({super.key});

  @override
  State<OtaPage> createState() => _OtaPageState();
}

class _OtaPageState extends State<OtaPage> {
  String _tab = 'pack';
  bool _busy = false;
  String? _packerVer;
  String? _avbrootVer;

  // 造包
  String? _targetDir;
  String? _sourceDir;
  bool _delta = false;
  String _compression = 'xz';
  int _level = 6;

  // OTA 操作
  String? _otaPath;

  // 密钥
  String? _avbKey;
  String? _otaKey;
  String? _otaCrt;
  String? _magiskApk;

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
    await OtaService.instance.init();
    final pv = await OtaService.instance.packerVersion();
    final av = await OtaService.instance.avbrootVersion();
    if (!mounted) return;
    setState(() {
      _packerVer = pv;
      _avbrootVer = av;
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

  Future<void> _run(String action) async {
    setState(() {
      _busy = true;
      _log.clear();
    });

    OtaResult r;

    switch (action) {
      case 'pack':
        if (_targetDir == null) {
          _addLog('❌ 请选择目标镜像目录');
          setState(() => _busy = false);
          return;
        }
        final out = '${_targetDir!}${Platform.pathSeparator}payload.bin';
        r = _delta
            ? await OtaService.instance.packDelta(
                sourceDir: _sourceDir ?? '',
                targetDir: _targetDir!,
                output: out,
                compression: _compression,
                level: _level,
                onLine: _addLog,
              )
            : await OtaService.instance.packFull(
                targetDir: _targetDir!,
                output: out,
                compression: _compression,
                level: _level,
                onLine: _addLog,
              );

      case 'verify':
        if (_otaPath == null) {
          _addLog('❌ 请选择 OTA');
          setState(() => _busy = false);
          return;
        }
        r = await OtaService.instance.verifyOta(
          otaPath: _otaPath!,
          onLine: _addLog,
        );

      case 'list':
        if (_otaPath == null) {
          _addLog('❌ 请选择 OTA');
          setState(() => _busy = false);
          return;
        }
        r = await OtaService.instance.listOta(
          otaPath: _otaPath!,
          onLine: _addLog,
        );

      case 'extract':
        if (_otaPath == null) {
          _addLog('❌ 请选择 OTA');
          setState(() => _busy = false);
          return;
        }
        final dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择解包输出目录',
        );
        if (dir == null) {
          setState(() => _busy = false);
          return;
        }
        r = await OtaService.instance.extractOta(
          otaPath: _otaPath!,
          outputDir: dir,
          fastboot: true,
          onLine: _addLog,
        );

      case 'keys':
        final dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择密钥保存目录',
        );
        if (dir == null) {
          setState(() => _busy = false);
          return;
        }
        r = await OtaService.instance.generateKeys(
          outputDir: dir,
          onLine: _addLog,
        );
        if (r.ok && mounted) {
          setState(() {
            _avbKey = '$dir${Platform.pathSeparator}avb.key';
            _otaKey = '$dir${Platform.pathSeparator}ota.key';
            _otaCrt = '$dir${Platform.pathSeparator}ota.crt';
          });
        }

      case 'patch':
        if (_otaPath == null || _avbKey == null || _otaKey == null || _otaCrt == null) {
          _addLog('❌ 需要 OTA 文件和完整密钥');
          setState(() => _busy = false);
          return;
        }
        final base = _otaPath!.replaceAll(RegExp(r'\.zip$'), '');
        r = await OtaService.instance.patchOta(
          inputOta: _otaPath!,
            outputOta: '${base}_patched.zip',
          avbKey: _avbKey!,
          otaKey: _otaKey!,
          otaCrt: _otaCrt!,
          magiskApk: _magiskApk,
          onLine: _addLog,
        );

      default:
        r = OtaResult(false, '未知操作', []);
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
          child: Column(
            children: [
              // Tab
              Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    for (final (id, label) in [
                      ('pack', '生成 payload'),
                      ('ota', 'OTA 操作'),
                      ('keys', '密钥管理'),
                    ])
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _tab = id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
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
                  child: _tab == 'pack'
                      ? _buildPack()
                      : _tab == 'ota'
                          ? _buildOta()
                          : _buildKeys(),
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

  Widget _buildPack() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 状态
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (_packerVer != null ? AppTheme.success : AppTheme.danger)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                _packerVer != null ? Icons.check_circle : Icons.error,
                size: 15,
                color:
                    _packerVer != null ? AppTheme.success : AppTheme.danger,
              ),
              const SizedBox(width: 8),
              Text(
                _packerVer != null
                    ? 'payload_packer $_packerVer'
                    : 'payload_packer 未就绪',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
          ),
          child: const Text(
            '从一堆 .img 文件生成 OTA 的 payload.bin。\n\n'
            '全量：把所有新镜像打包\n'
            '增量：只打包和旧版本的差异（体积小很多）\n\n'
            '⚠️ 生成的 payload.bin 未签名，需用 avbroot 签名',
            style: TextStyle(
                fontSize: 11, color: AppTheme.textSecondary, height: 1.6),
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '目标镜像目录',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final d = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: '选择包含新 .img 文件的目录',
                    );
                    if (d != null) setState(() => _targetDir = d);
                  },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: Text(
            _targetDir ?? '未选择（放 system.img / vendor.img 等）',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: _targetDir != null
                  ? AppTheme.textPrimary
                  : AppTheme.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '选项',
          child: Column(
            children: [
              Row(
                children: [
                  Checkbox(
                    value: _delta,
                    onChanged: (v) => setState(() => _delta = v ?? false),
                    visualDensity: VisualDensity.compact,
                  ),
                  const Text('增量模式（需要源目录）',
                      style: TextStyle(fontSize: 12.5)),
                ],
              ),
              if (_delta) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 7),
                        decoration: BoxDecoration(
                          color: AppTheme.bgElevated,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          _sourceDir ?? '未选择源目录',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: _sourceDir != null
                                ? AppTheme.textPrimary
                                : AppTheme.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      onPressed: () async {
                        final d = await FilePicker.platform.getDirectoryPath(
                          dialogTitle: '选择旧版本镜像目录',
                        );
                        if (d != null) setState(() => _sourceDir = d);
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                      ),
                      child: const Text('选择', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
              ],
              const Divider(height: 20),
              _optionRow(
                '压缩',
                DropdownButton<String>(
                  value: _compression,
                  isDense: true,
                  underline: const SizedBox(),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textPrimary),
                  items: const [
                    DropdownMenuItem(value: 'xz', child: Text('xz（最小）')),
                    DropdownMenuItem(value: 'zstd', child: Text('zstd（快）')),
                    DropdownMenuItem(value: 'bz2', child: Text('bz2')),
                  ],
                  onChanged: (v) =>
                      setState(() => _compression = v ?? 'xz'),
                ),
              ),
              _optionRow(
                '压缩级别',
                Slider(
                  value: _level.toDouble(),
                  min: 0,
                  max: 9,
                  divisions: 9,
                  label: '$_level',
                  onChanged: (v) => setState(() => _level = v.round()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        SizedBox(
          height: 46,
          child: ElevatedButton.icon(
            onPressed: (_busy || _targetDir == null) ? null : () => _run('pack'),
            icon: Icon(_busy ? Icons.hourglass_top : Icons.build, size: 18),
            label: Text(_busy ? '生成中…' : '生成 payload.bin'),
          ),
        ),
      ],
    );
  }

  Widget _buildOta() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (_avbrootVer != null ? AppTheme.success : AppTheme.danger)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                _avbrootVer != null ? Icons.check_circle : Icons.error,
                size: 15,
                color:
                    _avbrootVer != null ? AppTheme.success : AppTheme.danger,
              ),
              const SizedBox(width: 8),
              Text(
                _avbrootVer != null
                    ? 'avbroot $_avbrootVer'
                    : 'avbroot 未就绪',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: 'OTA 文件',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final r = await FilePicker.platform.pickFiles(
                      dialogTitle: '选择 OTA zip',
                      type: FileType.any,
                    );
                    if (r != null && r.files.single.path != null) {
                      setState(() => _otaPath = r.files.single.path);
                    }
                  },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 11.5)),
          ),
          child: Text(
            _otaPath?.split(Platform.pathSeparator).last ?? '未选择',
            style: TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: _otaPath != null
                  ? AppTheme.textPrimary
                  : AppTheme.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '操作',
          child: Column(
            children: [
              for (final (id, label, desc, icon) in [
                ('verify', '验证签名', '检查 OTA 是否有效', Icons.verified),
                ('list', '列出内容', '查看包含哪些分区', Icons.list),
                ('extract', '解包 OTA', '解出镜像 + 生成 fastboot 脚本', Icons.unarchive),
                ('patch', '重签 OTA', '用自己密钥重签（可选注入 Magisk）', Icons.edit),
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
                            crossAxisAlignment: CrossAxisAlignment.start,
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

        if (_busy) ...[
          const SizedBox(height: 14),
          const InlineLoader(text: '处理中…'),
        ],
      ],
    );
  }

  Widget _buildKeys() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warning.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.warning.withValues(alpha: 0.25)),
          ),
          child: const Text(
            'AVB 密钥用于给镜像和 OTA 签名。\n\n'
            '· avb.key —— 签 AVB 元数据\n'
            '· ota.key + ota.crt —— 签 OTA 包\n\n'
            '⚠️ 密钥丢失后无法再签署同一设备的 OTA\n'
            '⚠️ 请备份到安全位置',
            style: TextStyle(
                fontSize: 11, color: AppTheme.textSecondary, height: 1.6),
          ),
        ),
        const SizedBox(height: 14),

        AppCard(
          title: '密钥状态',
          child: Column(
            children: [
              InfoRow(
                label: 'avb.key',
                value: _avbKey != null && File(_avbKey!).existsSync()
                    ? '已生成'
                    : '未生成',
                monospace: true,
              ),
              InfoRow(
                label: 'ota.key',
                value: _otaKey != null && File(_otaKey!).existsSync()
                    ? '已生成'
                    : '未生成',
                monospace: true,
              ),
              InfoRow(
                label: 'ota.crt',
                value: _otaCrt != null && File(_otaCrt!).existsSync()
                    ? '已生成'
                    : '未生成',
                monospace: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        SizedBox(
          height: 46,
          child: ElevatedButton.icon(
            onPressed: _busy ? null : () => _run('keys'),
            icon: const Icon(Icons.vpn_key, size: 18),
            label: const Text('生成新密钥对（RSA-4096）'),
          ),
        ),
      ],
    );
  }

  Widget _optionRow(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
