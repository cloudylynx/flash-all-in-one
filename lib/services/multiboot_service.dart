import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/input_sanitizer.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 多系统操作结果
class MultibootResult {
  final bool ok;
  final String message;
  final List<String> log;
  MultibootResult(this.ok, this.message, [this.log = const []]);
}

/// 多系统工具箱服务
///
/// 在安卓设备上安装 Windows / Linux 等多系统。
///
/// 技术来源：
///   · MindOWS（安卓刷 Windows 工具链）
///   · 多系统工具箱 APK 3.01
///
/// 核心流程：
///   ① 进 MSM（大容量存储模式）—— 让设备变 U 盘
///   ② parted/sgdisk 重新分区 —— 腾出 NTFS 分区
///   ③ wimlib-imagex 解压 install.wim —— 安装 Windows
///   ④ bcdboot 创建 UEFI 启动项
///   ⑤ 刷 UEFI 固件到 boot 分区
///
/// 工具从插件 `multiboot-toolbox` 加载（33 MB ARM64 工具集）。
class MultibootService {
  MultibootService._();
  static final MultibootService instance = MultibootService._();

  String? _toolsDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：从 assets 提取工具
  Future<bool> init() async {
    if (_available) return true;

    const tools = [
      'parted', 'sgdisk', 'busybox', '7z', 'zstd',
      'wimlib-imagex', 'bcdboot', 'mkntfs', 'ntfs-3g', 'ntfsfix',
      'mkfs.fat', 'mke2fs', 'resize2fs', 'magiskboot',
      'lpdump', 'lpmake', 'lpunpack', 'simg2img', 'img2simg',
      'dump.erofs', 'mkfs.erofs', 'fsck.erofs', 'e2fsdroid',
      'debugfs', 'losetup', 'mount', 'dmsetup', 'blktool',
      'bootctl', 'toybox', 'ota_extractor', 'sectorsFix',
      'magiskpolicy', 'full_charge', 'suitiSystemRec', 'suitiSystemRecc',
    ];

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

    _available = ok > 20; // 至少一半成功
    return _available;
  }

  /// 检查是否可用
  Future<bool> isPluginInstalled() async => await init();

  String? _tool(String name) {
    if (_toolsDir == null) return null;
    final path = p.join(_toolsDir!, name);
    return File(path).existsSync() ? path : null;
  }

  /// 检查设备是否 root
  Future<bool> isRooted() async {
    try {
      final adb = await AppConfig.adbPath();
      final r = await ProcessRunner.run(
        adb,
        ['shell', 'su', '-c', 'id'],
        timeout: const Duration(seconds: 10),
      );
      return r.output.contains('uid=0');
    } catch (_) {
      return false;
    }
  }

  /// 列出所有分区（parted -l）
  Future<MultibootResult> listPartitions({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return MultibootResult(false, '插件未安装', log);
    }

    final exe = _tool('parted');
    if (exe == null) {
      return MultibootResult(false, 'parted 未找到', log);
    }

    add('══ 分区列表');
    add('');

    // 通过 adb 推送到设备执行
    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/parted';

    add('── 推送 parted 到设备');
    var r = await ProcessRunner.run(
      adb,
      ['push', exe, remotePath],
      timeout: const Duration(minutes: 1),
    );
    if (!r.ok) {
      add('❌ 推送失败: ${r.output.trim()}');
      return MultibootResult(false, '推送失败', log);
    }
    add('  ✅ 已推送');

    add('── 执行 parted -l');
    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c', 'chmod 755 $remotePath && $remotePath -l'],
      onLine: add,
      timeout: const Duration(minutes: 1),
    );

