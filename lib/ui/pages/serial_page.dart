import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/serial_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// TTL / 串口终端
class SerialPage extends StatefulWidget {
  const SerialPage({super.key});

  @override
  State<SerialPage> createState() => _SerialPageState();
}

class _SerialPageState extends State<SerialPage> {
  bool _ready = false;
  String? _version;
  List<SerialPort> _ports = [];
  String? _selectedPort;
  int _baud = 115200;
  int _dataBits = 8;
  String _parity = 'none';
  int _stopBits = 1;
  String _flow = 'none';
  bool _timestamp = true;
  bool _localEcho = false;
  bool _autoReconnect = true;

  bool _connected = false;
  bool _hexMode = false;

  final _inputController = TextEditingController();
  final _log = <String>[];
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    SerialService.instance.close();
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final ok = await SerialService.instance.init();
    final ver = await SerialService.instance.version();
    final ports = await SerialService.instance.listPorts();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _version = ver;
      _ports = ports;
      if (ports.isNotEmpty && _selectedPort == null) {
        _selectedPort = ports.first.path;
      }
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

  Future<void> _refreshPorts() async {
    final ports = await SerialService.instance.listPorts();
    if (!mounted) return;
    setState(() {
      _ports = ports;
      if (ports.isNotEmpty &&
          (_selectedPort == null ||
              !ports.any((p) => p.path == _selectedPort))) {
        _selectedPort = ports.first.path;
      }
    });
  }

  Future<void> _connect() async {
    if (_selectedPort == null) return;
    _log.clear();

    final r = await SerialService.instance.open(
      port: _selectedPort!,
      baud: _baud,
      dataBits: _dataBits,
      parity: _parity,
      stopBits: _stopBits,
      flow: _flow,
      timestamp: _timestamp,
      localEcho: _localEcho,
      autoReconnect: _autoReconnect,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _connected = r.ok);
    if (r.ok) _inputFocus.requestFocus();
  }

  Future<void> _disconnect() async {
    await SerialService.instance.close();
    if (!mounted) return;
    setState(() => _connected = false);
    _addLog('── 已断开');
  }

  Future<void> _send() async {
    final text = _inputController.text;
    if (text.isEmpty) return;
    final ok = await SerialService.instance
        .send(text, newline: !_hexMode, hex: _hexMode);
    if (ok) {
      if (_localEcho) _addLog('→ $text');
      _inputController.clear();
      _inputFocus.requestFocus();
    }
  }

