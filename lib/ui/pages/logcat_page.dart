import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 日志查看（logcat）
class LogcatPage extends StatefulWidget {
  const LogcatPage({super.key});

  @override
  State<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends State<LogcatPage> {

  @override
  void initState() {
    super.initState();
    // 测试用：GAOJI_AUTO=1 自动开始抓日志
    if (Platform.environment['GAOJI_AUTO'] == '1') {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _start();
      });
    }
  }
  final List<_LogLine> _lines = [];
  final _scrollController = ScrollController();
  final _filterController = TextEditingController();
  final _tagController = TextEditingController();

  bool _running = false;
  bool _autoScroll = true;
  String _level = 'V'; // V/D/I/W/E
  String _buffer = 'main';
  final int _maxLines = 2000;
  Process? _proc;
  StreamSubscription? _sub;

  @override
  void dispose() {
    _stop();
    _scrollController.dispose();
    _filterController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
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
    if (device == null) return;

    if (_running) await _stop();

    setState(() {
      _running = true;
      _lines.clear();
    });

    final adb = await AppConfig.adbPath();
    final args = <String>[
      '-s',
      device.serial,
      'logcat',
      '-v',
      'time',
      '-b',
      _buffer,
      '*:$_level',
    ];

    try {
      _proc = await Process.start(adb, args);
      _sub = _proc!.stdout
          .transform(utf8.decoder)
          .listen(_onLine, onDone: () {
        if (mounted) setState(() => _running = false);
      });
      _proc!.stderr
          .transform(utf8.decoder)
          .listen((s) => _onLine(s, isErr: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('启动失败: $e')));
    }
  }

  void _onLine(String chunk, {bool isErr = false}) {
    if (!mounted) return;
    for (final line in chunk.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parsed = _parseLogLine(line);
      if (parsed == null) continue;
      if (!_matchFilter(parsed)) continue;

      setState(() {
        _lines.add(parsed);
        if (_lines.length > _maxLines) {
          _lines.removeRange(0, _lines.length - _maxLines);
        }
      });
    }

    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController
              .jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  _LogLine? _parseLogLine(String line) {
    // 格式: 10-31 16:00:00.123  1234  1234 I Tag     : message
    final m = RegExp(
            r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.+?)\s*:\s*(.*)$')
        .firstMatch(line);
    if (m == null) {
      return _LogLine(
        time: '',
        pid: '',
        tid: '',
        level: '?',
        tag: '',
        message: line,
        raw: line,
      );
    }
    return _LogLine(
      time: m.group(1)!,
      pid: m.group(2)!,
      tid: m.group(3)!,
      level: m.group(4)!,
      tag: m.group(5)!,
      message: m.group(6)!,
      raw: line,
    );
  }

  bool _matchFilter(_LogLine l) {
    final f = _filterController.text.trim().toLowerCase();
    if (f.isNotEmpty) {
      if (!l.message.toLowerCase().contains(f) &&
          !l.tag.toLowerCase().contains(f)) {
        return false;
      }
    }
    final t = _tagController.text.trim();
    if (t.isNotEmpty && !l.tag.contains(t)) return false;
    return true;
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    _proc?.kill();
    _proc = null;
    if (mounted) setState(() => _running = false);
  }

  Future<void> _clear() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device != null) {
      await AdbService.instance.clearLogcat(device.serial);
    }
    setState(() => _lines.clear());
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'V':
        return AppTheme.textMuted;
      case 'D':
        return AppTheme.accent;
      case 'I':
        return AppTheme.success;
      case 'W':
        return AppTheme.warning;
      case 'E':
      case 'F':
        return AppTheme.danger;
      case 'A':
        return AppTheme.danger;
      default:
        return AppTheme.textSecondary;
    }
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

    return Column(
      children: [
        // 工具条
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              // 开始/停止
              SizedBox(
                height: 32,
                child: ElevatedButton.icon(
                  onPressed: _running ? _stop : _start,
                  icon: Icon(
                      _running ? Icons.stop : Icons.play_arrow,
                      size: 15),
                  label: Text(_running ? '停止' : '开始',
                      style: const TextStyle(fontSize: 11.5)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _running ? AppTheme.danger : AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 清空
              IconButton(
                icon: const Icon(Icons.delete_sweep, size: 17),
                color: AppTheme.textSecondary,
                visualDensity: VisualDensity.compact,
                tooltip: '清空',
                onPressed: _clear,
              ),
              const SizedBox(width: 8),

              // 级别
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppTheme.bgElevated,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: AppTheme.border),
                ),
                child: DropdownButton<String>(
                  value: _level,
                  underline: const SizedBox(),
                  isDense: true,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textPrimary),
                  items: const [
                    DropdownMenuItem(value: 'V', child: Text('Verbose')),
                    DropdownMenuItem(value: 'D', child: Text('Debug')),
                    DropdownMenuItem(value: 'I', child: Text('Info')),
                    DropdownMenuItem(value: 'W', child: Text('Warn')),
                    DropdownMenuItem(value: 'E', child: Text('Error')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _level = v);
                    if (_running) _start();
                  },
                ),
              ),
              const SizedBox(width: 8),

              // 缓冲区
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppTheme.bgElevated,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: AppTheme.border),
                ),
                child: DropdownButton<String>(
                  value: _buffer,
                  underline: const SizedBox(),
                  isDense: true,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textPrimary),
                  items: const [
                    DropdownMenuItem(value: 'main', child: Text('main')),
                    DropdownMenuItem(value: 'system', child: Text('system')),
                    DropdownMenuItem(value: 'crash', child: Text('crash')),
                    DropdownMenuItem(value: 'events', child: Text('events')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _buffer = v);
                    if (_running) _start();
                  },
                ),
              ),
              const SizedBox(width: 12),

              // 过滤
              SizedBox(
                width: 160,
                height: 30,
                child: TextField(
                  controller: _filterController,
                  style: const TextStyle(fontSize: 11.5),
                  decoration: const InputDecoration(
                    hintText: '过滤内容…',
                    prefixIcon: Icon(Icons.search, size: 14),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 5),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                height: 30,
                child: TextField(
                  controller: _tagController,
                  style: const TextStyle(fontSize: 11.5),
                  decoration: const InputDecoration(
                    hintText: 'Tag…',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 5),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),

              const Spacer(),

              // 自动滚动
              Row(
                children: [
                  Checkbox(
                    value: _autoScroll,
                    onChanged: (v) =>
                        setState(() => _autoScroll = v ?? true),
                    visualDensity: VisualDensity.compact,
                  ),
                  const Text('自动滚动',
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                ],
              ),
              const SizedBox(width: 10),
              Text('${_lines.length} 行',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
        ),

        // 日志列表
        Expanded(
          child: Container(
            color: const Color(0xFF0A0C10),
            child: _lines.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _running ? Icons.hourglass_top : Icons.article_outlined,
                          size: 32,
                          color: AppTheme.textMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _running ? '等待日志…' : '点击「开始」抓取日志',
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) {
                      final l = _lines[i];
                      final c = _levelColor(l.level);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 100,
                              child: Text(
                                l.time,
                                style: const TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    color: AppTheme.textMuted),
                              ),
                            ),
                            SizedBox(
                              width: 18,
                              child: Text(
                                l.level,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    color: c),
                              ),
                            ),
                            SizedBox(
                              width: 140,
                              child: Text(
                                l.tag,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    color: c.withValues(alpha: 0.8)),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                l.message,
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    fontFamily: 'monospace',
                                    color: AppTheme.textSecondary,
                                    height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _LogLine {
  final String time;
  final String pid;
  final String tid;
  final String level;
  final String tag;
  final String message;
  final String raw;

  _LogLine({
    required this.time,
    required this.pid,
    required this.tid,
    required this.level,
    required this.tag,
    required this.message,
    required this.raw,
  });
}
