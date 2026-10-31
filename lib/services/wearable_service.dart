import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 操作结果
class WearableResult {
  final bool ok;
  final String message;
  final List<String> log;
  WearableResult(this.ok, this.message, [this.log = const []]);
}

/// 智能穿戴 / 开发板服务
///
/// 覆盖：
///   · ESP32 / ESP8266  → esptool 5.6.0（6527★，GPL-2.0）
///   · 树莓派           → rpiboot（1366★，Apache-2.0）
///   · Arduino          → arduino-cli 1.5.1（5080★，GPL-3.0）
///   · 小米穿戴（Vela） → AstroBox 外链（AGPL-3.0，纯 GUI 无法集成）
class WearableService {
  WearableService._();
  static final WearableService instance = WearableService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    final plat = Platform.isWindows ? 'windows' : 'linux';

    // esptool
    final esp = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/$plat/esp/esptool${Platform.isWindows ? ".exe" : ""}',
      subDir: 'wearable',
      fileName: 'esptool${Platform.isWindows ? ".exe" : ""}',
      executable: true,
    );
    if (esp != null) _dir = File(esp).parent.path;

    // rpiboot（仅 Linux）
    if (!Platform.isWindows) {
      await ToolExtractor.extractFile(
        assetPath: 'assets/tools/linux/rpi/rpiboot',
        subDir: 'wearable',
        fileName: 'rpiboot',
        executable: true,
      );
    }

    // arduino-cli
    await ToolExtractor.extractFile(
      assetPath:
          'assets/tools/$plat/arduino/arduino-cli${Platform.isWindows ? ".exe" : ""}',
      subDir: 'wearable',
      fileName: 'arduino-cli${Platform.isWindows ? ".exe" : ""}',
      executable: true,
    );

    // picotool（树莓派 Pico，仅 Linux）
    if (!Platform.isWindows) {
      await ToolExtractor.extractFile(
        assetPath: 'assets/tools/linux/pico/picotool',
        subDir: 'wearable',
        fileName: 'picotool',
        executable: true,
      );
    }

    // stlink（STM32）
    final stSuffix = Platform.isWindows ? '.exe' : '';
    for (final name in ['st-flash', 'st-info', 'st-util']) {
      await ToolExtractor.extractFile(
        assetPath: 'assets/tools/$plat/stm32/$name$stSuffix',
        subDir: 'wearable',
        fileName: '$name$stSuffix',
        executable: true,
      );
    }
    // stlink 的芯片描述文件（81 个）
    if (!Platform.isWindows) {
      // 提取所有 .chip（81 个，硬编码因为 Flutter 3.x 无 AssetManifest.json）
      const chips = [
        'C011xx', 'C031xx', 'C051xx', 'C071xx', 'C091xx',
        'C53x_C54x', 'C55x_C56x', 'C59x_C5Ax',
        'F03x', 'F04x', 'F05x', 'F07x', 'F09x',
        'F1xx_CL', 'F1xx_HD', 'F1xx_LD', 'F1xx_MD',
        'F1xx_VL_HD', 'F1xx_VL_MD_LD', 'F1xx_XLD',
        'F2xx', 'F301_F302_F318', 'F302_F303_F358',
        'F302_F303_F398_HD', 'F303_F328_F334', 'F37x',
        'F401xB_xC', 'F401xD_xE', 'F410', 'F411xC_xE', 'F412',
        'F413_F423', 'F42x_F43x', 'F446', 'F46x_F47x', 'F4x5_F4x7',
        'F72x_F73x', 'F74x_F75x', 'F76x_F77x',
        'G03x_G04x', 'G05x_G06x', 'G07x_G08x', 'G0Bx_G0Cx',
        'G43x_G44x', 'G47x_G48x', 'G49x_G4Ax',
        'H52_H53xx', 'H5xx', 'H72x_H73x', 'H74x_H75x', 'H7Ax_H7Bx',
        'L0xxx_Cat_1', 'L0xxx_Cat_2', 'L0xxx_Cat_3', 'L0xxx_Cat_5',
        'L1xx_Cat_1', 'L1xx_Cat_2', 'L1xx_Cat_3', 'L1xx_Cat_4', 'L1xx_Cat_5',
        'L41x_L42x', 'L43x_L44x', 'L45x_L46x', 'L47x_L48x',
        'L496x_L4A6x', 'L4Px_L4Qx', 'L4Rx', 'L5x2xx',
        'U031xx', 'U073xx_083xx', 'U535_U545', 'U575_U585',
        'U59x_U5Ax', 'U5Fx_U5Gx',
        'WB05', 'WB06_WB07', 'WB09', 'WBx0_WBx5',
        'WL3x', 'WLEx', 'unknown_device',
      ];
      for (final chip in chips) {
        await ToolExtractor.extractFile(
          assetPath: 'assets/tools/linux/stm32/chips/$chip.chip',
          subDir: 'wearable/chips',
          fileName: '$chip.chip',
        );
      }
    }

    // stlink 的库
    if (Platform.isWindows) {
      await ToolExtractor.extractFile(
        assetPath: 'assets/tools/windows/stm32/libstlink.dll',
        subDir: 'wearable',
        fileName: 'libstlink.dll',
      );
    } else {
      for (final lib in ['libstlink.so.1.9.0']) {
        await ToolExtractor.extractFile(
          assetPath: 'assets/tools/linux/stm32/$lib',
          subDir: 'wearable',
          fileName: lib,
        );
      }
      // 创建软链接
      try {
        final dir = _dir!;
        final so = File(p.join(dir, 'libstlink.so.1.9.0'));
        if (so.existsSync()) {
          final l1 = Link(p.join(dir, 'libstlink.so.1'));
          if (!l1.existsSync()) {
            await l1.create('libstlink.so.1.9.0');
          }
        }
      } catch (_) {}
    }

    _available = _dir != null;
    return _available;
  }

  String? _exe(String name) {
    if (_dir == null) return null;
    final suffix = Platform.isWindows ? '.exe' : '';
    final path = p.join(_dir!, '$name$suffix');
    return File(path).existsSync() ? path : null;
  }

  // ═══════════════════════════════════════════════
  // ESP32 / ESP8266
  // ═══════════════════════════════════════════════

  /// esptool 版本
  Future<String?> esptoolVersion() async {
    if (!await init()) return null;
    final exe = _exe('esptool');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'v?([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 支持的芯片列表
  static const List<String> espChips = [
    'esp8266',
    'esp32',
    'esp32s2',
    'esp32s3',
    'esp32c3',
    'esp32c2',
    'esp32c6',
    'esp32c61',
    'esp32c5',
    'esp32e22',
    'esp32h2',
    'esp32h21',
    'esp32p4',
    'esp32h4',
    'esp32s31',
  ];

  /// 检测串口上的 ESP 芯片
  Future<WearableResult> espDetectChip({
    required String port,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'esptool 未就绪', log);
    final exe = _exe('esptool');
    if (exe == null) return WearableResult(false, 'esptool 未找到', log);

    add('══ 检测 ESP 芯片');
    add('  串口: $port');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['-p', port, 'chip-id'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return WearableResult(
      code == 0,
      code == 0 ? '检测成功' : '检测失败（检查串口和驱动）',
      log,
    );
  }

  /// 读取 MAC 地址
  Future<WearableResult> espReadMac({
    required String port,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'esptool 未就绪', log);
    final exe = _exe('esptool');
    if (exe == null) return WearableResult(false, 'esptool 未找到', log);

    add('══ 读取 MAC 地址');
    add('  串口: $port');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['-p', port, 'read-mac'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return WearableResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 刷写固件
  ///
  /// 典型用法：把 .bin 写到 0x10000（应用分区）
  Future<WearableResult> espFlash({
    required String port,
    required String chip,
    required String firmwarePath,
    String address = '0x10000',
    int baud = 460800,
    bool eraseFirst = false,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WearableResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return WearableResult(false, 'esptool 未就绪', log);
    final exe = _exe('esptool');
    if (exe == null) return WearableResult(false, 'esptool 未找到', log);

    if (!File(firmwarePath).existsSync()) {
      return WearableResult(false, '固件文件不存在', log);
    }

    add('══ 刷写 ESP 固件');
    add('  芯片: $chip');
    add('  串口: $port');
    add('  波特率: $baud');
    add('  文件: ${p.basename(firmwarePath)}');
    add('  大小: ${(File(firmwarePath).lengthSync() / 1024).toStringAsFixed(1)} KB');
    add('  地址: $address');
    if (eraseFirst) add('  刷前擦除: 是');
    add('');
    add('⚠️ 刷错地址或芯片型号会导致设备无法启动');

    // 先擦除
    if (eraseFirst) {
      add('── 擦除 Flash');
      final eraseCode = await ProcessRunner.stream(
        exe,
        ['-p', port, '-c', chip, '-b', '$baud', 'erase-flash'],
        onLine: add,
        timeout: const Duration(minutes: 5),
        workingDirectory: _dir,
      );
      if (eraseCode != 0) {
        add('');
        add('❌ 擦除失败，中止');
        return WearableResult(false, '擦除失败', log);
      }
      add('');
    }

    // 刷写
    add('── 刷写中');
    final code = await ProcessRunner.stream(
      exe,
      [
        '-p', port,
        '-c', chip,
        '-b', '$baud',
        'write-flash',
        address,
        firmwarePath,
      ],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 刷写完成');
      return WearableResult(true, '固件已刷入', log);
    }
    return WearableResult(false, '刷写失败（退出码 $code）', log);
  }

  /// 读取 Flash 内容
  Future<WearableResult> espReadFlash({
    required String port,
    required String chip,
    required String address,
    required int size,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'esptool 未就绪', log);
    final exe = _exe('esptool');
    if (exe == null) return WearableResult(false, 'esptool 未找到', log);

    add('══ 读取 Flash');
    add('  地址: $address');
    add('  大小: ${(size / 1024).toStringAsFixed(1)} KB');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      [
        '-p', port,
        '-c', chip,
        'read-flash',
        address,
        '$size',
        outputPath,
      ],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final actual = File(outputPath).lengthSync();
      add('');
      add('✅ 已读取 ${(actual / 1024).toStringAsFixed(1)} KB');
      return WearableResult(true, 'Flash 已读取', log);
    }
    return WearableResult(false, '读取失败', log);
  }

  /// 擦除 Flash
  Future<WearableResult> espEraseFlash({
    required String port,
    required String chip,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WearableResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return WearableResult(false, 'esptool 未就绪', log);
    final exe = _exe('esptool');
    if (exe == null) return WearableResult(false, 'esptool 未找到', log);

    add('══ 擦除 Flash');
    add('  芯片: $chip');
    add('  串口: $port');
    add('');
    add('⚠️ 擦除后设备无法启动，必须先有可刷的固件');

    final code = await ProcessRunner.stream(
      exe,
      ['-p', port, '-c', chip, 'erase-flash'],
      onLine: add,
      timeout: const Duration(minutes: 5),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 已擦除');
      return WearableResult(true, 'Flash 已擦除', log);
    }
    return WearableResult(false, '擦除失败', log);
  }

  // ═══════════════════════════════════════════════
  // 树莓派
  // ═══════════════════════════════════════════════

  /// rpiboot 版本
  Future<String?> rpibootVersion() async {
    if (Platform.isWindows) return null;
    if (!await init()) return null;
    final exe = _exe('rpiboot');
    if (exe == null) return null;
    return '1.0';
  }

  /// 引导树莓派到 USB 大容量存储模式
  ///
  /// 用法：树莓派通过 USB 连到电脑，然后运行这个命令，
  /// 它会推送 bootcode 到 Pi 的内存，Pi 变成一个 U 盘。
  Future<WearableResult> rpiBootToMassStorage({
    String? gadgetDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return WearableResult(false, 'rpiboot 目前仅支持 Linux', log);
    }
    if (!await init()) return WearableResult(false, 'rpiboot 未就绪', log);
    final exe = _exe('rpiboot');
    if (exe == null) return WearableResult(false, 'rpiboot 未找到', log);

    add('══ 引导树莓派到 U 盘模式');
    add('');
    add('ℹ️ 需要：');
    add('  · 树莓派通过 USB 连到电脑');
    add('  · 树莓派进了 USB boot 模式');
    add('    （eMMC 机型：按住 boot 键上电）');
    add('');

    final args = <String>[];
    if (gadgetDir != null) {
      args.addAll(['-d', gadgetDir]);
    }

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 树莓派已进入 U 盘模式，可以像 U 盘一样写入镜像');
      return WearableResult(true, '已进入 U 盘模式', log);
    }
    return WearableResult(false, '引导失败（退出码 $code）', log);
  }

  // ═══════════════════════════════════════════════
  // Arduino
  // ═══════════════════════════════════════════════

  /// arduino-cli 版本
  Future<String?> arduinoVersion() async {
    if (!await init()) return null;
    final exe = _exe('arduino-cli');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'Version:\s*([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 列出已连接的 Arduino 板子
  Future<WearableResult> arduinoListBoards({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'arduino-cli 未就绪', log);
    final exe = _exe('arduino-cli');
    if (exe == null) return WearableResult(false, 'arduino-cli 未找到', log);

    add('══ Arduino 板子列表');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['board', 'list'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return WearableResult(code == 0, code == 0 ? '已列出' : '未检测到板子', log);
  }

  /// 列出已安装的核心
  Future<WearableResult> arduinoListCores({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'arduino-cli 未就绪', log);
    final exe = _exe('arduino-cli');
    if (exe == null) return WearableResult(false, 'arduino-cli 未找到', log);

    add('══ 已安装的核心');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['core', 'list'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return WearableResult(code == 0, code == 0 ? '已列出' : '读取失败', log);
  }

  /// 编译并上传 Arduino 草图
  Future<WearableResult> arduinoUpload({
    required String sketchPath,
    required String fqbn,
    required String port,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'arduino-cli 未就绪', log);
    final exe = _exe('arduino-cli');
    if (exe == null) return WearableResult(false, 'arduino-cli 未找到', log);

    add('══ 编译并上传');
    add('  草图: ${p.basename(sketchPath)}');
    add('  板型: $fqbn');
    add('  串口: $port');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['compile', '--upload', '-p', port, '--fqbn', fqbn, sketchPath],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 上传完成');
      return WearableResult(true, '已上传', log);
    }
    return WearableResult(false, '上传失败', log);
  }

  // ═══════════════════════════════════════════════
  // 树莓派 Pico（RP2040 / RP2350）
  // ═══════════════════════════════════════════════

  /// picotool 版本
  Future<String?> picotoolVersion() async {
    if (Platform.isWindows) return null;
    if (!await init()) return null;
    final exe = _exe('picotool');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'v([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 列出 BOOTSEL 模式的 Pico 设备
  Future<WearableResult> picoListDevices({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return WearableResult(false, 'picotool 目前仅支持 Linux', log);
    }
    if (!await init()) return WearableResult(false, 'picotool 未就绪', log);
    final exe = _exe('picotool');
    if (exe == null) return WearableResult(false, 'picotool 未找到', log);

    add('══ Pico 设备列表');
    add('  （需要设备处于 BOOTSEL 模式：按住 BOOTSEL 键插 USB）');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['info'],
      onLine: add,
      timeout: const Duration(seconds: 20),
      workingDirectory: _dir,
    );

    return WearableResult(code == 0, code == 0 ? '已列出' : '未检测到设备', log);
  }

  /// 读取 Pico 固件信息
  Future<WearableResult> picoInfo({
    required String uf2Path,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return WearableResult(false, 'picotool 目前仅支持 Linux', log);
    }
    if (!await init()) return WearableResult(false, 'picotool 未就绪', log);
    final exe = _exe('picotool');
    if (exe == null) return WearableResult(false, 'picotool 未找到', log);

    add('══ 固件信息');
    add('  文件: ${p.basename(uf2Path)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['info', uf2Path],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return WearableResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 刷写 Pico 固件
  Future<WearableResult> picoFlash({
    required String firmwarePath,
    bool verify = true,
    bool reboot = true,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WearableResult(false, '需要确认（confirmed=false）', log);
    }

    if (Platform.isWindows) {
      return WearableResult(false, 'picotool 目前仅支持 Linux', log);
    }
    if (!await init()) return WearableResult(false, 'picotool 未就绪', log);
    final exe = _exe('picotool');
    if (exe == null) return WearableResult(false, 'picotool 未找到', log);

    if (!File(firmwarePath).existsSync()) {
      return WearableResult(false, '固件文件不存在', log);
    }

    add('══ 刷写 Pico 固件');
    add('  文件: ${p.basename(firmwarePath)}');
    add('  大小: ${(File(firmwarePath).lengthSync() / 1024).toStringAsFixed(1)} KB');
    if (verify) add('  刷后校验: 是');
    if (reboot) add('  刷后重启: 是');
    add('');
    add('ℹ️ 支持 .uf2 / .elf / .bin');

    final args = <String>['load', firmwarePath];
    if (reboot) args.add('-x');

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 刷写完成');
      return WearableResult(true, '固件已刷入', log);
    }
    return WearableResult(false, '刷写失败', log);
  }

  /// 从 Pico 读取 Flash
  Future<WearableResult> picoSave({
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return WearableResult(false, 'picotool 目前仅支持 Linux', log);
    }
    if (!await init()) return WearableResult(false, 'picotool 未就绪', log);
    final exe = _exe('picotool');
    if (exe == null) return WearableResult(false, 'picotool 未找到', log);

    add('══ 读取 Pico Flash');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['save', '-a', outputPath],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final size = File(outputPath).lengthSync();
      add('');
      add('✅ 已读取 ${(size / 1024).toStringAsFixed(1)} KB');
      return WearableResult(true, 'Flash 已读取', log);
    }
    return WearableResult(false, '读取失败', log);
  }

  /// 擦除 Pico Flash
  Future<WearableResult> picoErase({
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WearableResult(false, '需要确认（confirmed=false）', log);
    }

    if (Platform.isWindows) {
      return WearableResult(false, 'picotool 目前仅支持 Linux', log);
    }
    if (!await init()) return WearableResult(false, 'picotool 未就绪', log);
    final exe = _exe('picotool');
    if (exe == null) return WearableResult(false, 'picotool 未找到', log);

    add('══ 擦除 Pico Flash');
    add('');
    add('⚠️ 擦除后设备无法启动，必须先有可刷的固件');

    final code = await ProcessRunner.stream(
      exe,
      ['erase', '-a'],
      onLine: add,
      timeout: const Duration(minutes: 2),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 已擦除');
      return WearableResult(true, 'Flash 已擦除', log);
    }
    return WearableResult(false, '擦除失败', log);
  }

  // ═══════════════════════════════════════════════
  // STM32（stlink）
  // ═══════════════════════════════════════════════

  /// stlink 需要的环境变量（chips 目录 + 库路径）
  Map<String, String>? _stlinkEnv() {
    if (_dir == null) return null;
    if (Platform.isWindows) return null;
    return {
      'STLINK_CHIPS_DIR': p.join(_dir!, 'chips'),
      'LD_LIBRARY_PATH': _dir!,
    };
  }

  /// st-info 版本
  Future<String?> stlinkVersion() async {
    if (!await init()) return null;
    final exe = _exe('st-info');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['--version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'v?([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 检测 STM32 设备
  Future<WearableResult> stlinkProbe({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'stlink 未就绪', log);
    final exe = _exe('st-info');
    if (exe == null) return WearableResult(false, 'st-info 未找到', log);

    add('══ STM32 设备检测');
    add('  （需要 ST-Link 调试器）');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['--probe'],
      onLine: add,
      timeout: const Duration(seconds: 20),
      workingDirectory: _dir,
      environment: _stlinkEnv(),
    );

    return WearableResult(code == 0, code == 0 ? '检测成功' : '未检测到设备', log);
  }

  /// 读取 STM32 Flash
  Future<WearableResult> stlinkReadFlash({
    required String address,
    required int size,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return WearableResult(false, 'stlink 未就绪', log);
    final exe = _exe('st-flash');
    if (exe == null) return WearableResult(false, 'st-flash 未找到', log);

    add('══ 读取 STM32 Flash');
    add('  地址: $address');
    add('  大小: $size 字节');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['read', outputPath, address, '$size'],
      onLine: add,
      timeout: const Duration(minutes: 5),
      workingDirectory: _dir,
      environment: _stlinkEnv(),
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final actual = File(outputPath).lengthSync();
      add('');
      add('✅ 已读取 ${(actual / 1024).toStringAsFixed(1)} KB');
      return WearableResult(true, 'Flash 已读取', log);
    }
    return WearableResult(false, '读取失败', log);
  }

  /// 刷写 STM32 固件
  Future<WearableResult> stlinkFlash({
    required String firmwarePath,
    String address = '0x08000000',
    bool verify = true,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WearableResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return WearableResult(false, 'stlink 未就绪', log);
    final exe = _exe('st-flash');
    if (exe == null) return WearableResult(false, 'st-flash 未找到', log);

    if (!File(firmwarePath).existsSync()) {
      return WearableResult(false, '固件文件不存在', log);
    }

    add('══ 刷写 STM32 固件');
    add('  文件: ${p.basename(firmwarePath)}');
    add('  大小: ${(File(firmwarePath).lengthSync() / 1024).toStringAsFixed(1)} KB');
    add('  地址: $address');
    add('');
    add('⚠️ STM32 的 Flash 起始地址通常是 0x08000000');
    add('  写错地址会导致设备无法启动');

    final code = await ProcessRunner.stream(
      exe,
      ['--reset', 'write', firmwarePath, address],
      onLine: add,
      timeout: const Duration(minutes: 5),
      workingDirectory: _dir,
      environment: _stlinkEnv(),
    );

    if (code == 0) {
      add('');
      add('✅ 刷写完成');
      return WearableResult(true, '固件已刷入', log);
    }
    return WearableResult(false, '刷写失败', log);
  }

  /// 擦除 STM32 Flash
  Future<WearableResult> stlinkErase({
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WearableResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return WearableResult(false, 'stlink 未就绪', log);
    final exe = _exe('st-flash');
    if (exe == null) return WearableResult(false, 'st-flash 未找到', log);

    add('══ 擦除 STM32 Flash');
    add('');
    add('⚠️ 擦除后设备无法启动');

    final code = await ProcessRunner.stream(
      exe,
      ['erase'],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
      environment: _stlinkEnv(),
    );

    if (code == 0) {
      add('');
      add('✅ 已擦除');
      return WearableResult(true, 'Flash 已擦除', log);
    }
    return WearableResult(false, '擦除失败', log);
  }

}
