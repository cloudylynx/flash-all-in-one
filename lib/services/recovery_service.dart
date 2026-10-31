import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// 数据恢复结果
class RecoveryResult {
  final bool ok;
  final String message;
  final List<String> log;
  RecoveryResult(this.ok, this.message, [this.log = const []]);
}

/// 数据恢复与分区修复服务
///
/// 技术来源：
///   · cgsecurity/testdisk + photorec（2658★，GPL-2.0）
///     静态二进制，零依赖，2.69 MB
///
/// 能解决的核心场景：
///   ① **刷错机型 GPT → 容量错位/无法识别分区**
///      testdisk 能扫备份 GPT 头、从 MBR 反推、重建主表
///   ② **误删文件恢复**
///      photorec 按文件签名雕刻（不依赖文件系统元数据）
///      **这是唯一能救 F2FS 的方案**——sleuthkit 不支持 F2FS
///
/// ⚠️ 重要：写操作不可逆，必须先备份
class RecoveryService {
  RecoveryService._();
  static final RecoveryService instance = RecoveryService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    final suffix = Platform.isWindows ? '_win.exe' : '_static';

    for (final name in ['testdisk', 'photorec']) {
      final path = await ToolExtractor.extractFile(
        assetPath:
            'assets/tools/${Platform.isWindows ? "windows" : "linux"}/recovery/$name$suffix',
        subDir: 'recovery',
        fileName: '$name$suffix',
        executable: true,
      );
      if (path != null && _dir == null) {
        _dir = File(path).parent.path;
      }
    }

    // Windows 还需要 Cygwin DLL
    if (Platform.isWindows && _dir != null) {
      for (final dll in [
        'cygwin1.dll',
        'cygewf-2.dll',
        'cygiconv-2.dll',
        'cygncursesw-10.dll',
        'cyggcc_s-1.dll',
      ]) {
        await ToolExtractor.extractFile(
          assetPath: 'assets/tools/windows/recovery/$dll',
          subDir: 'recovery',
          fileName: dll,
        );
      }
    }

