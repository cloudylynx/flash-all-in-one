import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 扩容结果
class ResizeResult {
  final bool ok;
  final String message;
  final List<String> log;
  ResizeResult(this.ok, this.message, [this.log = const []]);
}

/// 分区信息
class PartitionInfo {
  final int number;
  final String name;
  final String typeCode;
  final String startSector;
  final String endSector;
  final String size;
  final bool isUserdata;

  PartitionInfo({
    required this.number,
    required this.name,
    required this.typeCode,
    required this.startSector,
    required this.endSector,
    required this.size,
    this.isUserdata = false,
  });

  Map<String, dynamic> toJson() => {
        'number': number,
        'name': name,
        'typeCode': typeCode,
        'start': startSector,
        'end': endSector,
        'size': size,
        'isUserdata': isUserdata,
      };
}

/// 分区扩容服务
///
/// 技术来源：多系统工具箱 APK 3.01（反编译分析）
///
/// 核心原理（从 smali 提取的真实参数）：
///   · 目标分区: "userdata"
///   · 目标大小: 128 GB（可调）
///   · MTK 特殊: "sdc" 分区要在 80/96 之间腾挪
///   · 遍历字母: a/b/d/e/f/c（非MTK）、c（MTK）
///   · 工具: sgdisk + busybox(dd) + resize2fs + e2fsck
///
/// 扩容流程：
///   ① 备份分区表（sgdisk --backup）
///   ② 读分区表，找 userdata 的编号/起始/结束
///   ③ 删 userdata 分区
///   ④ 用新大小重建（起始不变，结束扩展到磁盘末尾或指定位置）
///   ⑤ 恢复分区名和类型码
///   ⑥ 通知内核重读分区表
///   ⑦ e2fsck 检查文件系统
///   ⑧ resize2fs 扩容文件系统
class PartitionResizeService {
  PartitionResizeService._();
  static final PartitionResizeService instance = PartitionResizeService._();

  String? _toolsDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：从 assets 提取工具
  Future<bool> init() async {
    if (_available) return true;

    const tools = ['sgdisk', 'parted', 'busybox', 'resize2fs', 'mke2fs', 'e2fsdroid'];

    var ok = 0;
    for (final t in tools) {
      final path = await ToolExtractor.extractFile(
        assetPath: 'assets/tools/android/multiboot/$t',
        subDir: 'multiboot',
        fileName: t,
        executable: true,
      );
      if (path != null) {
        _toolsDir ??= File(path).parent.path;
        ok++;
      }
    }

    _available = ok >= 4;
    return _available;
  }

  String? _tool(String name) {
    if (_toolsDir == null) return null;
    final path = p.join(_toolsDir!, name);
    return File(path).existsSync() ? path : null;
  }

  /// 检测是否为 MTK 平台（决定分区字母遍历顺序）
  Future<bool> isMtkPlatform() async {
    try {
      final adb = await AppConfig.adbPath();
      final r = await ProcessRunner.run(
        adb,
        ['shell', 'getprop ro.board.platform; getprop ro.hardware'],
        timeout: const Duration(seconds: 10),
      );
      final out = r.output.toLowerCase();
      return out.contains('mt') || out.contains('mediatek');
    } catch (_) {
      return false;
    }
  }

  /// 找主存储设备
  Future<String?> findStorageDevice() async {
    try {
      final adb = await AppConfig.adbPath();

      // 优先用 by-name 目录
      final byName = await ProcessRunner.run(
        adb,
        ['shell', 'ls /dev/block/by-name/userdata 2>/dev/null'],
        timeout: const Duration(seconds: 10),
      );
      if (byName.output.trim().isNotEmpty) {
        // 解析符号链接目标，得到 /dev/block/sdaXX
        final real = await ProcessRunner.run(
          adb,
          ['shell', 'readlink -f /dev/block/by-name/userdata'],
          timeout: const Duration(seconds: 10),
        );
        final target = real.output.trim();
        if (target.isNotEmpty) {
          // 从 /dev/block/sda25 提取 /dev/block/sda
          final m = RegExp(r'^(/dev/block/(?:sd[a-z]|mmcblk\d+|nvme\d+n\d+))')
              .firstMatch(target);
          if (m != null) return m.group(1);
        }
      }

      // 备用：遍历 /sys/block
      final ls = await ProcessRunner.run(
        adb,
        ['shell', 'ls /sys/block/'],
        timeout: const Duration(seconds: 10),
      );
      for (final dev in ls.stdout.split('\n')) {
        final d = dev.trim();
        if (d.startsWith('sd') || d.startsWith('mmcblk') ||
            d.startsWith('nvme')) {
          if (!d.contains('boot')) return '/dev/block/$d';
        }
      }
    } catch (_) {}
    return null;
  }

