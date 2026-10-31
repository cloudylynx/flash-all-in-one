import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../services/adb_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Shell 终端
///
/// 在设备上执行 shell 命令，支持命令历史。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  final List<_TerminalLine> _lines = [];
  final List<String> _history = [];
  int _historyIndex = -1;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _lines.add(_TerminalLine.system('输入命令后回车执行。常用：ls / getprop / pm list packages'));
    // 进页面就聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _execute() async {
    final cmd = _controller.text.trim();
    if (cmd.isEmpty || _running) return;

    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) {
      setState(() {
        _lines.add(_TerminalLine.error('未选中设备'));
      });
      _scrollToBottom();
      return;
    }

    setState(() {
      _running = true;
      _lines.add(_TerminalLine.command(cmd));
      _controller.clear();
      _history.insert(0, cmd);
      _historyIndex = -1;
    });
    _scrollToBottom();

    // 拆分命令参数（简单按空格拆，支持引号）
    final args = _splitArgs(cmd);
    final result = await AdbService.instance.shell(
      device.serial,
      args,
      timeout: AppConfig.longTimeout,
    );

    setState(() {
      _running = false;
      if (result.output.isNotEmpty) {
        _lines.add(_TerminalLine.output(result.output));
      }
      if (!result.ok) {
        _lines.add(_TerminalLine.error('退出码 ${result.exitCode}'));
      }
    });
    _scrollToBottom();

    // 执行完把焦点还给输入框，否则要再点一次才能继续打字
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// 简单参数拆分（支持单双引号）
  List<String> _splitArgs(String cmd) {
    final result = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < cmd.length; i++) {
      final c = cmd[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          buf.write(c);
        }
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == ' ') {
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

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_history.isNotEmpty && _historyIndex < _history.length - 1) {
        setState(() {
          _historyIndex++;
          _controller.text = _history[_historyIndex];
          _controller.selection = TextSelection.collapsed(
              offset: _controller.text.length);
        });
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex > 0) {
        setState(() {
          _historyIndex--;
          _controller.text = _history[_historyIndex];
          _controller.selection = TextSelection.collapsed(
              offset: _controller.text.length);
        });
      } else if (_historyIndex == 0) {
        setState(() {
          _historyIndex = -1;
          _controller.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceProvider>().selectedDevice;

    if (device == null) {
      return const EmptyState(
        icon: Icons.developer_board_off,
        title: '未选中设备',
        subtitle: '请先在「设备」页面选择一台设备',
      );
    }

    return Column(
      children: [
        // 工具条
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 16, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text(
                '${device.displayName} (${device.serial})',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const Spacer(),
              if (_running)
                const InlineLoader(text: '执行中')
              else
                TextButton.icon(
                  onPressed: () => setState(() => _lines.clear()),
                  icon: const Icon(Icons.delete_sweep, size: 15),
                  label: const Text('清屏'),
                ),
            ],
          ),
        ),

        // 输出区
        Expanded(
          child: Container(
            color: const Color(0xFF0A0C10),
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(14),
              itemCount: _lines.length,
              itemBuilder: (context, i) => _lines[i],
            ),
          ),
        ),

        // 输入区
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              const Text(
                '\$',
                style: TextStyle(
                  color: AppTheme.accent,
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Focus(
                  onKeyEvent: (node, event) {
                    _onKey(event);
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    // 用 readOnly 而不是 enabled:false
                    // enabled:false 会销毁焦点，导致执行后要重新点击才能输入
                    readOnly: _running,
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: AppTheme.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      hintText: '输入 shell 命令…',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onSubmitted: (_) => _execute(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _running ? null : _execute,
                child: const Text('执行'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TerminalLine extends StatelessWidget {
  final String text;
  final _LineType type;

  const _TerminalLine._(this.text, this.type);

  factory _TerminalLine.command(String t) =>
      _TerminalLine._(t, _LineType.command);
  factory _TerminalLine.output(String t) =>
      _TerminalLine._(t, _LineType.output);
  factory _TerminalLine.error(String t) => _TerminalLine._(t, _LineType.error);
  factory _TerminalLine.system(String t) =>
      _TerminalLine._(t, _LineType.system);

  @override
  Widget build(BuildContext context) {
    Color color;
    String prefix = '';
    switch (type) {
      case _LineType.command:
        color = AppTheme.accent;
        prefix = '\$ ';
      case _LineType.output:
        color = AppTheme.textPrimary;
      case _LineType.error:
        color = AppTheme.danger;
        prefix = '✗ ';
      case _LineType.system:
        color = AppTheme.textMuted;
        prefix = '# ';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText(
        '$prefix$text',
        style: TextStyle(
          fontSize: 12.5,
          fontFamily: 'monospace',
          color: color,
          height: 1.45,
        ),
      ),
    );
  }
}

enum _LineType { command, output, error, system }
