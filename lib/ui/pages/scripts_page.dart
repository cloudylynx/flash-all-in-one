import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 脚本录制与回放
///
/// 记录一系列 ADB 命令，可保存、加载、批量执行
class ScriptsPage extends StatefulWidget {
  const ScriptsPage({super.key});

  @override
  State<ScriptsPage> createState() => _ScriptsPageState();
}

class _ScriptsPageState extends State<ScriptsPage> {
  final List<_ScriptStep> _steps = [];
  final List<String> _log = [];
  final _scrollController = ScrollController();
  final _cmdController = TextEditingController();
  final _nameController = TextEditingController(text: '未命名脚本');

  List<String> _savedScripts = [];
  bool _running = false;
  int _runningIndex = -1;
  String? _scriptsDir;

  @override
  void initState() {
    super.initState();
    _initDir();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _cmdController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _initDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'scripts'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _scriptsDir = dir.path;
    _refreshList();
  }

  void _refreshList() {
    if (_scriptsDir == null) return;
    final dir = Directory(_scriptsDir!);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
    if (!mounted) return;
    setState(() => _savedScripts = files);
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

  void _addStep() {
    final cmd = _cmdController.text.trim();
    if (cmd.isEmpty) return;
    setState(() {
      _steps.add(_ScriptStep(
        command: cmd,
        description: '',
        waitMs: 500,
      ));
      _cmdController.clear();
    });
  }

  void _addPreset(String cmd, String desc) {
    setState(() {
      _steps.add(_ScriptStep(command: cmd, description: desc, waitMs: 500));
    });
  }

  Future<void> _save() async {
    if (_scriptsDir == null) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _snack('请输入脚本名');
      return;
    }

    final data = {
      'name': name,
      'created': DateTime.now().toIso8601String(),
      'steps': _steps
          .map((s) => {
                'command': s.command,
                'description': s.description,
                'waitMs': s.waitMs,
              })
          .toList(),
    };

    final file = File(p.join(_scriptsDir!, '$name.json'));
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data));
    _refreshList();
    _snack('已保存: $name');
  }

  Future<void> _load(String name) async {
    if (_scriptsDir == null) return;
    final file = File(p.join(_scriptsDir!, '$name.json'));
    if (!file.existsSync()) return;

    try {
      final data = json.decode(await file.readAsString()) as Map;
      final steps = (data['steps'] as List)
          .map((s) => _ScriptStep(
                command: s['command'] as String,
                description: s['description'] as String? ?? '',
                waitMs: s['waitMs'] as int? ?? 500,
              ))
          .toList();

      if (!mounted) return;
      setState(() {
        _nameController.text = name;
        _steps
          ..clear()
          ..addAll(steps);
      });
      _snack('已加载: $name（${steps.length} 步）');
    } catch (e) {
      _snack('加载失败: $e');
    }
  }

  Future<void> _deleteScript(String name) async {
    if (_scriptsDir == null) return;
    final file = File(p.join(_scriptsDir!, '$name.json'));
    if (file.existsSync()) file.deleteSync();
    _refreshList();
    _snack('已删除: $name');
  }

  Future<void> _run() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) {
      _snack('未选中设备');
      return;
    }
    if (_steps.isEmpty) {
      _snack('脚本为空');
      return;
    }

    setState(() {
      _running = true;
      _log.clear();
    });

    for (var i = 0; i < _steps.length; i++) {
      if (!_running) break;
      if (!mounted) return;

      setState(() => _runningIndex = i);
      final step = _steps[i];
      _addLog('══ [${i + 1}/${_steps.length}] ${step.command}');

      // 解析命令
      final parts = _splitArgs(step.command);
      if (parts.isEmpty) continue;

      final r = await AdbService.instance.shell(device.serial, parts);
      if (r.output.trim().isNotEmpty) {
        for (final line in r.output.trim().split('\n').take(20)) {
          _addLog('  $line');
        }
      }
      _addLog(r.ok ? '  ✓' : '  ✗ 退出码 ${r.exitCode}');

      if (step.waitMs > 0) {
        await Future.delayed(Duration(milliseconds: step.waitMs));
      }
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _runningIndex = -1;
    });
    _addLog('══ 执行完成');
  }

  List<String> _splitArgs(String cmd) {
    final result = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    var quoteChar = '';

    for (var i = 0; i < cmd.length; i++) {
      final c = cmd[i];
      if (!inQuote && (c == '"' || c == "'")) {
        inQuote = true;
        quoteChar = c;
      } else if (inQuote && c == quoteChar) {
        inQuote = false;
      } else if (!inQuote && c == ' ') {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) result.add(buf.toString());
    return result;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceProvider>().selectedDevice;

    return Row(
      children: [
        // 左：脚本编辑
        Expanded(
          flex: 3,
          child: Column(
            children: [
              // 工具条
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 160,
                      height: 30,
                      child: TextField(
                        controller: _nameController,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: '脚本名',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 30,
                      child: OutlinedButton(
                        onPressed: _steps.isEmpty ? null : _save,
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: const Text('保存',
                            style: TextStyle(fontSize: 11.5)),
                      ),
                    ),
                    const Spacer(),
                    if (_running)
                      Row(
                        children: [
                          const InlineLoader(),
                          const SizedBox(width: 8),
                          Text(
                            '执行中 ${_runningIndex + 1}/${_steps.length}',
                            style: const TextStyle(
                                fontSize: 11.5, color: AppTheme.primary),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 28,
                            child: ElevatedButton(
                              onPressed: () =>
                                  setState(() => _running = false),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.danger,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10),
                              ),
                              child: const Text('停止',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                        ],
                      )
                    else
                      SizedBox(
                        height: 30,
                        child: ElevatedButton.icon(
                          onPressed: (device == null || _steps.isEmpty)
                              ? null
                              : _run,
                          icon: const Icon(Icons.play_arrow, size: 15),
                          label: const Text('执行',
                              style: TextStyle(fontSize: 11.5)),
                          style: ElevatedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // 添加命令
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 30,
                        child: TextField(
                          controller: _cmdController,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            hintText: 'adb shell 命令（如 pm list packages）',
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 5),
                          ),
                          onSubmitted: (_) => _addStep(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 30,
                      child: ElevatedButton(
                        onPressed: _addStep,
                        style: ElevatedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: const Text('添加',
                            style: TextStyle(fontSize: 11.5)),
                      ),
                    ),
                  ],
                ),
              ),

              // 常用命令
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (label, cmd) in [
                        ('列包', 'pm list packages'),
                        ('电池', 'dumpsys battery'),
                        ('内存', 'cat /proc/meminfo'),
                        ('存储', 'df -h'),
                        ('属性', 'getprop'),
                        ('进程', 'ps -A'),
                        ('前台', 'dumpsys activity activities | grep mResumedActivity'),
                        ('清缓存', 'pm clear'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            label: Text(label,
                                style: const TextStyle(fontSize: 10.5)),
                            onPressed: () => _addPreset(cmd, label),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // 步骤列表
              Expanded(
                child: _steps.isEmpty
                    ? const EmptyState(
                        icon: Icons.play_circle_outline,
                        title: '脚本为空',
                        subtitle: '输入命令添加步骤，或用上方快捷命令\n'
                            '保存后可重复执行，适合批量操作',
                      )
                    : ListView.builder(
                        itemCount: _steps.length,
                        itemBuilder: (context, i) {
                          final step = _steps[i];
                          final running = _runningIndex == i;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            color: running
                                ? AppTheme.primary.withValues(alpha: 0.08)
                                : Colors.transparent,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 26,
                                  child: Text('${i + 1}.',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: AppTheme.textMuted)),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        step.command,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                            color: AppTheme.textPrimary),
                                      ),
                                      if (step.description.isNotEmpty)
                                        Text(
                                          step.description,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              color: AppTheme.textMuted),
                                        ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 70,
                                  child: Text('${step.waitMs}ms',
                                      style: const TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.textMuted)),
                                ),
                                if (!_running)
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 14),
                                    color: AppTheme.textMuted,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => setState(
                                        () => _steps.removeAt(i)),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        // 右：保存的脚本 + 日志
        Container(
          width: 340,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              // 保存的脚本
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined,
                        size: 14, color: AppTheme.accent),
                    const SizedBox(width: 6),
                    const Text('已保存',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    Text('${_savedScripts.length}',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted)),
                  ],
                ),
              ),
              if (_savedScripts.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _savedScripts.length,
                    itemBuilder: (context, i) {
                      final name = _savedScripts[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.description,
                            size: 14, color: AppTheme.textSecondary),
                        title: Text(name,
                            style: const TextStyle(fontSize: 11.5)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 13),
                          color: AppTheme.textMuted,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _deleteScript(name),
                        ),
                        onTap: () => _load(name),
                      );
                    },
                  ),
                ),

              const Divider(height: 1),

              // 执行日志
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.terminal, size: 14, color: AppTheme.accent),
                    const SizedBox(width: 6),
                    const Text('执行输出',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 14),
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
                          child: Text('等待执行…',
                              style: TextStyle(
                                  fontSize: 11, color: AppTheme.textMuted)))
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(8),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final line = _log[i];
                            Color c = AppTheme.textSecondary;
                            if (line.contains('✓')) c = AppTheme.success;
                            if (line.contains('✗')) c = AppTheme.danger;
                            if (line.startsWith('══')) c = AppTheme.accent;
                            return SelectableText(line,
                                style: TextStyle(
                                    fontSize: 10.5,
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

class _ScriptStep {
  final String command;
  final String description;
  final int waitMs;

  _ScriptStep({
    required this.command,
    required this.description,
    required this.waitMs,
  });
}
