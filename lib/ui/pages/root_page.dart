import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../core/device_waiter.dart';
import '../../services/device_provider.dart';
import '../../services/ghostlock_service.dart';
import '../../services/kernelsu_service.dart';
import '../../services/root_manager_service.dart';
import '../../services/root_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 一键 Root
///
/// 支持 Magisk / KernelSU / SukiSU / APatch
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  RootMethod _method = RootMethod.magisk;

  // Root 管理器
  List<RootManager> _installedManagers = [];
  bool _checkingManagers = false;
  bool _rootAvailable = false;

  // GhostLock 临时 Root
  bool _ghostKernelOk = false;
  String _ghostKernelMsg = '';
  String? _ghostKernelVer;
  bool _ghostChecking = false;

  // KernelSU LKM
  DeviceKernelInfo? _kernelInfo;
  KsuModule? _matchedModule;
  bool _ksuChecking = false;
  String? _bootImage;
  String? _magiskApk;
  bool _ready = false;
  String? _version;
  bool _busy = false;
  bool _keepVerity = false;
  bool _keepForceEncrypt = false;
  String? _patchedImage;
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
    _prewarm();
  }

  /// 预提取工具（提升首次使用体验）
  Future<void> _prewarm() async {
    await GhostLockService.instance.init();
    await KernelSuService.instance.init();

    // 等设备就绪后自动检测 GhostLock 内核
    if (!mounted) return;
    final device = await DeviceWaiter.wait(context);
    if (device == null || !mounted) return;
    if (_ghostKernelVer == null) {
      await _checkGhost();
    }
    if (_installedManagers.isEmpty && !_checkingManagers) {
      await _checkManagers();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await RootService.instance.init();
    String? ver;
    if (ok) ver = await RootService.instance.version();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _version = ver;
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

  Future<void> _pickBoot() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 boot.img',
      type: FileType.custom,
      allowedExtensions: ['img'],
    );
    if (r != null && r.files.single.path != null) {
      setState(() => _bootImage = r.files.single.path);
    }
  }

  Future<void> _pickApk() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 Magisk APK',
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    if (r != null && r.files.single.path != null) {
      setState(() => _magiskApk = r.files.single.path);
    }
  }

  /// 从设备拉取 boot 分区
  Future<void> _pullBoot() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) {
      _addLog('❌ 未选中设备');
      return;
    }

    setState(() => _busy = true);
    _addLog('══ 从设备拉取 boot 分区');

    // 找 boot 分区路径
    final paths = [
      '/dev/block/by-name/boot',
      '/dev/block/by-name/boot_a',
      '/dev/block/bootdevice/by-name/boot',
    ];

    String? found;
    for (final path in paths) {
      final r = await AdbService.instance.shell(
          device.serial, ['ls', '-l', path]);
      if (r.ok && !r.output.contains('No such')) {
        found = path;
        _addLog('  ✓ 找到: $path');
        break;
      }
    }

    if (found == null) {
      _addLog('❌ 找不到 boot 分区');
      if (mounted) setState(() => _busy = false);
      return;
    }

    // 需要 root 权限才能读
    final outPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}boot.img';
    _addLog('── 导出到 $outPath');
    _addLog('  （需要 root 权限，无 root 会失败）');

    final r = await AdbService.instance.shell(
      device.serial,
      ['su', '-c', 'dd if=$found of=/sdcard/boot.img'],
    );
    if (!r.ok) {
      _addLog('❌ 导出失败（可能需要 root）');
      if (mounted) setState(() => _busy = false);
      return;
    }

    final pull = await AdbService.instance.pull(
        device.serial, '/sdcard/boot.img', outPath);
    if (pull.ok) {
      _addLog('✅ 已拉取: $outPath');
      if (mounted) {
        setState(() {
          _bootImage = outPath;
          _busy = false;
        });
      }
    } else {
      _addLog('❌ 拉取失败');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _patch() async {
    if (_bootImage == null) {
      _addLog('❌ 请先选择 boot.img');
      return;
    }
    if (_magiskApk == null) {
      _addLog('❌ 请先选择 Magisk APK');
      return;
    }

    setState(() {
      _busy = true;
      _log.clear();
      _patchedImage = null;
    });

    final workDir =
        Directory.systemTemp.createTempSync('magisk_patch_').path;
    _addLog('工作目录: $workDir');
    _addLog('');

    final result = await RootService.instance.patchBoot(
      bootImage: _bootImage!,
      magiskApk: _magiskApk!,
      workDir: workDir,
      keepVerity: _keepVerity,
      keepForceEncrypt: _keepForceEncrypt,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok && result.message.contains('new-boot')) {
        _patchedImage = result.message;
      }
    });
    _addLog('');
    _addLog(result.ok ? '✅ ${result.message}' : '❌ ${result.message}');
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return EmptyState(
        icon: Icons.security,
        title: 'magiskboot 未就绪',
        subtitle: '需要 magiskboot.exe（应放在 tools/mtk/ 或 tools/magisk/ 下）',
        action: ElevatedButton.icon(
          onPressed: _init,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重新检测'),
        ),
      );
    }

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
                        'magiskboot ${_version ?? "就绪"}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Root 管理器安装
                AppCard(
                  title: 'Root 管理器',
                  trailing: Row(
                    children: [
                      if (_rootAvailable)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.success.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('已 Root',
                              style: TextStyle(
                                  fontSize: 9.5, color: AppTheme.success)),
                        ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 15),
                        color: AppTheme.textMuted,
                        visualDensity: VisualDensity.compact,
                        onPressed: _checkingManagers ? null : _checkManagers,
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '内置 7 个 Root 管理器，可直接推送到设备安装',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 10),
                      for (final m in RootManagerService.managers)
                        _buildManagerRow(m),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // GhostLock 一键临时 Root（最优先）
                AppCard(
                  title: '一键临时 Root（GhostLock）',
                  trailing: OutlinedButton(
                    onPressed: _ghostChecking ? null : _checkGhost,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                    ),
                    child: Text(_ghostChecking ? '检测中' : '检测内核',
                        style: const TextStyle(fontSize: 11)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: AppTheme.primary.withValues(alpha: 0.25)),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'CVE-2026-43499 · 2440★ · Apache-2.0',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primary),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '纯 ADB 执行，不需要 Shizuku\n'
                              'adb shell 本身就是 shell 用户，没有 seccomp 过滤\n'
                              '所以直接跳过 W3 阶段',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: AppTheme.textSecondary,
                                  height: 1.5),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_ghostKernelVer != null) ...[
                        InfoRow(
                            label: '设备内核',
                            value: _ghostKernelVer!,
                            monospace: true),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: (_ghostKernelOk
                                    ? AppTheme.success
                                    : AppTheme.warning)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _ghostKernelOk
                                    ? Icons.check_circle
                                    : Icons.warning_amber,
                                size: 13,
                                color: _ghostKernelOk
                                    ? AppTheme.success
                                    : AppTheme.warning,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _ghostKernelMsg,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: _ghostKernelOk
                                          ? AppTheme.success
                                          : AppTheme.warning),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: (_busy || !_ghostKernelOk)
                              ? null
                              : _runGhostLock,
                          icon: const Icon(Icons.bolt, size: 17),
                          label: const Text('一键临时 Root'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '⚠️ 临时 Root，重启失效\n'
                        '⚠️ 内核版本必须精确匹配（内置 85 个 profile）\n'
                        '⚠️ 需要先解锁 BL 或已有 ADB shell 权限',
                        style: TextStyle(
                            fontSize: 10,
                            color: AppTheme.textMuted,
                            height: 1.5),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _showSupportedKernels,
                            icon: const Icon(Icons.list, size: 14),
                            label: const Text('查看支持的内核',
                                style: TextStyle(fontSize: 11)),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _ghostKernelVer == null
                                ? null
                                : () async {
                                    final device = context
                                        .read<DeviceProvider>()
                                        .selectedDevice;
                                    if (device == null) return;
                                    await GhostLockService.instance
                                        .cleanup(device.serial);
                                    _addLog('✅ 已清理设备端文件');
                                  },
                            icon: const Icon(Icons.delete_outline, size: 14),
                            label: const Text('清理',
                                style: TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // KernelSU 内核模块（仅 KernelSU 系列显示）
                if (_method == RootMethod.kernelsu ||
                    _method == RootMethod.kernelsuNext ||
                    _method == RootMethod.sukisu) ...[
                  AppCard(
                    title: 'KernelSU 内核模块',
                    trailing: OutlinedButton(
                      onPressed: _ksuChecking ? null : _detectKernel,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                      child: Text(_ksuChecking ? '检测中' : '检测内核',
                          style: const TextStyle(fontSize: 11)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_kernelInfo == null)
                          const Text(
                            '点击「检测内核」自动匹配对应版本的 .ko\n\n'
                            '内置 16 个模块（8 个 Android 版本 × 2 架构）\n'
                            'android12-5.10 到 android17-6.18',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                                height: 1.6),
                          )
                        else ...[
                          InfoRow(
                              label: 'Android',
                              value:
                                  '${_kernelInfo!.androidName} (SDK ${_kernelInfo!.sdkVersion})'),
                          InfoRow(
                              label: '内核',
                              value: _kernelInfo!.kernelVersion,
                              monospace: true),
                          InfoRow(
                              label: '架构', value: _kernelInfo!.arch),
                          if (_matchedModule != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppTheme.success
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: AppTheme.success
                                        .withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.check_circle,
                                      size: 14, color: AppTheme.success),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _matchedModule!.name,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: AppTheme.success),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 36,
                              child: ElevatedButton.icon(
                                onPressed: _busy ? null : _loadKsu,
                                icon: const Icon(Icons.memory, size: 15),
                                label: const Text('加载模块（临时）',
                                    style: TextStyle(fontSize: 11.5)),
                              ),
                            ),
                          ] else
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppTheme.warning
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                '⚠️ 没有完全匹配的模块\n'
                                '可能内核版本不在支持列表内\n'
                                '建议改用 Magisk 或 GKI 模式',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.warning,
                                    height: 1.5),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // Root 方案
                AppCard(
                  title: 'Root 方案',
                  child: Column(
                    children: [
                      for (final m in RootMethod.values)
                        InkWell(
                          onTap: () => setState(() => _method = m),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Icon(
                                  _method == m
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 17,
                                  color: _method == m
                                      ? AppTheme.primary
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(m.label,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: _method == m
                                                ? AppTheme.textPrimary
                                                : AppTheme.textSecondary,
                                          )),
                                      Text(m.desc,
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
                const SizedBox(height: 14),

                // 文件
                AppCard(
                  title: '输入文件',
                  child: Column(
                    children: [
                      _fileRow(
                        label: 'boot.img',
                        value: _bootImage,
                        hint: '选择或从设备拉取',
                        onPick: _pickBoot,
                        extra: TextButton(
                          onPressed: _busy ? null : _pullBoot,
                          child: const Text('从设备拉取',
                              style: TextStyle(fontSize: 11)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _fileRow(
                        label: 'Magisk APK',
                        value: _magiskApk,
                        hint: '官方/狐狸/Alpha 均可',
                        onPick: _pickApk,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 选项
                AppCard(
                  title: '选项',
                  child: Column(
                    children: [
                      CheckboxListTile(
                        dense: true,
                        value: _keepVerity,
                        onChanged: (v) =>
                            setState(() => _keepVerity = v ?? false),
                        title: const Text('保留 dm-verity',
                            style: TextStyle(fontSize: 12.5)),
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        dense: true,
                        value: _keepForceEncrypt,
                        onChanged: (v) => setState(
                            () => _keepForceEncrypt = v ?? false),
                        title: const Text('保留强制加密',
                            style: TextStyle(fontSize: 12.5)),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // 按钮
                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: (_busy || _bootImage == null || _magiskApk == null)
                        ? null
                        : _patch,
                    icon: Icon(
                        _busy ? Icons.hourglass_top : Icons.auto_fix_high,
                        size: 18),
                    label: Text(_busy ? '修补中…' : '开始修补 boot'),
                  ),
                ),

                if (_patchedImage != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppTheme.success.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.check_circle,
                                size: 16, color: AppTheme.success),
                            SizedBox(width: 8),
                            Text('修补完成',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.success)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _patchedImage!,
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppTheme.textSecondary),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '下一步：fastboot flash boot <上面的路径>',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
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
                    const Text('修补日志',
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
                            if (line.contains('❌') || line.contains('!')) {
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

  Widget _fileRow({
    required String label,
    required String? value,
    required String hint,
    required VoidCallback onPick,
    Widget? extra,
  }) {
    final name = value?.split(Platform.pathSeparator).last;
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12.5, color: AppTheme.textSecondary)),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: AppTheme.bgElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              name ?? hint,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: name != null ? AppTheme.textPrimary : AppTheme.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 6),
        if (extra != null) extra,
        OutlinedButton(
          onPressed: onPick,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
          child: const Text('选择', style: TextStyle(fontSize: 11.5)),
        ),
      ],
    );
  }

  /// 检测内核并匹配 KernelSU 模块
  Future<void> _detectKernel() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() => _ksuChecking = true);

    final info = await KernelSuService.instance.detectDevice(device.serial);
    KsuModule? matched;
    if (info != null) {
      matched = KernelSuService.instance.matchModule(info);
    }

    if (!mounted) return;
    setState(() {
      _kernelInfo = info;
      _matchedModule = matched;
      _ksuChecking = false;
    });

    if (info == null) {
      _addLog('❌ 无法检测内核信息');
    } else {
      _addLog('══ 设备内核');
      _addLog('  Android: ${info.androidName} (SDK ${info.sdkVersion})');
      _addLog('  内核: ${info.kernelVersion}');
      _addLog('  架构: ${info.arch}');
      _addLog(matched != null
          ? '  ✅ 匹配模块: ${matched.name}'
          : '  ⚠️ 无匹配的 KernelSU 模块');
    }
  }

  /// 加载 KernelSU 模块
  Future<void> _loadKsu() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null || _matchedModule == null) return;

    setState(() => _busy = true);
    _log.clear();

    final r = await KernelSuService.instance.loadLkm(
      serial: device.serial,
      module: _matchedModule!,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }


  /// 检测 GhostLock 内核支持
  Future<void> _checkGhost() async {
    final device = await DeviceWaiter.wait(context);
    if (device == null || !mounted) return;

    setState(() => _ghostChecking = true);

    final (ok, msg, kernel) =
        await GhostLockService.instance.checkKernel(device.serial);

    if (!mounted) return;
    setState(() {
      _ghostKernelOk = ok;
      _ghostKernelMsg = msg;
      _ghostKernelVer = kernel;
      _ghostChecking = false;
    });

    _addLog('══ GhostLock 内核检测');
    _addLog('  $msg');
  }

  /// 执行 GhostLock 一键临时 Root
  Future<void> _runGhostLock() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('一键临时 Root'),
        content: const Text(
            '将执行 GhostLock（CVE-2026-43499）获取临时 Root。\n\n'
            '⚠️ 利用内核漏洞，有极小概率导致系统不稳定\n'
            '⚠️ 重启后失效\n'
            '⚠️ 部分安全应用可能检测到\n\n'
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
            child: const Text('执行'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    _log.clear();

    final r = await GhostLockService.instance.execute(
      serial: device.serial,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

    // 验证
    if (r.ok) {
      final hasRoot =
          await GhostLockService.instance.verifyRoot(device.serial);
      _addLog(hasRoot ? '✅ 验证通过：uid=0(root)' : '⚠️ 验证失败：未获取到 root');
    }
  }


  /// 显示支持的内核列表
  Future<void> _showSupportedKernels() async {
    final profiles = await GhostLockService.instance.listProfiles();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text('支持的内核（${profiles.length} 个）'),
        content: SizedBox(
          width: 500,
          height: 400,
          child: profiles.isEmpty
              ? const Center(
                  child: Text('profile 未提取，请先点「检测内核」',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textMuted)))
              : ListView.builder(
                  itemCount: profiles.length,
                  itemBuilder: (c, i) {
                    final name = profiles[i];
                    final isMatch = name == _ghostKernelVer;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      color: isMatch
                          ? AppTheme.success.withValues(alpha: 0.1)
                          : null,
                      child: Row(
                        children: [
                          if (isMatch)
                            const Icon(Icons.check_circle,
                                size: 13, color: AppTheme.success),
                          if (isMatch) const SizedBox(width: 6),
                          Expanded(
                            child: SelectableText(
                              name,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: isMatch
                                    ? AppTheme.success
                                    : AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭')),
        ],
      ),
    );
  }


  /// 检查 Root 状态和管理器
  Future<void> _checkManagers() async {
    final device = await DeviceWaiter.wait(context);
    if (device == null || !mounted) return;

    setState(() => _checkingManagers = true);

    final status = await RootManagerService.instance.checkRootStatus(device.serial);

    if (!mounted) return;
    setState(() {
      _rootAvailable = status['isRooted'] == true;
      _installedManagers =
          (status['managers'] as List).cast<RootManager>();
      _checkingManagers = false;
    });

    _addLog('══ Root 状态检查');
    _addLog('  su 命令: ${status['hasSu'] == true ? "有" : "无"}');
    _addLog('  已 Root: ${status['isRooted'] == true ? "是" : "否"}');
    _addLog('  已装管理器: ${_installedManagers.map((m) => m.name).join(", ")}');
  }

  /// 构建单个管理器行
  Widget _buildManagerRow(RootManager m) {
    final installed =
        _installedManagers.any((x) => x.id == m.id);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check_circle : Icons.android,
            size: 15,
            color: installed ? AppTheme.success : AppTheme.textMuted,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  style: TextStyle(
                    fontSize: 12,
                    color: installed
                        ? AppTheme.success
                        : AppTheme.textPrimary,
                  ),
                ),
                Text(
                  m.description,
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          if (installed)
            TextButton(
              onPressed: _busy ? null : () => _uninstallManager(m),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
              ),
              child: const Text('卸载', style: TextStyle(fontSize: 10.5)),
            )
          else
            OutlinedButton(
              onPressed: _busy ? null : () => _installManager(m),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
              ),
              child: const Text('安装', style: TextStyle(fontSize: 10.5)),
            ),
        ],
      ),
    );
  }

  Future<void> _installManager(RootManager m) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() => _busy = true);
    _log.clear();

    final r = await RootManagerService.instance.install(
      serial: device.serial,
      manager: m,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

    if (r.ok) await _checkManagers();
  }

  Future<void> _uninstallManager(RootManager m) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() => _busy = true);
    _log.clear();

    final r = await RootManagerService.instance.uninstall(
      serial: device.serial,
      manager: m,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');

    if (r.ok) await _checkManagers();
  }

}