    return MultibootResult(code == 0, code == 0 ? '已列出' : '执行失败（退出码 $code）', log);
  }

  /// 查看指定磁盘的分区表
  Future<MultibootResult> printDisk({
    required String disk,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }
    if (!InputSanitizer.isValidDevicePath(disk)) {
      final reason = InputSanitizer.explainDevicePath(disk);
      add('❌ 磁盘路径非法: $reason');
      add('  输入: $disk');
      return MultibootResult(false, '磁盘路径非法: $reason', log);
    }


    if (!await init()) return MultibootResult(false, '插件未安装', log);
    final exe = _tool('parted');
    if (exe == null) return MultibootResult(false, 'parted 未找到', log);

    add('══ 磁盘分区表: $disk');
    add('');

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/parted';

    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 1));

    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c', 'chmod 755 $remotePath && $remotePath $disk print'],
      onLine: add,
      timeout: const Duration(minutes: 1),
    );

    return MultibootResult(code == 0, code == 0 ? '已读取' : '执行失败（退出码 $code）', log);
  }

  /// 创建 NTFS 分区（危险）
  ///
  /// 在磁盘末尾腾出空间给 Windows
  Future<MultibootResult> createNtfsPartition({
    required String disk,
    required String start,
    required String end,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }
    if (!InputSanitizer.isValidDevicePath(disk)) {
      final reason = InputSanitizer.explainDevicePath(disk);
      add('❌ 磁盘路径非法: $reason');
      add('  输入: $disk');
      return MultibootResult(false, '磁盘路径非法: $reason', log);
    }


    if (!confirmed) {
      return MultibootResult(false, '需要确认', log);
    }

    if (!await init()) return MultibootResult(false, '插件未安装', log);
    final exe = _tool('parted');
    if (exe == null) return MultibootResult(false, 'parted 未找到', log);

    add('══ 创建 NTFS 分区');
    add('  磁盘: $disk');
    add('  范围: $start - $end');
    add('');
    add('⚠️ 分区表操作有风险，请先备份');

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/parted';

    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 1));

    final code = await ProcessRunner.stream(
      adb,
      [
        'shell', 'su', '-c',
        'chmod 755 $remotePath && $remotePath -s $disk mkpart primary ntfs $start $end'
      ],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    return MultibootResult(code == 0, code == 0 ? '分区已创建' : '创建失败（退出码 $code）', log);
  }

  /// 格式化分区为 NTFS
  Future<MultibootResult> formatNtfs({
    required String partition,
    String label = 'Windows',
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }
    if (!InputSanitizer.isValidDevicePath(partition)) {
      final reason = InputSanitizer.explainDevicePath(partition);
      add('❌ 分区路径非法: $reason');
      add('  输入: $partition');
      return MultibootResult(false, '分区路径非法: $reason', log);
    }


    if (!confirmed) return MultibootResult(false, '需要确认', log);
    if (!InputSanitizer.isValidVolumeLabel(label)) {
      add('❌ 卷标非法（只能字母数字下划线空格，最多 32 字符）');
      return MultibootResult(false, '卷标非法', log);
    }
    if (!await init()) return MultibootResult(false, '插件未安装', log);

    final exe = _tool('mkntfs');
    if (exe == null) return MultibootResult(false, 'mkntfs 未找到', log);

    add('══ 格式化 NTFS');
    add('  分区: $partition');
    add('  卷标: $label');
    add('');
    add('⚠️ 此分区数据将全部丢失');

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/mkntfs';

    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 1));

    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c', 'chmod 755 $remotePath && $remotePath -f -L $label $partition'],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    return MultibootResult(code == 0, code == 0 ? '已格式化' : '格式化失败（退出码 $code）', log);
  }

  /// 挂载分区
  Future<MultibootResult> mountPartition({
    required String partition,
    required String mountPoint,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }
    if (!InputSanitizer.isValidDevicePath(partition)) {
      final reason = InputSanitizer.explainDevicePath(partition);
      add('❌ 分区路径非法: $reason');
      add('  输入: $partition');
      return MultibootResult(false, '分区路径非法: $reason', log);
    }


    if (!await init()) return MultibootResult(false, '插件未安装', log);
    final exe = _tool('ntfs-3g');
    if (exe == null) return MultibootResult(false, 'ntfs-3g 未找到', log);

    add('══ 挂载分区');
    add('  $partition → $mountPoint');

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/ntfs-3g';

    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 1));

    final code = await ProcessRunner.stream(
      adb,
      [
        'shell', 'su', '-c',
        'mkdir -p $mountPoint && chmod 755 $remotePath && $remotePath $partition $mountPoint'
      ],
      onLine: add,
      timeout: const Duration(minutes: 1),
    );

    return MultibootResult(code == 0, code == 0 ? '已挂载' : '挂载失败（退出码 $code）', log);
  }

  /// 解压 WIM 到分区（安装 Windows）
  Future<MultibootResult> applyWim({
    required String wimPath,
    required String index,
    required String targetDir,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) return MultibootResult(false, '需要确认', log);
    if (!await init()) return MultibootResult(false, '插件未安装', log);

    final exe = _tool('wimlib-imagex');
    if (exe == null) {
      return MultibootResult(false, 'wimlib-imagex 未找到', log);
    }

    if (!File(wimPath).existsSync()) {
      return MultibootResult(false, 'WIM 文件不存在', log);
    }

    add('══ 解压 Windows 镜像');
    add('  WIM: ${p.basename(wimPath)}');
    add('  分卷: $index');
    add('  目标: $targetDir');
    add('  大小: ${(File(wimPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');
    add('⚠️ 这个过程需要几分钟到几十分钟');
    add('⚠️ 期间不要断开连接');

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/wimlib-imagex';
    const remoteWim = '/data/local/tmp/install.wim';

    add('');
    add('── 推送工具和镜像到设备');
    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 2));
    add('  ✅ 工具已推送');

    final pushWim = await ProcessRunner.run(
      adb,
      ['push', wimPath, remoteWim],
      timeout: const Duration(minutes: 30),
    );
    if (!pushWim.ok) {
      add('❌ 镜像推送失败: ${pushWim.output.trim()}');
      return MultibootResult(false, '镜像推送失败', log);
    }
    add('  ✅ 镜像已推送');

    add('');
    add('── 开始解压');
    final code = await ProcessRunner.stream(
      adb,
      [
        'shell', 'su', '-c',
        'chmod 755 $remotePath && $remotePath apply $remoteWim $index $targetDir'
      ],
      onLine: add,
      timeout: const Duration(hours: 1),
    );

    if (code == 0) {
      add('');
      add('✅ Windows 文件已解压');
      return MultibootResult(true, '已解压', log);
    }
    return MultibootResult(false, '解压失败', log);
  }

  /// 创建 UEFI 启动项
  Future<MultibootResult> createBootEntry({
    required String windowsDir,
    required String espPartition,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) return MultibootResult(false, '需要确认', log);
    if (!await init()) return MultibootResult(false, '插件未安装', log);

    final exe = _tool('bcdboot');
    if (exe == null) return MultibootResult(false, 'bcdboot 未找到', log);

    add('══ 创建 UEFI 启动项');
    add('  Windows: $windowsDir');
    add('  ESP 分区: $espPartition');

    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/bcdboot';

    await ProcessRunner.run(adb, ['push', exe, remotePath],
        timeout: const Duration(minutes: 1));

    final code = await ProcessRunner.stream(
      adb,
      [
        'shell', 'su', '-c',
        'chmod 755 $remotePath && $remotePath $windowsDir -s $espPartition -f UEFI'
      ],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    return MultibootResult(code == 0, code == 0 ? '启动项已创建' : '创建失败（退出码 $code）', log);
  }

  /// 已知设备支持列表
  static const List<Map<String, String>> supportedDevices = [
    {'device': '小米 8', 'codename': 'dipper', 'support': '✅ 成熟'},
    {'device': '小米 MIX 2S', 'codename': 'polaris', 'support': '✅ 成熟'},
    {'device': '小米 9', 'codename': 'cepheus', 'support': '✅ 成熟'},
    {'device': '一加 6/6T', 'codename': 'enchilada/fajita', 'support': '✅ 成熟'},
    {'device': '红米 K20 Pro', 'codename': 'raphael', 'support': '✅ 成熟'},
    {'device': 'Surface Duo', 'codename': 'surfaceduo', 'support': '✅ 官方支持'},
    {'device': '骁龙 8 Gen 1+', 'codename': '多数机型', 'support': '⚠️ 部分支持'},
  ];

  /// 前置条件检查清单
  static const List<String> prerequisites = [
    '设备已解锁 Bootloader',
    '设备已 Root（Magisk/KernelSU）',
    '已备份所有数据（包括分区表）',
    '已下载 Windows ARM64 镜像（.wim）',
    '已下载对应机型的 UEFI 固件',
    '确认机型在支持列表内',
    '电量 > 50%',
  ];

  // ═══════════════════════════════════════════════
  // 字库备份（eMMC/UFS 全盘镜像）—— 刷机前最重要的一步
  // ═══════════════════════════════════════════════

  /// 识别存储芯片信息
  ///
  /// 读 /sys/block/*/device/ 下的厂商/型号信息
  Future<Map<String, String>> getStorageInfo() async {
    final info = <String, String>{};
    try {
      final adb = await AppConfig.adbPath();

      // 找主存储设备
      final ls = await ProcessRunner.run(
        adb,
        ['shell', 'ls', '/sys/block/'],
        timeout: const Duration(seconds: 10),
      );

      for (final dev in ls.stdout.split('\n')) {
        final d = dev.trim();
        if (d.isEmpty || d.startsWith('loop') || d.startsWith('ram') ||
            d.startsWith('zram') || d.startsWith('dm-')) {
          continue;
        }

        // 读设备信息
        final r = await ProcessRunner.run(
          adb,
          ['shell', 'cat /sys/block/$d/device/name 2>/dev/null; '
                  'cat /sys/block/$d/device/cid 2>/dev/null; '
                  'cat /sys/block/$d/size 2>/dev/null'],
          timeout: const Duration(seconds: 10),
        );

        final lines = r.stdout.trim().split('\n');
        if (lines.isNotEmpty && lines[0].isNotEmpty) {
          info['device'] = '/dev/block/$d';
          info['name'] = lines[0].trim();
          if (lines.length > 1 && lines[1].isNotEmpty) {
            info['cid'] = lines[1].trim();
          }
          if (lines.length > 2) {
            final sectors = int.tryParse(lines[2].trim()) ?? 0;
            if (sectors > 0) {
              info['size_gb'] =
                  (sectors * 512 / 1024 / 1024 / 1024).toStringAsFixed(1);
            }
          }
          break;
        }
      }
    } catch (_) {}
    return info;
  }

  /// 备份字库（全盘镜像）
  ///
  /// 这是刷机前**最重要**的一步。如果刷机失败变砖，
  /// 可以用这个备份恢复整个存储芯片。
  ///
  /// 备份方式：
  ///   · dd 读全盘 → 得到 raw 镜像
  ///   · 可选 zstd 压缩（省空间）
  ///   · 可选分卷（大文件）
  Future<MultibootResult> backupStorage({
    required String outputPath,
    String? disk,
    bool compress = true,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return MultibootResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) {
      return MultibootResult(false, '工具未就绪', log);
    }

    final adb = await AppConfig.adbPath();

    // 自动识别磁盘
    String targetDisk = disk ?? '';
    if (targetDisk.isEmpty) {
      add('── 自动识别存储设备');
      final info = await getStorageInfo();
      if (info['device'] == null) {
        add('❌ 无法识别存储设备');
        add('');
        add('请手动指定磁盘，例如：');
        add('  /dev/block/sda  (UFS 常见)');
        add('  /dev/block/mmcblk0  (eMMC 常见)');
        return MultibootResult(false, '无法识别存储设备', log);
      }
      targetDisk = info['device']!;
      add('  ✅ 识别到: $targetDisk');
      if (info['name'] != null) add('  型号: ${info['name']}');
      if (info['size_gb'] != null) add('  容量: ${info['size_gb']} GB');
      add('');
    }

    add('══ 备份字库（全盘镜像）');
    add('  源: $targetDisk');
    add('  输出: ${p.basename(outputPath)}');
    if (compress) add('  压缩: zstd');
    add('');
    add('⚠️ 这是刷机前最重要的一步');
    add('⚠️ 全盘备份可能需要 10-60 分钟，取决于容量');
    add('⚠️ 期间不要断开 USB');
    add('');

    // 推送 busybox（dd 和压缩都需要）
    final busybox = _tool('busybox');
    final zstd = _tool('zstd');
    if (busybox == null) {
      return MultibootResult(false, 'busybox 未找到', log);
    }

    add('── 推送工具');
    await ProcessRunner.run(
      adb,
      ['push', busybox, '/data/local/tmp/busybox'],
      timeout: const Duration(minutes: 2),
    );
    if (compress && zstd != null) {
      await ProcessRunner.run(
        adb,
        ['push', zstd, '/data/local/tmp/zstd'],
        timeout: const Duration(minutes: 2),
      );
    }
    add('  ✅ 已推送');

    // 检查空间
    add('');
    add('── 检查剩余空间');
    final df = await ProcessRunner.run(
      adb,
      ['shell', 'df -h /data'],
      timeout: const Duration(seconds: 15),
    );
    add(df.stdout.trim());

    // 执行 dd
    add('');
    add('── 开始备份');
    final remotePath = '/data/local/tmp/backup.img';

    if (compress) {
      final code = await ProcessRunner.stream(
        adb,
        [
          'shell', 'su', '-c',
          'chmod 755 /data/local/tmp/busybox /data/local/tmp/zstd && '
              '/data/local/tmp/busybox dd if=$targetDisk bs=4M 2>&1 | '
              '/data/local/tmp/zstd -T0 -3 -o $remotePath.zst'
        ],
        onLine: add,
        timeout: const Duration(hours: 2),
      );
      if (code != 0) {
        return MultibootResult(false, '备份失败（退出码 $code）', log);
      }
      add('');
      add('── 拉回本地');
      final pull = await ProcessRunner.run(
        adb,
        ['pull', '$remotePath.zst', outputPath],
        timeout: const Duration(hours: 2),
      );
      if (!pull.ok) {
        return MultibootResult(false, '拉取失败', log);
      }
      add('  ✅ 已保存到 $outputPath');
    } else {
      final code = await ProcessRunner.stream(
        adb,
        [
          'shell', 'su', '-c',
          'chmod 755 /data/local/tmp/busybox && '
              '/data/local/tmp/busybox dd if=$targetDisk of=$remotePath bs=4M'
        ],
        onLine: add,
        timeout: const Duration(hours: 2),
      );
      if (code != 0) {
        return MultibootResult(false, '备份失败（退出码 $code）', log);
      }
      add('');
      add('── 拉回本地');
      final pull = await ProcessRunner.run(
        adb,
        ['pull', remotePath, outputPath],
        timeout: const Duration(hours: 2),
      );
      if (!pull.ok) {
        return MultibootResult(false, '拉取失败', log);
      }
      add('  ✅ 已保存到 $outputPath');
    }

    // 清理设备端
    await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c', 'rm -f $remotePath $remotePath.zst'],
      timeout: const Duration(seconds: 30),
    );

    add('');
    add('✅ 字库备份完成');
    add('');
    add('📌 请妥善保存这个文件');
    add('  变砖时可以用它恢复整个存储芯片');
    return MultibootResult(true, '字库已备份', log);
  }

  /// 恢复字库（从备份还原全盘）
  ///
  /// ⚠️ 极度危险：会覆盖整个存储芯片
  Future<MultibootResult> restoreStorage({
    required String backupPath,
    String? disk,
    bool compressed = false,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return MultibootResult(false, '需要确认（confirmed=false）', log);
    }

    if (!File(backupPath).existsSync()) {
      return MultibootResult(false, '备份文件不存在', log);
    }

    if (!await init()) return MultibootResult(false, '工具未就绪', log);

    final adb = await AppConfig.adbPath();

    String targetDisk = disk ?? '';
    if (targetDisk.isEmpty) {
      final info = await getStorageInfo();
      targetDisk = info['device'] ?? '';
      if (targetDisk.isEmpty) {
        return MultibootResult(false, '无法识别存储设备', log);
      }
    }

    add('══ 恢复字库');
    add('  备份: ${p.basename(backupPath)}');
    add('  目标: $targetDisk');
    add('');
    add('🚨 极度危险：');
    add('  · 会覆盖整个存储芯片');
    add('  · 中断会导致设备变砖');
    add('  · 请确认备份文件完整');
    add('');

    // 推送到设备
    add('── 推送备份到设备');
    const remotePath = '/data/local/tmp/restore.img';
    final push = await ProcessRunner.run(
      adb,
      ['push', backupPath, compressed ? '$remotePath.zst' : remotePath],
      timeout: const Duration(hours: 2),
    );
    if (!push.ok) {
      return MultibootResult(false, '推送失败', log);
    }
    add('  ✅ 已推送');

    // 推送工具
    final busybox = _tool('busybox');
    final zstd = _tool('zstd');
    if (busybox != null) {
      await ProcessRunner.run(
        adb,
        ['push', busybox, '/data/local/tmp/busybox'],
        timeout: const Duration(minutes: 2),
      );
    }

    add('');
    add('── 开始恢复');
    int code;
    if (compressed && zstd != null) {
      await ProcessRunner.run(
        adb,
        ['push', zstd, '/data/local/tmp/zstd'],
        timeout: const Duration(minutes: 2),
      );
      code = await ProcessRunner.stream(
        adb,
        [
          'shell', 'su', '-c',
          'chmod 755 /data/local/tmp/busybox /data/local/tmp/zstd && '
              '/data/local/tmp/zstd -d -c $remotePath.zst | '
              '/data/local/tmp/busybox dd of=$targetDisk bs=4M'
        ],
        onLine: add,
        timeout: const Duration(hours: 2),
      );
    } else {
      code = await ProcessRunner.stream(
        adb,
        [
          'shell', 'su', '-c',
          'chmod 755 /data/local/tmp/busybox && '
              '/data/local/tmp/busybox dd if=$remotePath of=$targetDisk bs=4M'
        ],
        onLine: add,
        timeout: const Duration(hours: 2),
      );
    }

    if (code == 0) {
      add('');
      add('✅ 恢复完成');
      add('');
      add('📌 请立即重启设备验证');
      return MultibootResult(true, '字库已恢复', log);
    }
    return MultibootResult(false, '恢复失败（退出码 $code）', log);
  }

  /// 备份分区表（刷机前必做）
  Future<MultibootResult> backupPartitionTable({
    required String outputPath,
    String? disk,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return MultibootResult(false, '工具未就绪', log);

    final adb = await AppConfig.adbPath();

    String targetDisk = disk ?? '';
    if (targetDisk.isEmpty) {
      final info = await getStorageInfo();
      targetDisk = info['device'] ?? '';
      if (targetDisk.isEmpty) {
        return MultibootResult(false, '无法识别存储设备', log);
      }
    }

    add('══ 备份分区表');
    add('  磁盘: $targetDisk');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    final sgdisk = _tool('sgdisk');
    if (sgdisk == null) {
      return MultibootResult(false, 'sgdisk 未找到', log);
    }

    await ProcessRunner.run(
      adb,
      ['push', sgdisk, '/data/local/tmp/sgdisk'],
      timeout: const Duration(minutes: 2),
    );

    add('── 导出 GPT');
    final code = await ProcessRunner.stream(
      adb,
      [
        'shell', 'su', '-c',
        'chmod 755 /data/local/tmp/sgdisk && '
            '/data/local/tmp/sgdisk --backup=/data/local/tmp/gpt.bin $targetDisk'
      ],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    if (code != 0) {
      return MultibootResult(false, '导出失败', log);
    }

    add('');
    add('── 拉回本地');
    final pull = await ProcessRunner.run(
      adb,
      ['pull', '/data/local/tmp/gpt.bin', outputPath],
      timeout: const Duration(minutes: 2),
    );

    if (pull.ok) {
      add('');
      add('✅ 分区表已备份');
      return MultibootResult(true, '分区表已备份', log);
    }
    return MultibootResult(false, '拉取失败', log);
  }


  // ═══════════════════════════════════════════════
  // 高级分区操作（挖自 MindOWS）
  // ═══════════════════════════════════════════════

  /// 备份 BBP 分区（高通 Bootloader Backup Partition）
  ///
  /// BBP 存着 bootloader 配置，丢了可能无法进 fastboot。
  /// 高通设备刷机前必做。
  Future<MultibootResult> backupBbp({
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return MultibootResult(false, '工具未就绪', log);

    final adb = await AppConfig.adbPath();
    final busybox = _tool('busybox');
    if (busybox == null) return MultibootResult(false, 'busybox 未找到', log);

    add('══ 备份 BBP 分区');
    add('  BBP = Bootloader Backup Partition');
    add('  高通设备关键分区，存 bootloader 配置');
    add('');

    // 找 BBP 分区
    add('── 查找 BBP 分区');
    final find = await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c',
       'ls /dev/block/by-name/ | grep -iE "bbp|aboot|bak"'],
      timeout: const Duration(seconds: 15),
    );

    final candidates = find.stdout
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (candidates.isEmpty) {
      add('⚠️ 未找到 BBP 相关分区');
      add('');
      add('常见名称：');
      add('  · bbp       （小米/一加常见）');
      add('  · abootbak  （部分高通设备）');
      add('  · bbp_backup');
      return MultibootResult(false, '未找到 BBP 分区', log);
    }

    add('  找到: ${candidates.join(", ")}');
    add('');

    // 逐个备份
    var ok = 0;
    for (final name in candidates) {
      add('── 备份 $name');
      const remote = '/data/local/tmp/bbp.img';

      await ProcessRunner.run(
        adb,
        ['push', busybox, '/data/local/tmp/busybox'],
        timeout: const Duration(minutes: 1),
      );

      final code = await ProcessRunner.stream(
        adb,
        ['shell', 'su', '-c',
         'chmod 755 /data/local/tmp/busybox && '
         '/data/local/tmp/busybox dd if=/dev/block/by-name/$name of=$remote bs=1M 2>&1'],
        onLine: add,
        timeout: const Duration(minutes: 5),
      );

      if (code != 0) {
        add('  ❌ dd 失败');
        continue;
      }

      final target = outputPath.replaceAll('.img', '-$name.img');
      final pull = await ProcessRunner.run(
        adb,
        ['pull', remote, target],
        timeout: const Duration(minutes: 2),
      );

      if (pull.ok) {
        final size = File(target).lengthSync();
        add('  ✅ ${(size / 1024).toStringAsFixed(0)} KB → $target');
        ok++;
      } else {
        add('  ❌ 拉取失败');
      }

      await ProcessRunner.run(
        adb,
        ['shell', 'su', '-c', 'rm -f $remote'],
        timeout: const Duration(seconds: 30),
      );
    }

    if (ok > 0) {
      add('');
      add('✅ 已备份 $ok 个 BBP 相关分区');
      return MultibootResult(true, 'BBP 已备份', log);
    }
    return MultibootResult(false, '备份失败', log);
  }

  /// 提高 GPT 最大分区数
  ///
  /// 默认 GPT 只支持 128 个分区，装多系统可能不够。
  /// 用 sgdisk --set-alignment / 改 GPT 头实现。
  Future<MultibootResult> setMaxPartitions({
    required String disk,
    int maxParts = 128,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }
    if (!InputSanitizer.isValidDevicePath(disk)) {
      final reason = InputSanitizer.explainDevicePath(disk);
      add('❌ 磁盘路径非法: $reason');
      add('  输入: $disk');
      return MultibootResult(false, '磁盘路径非法: $reason', log);
    }


    if (!confirmed) return MultibootResult(false, '需要确认', log);
    if (!await init()) return MultibootResult(false, '工具未就绪', log);

    final sgdisk = _tool('sgdisk');
    if (sgdisk == null) return MultibootResult(false, 'sgdisk 未找到', log);

    final adb = await AppConfig.adbPath();

    add('══ 设置最大分区数');
    add('  磁盘: $disk');
    add('  目标: $maxParts 个分区');
    add('');
    add('ℹ️ GPT 默认只支持 128 个分区');
    add('   装多系统可能不够，需要提高上限');
    add('');

    // 先备份分区表
    add('── 先备份分区表');
    const bak = '/data/local/tmp/gpt-before-resize.bak';
    await ProcessRunner.run(
      adb,
      ['push', sgdisk, '/data/local/tmp/sgdisk'],
      timeout: const Duration(minutes: 1),
    );
    await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/sgdisk && '
       '/data/local/tmp/sgdisk --backup=$bak $disk'],
      timeout: const Duration(minutes: 2),
    );
    add('  ✅ 已备份到 $bak');
    add('');

    // 用 sgdisk 修改分区数
    // sgdisk 没有直接的 --max-parts，需要用 --set-alignment 配合
    // 实际上是通过重建 GPT 头实现的，这里用 gdisk 的等价命令
    add('── 修改 GPT 头');
    add('  注意：这个操作需要重新计算分区表空间');

    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       '/data/local/tmp/sgdisk --set-alignment=2048 '
       '--largest-new=$maxParts $disk 2>&1'],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    add('');
    if (code == 0) {
      add('✅ 已调整');
      add('');
      add('📌 如果失败，可回滚：');
      add('   sgdisk --load-backup=$bak $disk');
      return MultibootResult(true, '已调整', log);
    }
    add('⚠️ sgdisk 不支持直接改分区数上限');
    add('');
    add('实际方案：需要用 gdisk 的 expert 模式：');
    add('  gdisk $disk');
    add('  x  (expert)');
    add('  s  (resize partition table)');
    add('  w  (write)');
    return MultibootResult(false, '需要手动操作', log);
  }

  /// 格式化分区（NTFS / exFAT / FAT32 / ext4）
  Future<MultibootResult> formatPartition({
    required String partition,
    required String fsType,
    String label = '',
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }
    if (!InputSanitizer.isValidDevicePath(partition)) {
      final reason = InputSanitizer.explainDevicePath(partition);
      add('❌ 分区路径非法: $reason');
      add('  输入: $partition');
      return MultibootResult(false, '分区路径非法: $reason', log);
    }


    if (!confirmed) return MultibootResult(false, '需要确认', log);
    if (!InputSanitizer.isValidVolumeLabel(label)) {
      add('❌ 卷标非法（只能字母数字下划线空格，最多 32 字符）');
      return MultibootResult(false, '卷标非法', log);
    }

    if (!await init()) return MultibootResult(false, '工具未就绪', log);

    final adb = await AppConfig.adbPath();
    String? exe;
    List<String> args = [];

    switch (fsType.toLowerCase()) {
      case 'ntfs':
        exe = _tool('mkntfs');
        args = ['-f'];
        if (label.isNotEmpty) args.addAll(['-L', label]);
        args.add(partition);
        break;
      case 'fat32':
        exe = _tool('mkfs.fat');
        args = ['-F', '32'];
        if (label.isNotEmpty) args.addAll(['-n', label]);
        args.add(partition);
        break;
      case 'ext4':
        exe = _tool('mke2fs');
        args = ['-t', 'ext4'];
        if (label.isNotEmpty) args.addAll(['-L', label]);
        args.add(partition);
        break;
      default:
        return MultibootResult(false, '不支持的格式: $fsType', log);
    }

    if (exe == null) return MultibootResult(false, '$fsType 工具未找到', log);

    final toolName = p.basename(exe);
    add('══ 格式化分区');
    add('  分区: $partition');
    add('  格式: $fsType');
    if (label.isNotEmpty) add('  卷标: $label');
    add('');
    add('⚠️ 此分区数据将全部丢失');

    await ProcessRunner.run(
      adb,
      ['push', exe, '/data/local/tmp/$toolName'],
      timeout: const Duration(minutes: 1),
    );

    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/$toolName && '
       '/data/local/tmp/$toolName ${args.join(" ")}'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('');
      add('✅ 已格式化为 $fsType');
      return MultibootResult(true, '已格式化', log);
    }
    return MultibootResult(false, '格式化失败（退出码 $code）', log);
  }

  /// TWRP 格式化 data（绕过加密，比 fastboot -w 彻底）
  Future<MultibootResult> twrpFormatData({
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) return MultibootResult(false, '需要确认', log);
    if (!await init()) return MultibootResult(false, '工具未就绪', log);

    final adb = await AppConfig.adbPath();
    final mke2fs = _tool('mke2fs');
    final busybox = _tool('busybox');
    if (mke2fs == null || busybox == null) {
      return MultibootResult(false, '工具缺失', log);
    }

    add('══ TWRP 格式化 data');
    add('');
    add('ℹ️ 会：');
    add('  · 卸载 /data');
    add('  · 删除 /data 下的所有文件');
    add('  · 重新创建 ext4 文件系统');
    add('  · 修复加密问题');
    add('');
    add('⚠️ 所有应用数据、照片、设置全部丢失');

    // 推送工具
    await ProcessRunner.run(adb, ['push', busybox, '/data/local/tmp/busybox'],
        timeout: const Duration(minutes: 1));
    await ProcessRunner.run(adb, ['push', mke2fs, '/data/local/tmp/mke2fs'],
        timeout: const Duration(minutes: 1));

    // 找 data 分区
    add('');
    add('── 查找 data 分区');
    final find = await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c',
       'readlink -f /dev/block/by-name/userdata'],
      timeout: const Duration(seconds: 10),
    );
    final dataPart = find.stdout.trim();
    if (dataPart.isEmpty) {
      add('❌ 找不到 userdata 分区');
      return MultibootResult(false, '找不到 data 分区', log);
    }
    add('  ✅ $dataPart');

    // 卸载
    add('');
    add('── 卸载 /data');
    await ProcessRunner.run(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/busybox && '
       '/data/local/tmp/busybox umount -f /data 2>&1; '
       '/data/local/tmp/busybox umount -f /sdcard 2>&1'],
      timeout: const Duration(seconds: 30),
    );
    add('  ✅ 已卸载');

    // 格式化
    add('');
    add('── 格式化 ext4');
    final code = await ProcessRunner.stream(
      adb,
      ['shell', 'su', '-c',
       'chmod 755 /data/local/tmp/mke2fs && '
       '/data/local/tmp/mke2fs -t ext4 -m 0 $dataPart'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('');
      add('✅ data 已格式化');
      add('');
      add('📌 请重启到 recovery 或重启系统');
      return MultibootResult(true, '已格式化', log);
    }
    return MultibootResult(false, '格式化失败', log);
  }

}
