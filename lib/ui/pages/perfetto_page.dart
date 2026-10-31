import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/device_provider.dart';
import '../../services/perfetto_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 性能追踪（Perfetto）
class PerfettoPage extends StatefulWidget {
  const PerfettoPage({super.key});

  @override
  State<PerfettoPage> createState() => _PerfettoPageState();
}

class _PerfettoPageState extends State<PerfettoPage> {
  String _preset = 'quick';
  bool _busy = false;
  bool _checking = false;
  bool? _supported;
  String _supportMsg = '';
  String? _lastTrace;
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    var device = context.read<DeviceProvider>().selectedDevice;

    // 设备列表可能还没加载完，等最多 5 秒
    if (device == null) {
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        device = context.read<DeviceProvider>().selectedDevice;
        if (device != null) break;
      }
    }

    if (device == null) {
      if (!mounted) return;
      setState(() {
        _supported = false;
        _supportMsg = '未选中设备';
      });
      return;
    }

    final (ok, msg) =
        await PerfettoService.instance.checkSupport(device.serial);
    if (!mounted) return;
    setState(() {
      _supported = ok;
      _supportMsg = msg;
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

  Future<void> _capture() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dir == null) return;

    final preset = PerfettoService.presets[_preset]!;
    final out =
        '$dir${Platform.pathSeparator}trace_${DateTime.now().millisecondsSinceEpoch}.pftrace';

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await PerfettoService.instance.capture(
      serial: device.serial,
      preset: preset,
      outputPath: out,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) _lastTrace = r.tracePath;
    });
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

    // 首次拿到设备时自动检测（initState 时设备可能还没就绪）
    if (_supported == null && !_checking) {
      _checking = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _check();
        _checking = false;
      });
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
                // 支持状态
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_supported == true
                            ? AppTheme.success
                            : _supported == false
                                ? AppTheme.warning
                                : AppTheme.textMuted)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_supported == true
                              ? AppTheme.success
                              : _supported == false
                                  ? AppTheme.warning
                                  : AppTheme.textMuted)
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _supported == true
                            ? Icons.check_circle
                            : _supported == false
                                ? Icons.warning_amber
                                : Icons.hourglass_top,
                        size: 16,
                        color: _supported == true
                            ? AppTheme.success
                            : _supported == false
                                ? AppTheme.warning
                                : AppTheme.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _supportMsg.isEmpty ? '检测中…' : _supportMsg,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 15),
                        color: AppTheme.textMuted,
                        visualDensity: VisualDensity.compact,
                        onPressed: _check,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 采集预设
                AppCard(
                  title: '采集预设',
                  child: Column(
                    children: [
                      for (final p in PerfettoService.presets.values)
                        InkWell(
                          onTap: () => setState(() => _preset = p.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Icon(
                                  _preset == p.id
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 16,
                                  color: _preset == p.id
                                      ? AppTheme.primary
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(p.name,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: _preset == p.id
                                                ? AppTheme.textPrimary
                                                : AppTheme.textSecondary,
                                          )),
                                      Text(p.description,
                                          style: const TextStyle(
                                              fontSize: 10.5,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bgElevated,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${p.duration}s / ${p.bufferSize}MB',
                                    style: const TextStyle(
                                        fontSize: 9.5,
                                        fontFamily: 'monospace',
                                        color: AppTheme.textMuted),
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

                // 类别预览
                AppCard(
                  title: '采集类别',
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in PerfettoService.presets[_preset]!.categories)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color:
                                    AppTheme.primary.withValues(alpha: 0.3)),
                          ),
                          child: Text(c,
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  color: AppTheme.primary)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: (_busy || _supported != true) ? null : _capture,
                    icon: Icon(
                        _busy ? Icons.hourglass_top : Icons.speed,
                        size: 18),
                    label: Text(_busy
                        ? '采集中…（${PerfettoService.presets[_preset]!.duration} 秒）'
                        : '开始采集'),
                  ),
                ),

                if (_lastTrace != null) ...[
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
                                size: 15, color: AppTheme.success),
                            SizedBox(width: 8),
                            Text('Trace 已生成',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.success)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _lastTrace!,
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: AppTheme.textSecondary),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '分析方式：\n'
                          '  · 浏览器打开 ui.perfetto.dev，拖入文件\n'
                          '  · 或用 trace_processor 命令行查询',
                          style: TextStyle(
                              fontSize: 10.5,
                              color: AppTheme.textMuted,
                              height: 1.6),
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
                    const Text('采集日志',
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
                          child: Text('等待采集…',
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