    _available = _dir != null;
    return _available;
  }

  String? _exe(String name) {
    if (_dir == null) return null;
    final suffix = Platform.isWindows ? '_win.exe' : '_static';
    final path = p.join(_dir!, '$name$suffix');
    return File(path).existsSync() ? path : null;
  }

  /// testdisk 版本
  Future<String?> testdiskVersion() async {
    if (!await init()) return null;
    final exe = _exe('testdisk');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['/version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'TestDisk\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// photorec 版本
  Future<String?> photorecVersion() async {
    if (!await init()) return null;
    final exe = _exe('photorec');
    if (exe == null) return null;
    final r = await ProcessRunner.run(exe, ['/version'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    final m = RegExp(r'PhotoRec\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 只读扫描分区表（安全，不写任何东西）
  ///
  /// 用于诊断 GPT 是否损坏。testdisk 的 `/list` 只读列出分区。
  Future<RecoveryResult> scanPartitionTable({
    required String imagePath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return RecoveryResult(false, 'testdisk 未就绪', log);
    final exe = _exe('testdisk');
    if (exe == null) return RecoveryResult(false, 'testdisk 未找到', log);

    if (!File(imagePath).existsSync()) {
      return RecoveryResult(false, '文件不存在: $imagePath', log);
    }

    add('══ 扫描分区表（只读）');
    add('  文件: ${p.basename(imagePath)}');
    final size = File(imagePath).lengthSync();
    add('  大小: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');
    add('ℹ️ 这是只读操作，不会修改任何数据');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['/list', imagePath],
      onLine: add,
      timeout: const Duration(minutes: 5),
      workingDirectory: _dir,
    );

    return RecoveryResult(
      code == 0,
      code == 0 ? '扫描完成' : '扫描失败（退出码 $code）',
      log,
    );
  }

  /// 备份当前分区表（安全操作，写操作前的必备步骤）
  ///
  /// testdisk 的 `/dump` 参数把分区表导出为文本。
  /// **这是修复前的最后一道保险**。
  Future<RecoveryResult> backupPartitionTable({
    required String imagePath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return RecoveryResult(false, 'testdisk 未就绪', log);
    final exe = _exe('testdisk');
    if (exe == null) return RecoveryResult(false, 'testdisk 未找到', log);

    Directory(outputDir).createSync(recursive: true);

    add('══ 备份分区表');
    add('  源: ${p.basename(imagePath)}');
    add('  输出: $outputDir');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['/dump', imagePath],
      onLine: add,
      timeout: const Duration(minutes: 5),
      workingDirectory: outputDir,
    );

    // testdisk /dump 会生成 _disk.txt 等文件
    var count = 0;
    try {
      count = Directory(outputDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('_disk') || f.path.endsWith('.txt'))
          .length;
    } catch (_) {}

    if (count > 0) {
      add('');
      add('✅ 已生成 $count 个备份文件');
      return RecoveryResult(true, '分区表已备份（$count 个文件）', log);
    }
    return RecoveryResult(false, '未生成备份文件', log);
  }

  /// 从镜像恢复已删除文件（photorec）
  ///
  /// photorec 按文件签名雕刻，**不依赖文件系统元数据**，
  /// 所以能救 testdisk 救不了的场景：
  ///   · 文件系统损坏
  ///   · **F2FS 分区**（sleuthkit 不支持）
  ///   · 分区表丢了但数据还在
  ///
  /// ⚠️ 恢复目标必须在另一个盘，不能是同盘
  Future<RecoveryResult> recoverFiles({
    required String imagePath,
    required String outputDir,
    String? fileFilter,
    bool includeDeleted = true,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return RecoveryResult(false, 'photorec 未就绪', log);
    final exe = _exe('photorec');
    if (exe == null) return RecoveryResult(false, 'photorec 未找到', log);

    if (!File(imagePath).existsSync()) {
      return RecoveryResult(false, '文件不存在: $imagePath', log);
    }

    Directory(outputDir).createSync(recursive: true);

    add('══ 文件雕刻恢复（photorec）');
    add('  源: ${p.basename(imagePath)}');
    add('  输出: $outputDir');
    if (fileFilter != null) add('  筛选: $fileFilter');
    add('');
    add('ℹ️ 按签名雕刻，不依赖文件系统元数据');
    add('  ✅ 能救 F2FS（sleuthkit 不支持）');
    add('  ✅ 能救分区表丢失的场景');
    add('');
    add('⚠️ 输出目录不能和源镜像在同一块盘');
    add('');

    // photorec 的批处理模式：/d 输出目录 /cmd 命令文件
    final cmdFile = p.join(outputDir, '.photorec.cmd');
    final cmdLines = <String>[
      if (includeDeleted) 'options,paranoid,space' else '',
      'options,everything',
      'search',
      'quit',
    ].where((l) => l.isNotEmpty).join('\n');
    await File(cmdFile).writeAsString(cmdLines);

    final args = <String>['/log', '/d', outputDir];
    if (fileFilter != null) {
      args.addAll(['/f', fileFilter]);
    }
    args.add(imagePath);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(hours: 2),
      workingDirectory: _dir,
    );

    // 统计恢复的文件
    var count = 0;
    var totalBytes = 0;
    try {
      for (final f in Directory(outputDir).listSync(recursive: true)) {
        if (f is File) {
          count++;
          totalBytes += f.lengthSync();
        }
      }
    } catch (_) {}

    add('');
    if (count > 0) {
      add('✅ 恢复 $count 个文件，共 ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB');
      return RecoveryResult(true, '恢复 $count 个文件', log);
    }
    add('❌ 未恢复任何文件');
    return RecoveryResult(false, '未恢复文件', log);
  }

  /// 用 photorec 检测镜像里的文件系统类型
  ///
  /// 用于判断：这个镜像是 ext4 还是 F2FS？能不能用 sleuthkit？
  Future<Map<String, dynamic>> detectFilesystem(String imagePath) async {
    final result = <String, dynamic>{};
    if (!await init()) return result;

    // 读镜像头部，看 magic
    try {
      final raf = await File(imagePath).open();
      await raf.setPosition(1024); // ext 超级块偏移
      final extMagic = await raf.read(2);
      await raf.close();

      // ext2/3/4 的 magic 是 0x53EF（小端 EF 53）
      if (extMagic.length == 2 && extMagic[0] == 0x53 && extMagic[1] == 0xEF) {
        result['fs'] = 'ext4';
        result['supportedBySleuthkit'] = true;
        result['note'] = '可用 sleuthkit 的 fls/icat 按 inode 提取';
        return result;
      }

      // F2FS 超级块在偏移 1024，magic 是 0xF2F52010
      final raf2 = await File(imagePath).open();
      await raf2.setPosition(1024);
      final f2fsMagic = await raf2.read(4);
      await raf2.close();

      if (f2fsMagic.length == 4 &&
          f2fsMagic[0] == 0x10 &&
          f2fsMagic[1] == 0x20 &&
          f2fsMagic[2] == 0xF5 &&
          f2fsMagic[3] == 0xF2) {
        result['fs'] = 'f2fs';
        result['supportedBySleuthkit'] = false;
        result['note'] = 'sleuthkit 不支持 F2FS，只能用 photorec 雕刻恢复';
        return result;
      }

      result['fs'] = 'unknown';
      result['supportedBySleuthkit'] = false;
      result['note'] = '未识别的文件系统';
    } catch (e) {
      result['error'] = '$e';
    }
    return result;
  }
}
