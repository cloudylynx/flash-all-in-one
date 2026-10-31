import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 紫光展锐操作结果
class SprdResult {
  final bool ok;
  final String message;
  final List<String> log;
  SprdResult(this.ok, this.message, [this.log = const []]);
}

/// 紫光展锐（Unisoc/Spreadtrum）服务
///
/// 技术来源：ilyakurdyukov/spreadtrum_flash（232★，**Unlicense 公有领域**）
///
/// 许可证优势：Unlicense 是最宽松的许可证（等同公有领域），
/// 可以自由商用、修改、闭源分发，无任何限制。
///
/// 覆盖设备：
///   · 传音全系（Tecno / Infinix / itel）
///   · 部分三星/诺基亚/摩托罗拉低端机
///   · 其他用展锐 SoC 的设备
///
/// 工具：
///   spd_dump.exe  —— 分区读/写/擦除/重分区
///   unpac.exe     —— PAC 固件解包
///   fphelper.exe  —— 展锐指纹相关（可选）
class SprdService {
  SprdService._();
  static final SprdService instance = SprdService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    // 1. 应用目录
    for (final sub in ['tools/sprd', 'tools']) {
      final d = p.join(AppConfig.exeDir, sub);
      final exe = p.join(d, Platform.isWindows ? 'spd_dump.exe' : 'spd_dump');
      if (File(exe).existsSync()) {
        _dir = d;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'sprd'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      const files = [
        'spd_dump.exe',
        'unpac.exe',
        'fphelper.exe',
        'fphelper_t117.exe',
        'libusb-1.0.dll',
      ];

      var extracted = 0;
      for (final f in files) {
        try {
          final target = File(p.join(dir.path, f));
          if (!target.existsSync()) {
            final data = await rootBundle.load('assets/tools/windows/sprd/$f');
            await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
          }
          extracted++;
        } catch (_) {}
      }

      if (extracted > 0) {
        _dir = dir.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  String? _exe(String name) {
    if (_dir == null) return null;
    final f = File(p.join(_dir!, '$name.exe'));
    return f.existsSync() ? f.path : null;
  }

  /// 解包 PAC 固件
  ///
  /// 用法：unpac PAC文件 输出目录
  Future<SprdResult> unpackPac({
    required String pacPath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('unpac');
    if (exe == null) {
      return SprdResult(false, 'unpac.exe 未找到', log);
    }

    if (!File(pacPath).existsSync()) {
      return SprdResult(false, 'PAC 文件不存在', log);
    }

    Directory(outputDir).createSync(recursive: true);

    add('══ PAC 解包');
    add('  固件: ${p.basename(pacPath)}');
    add('  输出: $outputDir');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      [pacPath, outputDir],
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      var count = 0;
      var totalSize = 0;
      try {
        final files =
            Directory(outputDir).listSync().whereType<File>().toList();
        count = files.length;
        for (final f in files) {
          totalSize += f.lengthSync();
        }
      } catch (_) {}

      add('');
      add('✅ 解包完成: $count 个文件，共 ${(totalSize / 1024 / 1024).toStringAsFixed(1)} MB');
      return SprdResult(true, '解包完成（$count 个文件）', log);
    }
    return SprdResult(false, '解包失败（退出码 $code）', log);
  }

  /// 读取分区
  ///
  /// 用法：spd_dump fdl fdl1.bin 0x5500 fdl fdl2.bin 0x9efffe00 read_part 分区名 0 大小
  Future<SprdResult> readPartition({
    required String fdl1Path,
    required String fdl2Path,
    required String partition,
    required String outputPath,
    String size = '8M',
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 读取分区: $partition');
    add('  大小: $size');
    add('  输出: $outputPath');
    add('');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'read_part', partition, '0', size,
      outputPath,
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('');
      add('✅ 读取完成');
      return SprdResult(true, '已读取 $partition', log);
    }
    return SprdResult(false, '读取失败（退出码 $code）', log);
  }

  /// 写入分区
  Future<SprdResult> writePartition({
    required String fdl1Path,
    required String fdl2Path,
    required String partition,
    required String imagePath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 写入分区: $partition');
    add('  镜像: ${p.basename(imagePath)}');
    add('  ⚠️ 写入有变砖风险');
    add('');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'write_part', partition, imagePath,
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 20),
    );

    if (code == 0) {
      add('');
      add('✅ 写入完成');
      return SprdResult(true, '已写入 $partition', log);
    }
    return SprdResult(false, '写入失败（退出码 $code）', log);
  }

  /// 擦除分区
  Future<SprdResult> erasePartition({
    required String fdl1Path,
    required String fdl2Path,
    required String partition,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 擦除分区: $partition');
    add('  ⚠️ 不可恢复');
    add('');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'erase_part', partition,
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 5),
    );

    if (code == 0) {
      add('✅ 擦除完成');
      return SprdResult(true, '已擦除 $partition', log);
    }
    return SprdResult(false, '擦除失败（退出码 $code）', log);
  }

  /// 关机（退出展锐模式）
  Future<SprdResult> powerOff({
    required String fdl1Path,
    required String fdl2Path,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 发送关机命令');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'power_off',
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 2),
    );

    return SprdResult(code == 0, code == 0 ? '已关机' : '关机失败', log);
  }

