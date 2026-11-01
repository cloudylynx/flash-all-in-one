import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 基带备份结果
class ModemResult {
  final bool ok;
  final String message;
  final List<String> log;
  ModemResult(this.ok, this.message, [this.log = const []]);
}

/// 基带分区信息
class ModemPartition {
  final String name;
  final String path;
  final int? sizeBytes;
  final String description;

  ModemPartition({
    required this.name,
    required this.path,
    this.sizeBytes,
    required this.description,
  });

  String get sizeText {
    if (sizeBytes == null) return '?';
    if (sizeBytes! > 1024 * 1024 * 1024) {
      return '${(sizeBytes! / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (sizeBytes! > 1024 * 1024) {
      return '${(sizeBytes! / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes! / 1024).toStringAsFixed(0)} KB';
  }
}

/// 基带备份服务
///
/// 基带（modem）刷丢了会没信号、IMEI 归零，比变砖还麻烦。
/// 刷机前必须备份。
///
/// 各平台基带分区：
///   高通: modem / modemst1 / modemst2 / fsg / fsc / persist / bluetooth
///   MTK:  nvram / nvdata / protect1 / protect2 / md1img / md1dsp
///   三星: modem / efs / persist
class ModemBackupService {
  ModemBackupService._();
  static final ModemBackupService instance = ModemBackupService._();

  String? _toolsDir;
  bool _available = false;

  bool get isAvailable => _available;

  Future<bool> init() async {
    if (_available) return true;
    final path = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/android/multiboot/busybox',
      subDir: 'multiboot',
      fileName: 'busybox',
      executable: true,
    );
    if (path == null) return false;
    _toolsDir = File(path).parent.path;
    _available = true;
    return true;
  }

  /// 所有可能的基带分区（按平台）
  static const Map<String, List<Map<String, String>>> partitionsByVendor = {
    'qualcomm': [
      {'name': 'modem', 'desc': '基带固件主体'},
      {'name': 'modemst1', 'desc': '基带状态 1'},
      {'name': 'modemst2', 'desc': '基带状态 2'},
      {'name': 'fsg', 'desc': '文件系统黄金副本（IMEI 备份）'},
      {'name': 'fsc', 'desc': '文件系统副本'},
      {'name': 'persist', 'desc': '持久化（传感器校准 + IMEI）'},
      {'name': 'bluetooth', 'desc': '蓝牙 MAC 地址'},
    ],
    'mediatek': [
      {'name': 'nvram', 'desc': 'NVRAM（IMEI、校准数据）'},
      {'name': 'nvdata', 'desc': 'NVRAM 数据'},
      {'name': 'protect1', 'desc': '保护分区 1'},
      {'name': 'protect2', 'desc': '保护分区 2'},
      {'name': 'md1img', 'desc': '基带镜像'},
      {'name': 'md1dsp', 'desc': '基带 DSP'},
    ],
    'samsung': [
      {'name': 'modem', 'desc': '基带固件'},
      {'name': 'efs', 'desc': 'EFS（IMEI）'},
      {'name': 'persist', 'desc': '持久化分区'},
    ],
  };

  /// 检测平台
  Future<String> detectVendor() async {
    try {
      final adb = await AppConfig.adbPath();
      final r = await ProcessRunner.run(
        adb,
        ['shell', 'getprop ro.board.platform; getprop ro.hardware; '
                'getprop ro.product.board'],
        timeout: const Duration(seconds: 10),
      );
      final out = r.output.toLowerCase();
      if (out.contains('mt') || out.contains('mediatek')) return 'mediatek';
      if (out.contains('qcom') || out.contains('msm') ||
          out.contains('sm') || out.contains('sdm')) {
        return 'qualcomm';
      }
      if (out.contains('exynos') || out.contains('universal')) {
        return 'samsung';
      }
    } catch (_) {}
    return 'qualcomm'; // 默认
  }

  /// 扫描设备上实际存在的基带分区
  Future<List<ModemPartition>> scanPartitions({
    void Function(String line)? onLine,
  }) async {
    final found = <ModemPartition>[];
    if (!await init()) return found;

    final vendor = await detectVendor();
    onLine?.call('  平台: $vendor');

    final candidates = partitionsByVendor[vendor] ?? [];
    final adb = await AppConfig.adbPath();

    for (final c in candidates) {
      final name = c['name']!;

      // 检查 /dev/block/by-name/<name> 是否存在
      final r = await ProcessRunner.run(
        adb,
        ['shell', 'su', '-c',
         'if [ -e /dev/block/by-name/$name ]; then '
         '  echo "EXISTS"; '
         '  readlink -f /dev/block/by-name/$name; '
         '  blockdev --getsize64 /dev/block/by-name/$name 2>/dev/null; '
         'fi'],
        timeout: const Duration(seconds: 10),
      );

      final lines = r.stdout.trim().split('\n');
      if (lines.isEmpty || !lines[0].contains('EXISTS')) continue;

      final realPath = lines.length > 1 ? lines[1].trim() : '';
      final size = lines.length > 2 ? int.tryParse(lines[2].trim()) : null;

      found.add(ModemPartition(
        name: name,
        path: realPath.isNotEmpty ? realPath : '/dev/block/by-name/$name',
        sizeBytes: size,
        description: c['desc']!,
      ));

      onLine?.call('  ✅ $name  '
          '${size != null ? "(${(size / 1024 / 1024).toStringAsFixed(1)} MB)" : ""}');
    }

    return found;
  }

