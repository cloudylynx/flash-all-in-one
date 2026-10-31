import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 串口设备信息
class SerialPort {
  final String path;
  final String description;
  final String? driver;
  final String? tid;

  SerialPort({
    required this.path,
    this.description = '',
    this.driver,
    this.tid,
  });

  @override
  String toString() => path;
}

/// 串口操作结果
class SerialResult {
  final bool ok;
  final String message;
  final List<String> log;
  SerialResult(this.ok, this.message, [this.log = const []]);
}

/// TTL / 串口通信服务
///
/// 工具：tio 3.9（3210★，GPL-2.0-or-later）
///   自己编译，仅 0.20 MB
///
/// 能力：
///   · 设备拔插自动重连（救砖反复复位不断线）
///   · 日志落盘带时间戳
///   · hex 输入输出
///   · DTR/RTS 时序控制（进 download 模式必需）
///   · 波特率 / 数据位 / 校验位 / 停止位 / 流控
///
/// 用途：
///   · 路由器 / 开发板串口调试
///   · 安卓设备 UART 救砖
///   · ESP32 / STM32 串口日志
///   · 树莓派串口控制台
class SerialService {
  SerialService._();
  static final SerialService instance = SerialService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 当前运行的会话
  Process? _running;
  StreamSubscription? _sub;
  bool get isConnected => _running != null;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    final tio = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/linux/serial/tio',
      subDir: 'serial',
      fileName: 'tio',
      executable: true,
    );
    if (tio != null) _dir = File(tio).parent.path;

    _available = _dir != null;
    return _available;
  }

  String? _exe() {
    if (_dir == null) return null;
    final path = p.join(_dir!, 'tio');
    return File(path).existsSync() ? path : null;
  }

  /// tio 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final exe = _exe();
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['--version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'tio\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 列出可用串口设备
  ///
  /// 自己扫描 /dev 和 /sys，不依赖 tio --list（后者在某些环境下输出不稳定）
  Future<List<SerialPort>> listPorts() async {
    final ports = <SerialPort>[];

    if (Platform.isWindows) {
      // Windows: 用 PowerShell 枚举 COM 口
      try {
        final r = await ProcessRunner.run(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            r'Get-CimInstance Win32_SerialPort | Select-Object DeviceID,Caption | ConvertTo-Json -Compress'
          ],
          timeout: const Duration(seconds: 10),
        );
        if (r.ok && r.stdout.trim().isNotEmpty) {
          final decoded = jsonDecode(r.stdout.trim());
          final list = decoded is List ? decoded : [decoded];
          for (final item in list) {
            if (item is Map) {
              ports.add(SerialPort(
                path: item['DeviceID']?.toString() ?? '',
                description: item['Caption']?.toString() ?? '',
              ));
            }
          }
        }
      } catch (_) {}
      return ports;
    }

    // Linux/macOS: 扫描 /dev
    final patterns = [
      '/dev/ttyUSB',
      '/dev/ttyACM',
      '/dev/ttyAMA',
      '/dev/ttyS',
      '/dev/tty.usbserial',
      '/dev/tty.wchusbserial',
      '/dev/cu.usbserial',
    ];

    try {
      final dev = Directory('/dev');
      if (dev.existsSync()) {
        for (final entity in dev.listSync()) {
          final path = entity.path;
          for (final pattern in patterns) {
            if (path.startsWith(pattern)) {
              // ttyS0~ttyS31 通常是主板自带，过滤掉（除非明确要）
              if (pattern == '/dev/ttyS') {
                final num = int.tryParse(path.replaceAll('/dev/ttyS', ''));
                if (num != null && num > 3) continue; // 只保留 ttyS0-3
              }
              ports.add(SerialPort(
                path: path,
                description: _describePort(path),
                driver: _driverOf(path),
              ));
              break;
            }
          }
        }
      }
    } catch (_) {}

    ports.sort((a, b) => a.path.compareTo(b.path));
    return ports;
  }

  /// 获取设备描述（USB 厂商/产品名）
  String _describePort(String path) {
    final name = p.basename(path);
    try {
      // /sys/class/tty/ttyUSB0/device/../ 下有 vendor/product
      final base = '/sys/class/tty/$name/device';
      final dir = Directory(base);
      if (dir.existsSync()) {
        // 往上找两层
        for (final candidate in [
          base,
          p.join(base, '..'),
          p.join(base, '..', '..'),
        ]) {
          final vf = File(p.join(candidate, 'idVendor'));
          final pf = File(p.join(candidate, 'idProduct'));
          final mf = File(p.join(candidate, 'manufacturer'));
          final prf = File(p.join(candidate, 'product'));
          if (vf.existsSync() && pf.existsSync()) {
            final vendor = vf.readAsStringSync().trim();
            final product = pf.readAsStringSync().trim();
            final manuf = mf.existsSync() ? mf.readAsStringSync().trim() : '';
            final prod = prf.existsSync() ? prf.readAsStringSync().trim() : '';
            if (manuf.isNotEmpty || prod.isNotEmpty) {
              return '$manuf $prod'.trim();
            }
            return 'USB $vendor:$product';
          }
        }
      }
    } catch (_) {}
    return '';
  }

  /// 获取驱动名
  String? _driverOf(String path) {
    final name = p.basename(path);
    try {
      final link = Link('/sys/class/tty/$name/device/driver');
      if (link.existsSync()) {
        final target = link.targetSync();
        return p.basename(target);
      }
    } catch (_) {}
    return null;
  }

  /// 打开串口会话
  ///
  /// [onLine] 每读到一行就回调
  /// [onRaw] 原始字节回调（用于 hex 模式）
  Future<SerialResult> open({
    required String port,
    int baud = 115200,
    int dataBits = 8,
    String parity = 'none',
    int stopBits = 1,
    String flow = 'none',
    bool timestamp = false,
    bool localEcho = false,
    String inputMode = 'normal',
    String outputMode = 'normal',
    String? logFile,
    bool autoReconnect = true,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (_running != null) {
      return SerialResult(false, '已有会话在运行', log);
    }

    if (!await init()) return SerialResult(false, 'tio 未就绪', log);
    final exe = _exe();
    if (exe == null) return SerialResult(false, 'tio 未找到', log);

    add('══ 打开串口');
    add('  设备: $port');
    add('  波特率: $baud $dataBits$parity$stopBits');
    add('  流控: $flow');
    if (logFile != null) add('  日志: $logFile');
    add('');

    final args = <String>[
      '-b', '$baud',
      '-d', '$dataBits',
      '-p', parity,
      '-s', '$stopBits',
      '-f', flow,
      '-t',
    ];
    if (timestamp) args.add('--timestamp');
    if (localEcho) args.add('-e');
    if (inputMode != 'normal') args.addAll(['--input-mode', inputMode]);
    if (outputMode != 'normal') args.addAll(['--output-mode', outputMode]);
    if (logFile != null) args.addAll(['--log', '--log-file', logFile]);
    if (!autoReconnect) args.add('-n');
    args.add(port);

    try {
      _running = await Process.start(
        exe,
        args,
        workingDirectory: _dir,
        environment: {'TERM': 'dumb'},
      );

      // 合并 stdout + stderr
      _sub = _running!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) add(line);
        }
      });

      _running!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) add(line);
        }
      });

      // 监听退出
      unawaited(_running!.exitCode.then((code) {
        add('');
        add('── 会话结束（退出码 $code）');
        _running = null;
        _sub?.cancel();
        _sub = null;
      }));

      add('✅ 已连接（点「发送」可以输入数据）');
      return SerialResult(true, '已连接 $port', log);
    } catch (e) {
      _running = null;
      add('❌ 打开失败: $e');
      return SerialResult(false, '打开失败: $e', log);
    }
  }

  /// 发送数据到串口
  Future<bool> send(String data, {bool newline = true, bool hex = false}) async {
    if (_running == null) return false;
    try {
      if (hex) {
        // hex 模式：把 "48 65 6C" 转成字节
        final bytes = <int>[];
        for (final part in data.split(RegExp(r'\s+'))) {
          if (part.isEmpty) continue;
          final v = int.tryParse(part, radix: 16);
          if (v != null) bytes.add(v);
        }
        _running!.stdin.add(bytes);
      } else {
        _running!.stdin.add(utf8.encode(newline ? '$data\n' : data));
      }
      await _running!.stdin.flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发送控制字符（Ctrl+C 等）
  Future<bool> sendControl(String key) async {
    if (_running == null) return false;
    const map = {
      'ctrl+c': 0x03,
      'ctrl+d': 0x04,
      'ctrl+z': 0x1A,
      'ctrl+x': 0x18,
      'enter': 0x0D,
      'esc': 0x1B,
      'tab': 0x09,
      'backspace': 0x7F,
    };
    final byte = map[key.toLowerCase()];
    if (byte == null) return false;
    try {
      _running!.stdin.add([byte]);
      await _running!.stdin.flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 关闭会话
  Future<void> close() async {
    if (_running == null) return;
    try {
      await _sub?.cancel();
      _sub = null;
      _running!.kill(ProcessSignal.sigterm);
      await _running!.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _running?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
    _running = null;
  }

  /// 测试串口（打开后读 2 秒再关）
  Future<SerialResult> testPort({
    required String port,
    int baud = 115200,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SerialResult(false, 'tio 未就绪', log);
    final exe = _exe();
    if (exe == null) return SerialResult(false, 'tio 未找到', log);

    add('══ 测试串口');
    add('  $port @ $baud');
    add('  （读 3 秒，看是否有数据）');
    add('');

    try {
      final proc = await Process.start(
        exe,
        ['-b', '$baud', '-t', port],
        workingDirectory: _dir,
        environment: {'TERM': 'dumb'},
      );

      var got = 0;
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            got++;
            add(line);
          }
        }
      });

      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) add('  $line');
        }
      });

      await Future.delayed(const Duration(seconds: 3));
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 2),
          onTimeout: () => -1);

      add('');
      if (got > 0) {
        add('✅ 收到 $got 行数据，串口工作正常');
        return SerialResult(true, '收到 $got 行', log);
      }
      add('⚠️ 3 秒内没收到数据');
      add('  可能原因：');
      add('    · 波特率不对（试试 9600 / 57600 / 115200 / 921600）');
      add('    · 接线问题（TX/RX 要交叉）');
      add('    · 设备没在输出');
      return SerialResult(false, '无数据', log);
    } catch (e) {
      add('❌ 打开失败: $e');
      add('');
      add('常见原因：');
      add('  · 没有权限（Linux 需加入 dialout 组）');
      add('    sudo usermod -a -G dialout \$USER');
      add('  · 设备被其他程序占用');
      return SerialResult(false, '打开失败', log);
    }
  }

  /// 常用波特率列表
  static const List<int> commonBaudRates = [
    1200, 2400, 4800, 9600, 19200, 38400, 57600,
    115200, 230400, 460800, 921600, 1500000, 2000000, 3000000,
  ];
}