  /// 帮助信息

  // ═══════════════════════════════════════════════════════
  // 以下功能借鉴 C-Hidery/sfd_tool 的命令设计
  // （GPL-3.0，仅借鉴命令流程与安全设计，不复制其代码）
  // ═══════════════════════════════════════════════════════

  /// 读取设备分区表
  ///
  /// 对应 sfd_tool 的 `part_table` / `cptable`
  Future<SprdResult> readPartitionTable({
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SprdResult(false, '展锐工具未就绪', log);
    final exe = _exe('spd_dump');
    if (exe == null) return SprdResult(false, 'spd_dump 未找到', log);

    add('══ 读取分区表');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['exec', 'fdl', 'partition_list', outputPath],
      onLine: add,
      timeout: const Duration(minutes: 2),
      workingDirectory: _dir,
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final size = File(outputPath).lengthSync();
      add('');
      add('✅ 分区表已保存: ${(size / 1024).toStringAsFixed(1)} KB');
      return SprdResult(true, '分区表已读取', log);
    }
    return SprdResult(false, '读取失败（退出码 $code）', log);
  }

  /// 读取设备信息（芯片型号、Flash 类型、UID）
  ///
  /// 对应 BSL 命令：
  ///   0x07 READ_CHIP_TYPE
  ///   0x0C READ_FLASH_TYPE
  ///   0x15 READ_FLASH_UID
  ///   0x1A READ_CHIP_UID
  ///   0x43 EMMC_CID
  Future<SprdResult> readDeviceInfo({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SprdResult(false, '展锐工具未就绪', log);
    final exe = _exe('spd_dump');
    if (exe == null) return SprdResult(false, 'spd_dump 未找到', log);

    add('══ 读取设备信息');
    add('  （BSL 0x07 / 0x0C / 0x15 / 0x1A / 0x43）');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['exec', 'fdl', 'chip_info'],
      onLine: add,
      timeout: const Duration(minutes: 2),
      workingDirectory: _dir,
    );

    return SprdResult(code == 0, code == 0 ? '设备信息已读取' : '读取失败', log);
  }

