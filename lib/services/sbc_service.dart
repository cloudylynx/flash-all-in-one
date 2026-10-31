import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 单板电脑操作结果
class SbcResult {
  final bool ok;
  final String message;
  final List<String> log;
  SbcResult(this.ok, this.message, [this.log = const []]);
}

/// 单板电脑（SBC）固件刷写服务
///
/// 覆盖：
///   · Rockchip（瑞芯微）：RK3399 / RK3588 / RK3568 等
///     工具：rkdeveloptool 1.32（464★，GPL-2.0，1.31 MB）
///   · Allwinner（全志）：H3 / H6 / A64 / T507 等
///     工具：sunxi-tools（688★，GPL-2.0，sunxi-fel 0.08 MB）
///
/// 两者都通过 USB OTG 的 BROM/Maskrom 模式救砖，
/// 和安卓的 EDL/9008 是同一类思路。
class SbcService {
  SbcService._();
  static final SbcService instance = SbcService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    final plat = Platform.isWindows ? 'windows' : 'linux';

    // rkdeveloptool
    final rkSuffix = Platform.isWindows ? '.exe' : '';
    final rk = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/$plat/rockchip/rkdeveloptool$rkSuffix',
      subDir: 'sbc',
      fileName: 'rkdeveloptool$rkSuffix',
      executable: true,
    );
    if (rk != null) _dir = File(rk).parent.path;

    // Windows 需要 libusb
    if (Platform.isWindows && _dir != null) {
      for (final dll in ['libusb-1.0.dll']) {
        await ToolExtractor.extractFile(
          assetPath: 'assets/tools/windows/rockchip/$dll',
          subDir: 'sbc',
          fileName: dll,
        );
      }
    }

    // sunxi-tools（只有 Linux 版）
    if (!Platform.isWindows) {
      for (final name in [
        'sunxi-fel',
        'sunxi-fexc',
        'sunxi-bootinfo',
        'sunxi-nand-part',
        'sunxi-pio',
      ]) {
        await ToolExtractor.extractFile(
          assetPath: 'assets/tools/linux/allwinner/$name',
          subDir: 'sbc',
          fileName: name,
          executable: true,
        );
      }
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

  /// rkdeveloptool 版本
  Future<String?> rkVersion() async {
    if (!await init()) return null;
    final exe = _exe('rkdeveloptool');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['-v'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'ver\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 是否支持全志
  bool get hasAllwinner => !Platform.isWindows;

  // ═══════════════════════════════════════════════════
  // Rockchip（瑞芯微）
  // ═══════════════════════════════════════════════════

  /// 列出 Rockchip 设备（Loader 或 Maskrom 模式）
  Future<SbcResult> rkListDevices({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ Rockchip 设备列表');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['ld'],
      onLine: add,
      timeout: const Duration(seconds: 15),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已列出' : '未检测到设备', log);
  }

  /// 下载并运行 Loader（Maskrom → Loader 模式）
  ///
  /// 这是 Rockchip 救砖的第一步：Maskrom 模式下设备只认 Loader。
  Future<SbcResult> rkDownloadLoader({
    required String loaderPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    if (!File(loaderPath).existsSync()) {
      return SbcResult(false, 'Loader 文件不存在: $loaderPath', log);
    }

    add('══ 下载 Loader');
    add('  文件: ${p.basename(loaderPath)}');
    add('  大小: ${(File(loaderPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');
    add('ℹ️ Maskrom 模式必须先用 Loader 引导');

    final code = await ProcessRunner.stream(
      exe,
      ['db', loaderPath],
      onLine: add,
      timeout: const Duration(minutes: 2),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ Loader 已运行，设备进入 Loader 模式');
      return SbcResult(true, 'Loader 已加载', log);
    }
    return SbcResult(false, 'Loader 加载失败', log);
  }

  /// 打印分区表
  Future<SbcResult> rkPrintPartitions({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ Rockchip 分区表');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['ppt'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 读取 Flash 信息（芯片型号、容量）
  Future<SbcResult> rkFlashInfo({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ Flash 信息');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['rfi'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 读取芯片信息
  Future<SbcResult> rkChipInfo({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ 芯片信息');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['rci'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 写入镜像到指定 LBA
  Future<SbcResult> rkWriteLba({
    required int beginSector,
    required String imagePath,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return SbcResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ 写入 LBA');
    add('  起始扇区: $beginSector');
    add('  镜像: ${p.basename(imagePath)}');
    add('  大小: ${(File(imagePath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');
    add('⚠️ 写错扇区会导致设备无法启动');

    final code = await ProcessRunner.stream(
      exe,
      ['wl', '$beginSector', imagePath],
      onLine: add,
      timeout: const Duration(minutes: 30),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 写入完成');
      return SbcResult(true, '已写入', log);
    }
    return SbcResult(false, '写入失败', log);
  }

  /// 写 GPT 分区表
  Future<SbcResult> rkWriteGpt({
    required String gptPath,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return SbcResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ 写入 GPT');
    add('  文件: ${p.basename(gptPath)}');
    add('');
    add('⚠️ GPT 写错会导致所有分区丢失');

    final code = await ProcessRunner.stream(
      exe,
      ['gpt', gptPath],
      onLine: add,
      timeout: const Duration(minutes: 5),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ GPT 已写入');
      return SbcResult(true, 'GPT 已写入', log);
    }
    return SbcResult(false, '写入失败', log);
  }

  /// 切换存储类型（eMMC / SD / SPI-NOR）
  Future<SbcResult> rkChangeStorage({
    required int storage, // 1=eMMC, 2=SD, 9=SPI-NOR
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    const names = {1: 'eMMC', 2: 'SD', 9: 'SPI-NOR'};
    add('══ 切换存储: ${names[storage] ?? storage}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['cs', '$storage'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已切换' : '切换失败', log);
  }

  /// 重启设备
  Future<SbcResult> rkReset({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('rkdeveloptool');
    if (exe == null) return SbcResult(false, 'rkdeveloptool 未找到', log);

    add('══ 重启设备');

    final code = await ProcessRunner.stream(
      exe,
      ['rd'],
      onLine: add,
      timeout: const Duration(seconds: 15),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已重启' : '重启失败', log);
  }

  // ═══════════════════════════════════════════════════
  // Allwinner（全志）— 仅 Linux
  // ═══════════════════════════════════════════════════

  /// 列出全志 FEL 设备
  Future<SbcResult> sunxiListDevices({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return SbcResult(false, '全志工具目前仅支持 Linux', log);
    }
    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('sunxi-fel');
    if (exe == null) return SbcResult(false, 'sunxi-fel 未找到', log);

    add('══ 全志 FEL 设备列表');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['-l'],
      onLine: add,
      timeout: const Duration(seconds: 15),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已列出' : '未检测到设备', log);
  }

  /// 读全志设备 SID（唯一序列号）
  Future<SbcResult> sunxiReadSid({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return SbcResult(false, '全志工具目前仅支持 Linux', log);
    }
    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('sunxi-fel');
    if (exe == null) return SbcResult(false, 'sunxi-fel 未找到', log);

    add('══ 读取 SID');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['sid'],
      onLine: add,
      timeout: const Duration(seconds: 15),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 引导 U-Boot（全志救砖核心操作）
  ///
  /// 对应 sunxi-fel uboot <u-boot-sunxi-with-spl.bin>
  Future<SbcResult> sunxiBootUboot({
    required String ubootPath,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return SbcResult(false, '需要确认（confirmed=false）', log);
    }

    if (Platform.isWindows) {
      return SbcResult(false, '全志工具目前仅支持 Linux', log);
    }
    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('sunxi-fel');
    if (exe == null) return SbcResult(false, 'sunxi-fel 未找到', log);

    if (!File(ubootPath).existsSync()) {
      return SbcResult(false, 'U-Boot 文件不存在', log);
    }

    add('══ 引导 U-Boot');
    add('  文件: ${p.basename(ubootPath)}');
    add('  大小: ${(File(ubootPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');
    add('ℹ️ 这是全志救砖的核心操作');
    add('  FEL 模式下从内存引导 U-Boot，不写 Flash');

    final code = await ProcessRunner.stream(
      exe,
      ['uboot', ubootPath],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ U-Boot 已引导');
      return SbcResult(true, 'U-Boot 已引导', log);
    }
    return SbcResult(false, '引导失败', log);
  }

  /// 读 SPI Flash 信息
  Future<SbcResult> sunxiSpiInfo({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return SbcResult(false, '全志工具目前仅支持 Linux', log);
    }
    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('sunxi-fel');
    if (exe == null) return SbcResult(false, 'sunxi-fel 未找到', log);

    add('══ SPI Flash 信息');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['spiflash-info'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    return SbcResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 读内存到文件（调试用）
  Future<SbcResult> sunxiReadMemory({
    required String address,
    required int length,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return SbcResult(false, '全志工具目前仅支持 Linux', log);
    }
    if (!await init()) return SbcResult(false, '工具未就绪', log);
    final exe = _exe('sunxi-fel');
    if (exe == null) return SbcResult(false, 'sunxi-fel 未找到', log);

    add('══ 读内存');
    add('  地址: $address');
    add('  长度: $length 字节');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['dump', address, '$length', outputPath],
      onLine: add,
      timeout: const Duration(minutes: 2),
      workingDirectory: _dir,
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final size = File(outputPath).lengthSync();
      add('');
      add('✅ 已读取 ${(size / 1024).toStringAsFixed(1)} KB');
      return SbcResult(true, '内存已读取', log);
    }
    return SbcResult(false, '读取失败', log);
  }
}
