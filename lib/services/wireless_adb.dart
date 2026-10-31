import 'dart:async';
import 'dart:io';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 无线 ADB 配对/连接结果
class WirelessResult {
  final bool ok;
  final String message;
  WirelessResult(this.ok, this.message);
}

/// 无线 ADB 服务
///
/// 支持两种模式：
/// 1. Android 11+ 无线调试配对（pair，需 6 位配对码）
/// 2. 传统 tcpip 模式（adb tcpip 5555 后直接 connect）
class WirelessAdbService {
  WirelessAdbService._();
  static final WirelessAdbService instance = WirelessAdbService._();

  String? _adbCache;
  Future<String> _adb() async {
    _adbCache ??= await AppConfig.adbPath();
    return _adbCache!;
  }

  /// 解析主机和端口（支持 "192.168.1.5:5555" 或 "192.168.1.5"）
  ({String host, int port})? parseAddress(String input, {int defaultPort = 5555}) {
    final t = input.trim();
    if (t.isEmpty) return null;
    final parts = t.split(':');
    final host = parts[0].trim();
    if (host.isEmpty) return null;
    var port = defaultPort;
    if (parts.length > 1) {
      port = int.tryParse(parts[1].trim()) ?? defaultPort;
    }
    if (port <= 0 || port > 65535) return null;
    return (host: host, port: port);
  }

  /// Android 11+ 配对
  ///
  /// 用户在手机上打开「无线调试 → 使用配对码配对设备」，
  /// 手机会显示 IP:端口 和 6 位配对码。
  Future<WirelessResult> pair({
    required String hostPort,
    required String pairingCode,
  }) async {
    final addr = parseAddress(hostPort);
    if (addr == null) {
      return WirelessResult(false, '地址格式错误，应为 IP:端口');
    }
    if (pairingCode.trim().length != 6 ||
        int.tryParse(pairingCode.trim()) == null) {
      return WirelessResult(false, '配对码应为 6 位数字');
    }

    final adb = await _adb();
    final r = await ProcessRunner.run(
      adb,
      ['pair', '${addr.host}:${addr.port}', pairingCode.trim()],
      timeout: AppConfig.normalTimeout,
    );

    final out = r.output;
    if (out.contains('Successfully paired')) {
      return WirelessResult(true, '配对成功');
    }
    return WirelessResult(false, out.isEmpty ? '配对失败（无输出）' : out);
  }

  /// 连接设备
  Future<WirelessResult> connect({
    required String hostPort,
  }) async {
    final addr = parseAddress(hostPort);
    if (addr == null) {
      return WirelessResult(false, '地址格式错误，应为 IP:端口');
    }

    final adb = await _adb();
    final r = await ProcessRunner.run(
      adb,
      ['connect', '${addr.host}:${addr.port}'],
      timeout: AppConfig.normalTimeout,
    );

    final out = r.output;
    if (out.contains('connected to') && !out.contains('failed')) {
      return WirelessResult(true, out);
    }
    return WirelessResult(false, out.isEmpty ? '连接失败（无输出）' : out);
  }

  /// 断开
  Future<WirelessResult> disconnect({String? hostPort}) async {
    final adb = await _adb();
    final args = ['disconnect'];
    if (hostPort != null && hostPort.trim().isNotEmpty) {
      final addr = parseAddress(hostPort);
      if (addr != null) args.add('${addr.host}:${addr.port}');
    }
    final r = await ProcessRunner.run(adb, args,
        timeout: AppConfig.shortTimeout);
    return WirelessResult(r.ok, r.output);
  }

  /// 把 USB 设备切到 TCP 模式（传统方式）
  ///
  /// 需要设备已通过 USB 连接且已授权。
  /// 成功后设备会监听 [port]，之后可拔掉 USB 用 connect 连接。
  Future<WirelessResult> enableTcpip({
    required String serial,
    int port = 5555,
  }) async {
    final adb = await _adb();
    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'tcpip', '$port'],
      timeout: AppConfig.normalTimeout,
    );

    if (r.output.contains('restarting in TCP mode')) {
      return WirelessResult(true, '已切换到 TCP 模式（端口 $port）');
    }
    return WirelessResult(false, r.output.isEmpty ? '切换失败' : r.output);
  }

  /// 获取设备 Wi-Fi IP（用于提示用户连接地址）
  Future<String?> deviceWifiIp(String serial) async {
    final adb = await _adb();
    // 优先 wlan0
    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'ip', '-f', 'inet', 'addr', 'show', 'wlan0'],
      timeout: AppConfig.normalTimeout,
    );
    final m = RegExp(r'inet\s+(\d+\.\d+\.\d+\.\d+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 列出当前通过 TCP 连接的设备
  Future<List<String>> listTcpDevices() async {
    final adb = await _adb();
    final r = await ProcessRunner.run(adb, ['devices'],
        timeout: AppConfig.shortTimeout);
    final result = <String>[];
    for (final line in r.stdout.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('List of')) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[0].contains(':')) {
        result.add('${parts[0]} (${parts[1]})');
      }
    }
    return result;
  }

  /// 本机可用的网段前缀（用于提示）
  Future<List<String>> localSubnets() async {
    final result = <String>[];
    try {
      if (Platform.isWindows) {
        final r = await ProcessRunner.run('ipconfig', [],
            timeout: AppConfig.shortTimeout);
        for (final m in RegExp(r'IPv4.*?:\s*(\d+\.\d+\.\d+)\.\d+')
            .allMatches(r.output)) {
          result.add('${m.group(1)}.x');
        }
      } else {
        final r = await ProcessRunner.run('ip', ['-4', 'addr'],
            timeout: AppConfig.shortTimeout);
        for (final m in RegExp(r'inet\s+(\d+\.\d+\.\d+)\.\d+')
            .allMatches(r.output)) {
          final prefix = m.group(1)!;
          if (prefix != '127.0.0') result.add('$prefix.x');
        }
      }
    } catch (_) {}
    return result.toSet().toList();
  }
}