  Future<void> _sendControl(String key) async {
    await SerialService.instance.sendControl(key);
    if (!mounted) return;
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 左侧：连接设置
        Container(
          width: 300,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: AppTheme.border)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 状态
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: (_ready ? AppTheme.success : AppTheme.danger)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Row(
                    children: [
                      Icon(_ready ? Icons.check_circle : Icons.error,
                          size: 13,
                          color:
                              _ready ? AppTheme.success : AppTheme.danger),
                      const SizedBox(width: 6),
                      Text(
                        _ready ? 'tio $_version' : 'tio 未就绪',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 串口选择
                Row(
                  children: [
                    const Text('串口设备',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 14),
                      color: AppTheme.textMuted,
                      visualDensity: VisualDensity.compact,
                      onPressed: _connected ? null : _refreshPorts,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_ports.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.bgElevated,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('未检测到串口设备',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted)),
                        SizedBox(height: 6),
                        Text(
                          'Linux: 需要 /dev/ttyUSB* 或 /dev/ttyACM*\n'
                          '权限: sudo usermod -a -G dialout \$USER',
                          style: TextStyle(
                              fontSize: 9.5,
                              color: AppTheme.textMuted,
                              height: 1.5),
                        ),
                      ],
                    ),
                  )
                else
                  DropdownButtonFormField<String>(
                    value: _selectedPort,
                    isDense: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.textPrimary),
                    items: [
                      for (final port in _ports)
                        DropdownMenuItem(
                          value: port.path,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(port.path,
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      fontFamily: 'monospace')),
                              if (port.description.isNotEmpty)
                                Text(port.description,
                                    style: const TextStyle(
                                        fontSize: 9,
                                        color: AppTheme.textMuted)),
                            ],
                          ),
                        ),
                    ],
                    onChanged: _connected
                        ? null
                        : (v) => setState(() => _selectedPort = v),
                  ),
                const SizedBox(height: 12),

                // 波特率
                _label('波特率'),
                DropdownButtonFormField<int>(
                  value: _baud,
                  isDense: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textPrimary),
                  items: [
                    for (final b in SerialService.commonBaudRates)
                      DropdownMenuItem(value: b, child: Text('$b')),
                  ],
                  onChanged: _connected
                      ? null
                      : (v) => setState(() => _baud = v ?? 115200),
                ),
                const SizedBox(height: 12),

                // 高级参数
                ExpansionTile(
                  title: const Text('高级参数',
                      style: TextStyle(
                          fontSize: 11.5, color: AppTheme.textSecondary)),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(left: 4),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('数据位'),
                              DropdownButton<int>(
                                value: _dataBits,
                                isDense: true,
                                underline: const SizedBox(),
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textPrimary),
                                items: const [
                                  DropdownMenuItem(value: 5, child: Text('5')),
                                  DropdownMenuItem(value: 6, child: Text('6')),
                                  DropdownMenuItem(value: 7, child: Text('7')),
                                  DropdownMenuItem(value: 8, child: Text('8')),
                                ],
                                onChanged: _connected
                                    ? null
                                    : (v) =>
                                        setState(() => _dataBits = v ?? 8),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('停止位'),
                              DropdownButton<int>(
                                value: _stopBits,
                                isDense: true,
                                underline: const SizedBox(),
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textPrimary),
                                items: const [
                                  DropdownMenuItem(value: 1, child: Text('1')),
                                  DropdownMenuItem(value: 2, child: Text('2')),
                                ],
                                onChanged: _connected
                                    ? null
                                    : (v) =>
                                        setState(() => _stopBits = v ?? 1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _label('校验位'),
                    DropdownButton<String>(
                      value: _parity,
                      isDense: true,
                      isExpanded: true,
                      underline: const SizedBox(),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textPrimary),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('无')),
                        DropdownMenuItem(value: 'even', child: Text('偶')), 
                        DropdownMenuItem(value: 'odd', child: Text('奇')),
                      ],
                      onChanged: _connected
                          ? null
                          : (v) => setState(() => _parity = v ?? 'none'),
                    ),
                    const SizedBox(height: 8),
                    _label('流控'),
                    DropdownButton<String>(
                      value: _flow,
                      isDense: true,
                      isExpanded: true,
                      underline: const SizedBox(),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textPrimary),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('无')),
                        DropdownMenuItem(value: 'hard', child: Text('硬件')),
                        DropdownMenuItem(value: 'soft', child: Text('软件')),
                      ],
                      onChanged: _connected
                          ? null
                          : (v) => setState(() => _flow = v ?? 'none'),
                    ),
                    const SizedBox(height: 10),
                    _switch('时间戳', _timestamp,
                        (v) => setState(() => _timestamp = v)),
                    _switch('本地回显', _localEcho,
                        (v) => setState(() => _localEcho = v)),
                    _switch('自动重连', _autoReconnect,
                        (v) => setState(() => _autoReconnect = v)),
                  ],
                ),
                const SizedBox(height: 14),

                // 连接按钮
                SizedBox(
                  height: 40,
                  child: _connected
                      ? OutlinedButton.icon(
                          onPressed: _disconnect,
                          icon: const Icon(Icons.link_off, size: 15),
                          label: const Text('断开',
                              style: TextStyle(fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.danger,
                          ),
                        )
                      : ElevatedButton.icon(
                          onPressed:
                              (_selectedPort == null || !_ready) ? null : _connect,
                          icon: const Icon(Icons.link, size: 15),
                          label: const Text('连接',
                              style: TextStyle(fontSize: 12)),
                        ),
                ),
                const SizedBox(height: 10),

                // 测试按钮
                SizedBox(
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: (_selectedPort == null || _connected || !_ready)
                        ? null
                        : () async {
                            _log.clear();
                            await SerialService.instance.testPort(
                              port: _selectedPort!,
                              baud: _baud,
                              onLine: _addLog,
                            );
                          },
                    icon: const Icon(Icons.science, size: 14),
                    label: const Text('测试（读 3 秒）',
                        style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 右侧：终端
        Expanded(
          child: Column(
            children: [
              // 工具栏
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    StatusDot(
                      color: _connected
                          ? AppTheme.success
                          : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      _connected ? '已连接 $_selectedPort' : '未连接',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.textSecondary),
                    ),
                    const Spacer(),
                    // hex 模式
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _hexMode = !_hexMode),
                      icon: Icon(
                        _hexMode ? Icons.code : Icons.text_fields,
                        size: 13,
                      ),
                      label: Text(
                        _hexMode ? 'HEX' : '文本',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: _hexMode
                            ? AppTheme.accent
                            : AppTheme.textMuted,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 15),
                      color: AppTheme.textMuted,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _log.clear()),
                    ),
                  ],
                ),
              ),

              // 终端输出
              Expanded(
                child: Container(
                  color: const Color(0xFF0A0C10),
                  child: _log.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.cable,
                                  size: 40, color: AppTheme.textMuted),
                              SizedBox(height: 12),
                              Text('选择一个串口设备并点击「连接」',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textMuted)),
                              SizedBox(height: 6),
                              Text('支持 TTL 调试、UART 救砖、开发板日志',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: AppTheme.textMuted)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(10),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final line = _log[i];
                            Color c = const Color(0xFFB0C4DE);
                            if (line.contains('✅')) c = AppTheme.success;
                            if (line.contains('❌') || line.contains('⚠️')) {
                              c = AppTheme.danger;
                            }
                            if (line.startsWith('══')) c = AppTheme.accent;
                            if (line.startsWith('──')) c = AppTheme.textMuted;
                            return SelectableText(line,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: c,
                                    height: 1.4));
                          },
                        ),
                ),
              ),

              // 控制键 + 输入
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: Column(
                  children: [
                    // 控制键
                    Row(
                      children: [
                        for (final (key, label) in [
                          ('ctrl+c', 'Ctrl+C'),
                          ('ctrl+d', 'Ctrl+D'),
                          ('ctrl+z', 'Ctrl+Z'),
                          ('esc', 'Esc'),
                          ('tab', 'Tab'),
                          ('enter', '↵'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: OutlinedButton(
                              onPressed:
                                  _connected ? () => _sendControl(key) : null,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 9, vertical: 4),
                                minimumSize: Size.zero,
                              ),
                              child: Text(label,
                                  style: const TextStyle(fontSize: 10)),
                            ),
                          ),
                        const Spacer(),
                        const Text('回车发送',
                            style: TextStyle(
                                fontSize: 9.5, color: AppTheme.textMuted)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 输入框
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            focusNode: _inputFocus,
                            readOnly: !_connected,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: _connected
                                  ? (_hexMode
                                      ? 'HEX 模式：48 65 6C 6C 6F'
                                      : '输入命令，回车发送')
                                  : '未连接',
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 11),
                            ),
                            style: const TextStyle(
                                fontSize: 12, fontFamily: 'monospace'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 40,
                          child: ElevatedButton.icon(
                            onPressed: _connected ? _send : null,
                            icon: const Icon(Icons.send, size: 15),
                            label:
                                const Text('发送', style: TextStyle(fontSize: 11.5)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5, color: AppTheme.textMuted)),
      );

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 10.5, color: AppTheme.textMuted)),
        ),
        Transform.scale(
          scale: 0.7,
          child: Switch(
            value: value,
            onChanged: _connected ? null : onChanged,
          ),
        ),
      ],
    );
  }
}