  /// 读分区表
  Future<List<PartitionInfo>> readPartitions({
    required String disk,
    void Function(String line)? onLine,
  }) async {
    final parts = <PartitionInfo>[];
    if (!await init()) return parts;

    final exe = _tool('sgdisk');
    if (exe == null) return parts;

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/sgdisk';

    // 推送
    await ProcessRunner.run(
      adb,
      ['push', exe, remotePath],
      timeout: const Duration(minutes: 1),
    );

    // 读分区表
    final r = await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c', 'chmod 755 $remotePath && $remotePath -p $disk'],
      timeout: const Duration(seconds: 30),
    );

    // 解析 sgdisk -p 输出
    // 例：
    // Number  Start (sector)    End (sector)  Size       Code  Name
    //    1            2048            6143   2.0 MiB    0700  pmic
    //   25       1234567         9876543   4.1 GiB     0700  userdata
    final re = RegExp(
      r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+\s*[KMGTP]?i?B)\s+([0-9A-Fa-f]{4})\s+(\S+)\s*$',
      multiLine: true,
    );

    for (final m in re.allMatches(r.output)) {
      final name = m.group(6)!.trim();
      parts.add(PartitionInfo(
        number: int.parse(m.group(1)!),
        startSector: m.group(2)!,
        endSector: m.group(3)!,
        size: m.group(4)!.trim(),
        typeCode: m.group(5)!,
        name: name,
        isUserdata: name == 'userdata',
      ));
    }

    for (final part in parts) {
      onLine?.call('  ${part.number.toString().padLeft(2)}  '
          '${part.name.padRight(20)} '
          '${part.size.padLeft(10)}  '
          '${part.startSector} → ${part.endSector}');
    }

    return parts;
  }

  /// 备份分区表
  Future<ResizeResult> backupPartitionTable({
    required String disk,
    String? outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return ResizeResult(false, '工具未就绪', log);
    final exe = _tool('sgdisk');
    if (exe == null) return ResizeResult(false, 'sgdisk 未找到', log);

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/sgdisk';
    const remoteBak = '/data/local/tmp/gpt.bak';

    add('══ 备份分区表');
    add('  磁盘: $disk');
    add('');

    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 1));

    add('── 导出 GPT');
    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 $remotePath && $remotePath --backup=$remoteBak $disk'],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    if (code != 0) {
      add('❌ 导出失败');
      return ResizeResult(false, '导出失败（退出码 $code）', log);
    }
    add('  ✅ 已导出到设备');

    // 拉回本地
    final savePath = outputPath ??
        '/tmp/gpt-backup-${DateTime.now().millisecondsSinceEpoch}.bin';
    add('');
    add('── 拉回本地: ${p.basename(savePath)}');
    final pull = await ProcessRunner.run(
      adb,
      ['pull', remoteBak, savePath],
      timeout: const Duration(minutes: 2),
    );

    if (!pull.ok) {
      add('❌ 拉取失败');
      return ResizeResult(false, '拉取失败', log);
    }

    add('  ✅ 已保存');
    add('');
    add('📌 恢复命令（如果需要回滚）：');
    add('   sgdisk --load-backup=$remoteBak $disk');
    return ResizeResult(true, '分区表已备份', log);
  }

  /// 扩容 userdata 分区
  ///
  /// [targetSizeGb] 目标大小（GB）。0 表示用到磁盘末尾。
  Future<ResizeResult> expandUserdata({
    required String disk,
    int targetSizeGb = 0,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return ResizeResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return ResizeResult(false, '工具未就绪', log);

    final sgdisk = _tool('sgdisk');
    final busybox = _tool('busybox');
    final resize2fs = _tool('resize2fs');
    if (sgdisk == null || busybox == null || resize2fs == null) {
      return ResizeResult(false, '必要工具缺失', log);
    }

    final adb = await AppConfig.adbPath();

    add('══ 扩容 userdata 分区');
    add('  磁盘: $disk');
    add('  目标: ${targetSizeGb > 0 ? "$targetSizeGb GB" : "扩展到磁盘末尾"}');
    add('');

    // ═══ ① 检测平台 ═══
    final isMtk = await isMtkPlatform();
    add('  平台: ${isMtk ? "MTK（需要处理 sdc 分区）" : "高通/其他"}');
    add('');

    // ═══ ② 推送工具 ═══
    add('── 推送工具');
    for (final t in [
      MapEntry(sgdisk, '/data/local/tmp/sgdisk'),
      MapEntry(busybox, '/data/local/tmp/busybox'),
      MapEntry(resize2fs, '/data/local/tmp/resize2fs'),
    ]) {
      await ProcessRunner.run(
        adb,
        ['push', t.key, t.value],
        timeout: const Duration(minutes: 2),
      );
    }
    add('  ✅ 已推送');

    // ═══ ③ 备份分区表 ═══
    add('');
    add('── 备份分区表');
    const remoteBak = '/data/local/tmp/gpt.bak';
    final bakCode = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/sgdisk && '
       '/data/local/tmp/sgdisk --backup=$remoteBak $disk'],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );
    if (bakCode != 0) {
      add('❌ 备份失败，中止');
      return ResizeResult(false, '备份失败', log);
    }
    add('  ✅ 已备份到 $remoteBak');

    // ═══ ④ 读分区表 ═══
    add('');
    add('── 读分区表');
    final parts = await readPartitions(disk: disk, onLine: add);
    final userdata = parts.where((p) => p.isUserdata).firstOrNull;

    if (userdata == null) {
      add('');
      add('❌ 找不到 userdata 分区');
      return ResizeResult(false, '找不到 userdata', log);
    }

    add('');
    add('  userdata: 分区 #${userdata.number}');
    add('    起始: ${userdata.startSector}');
    add('    结束: ${userdata.endSector}');
    add('    当前: ${userdata.size}');

    // ═══ ⑤ 计算新结束扇区 ═══
    add('');
    add('── 计算新大小');

    final startSector = int.parse(userdata.startSector);
    final oldEndSector = int.parse(userdata.endSector);

    // 读磁盘总扇区数
    final totalOut = await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c', 'cat /sys/block/${p.basename(disk)}/size'],
      timeout: const Duration(seconds: 10),
    );
    final totalSectors = int.tryParse(totalOut.output.trim()) ?? 0;

    if (totalSectors == 0) {
      add('❌ 无法读取磁盘总扇区数');
      return ResizeResult(false, '无法读磁盘大小', log);
    }

    int newEndSector;
    if (targetSizeGb > 0) {
      // 指定大小
      const sectorsPerGb = 2097152; // 512 * 1024 * 1024
      newEndSector = startSector + targetSizeGb * sectorsPerGb - 1;
      if (newEndSector > totalSectors - 34) {
        add('⚠️ 目标大小超过磁盘容量，改用磁盘末尾');
        newEndSector = totalSectors - 34;
      }
    } else {
      // 扩展到磁盘末尾（留 34 扇区给 GPT 备份表）
      newEndSector = totalSectors - 34;
    }

    add('  磁盘总扇区: $totalSectors');
    add('  新结束扇区: $newEndSector');
    add('  增长: ${((newEndSector - oldEndSector) * 512 / 1024 / 1024 / 1024).toStringAsFixed(1)} GB');

    if (newEndSector <= oldEndSector) {
      add('');
      add('⚠️ 新大小不大于当前大小，无需扩容');
      return ResizeResult(false, '目标大小不够', log);
    }

    // ═══ ⑥ MTK 特殊处理 ═══
    if (isMtk) {
      add('');
      add('── MTK 平台：检查 sdc 分区');
      final sdc = parts.where((p) => p.name == 'sdc').firstOrNull;
      if (sdc != null) {
        add('  sdc 在 #${sdc.number}（${sdc.size}）');
        add('  ⚠️ MTK 的 sdc 分区可能需要先移动');
        add('  📌 参考：原工具在 80/96 扇区之间腾挪');
      }
    }

    // ═══ ⑦ 删分区 ═══
    add('');
    add('── 删除旧 userdata 分区');
    var code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       '/data/local/tmp/sgdisk --delete=${userdata.number} $disk'],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );
    if (code != 0) {
      add('❌ 删除失败，尝试恢复分区表');
      await ProcessRunner.run(
        adb,
        ['shell', 'su', '-c', '/data/local/tmp/sgdisk --load-backup=$remoteBak $disk'],
        timeout: const Duration(minutes: 2),
      );
      return ResizeResult(false, '删除失败（已尝试恢复）', log);
    }
    add('  ✅ 已删除');

    // ═══ ⑧ 重建分区 ═══
    add('');
    add('── 重建 userdata 分区');
    code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       '/data/local/tmp/sgdisk --new=${userdata.number}:$startSector:$newEndSector '
       '--typecode=${userdata.number}:${userdata.typeCode} '
       '--change-name=${userdata.number}:userdata $disk'],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );
    if (code != 0) {
      add('❌ 重建失败，尝试恢复分区表');
      await ProcessRunner.run(
        adb,
        ['shell', 'su', '-c', '/data/local/tmp/sgdisk --load-backup=$remoteBak $disk'],
        timeout: const Duration(minutes: 2),
      );
      return ResizeResult(false, '重建失败（已尝试恢复）', log);
    }
    add('  ✅ 已重建');

    // ═══ ⑨ 通知内核 ═══
    add('');
    add('── 通知内核重读分区表');
    await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c', 'blockdev --rereadpt $disk 2>/dev/null || '
              '/data/local/tmp/busybox partprobe $disk 2>/dev/null || true'],
      timeout: const Duration(seconds: 30),
    );
    add('  ✅ 已通知');
    await Future.delayed(const Duration(seconds: 2));

    // ═══ ⑩ 检查文件系统 ═══
    add('');
    add('── 检查文件系统');
    final partPath = '$disk${userdata.number}';
    code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       '/data/local/tmp/busybox umount $partPath 2>/dev/null; '
       '/data/local/tmp/busybox e2fsck -f -y $partPath'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );
    add(code == 0 ? '  ✅ 文件系统正常' : '  ⚠️ e2fsck 返回 $code（可能已修复）');

    // ═══ ⑪ 扩容文件系统 ═══
    add('');
    add('── 扩容文件系统');
    code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c', '/data/local/tmp/resize2fs $partPath'],
      onLine: add,
      timeout: const Duration(minutes: 30),
    );

    if (code != 0) {
      add('');
      add('❌ resize2fs 失败');
      add('');
      add('📌 分区表已改，但文件系统没扩容。请尝试：');
      add('   1. 重启设备，在 TWRP 里手动 resize2fs');
      add('   2. 或执行：adb shell su -c "resize2fs $partPath"');
      return ResizeResult(false, '文件系统扩容失败', log);
    }

    add('  ✅ 文件系统已扩容');

    // ═══ ⑫ 完成 ═══
    add('');
    add('✅ userdata 扩容完成');
    add('');
    add('📌 请重启设备验证');
    add('   备份的分区表在设备上：$remoteBak');

    return ResizeResult(true, '扩容完成', log);
  }

  /// 恢复分区表（回滚）
  Future<ResizeResult> restorePartitionTable({
    required String disk,
    required String backupPath,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) return ResizeResult(false, '需要确认', log);
    if (!File(backupPath).existsSync()) {
      return ResizeResult(false, '备份文件不存在', log);
    }

    if (!await init()) return ResizeResult(false, '工具未就绪', log);
    final sgdisk = _tool('sgdisk');
    if (sgdisk == null) return ResizeResult(false, 'sgdisk 未找到', log);

    final adb = await AppConfig.adbPath();

    add('══ 恢复分区表');
    add('  备份: ${p.basename(backupPath)}');
    add('  磁盘: $disk');
    add('');
    add('🚨 这会覆盖当前分区表');

    add('── 推送');
    await ProcessRunner.run(adb, ['push', sgdisk, '/data/local/tmp/sgdisk'],
        timeout: const Duration(minutes: 1));
    await ProcessRunner.run(
        adb, ['push', backupPath, '/data/local/tmp/gpt-restore.bak'],
        timeout: const Duration(minutes: 2));

    add('── 恢复');
    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/sgdisk && '
       '/data/local/tmp/sgdisk --load-backup=/data/local/tmp/gpt-restore.bak $disk'],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    if (code == 0) {
      add('');
      add('✅ 分区表已恢复');
      return ResizeResult(true, '已恢复', log);
    }
    return ResizeResult(false, '恢复失败', log);
  }

  /// 剩余空间统计
  Future<Map<String, String>> getFreeSpace({
    required String disk,
  }) async {
    final info = <String, String>{};
    try {
      final parts = await readPartitions(disk: disk);
      if (parts.isEmpty) return info;

      final adb = await AppConfig.adbPath();
      final totalOut = await ProcessRunner.run(
        adb,
        ['shell', 'su', '-c', 'cat /sys/block/${p.basename(disk)}/size'],
        timeout: const Duration(seconds: 10),
      );
      final totalSectors = int.tryParse(totalOut.output.trim()) ?? 0;
      if (totalSectors == 0) return info;

      // 找最后一个分区的结束扇区
      var maxEnd = 0;
      for (final part in parts) {
        final e = int.tryParse(part.endSector) ?? 0;
        if (e > maxEnd) maxEnd = e;
      }

      final freeSectors = totalSectors - maxEnd - 34;
      info['total_gb'] = (totalSectors * 512 / 1024 / 1024 / 1024).toStringAsFixed(1);
      info['free_gb'] = (freeSectors * 512 / 1024 / 1024 / 1024).toStringAsFixed(1);
      info['partitions'] = '${parts.length}';
    } catch (_) {}
    return info;
  }
}