  /// 备份单个分区
  Future<ModemResult> backupPartition({
    required String partitionName,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return ModemResult(false, '工具未就绪', log);

    final busybox = p.join(_toolsDir!, 'busybox');
    if (!File(busybox).existsSync()) {
      return ModemResult(false, 'busybox 未找到', log);
    }

    final adb = await AppConfig.adbPath();
    final remotePath = '/data/local/tmp/$partitionName.img';

    add('══ 备份 $partitionName');
    add('');

    // 推送 busybox
    await ProcessRunner.run(
      adb,
      ['push', busybox, '/data/local/tmp/busybox'],
      timeout: const Duration(minutes: 1),
    );

    // dd 读分区
    add('── 读取分区');
    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/busybox && '
       '/data/local/tmp/busybox dd if=/dev/block/by-name/$partitionName '
       'of=$remotePath bs=1M 2>&1'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code != 0) {
      add('❌ 读取失败（退出码 $code）');
      return ModemResult(false, '读取失败', log);
    }

    // 拉回
    add('');
    add('── 拉回本地');
    final pull = await ProcessRunner.run(
      adb,
      ['pull', remotePath, outputPath],
      timeout: const Duration(minutes: 5),
    );

    if (!pull.ok) {
      add('❌ 拉取失败');
      return ModemResult(false, '拉取失败', log);
    }

    // 清理设备端
    await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c', 'rm -f $remotePath'],
      timeout: const Duration(seconds: 30),
    );

    final size = File(outputPath).lengthSync();
    add('  ✅ 已保存 ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
    add('  路径: $outputPath');

    return ModemResult(true, '$partitionName 已备份', log);
  }

  /// 备份全部基带分区
  Future<ModemResult> backupAll({
    required String outputDir,
    void Function(String line)? onLine,
    void Function(int current, int total, String name)? onProgress,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return ModemResult(false, '工具未就绪', log);

    add('══ 备份全部基带分区');
    add('');

    final parts = await scanPartitions(onLine: add);
    if (parts.isEmpty) {
      add('');
      add('❌ 没找到基带分区');
      add('');
      add('可能原因：');
      add('  · 设备未 root');
      add('  · 分区名与预期不同（可以手动指定）');
      return ModemResult(false, '没找到基带分区', log);
    }

    add('');
    add('── 找到 ${parts.length} 个分区，开始备份');
    add('');

    final dir = Directory(outputDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    var success = 0;
    final failed = <String>[];

    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      onProgress?.call(i + 1, parts.length, part.name);

      add('── [${i + 1}/${parts.length}] ${part.name} (${part.sizeText})');
      final target = p.join(outputDir, '${part.name}.img');

      final r = await backupPartition(
        partitionName: part.name,
        outputPath: target,
        onLine: null,
      );

      if (r.ok) {
        success++;
        add('  ✅ 完成');
      } else {
        failed.add(part.name);
        add('  ❌ 失败: ${r.message}');
      }
      add('');
    }

    add('════════════════════════');
    add('✅ 成功 $success / ${parts.length}');
    if (failed.isNotEmpty) {
      add('❌ 失败: ${failed.join(", ")}');
    }
    add('');
    add('📌 备份位置: $outputDir');
    add('');
    add('⚠️ 请妥善保存这些文件');
    add('  刷机后没信号时，可以用它们恢复基带');

    return ModemResult(
      failed.isEmpty,
      failed.isEmpty ? '全部备份完成' : '部分失败',
      log,
    );
  }

  /// 恢复单个分区
  Future<ModemResult> restorePartition({
    required String partitionName,
    required String imagePath,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) return ModemResult(false, '需要确认', log);
    if (!File(imagePath).existsSync()) {
      return ModemResult(false, '镜像文件不存在', log);
    }

    if (!await init()) return ModemResult(false, '工具未就绪', log);

    final adb = await AppConfig.adbPath();
    final busybox = p.join(_toolsDir!, 'busybox');
    final remotePath = '/data/local/tmp/restore-$partitionName.img';

    add('══ 恢复 $partitionName');
    add('  镜像: ${p.basename(imagePath)}');
    add('  大小: ${(File(imagePath).lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB');
    add('');
    add('🚨 会覆盖设备上的 $partitionName 分区');

    // 推送
    add('');
    add('── 推送镜像');
    await ProcessRunner.run(
      adb,
      ['push', busybox, '/data/local/tmp/busybox'],
      timeout: const Duration(minutes: 1),
    );
    final push = await ProcessRunner.run(
      adb,
      ['push', imagePath, remotePath],
      timeout: const Duration(minutes: 5),
    );
    if (!push.ok) {
      return ModemResult(false, '推送失败', log);
    }
    add('  ✅ 已推送');

    // dd 写回
    add('');
    add('── 写回分区');
    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/busybox && '
       '/data/local/tmp/busybox dd if=$remotePath '
       'of=/dev/block/by-name/$partitionName bs=1M 2>&1'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    // 清理
    await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c', 'rm -f $remotePath'],
      timeout: const Duration(seconds: 30),
    );

    if (code == 0) {
      add('');
      add('✅ 已恢复');
      add('');
      add('📌 请重启设备验证信号');
      return ModemResult(true, '已恢复', log);
    }
    return ModemResult(false, '恢复失败（退出码 $code）', log);
  }

  /// 读 IMEI（辅助验证）
  Future<String?> readImei() async {
    try {
      final adb = await AppConfig.adbPath();
      final r = await ProcessRunner.run(
        adb,
        ['shell', 'service call iphonesubinfo 1'],
        timeout: const Duration(seconds: 10),
      );
      if (r.output.trim().isEmpty) return null;

      // 解析输出里的数字
      final digits = RegExp(r'[0-9]').allMatches(r.output);
      if (digits.length >= 14) {
        return digits.map((m) => m.group(0)).join();
      }
    } catch (_) {}
    return null;
  }
}
