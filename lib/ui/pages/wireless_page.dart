import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/device_provider.dart';
import '../../services/wireless_adb.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 无线 ADB
///
/// 两种方式：
/// 1. Android 11+ 无线调试配对（推荐）
/// 2. USB 设备切 tcpip 后拔线
class WirelessPage extends StatefulWidget {
  const WirelessPage({super.key});

  @override
  State<WirelessPage> createState() => _WirelessPageState();
}

class _WirelessPageState extends State<WirelessPage> {
  final _pairAddrController = TextEditingController();
  final _pairCodeController = TextEditingController();
  final _connectAddrController = TextEditingController();
  final _portController = TextEditingController(text: '5555');

  bool _busy = false;
  String? _result;
  bool _resultOk = false;
  List<String> _tcpDevices = [];
  List<String> _subnets = [];
  String? _deviceIp;

  @override
  void initState() {
    super.initState();
    _refreshInfo();
  }

  @override
  void dispose() {
    _pairAddrController.dispose();
    _pairCodeController.dispose();
    _connectAddrController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _refreshInfo() async {
    final tcp = await WirelessAdbService.instance.listTcpDevices();
    final subnets = await WirelessAdbService.instance.localSubnets();

    final dp = context.read<DeviceProvider>();
    final device = dp.selectedDevice;
    String? ip;
    if (device != null) {
      ip = await WirelessAdbService.instance.deviceWifiIp(device.serial);
    }
    if (!mounted) return;
    setState(() {
      _tcpDevices = tcp;
      _subnets = subnets;
      _deviceIp = ip;
    });
  }

  void _setResult(bool ok, String msg) {
    if (!mounted) return;
    setState(() {
      _resultOk = ok;
      _result = msg;
      _busy = false;
    });
  }

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await WirelessAdbService.instance.pair(
      hostPort: _pairAddrController.text,
      pairingCode: _pairCodeController.text,
    );
    _setResult(r.ok, r.message);
    if (r.ok) _refreshInfo();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await WirelessAdbService.instance
        .connect(hostPort: _connectAddrController.text);
    _setResult(r.ok, r.message);
    if (r.ok) {
      _refreshInfo();
      if (mounted) context.read<DeviceProvider>().refresh();
    }
  }

  Future<void> _enableTcpip() async {
    final dp = context.read<DeviceProvider>();
    final device = dp.selectedDevice;
    if (device == null) {
      _setResult(false, '请先在「设备总览」选择一台 USB 连接的设备');
      return;
    }

    final port = int.tryParse(_portController.text) ?? 5555;
    setState(() {
      _busy = true;
      _result = null;
    });

    final r = await WirelessAdbService.instance
        .enableTcpip(serial: device.serial, port: port);
    if (r.ok) {
      await _refreshInfo();
      final ip = _deviceIp;
      if (ip != null) {
        _connectAddrController.text = '$ip:$port';
      }
      _setResult(true, '${r.message}\n\n'
          '现在可以拔掉 USB，点「连接」\n'
          '${ip != null ? "地址：$ip:$port" : "请先在手机上查 Wi-Fi IP"}');
    } else {
      _setResult(false, r.message);
    }
  }

  Future<void> _disconnect() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await WirelessAdbService.instance
        .disconnect(hostPort: _connectAddrController.text);
    _setResult(r.ok, r.message.isEmpty ? '已断开' : r.message);
    _refreshInfo();
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();
    final usbDevice = dp.selectedDevice;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 提示
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
            ),
            child: const Row(
              children: [
                Icon(Icons.wifi, size: 18, color: AppTheme.primary),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '无线 ADB 需要手机和电脑在同一 Wi-Fi 下。\n'
                    'Android 11+ 用「无线调试配对」；旧版本用「USB 切 TCP」。',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 方式一：配对
          AppCard(
            title: '方式一：无线调试配对（Android 11+）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '手机：设置 → 开发者选项 → 无线调试 → 使用配对码配对设备\n'
                  '（会显示「IP:端口」和 6 位配对码，端口每次不同）',
                  style: TextStyle(
                      fontSize: 11.5, color: AppTheme.textMuted, height: 1.6),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _pairAddrController,
                        style: const TextStyle(
                            fontSize: 12.5, fontFamily: 'monospace'),
                        decoration: InputDecoration(
                          labelText: '配对地址',
                          hintText: '192.168.1.5:37123',
                          helperText: _subnets.isEmpty
                              ? null
                              : '本机网段：${_subnets.join("  ")}',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _pairCodeController,
                        style: const TextStyle(
                            fontSize: 12.5, fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: '配对码',
                          hintText: '123456',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      height: 44,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _pair,
                        child: const Text('配对'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 方式二：USB 切 TCP
          AppCard(
            title: '方式二：USB 切 TCP（通用）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '需要设备已用 USB 连接并授权。切换后可以拔掉数据线。',
                  style: TextStyle(
                      fontSize: 11.5, color: AppTheme.textMuted, height: 1.6),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _portController,
                        style: const TextStyle(
                            fontSize: 12.5, fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: '端口',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        onPressed: (_busy || usbDevice == null)
                            ? null
                            : _enableTcpip,
                        icon: const Icon(Icons.usb, size: 16),
                        label: const Text('切换到 TCP'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (usbDevice == null)
                      const Text('需要先选一台 USB 设备',
                          style: TextStyle(
                              fontSize: 11.5, color: AppTheme.warning))
                    else if (_deviceIp != null)
                      Text('设备 IP: $_deviceIp',
                          style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: AppTheme.success)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 连接
          AppCard(
            title: '连接无线设备',
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _connectAddrController,
                    style: const TextStyle(
                        fontSize: 12.5, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: '地址',
                      hintText: '192.168.1.5:5555',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('连接'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _disconnect,
                    child: const Text('断开'),
                  ),
                ),
              ],
            ),
          ),

          // 结果
          if (_result != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_resultOk ? AppTheme.success : AppTheme.danger)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (_resultOk ? AppTheme.success : AppTheme.danger)
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _resultOk ? Icons.check_circle : Icons.error,
                    size: 16,
                    color: _resultOk ? AppTheme.success : AppTheme.danger,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      _result!,
                      style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: AppTheme.textSecondary,
                          height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // 当前 TCP 设备
          if (_tcpDevices.isNotEmpty) ...[
            const SizedBox(height: 14),
            AppCard(
              title: '当前无线连接',
              trailing: IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                color: AppTheme.textSecondary,
                visualDensity: VisualDensity.compact,
                onPressed: _refreshInfo,
              ),
              child: Column(
                children: [
                  for (final d in _tcpDevices)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.wifi,
                          size: 16, color: AppTheme.success),
                      title: Text(d,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
