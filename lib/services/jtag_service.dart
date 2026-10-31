import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// JTAG 操作结果
class JtagResult {
  final bool ok;
  final String message;
  final List<String> log;
  JtagResult(this.ok, this.message, [this.log = const []]);
}

/// JTAG / SWD 调试服务
///
/// 工具：openocd 0.12.0（2367★，GPL-2.0-or-later）
///   49 种调试接口 + 309 种芯片配置
///
/// 能力：
///   · JTAG / SWD 调试与烧写
///   · CPU 停机、读写内存、dump flash
///   · 救「连 EDL/BROM 都进不去」的彻底砖（需硬件 JTAG 焊点）
///   · 支持 STM32 / nRF52 / RP2040 / ESP32 等
///
/// ⚠️ 需要硬件：J-Link / ST-Link / FTDI / CMSIS-DAP 等调试器
class JtagService {
  JtagService._();
  static final JtagService instance = JtagService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;
    if (Platform.isWindows) return false;

    final path = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/linux/jtag/openocd',
      subDir: 'jtag',
      fileName: 'openocd',
      executable: true,
    );
    if (path == null) return false;

    _dir = File(path).parent.path;

    // 提取 scripts 目录（852 个 cfg）
    // 因为太多，只提取常用的
    const interfaces = [
      'interface/cmsis-dap.cfg',
      'interface/ftdi/ft232h-module-swd.cfg',
      'interface/jlink.cfg',
      'interface/stlink.cfg',
      'interface/stlink-dap.cfg',
      'interface/xds110.cfg',
    ];
    const targets = [
      'target/stm32f1x.cfg',
      'target/stm32f4x.cfg',
      'target/stm32f7x.cfg',
      'target/stm32g0x.cfg',
      'target/stm32h7x.cfg',
      'target/stm32l4x.cfg',
      'target/nrf51.cfg',
      'target/nrf52.cfg',
      'target/rp2040.cfg',
      'target/rp2040-core0.cfg',
      'target/rp2040-parts.cfg',
      'target/esp32.cfg',
      'target/esp32s2.cfg',
      'target/esp32s3.cfg',
    ];

    for (final cfg in [...interfaces, ...targets]) {
      await ToolExtractor.extractFile(
        assetPath: 'assets/tools/linux/jtag/scripts/$cfg',
        subDir: 'jtag/scripts/${p.dirname(cfg)}',
        fileName: p.basename(cfg),
      );
    }

    _available = true;
    return true;
  }

  String? _exe() {
    if (_dir == null) return null;
    final path = p.join(_dir!, 'openocd');
    return File(path).existsSync() ? path : null;
  }

  /// 环境变量（scripts 路径）
  Map<String, String>? _env() {
    if (_dir == null) return null;
    return {'OPENOCD_SCRIPTS': p.join(_dir!, 'scripts')};
  }

  /// openocd 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final exe = _exe();
    if (exe == null) return null;
    final r = await ProcessRunner.run(
      exe,
      ['--version'],
      timeout: AppConfig.shortTimeout,
      workingDirectory: _dir,
      environment: _env(),
    );
    final m = RegExp(r'Open On-Chip Debugger\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 常用调试器列表
  static const List<Map<String, String>> probes = [
    {'id': 'stlink', 'name': 'ST-Link V2', 'cfg': 'interface/stlink.cfg', 'desc': '最便宜，10-30 元'},
    {'id': 'jlink', 'name': 'J-Link', 'cfg': 'interface/jlink.cfg', 'desc': '最全，原版贵，克隆版 50-100 元'},
    {'id': 'cmsis-dap', 'name': 'CMSIS-DAP', 'cfg': 'interface/cmsis-dap.cfg', 'desc': '开源方案，20-50 元'},
    {'id': 'ft232h', 'name': 'FT232H', 'cfg': 'interface/ftdi/ft232h-module-swd.cfg', 'desc': '需自己接线'},
  ];

  /// 常用芯片列表
  static const List<Map<String, String>> chips = [
    {'id': 'stm32f1x', 'name': 'STM32F1xx', 'cfg': 'target/stm32f1x.cfg'},
    {'id': 'stm32f4x', 'name': 'STM32F4xx', 'cfg': 'target/stm32f4x.cfg'},
    {'id': 'stm32f7x', 'name': 'STM32F7xx', 'cfg': 'target/stm32f7x.cfg'},
    {'id': 'stm32g0x', 'name': 'STM32G0xx', 'cfg': 'target/stm32g0x.cfg'},
    {'id': 'stm32h7x', 'name': 'STM32H7xx', 'cfg': 'target/stm32h7x.cfg'},
    {'id': 'stm32l4x', 'name': 'STM32L4xx', 'cfg': 'target/stm32l4x.cfg'},
    {'id': 'nrf51', 'name': 'nRF51', 'cfg': 'target/nrf51.cfg'},
    {'id': 'nrf52', 'name': 'nRF52', 'cfg': 'target/nrf52.cfg'},
    {'id': 'rp2040', 'name': 'RP2040', 'cfg': 'target/rp2040.cfg'},
    {'id': 'esp32', 'name': 'ESP32', 'cfg': 'target/esp32.cfg'},
    {'id': 'esp32s3', 'name': 'ESP32-S3', 'cfg': 'target/esp32s3.cfg'},
  ];

  /// 检测调试器
  Future<JtagResult> scanProbes({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return JtagResult(false, 'openocd 未就绪', log);
    final exe = _exe();
    if (exe == null) return JtagResult(false, 'openocd 未找到', log);

    add('══ 扫描调试器');
    add('');

    // 用 usb 枚举看有没有已知调试器
    final probes = {
      '0483:3748': 'ST-Link V2',
      '0483:374b': 'ST-Link V2-1',
      '0483:374e': 'ST-Link V3',
      '1366:0101': 'J-Link',
      '1366:0105': 'J-Link',
      '0d28:0204': 'CMSIS-DAP (DAPLink)',
      '0403:6014': 'FT232H',
    };

    var found = 0;
    try {
      final usbDir = Directory('/sys/bus/usb/devices');
      if (usbDir.existsSync()) {
        for (final e in usbDir.listSync()) {
          final vf = File(p.join(e.path, 'idVendor'));
          final pf = File(p.join(e.path, 'idProduct'));
          if (vf.existsSync() && pf.existsSync()) {
            final id = '${vf.readAsStringSync().trim()}:${pf.readAsStringSync().trim()}';
            if (probes.containsKey(id)) {
              add('  ✅ ${probes[id]}  ($id)');
              found++;
            }
          }
        }
      }
    } catch (_) {}

    add('');
    if (found > 0) {
      add('✅ 找到 $found 个调试器');
      return JtagResult(true, '找到 $found 个调试器', log);
    }
    add('⚠️ 未检测到调试器');
    add('');
    add('常见调试器：');
    for (final p in probes_.entries) {
      add('  · ${p.value}');
    }
    return JtagResult(false, '未检测到调试器', log);
  }

  static const Map<String, String> probes_ = {
    'stlink': 'ST-Link V2（10-30 元，最便宜）',
    'jlink': 'J-Link（克隆版 50-100 元，最全）',
    'cmsisdap': 'CMSIS-DAP（20-50 元，开源）',
    'ft232h': 'FT232H（需自己接线）',
  };

  /// 测试连接（读芯片 ID）
  Future<JtagResult> testConnection({
    required String probeCfg,
    required String chipCfg,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return JtagResult(false, 'openocd 未就绪', log);
    final exe = _exe();
    if (exe == null) return JtagResult(false, 'openocd 未找到', log);

    add('══ 测试 JTAG 连接');
    add('  调试器: $probeCfg');
    add('  芯片: $chipCfg');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      [
        '-f', probeCfg,
        '-f', chipCfg,
        '-c', 'init',
        '-c', 'targets',
        '-c', 'shutdown',
      ],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0) {
      add('');
      add('✅ 连接成功');
      return JtagResult(true, '连接成功', log);
    }
    return JtagResult(false, '连接失败', log);
  }

  /// 读取芯片 ID
  Future<JtagResult> readChipId({
    required String probeCfg,
    required String chipCfg,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return JtagResult(false, 'openocd 未就绪', log);
    final exe = _exe();
    if (exe == null) return JtagResult(false, 'openocd 未找到', log);

    add('══ 读取芯片 ID');

    final code = await ProcessRunner.stream(
      exe,
      [
        '-f', probeCfg,
        '-f', chipCfg,
        '-c', 'init',
        '-c', 'reset halt',
        '-c', 'flash probe 0',
        '-c', 'shutdown',
      ],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
      environment: _env(),
    );

    return JtagResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 烧写固件
  Future<JtagResult> flashFirmware({
    required String probeCfg,
    required String chipCfg,
    required String firmwarePath,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return JtagResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return JtagResult(false, 'openocd 未就绪', log);
    final exe = _exe();
    if (exe == null) return JtagResult(false, 'openocd 未找到', log);

    if (!File(firmwarePath).existsSync()) {
      return JtagResult(false, '固件文件不存在', log);
    }

    add('══ JTAG 烧写');
    add('  文件: ${p.basename(firmwarePath)}');
    add('  大小: ${(File(firmwarePath).lengthSync() / 1024).toStringAsFixed(1)} KB');
    add('');

    final ext = p.extension(firmwarePath).toLowerCase();
    final writeCmd = ext == '.hex'
        ? 'program "$firmwarePath" verify reset exit'
        : 'program "$firmwarePath" 0x08000000 verify reset exit';

    final code = await ProcessRunner.stream(
      exe,
      [
        '-f', probeCfg,
        '-f', chipCfg,
        '-c', 'init',
        '-c', 'reset halt',
        '-c', writeCmd,
      ],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0) {
      add('');
      add('✅ 烧写完成');
      return JtagResult(true, '固件已烧入', log);
    }
    return JtagResult(false, '烧写失败', log);
  }

  /// dump Flash 到文件
  Future<JtagResult> dumpFlash({
    required String probeCfg,
    required String chipCfg,
    required String outputPath,
    String address = '0x08000000',
    int size = 0x100000,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return JtagResult(false, 'openocd 未就绪', log);
    final exe = _exe();
    if (exe == null) return JtagResult(false, 'openocd 未找到', log);

    add('══ Dump Flash');
    add('  地址: $address');
    add('  大小: ${(size / 1024).toStringAsFixed(0)} KB');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      [
        '-f', probeCfg,
        '-f', chipCfg,
        '-c', 'init',
        '-c', 'reset halt',
        '-c', 'dump_image "$outputPath" $address $size',
        '-c', 'shutdown',
      ],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final actual = File(outputPath).lengthSync();
      add('');
      add('✅ 已 dump ${(actual / 1024).toStringAsFixed(0)} KB');
      return JtagResult(true, 'Flash 已 dump', log);
    }
    return JtagResult(false, 'dump 失败', log);
  }
}
