import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 安装 APK
class InstallPage extends StatefulWidget {
  const InstallPage({super.key});

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final List<String> _apks = [];
  final List<String> _log = [];
  bool _installing = false;
  bool _replace = true;
  bool _grantAll = false;
  bool _downgrade = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 APK（可多选）',
      type: FileType.custom,
      allowedExtensions: ['apk'],
      allowMultiple: true,
    );
    if (r == null) return;
    setState(() {
      for (final f in r.files) {
        if (f.path != null && !_apks.contains(f.path)) _apks.add(f.path!);
      }
    });
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

  Future<void> _installAll() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) {
      _snack('未选中设备');
      return;
    }
    if (_apks.isEmpty) {
      _snack('请先选择 APK');
      return;
    }

    setState(() {
      _installing = true;
      _log.clear();
    });

    var ok = 0;
    var fail = 0;
    for (var i = 0; i < _apks.length; i++) {
      final path = _apks[i];
      final name = path.split(Platform.pathSeparator).last;
      _addLog('══ [${i + 1}/${_apks.length}] $name');

      final code = await AdbService.instance.install(
        device.serial,
        path,
        replace: _replace,
        grantAll: _grantAll,
        downgrade: _downgrade,
        onLine: _addLog,
      );

      if (code == 0) {
        ok++;
        _addLog('✅ 成功');
      } else {
        fail++;
        _addLog('❌ 失败（退出码 $code）');
      }
    }

    _addLog('══ 完成：成功 $ok，失败 $fail');
    if (!mounted) return;
    setState(() => _installing = false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceProvider>().selectedDevice;

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppCard(
                  title: 'APK 文件',
                  trailing: OutlinedButton.icon(
                    onPressed: _installing ? null : _pickFiles,
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('添加', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                  ),
                  child: _apks.isEmpty
                      ? const Text('点击「添加」选择 APK 文件',
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textMuted))
                      : Column(
                          children: [
                            for (var i = 0; i < _apks.length; i++)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.android,
                                    size: 16, color: AppTheme.success),
                                title: Text(
                                  _apks[i].split(Platform.pathSeparator).last,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  '${(File(_apks[i]).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB',
                                  style: const TextStyle(fontSize: 10.5),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close, size: 15),
                                  color: AppTheme.textMuted,
                                  onPressed: _installing
                                      ? null
                                      : () => setState(() => _apks.removeAt(i)),
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 14),
                AppCard(
                  title: '安装选项',
                  child: Column(
                    children: [
                      CheckboxListTile(
                        dense: true,
                        value: _replace,
                        onChanged: (v) => setState(() => _replace = v ?? true),
                        title: const Text('覆盖安装（-r）',
                            style: TextStyle(fontSize: 12.5)),
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        dense: true,
                        value: _grantAll,
                        onChanged: (v) => setState(() => _grantAll = v ?? false),
                        title: const Text('授予所有权限（-g）',
                            style: TextStyle(fontSize: 12.5)),
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        dense: true,
                        value: _downgrade,
                        onChanged: (v) =>
                            setState(() => _downgrade = v ?? false),
                        title: const Text('允许降级（-d）',
                            style: TextStyle(fontSize: 12.5)),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: (_installing || device == null) ? null : _installAll,
                    icon: Icon(_installing ? Icons.hourglass_top : Icons.install_desktop,
                        size: 18),
                    label: Text(_installing
                        ? '安装中…'
                        : '安装${_apks.length > 1 ? "全部（${_apks.length}）" : ""}'),
                  ),
                ),
                if (device == null) ...[
                  const SizedBox(height: 10),
                  const Text('⚠️ 未选中设备，请先在「设备」页选择',
                      style: TextStyle(fontSize: 12, color: AppTheme.warning)),
                ],
              ],
            ),
          ),
        ),
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
                    const Text('安装日志',
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
                          child: Text('等待安装…',
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
                                    fontSize: 11.5,
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