  /// 安全关闭 AVB 与 dm-verity
  ///
  /// 借鉴 sfd_tool 的 `dis_avb_tos` 设计：
  ///   **先自动备份 trustos 分区，再执行关闭**
  ///
  /// 这是关键的安全设计——sfd_tool 的 README 明确写了
  /// 「SFD Tool will automatically backup your trustos partition」。
  ///
  /// ⚠️ 警告（来自 sfd_tool README）：
  ///   关闭后设备将失去系统完整性保护：
  ///   · 银行 App / Google Pay 无法使用
  ///   · 微信/支付宝支付可能失败
  ///   · Netflix HD 等 DRM 内容无法播放
  ///   · 反作弊游戏（原神/PUBG）可能拒绝运行
  ///   · 恶意软件可以随意修改系统
  Future<SprdResult> disableAvbSafely({
    required String backupDir,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return SprdResult(false, '需要用户确认（confirmed=false）', log);
    }

    if (!await init()) return SprdResult(false, '展锐工具未就绪', log);
    final exe = _exe('spd_dump');
    if (exe == null) return SprdResult(false, 'spd_dump 未找到', log);

    add('══ 关闭 AVB / dm-verity');
    add('');
    add('⚠️ 此操作会降低设备安全性：');
    add('  · 银行 App / Google Pay 无法使用');
    add('  · 微信/支付宝支付可能失败');
    add('  · Netflix HD 等 DRM 内容无法播放');
    add('  · 反作弊游戏（原神/PUBG）可能拒绝运行');
    add('  · 恶意软件可随意修改系统');
    add('');
    add('── 第 1 步：备份 trustos 分区');
    add('  ⚠️ 这是安全设计——sfd_tool 的 dis_avb_tos 也会自动备份');

    Directory(backupDir).createSync(recursive: true);
    final trustosBackup = p.join(backupDir, 'trustos_backup.img');

    var code = await ProcessRunner.stream(
      exe,
      ['exec', 'fdl', 'r', 'trustos', trustosBackup],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
    );

    if (code != 0 || !File(trustosBackup).existsSync()) {
      add('');
      add('❌ trustos 备份失败，中止操作');
      add('  （备份失败时绝不能继续——这是最后一道防线）');
      return SprdResult(false, 'trustos 备份失败，已中止', log);
    }

    final size = File(trustosBackup).lengthSync();
    add('  ✅ 已备份: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    add('  路径: $trustosBackup');
    add('');
    add('── 第 2 步：执行 dis_avb_tos');

    code = await ProcessRunner.stream(
      exe,
      ['exec', 'fdl', 'dis_avb_tos'],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ AVB / dm-verity 已关闭');
      add('');
      add('📌 恢复方法：');
      add('  刷回 $trustosBackup 到 trustos 分区');
      return SprdResult(true, 'AVB 已关闭（trustos 已备份）', log);
    }

    add('');
    add('❌ 关闭失败，但 trustos 备份仍在: $trustosBackup');
    return SprdResult(false, '关闭失败', log);
  }

  /// 批量恢复分区（从文件夹）
  ///
  /// 借鉴 sfd_tool 的「Restore from folder」功能：
  ///   目录里放多个 <分区名>.img，一次性全部刷入。
  ///
  /// 安全设计：先扫描并列出所有将刷入的分区，确认后才执行。
  Future<SprdResult> restoreFromFolder({
    required String imageDir,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return SprdResult(false, '展锐工具未就绪', log);
    final exe = _exe('spd_dump');
    if (exe == null) return SprdResult(false, 'spd_dump 未找到', log);

    final dir = Directory(imageDir);
    if (!dir.existsSync()) {
      return SprdResult(false, '目录不存在: $imageDir', log);
    }

    // 扫描 .img 文件
    final images = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.img'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (images.isEmpty) {
      return SprdResult(false, '目录里没有 .img 文件', log);
    }

    add('══ 批量恢复分区');
    add('  目录: $imageDir');
    add('  找到 ${images.length} 个镜像:');
    var totalBytes = 0;
    for (final img in images) {
      final name = p.basenameWithoutExtension(img.path);
      final size = img.lengthSync();
      totalBytes += size;
      add('    $name  ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    }
    add('  总计: ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');

    if (!confirmed) {
      add('⚠️ 需要确认后才执行（confirmed=false）');
      add('');
      add('请核对上面的分区列表，确认无误后重新调用并传 confirmed=true');
      return SprdResult(false, '需要确认（已列出 ${images.length} 个分区）', log);
    }

    add('── 开始刷入');
    add('');

    var ok = 0;
    for (final img in images) {
      final name = p.basenameWithoutExtension(img.path);
      add('[$name] 刷入中…');

      final code = await ProcessRunner.stream(
        exe,
        ['exec', 'fdl', 'w', name, img.path],
        onLine: (line) {
          // 只显示错误行，避免刷屏
          if (line.contains('error') ||
              line.contains('Error') ||
              line.contains('fail')) {
            add('  $line');
          }
        },
        timeout: const Duration(minutes: 10),
        workingDirectory: _dir,
      );

      if (code == 0) {
        add('[$name] ✅');
        ok++;
      } else {
        add('[$name] ❌ 失败（退出码 $code）');
        add('');
        add('⚠️ 中止后续刷入，避免状态不一致');
        return SprdResult(false, '$ok/${images.length} 成功，$name 失败', log);
      }
    }

    add('');
    add('✅ 全部完成: $ok/${images.length} 个分区');
    return SprdResult(true, '$ok 个分区已恢复', log);
  }

  /// 读取内存（用于调试，需扩展 loader）
  ///
  /// 对应 BSL 0x70 BSL_CMD_E_READ_MEM
  Future<SprdResult> readMemory({
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

    if (!await init()) return SprdResult(false, '展锐工具未就绪', log);
    final exe = _exe('spd_dump');
    if (exe == null) return SprdResult(false, 'spd_dump 未找到', log);

    add('══ 读取内存');
    add('  地址: $address');
    add('  大小: ${(size / 1024).toStringAsFixed(1)} KB');
    add('  输出: ${p.basename(outputPath)}');
    add('');
    add('ℹ️ 需要扩展 loader 支持（BSL 0x70）');

    final code = await ProcessRunner.stream(
      exe,
      ['exec', 'fdl', 'read_mem', address, '$size', outputPath],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final actual = File(outputPath).lengthSync();
      add('');
      add('✅ 已读取 ${(actual / 1024).toStringAsFixed(1)} KB');
      return SprdResult(true, '内存已读取', log);
    }
    return SprdResult(false, '读取失败', log);
  }

  /// BSL 响应码解释
  ///
  /// 从 assets/data/spd_bsl_commands.json 查表
  static Future<String> explainResponse(int code) async {
    try {
      final json = await rootBundle.loadString('assets/data/spd_bsl_commands.json');
      // 简单字符串查找，避免引入 json 解析开销
      final hex = '0x${code.toRadixString(16).toUpperCase().padLeft(2, '0')}';
      final pattern = RegExp('"$hex"\\s*:\\s*\\{[^}]*"name"\\s*:\\s*"([^"]+)"[^}]*"desc"\\s*:\\s*"([^"]+)"');
      final m = pattern.firstMatch(json);
      if (m != null) {
        return '${m.group(1)}（${m.group(2)}）';
      }
      return '未知响应码 $hex';
    } catch (_) {
      return '未知响应码 0x${code.toRadixString(16)}';
    }
  }

  Future<String> help() async {
    if (!await init()) return '未就绪';
    final exe = _exe('spd_dump');
    if (exe == null) return 'spd_dump.exe 未找到';
    final r = await ProcessRunner.run(exe, ['--help'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    return r.output;
  }
}
