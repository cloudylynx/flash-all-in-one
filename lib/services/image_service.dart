import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 镜像格式
enum ImageFormat {
  erofs('erofs', 'EROFS', 'Android 11+ 常用只读文件系统'),
  ext4('ext4', 'ext4', '传统 Linux 文件系统'),
  sparse('sparse', 'Sparse', 'Android 稀疏镜像'),
  raw('raw', 'Raw', '原始镜像'),
  boot('boot', 'Boot', '启动镜像（含 kernel + ramdisk）'),
  unknown('unknown', '未知', '');

  final String id;
  final String label;
  final String desc;
  const ImageFormat(this.id, this.label, this.desc);
}

/// 解包结果
class ImageResult {
  final bool ok;
  final String message;
  final List<String> log;
  ImageResult(this.ok, this.message, [this.log = const []]);
}

/// Android 镜像解包/重打包服务
///
/// 技术来源：DNA-NEXT 工具箱
///
/// 工具链：
///   extract.erofs / dump.erofs / mkfs.erofs / fsck.erofs  —— EROFS 全套
///   e2fsdroid                                            —— ext4 打包
///   simg2img / img2simg / ext2simg                       —— sparse 转换
///   magiskboot                                            —— boot 镜像
///
/// 支持流程：
///   super.img → 拆出各分区 → 解包 EROFS/ext4 → 修改 → 重打包 → 合成 super
class ImageService {
  ImageService._();
  static final ImageService instance = ImageService._();

  String? _toolsDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 工具名 → 可执行文件名
  static const _tools = {
    'extract.erofs': 'extract.erofs',
    'dump.erofs': 'dump.erofs',
    'mkfs.erofs': 'mkfs.erofs',
    'fsck.erofs': 'fsck.erofs',
    'e2fsdroid': 'e2fsdroid',
    'simg2img': 'simg2img',
    'img2simg': 'img2simg',
    'ext2simg': 'ext2simg',
    'magiskboot': 'magiskboot',
  };

  /// 初始化
  Future<bool> init() async {
    // 1. 应用目录
    for (final sub in ['tools/dna', 'tools/img', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = Platform.isWindows ? 'extract.erofs.exe' : 'extract.erofs';
      if (File(p.join(dir, exe)).existsSync()) {
        _toolsDir = dir;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取（img 目录里所有工具）
    try {
      final dataDir = await getApplicationSupportDirectory();
      final toolsDir = Directory(p.join(dataDir.path, 'tools', 'img'));
      if (!toolsDir.existsSync()) toolsDir.createSync(recursive: true);

      const assetFiles = [
        'extract.erofs.exe',
        'mkfs.erofs.exe',
        'dump.erofs.exe',
        'fsck.erofs.exe',
        'e2fsdroid.exe',
        'simg2img.exe',
        'img2simg.exe',
        'ext2simg.exe',
        'lpmake.exe',
      ];

      var extracted = 0;
      for (final f in assetFiles) {
        try {
          final target = File(p.join(toolsDir.path, f));
          if (!target.existsSync()) {
            final data = await rootBundle.load('assets/tools/windows/img/$f');
            await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
          }
          extracted++;
        } catch (_) {}
      }

      if (extracted > 0) {
        _toolsDir = toolsDir.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  /// 找某个工具
  String? toolPath(String name) {
    if (_toolsDir == null) return null;
    final exe = Platform.isWindows ? '$name.exe' : name;
    final path = p.join(_toolsDir!, exe);
    return File(path).existsSync() ? path : null;
  }

  /// 可用工具清单
  List<String> get availableTools {
    final result = <String>[];
    for (final name in _tools.keys) {
      if (toolPath(name) != null) result.add(name);
    }
    return result;
  }

  /// 探测镜像格式（读魔数）
  Future<ImageFormat> detectFormat(String imagePath) async {
    final f = File(imagePath);
    if (!f.existsSync()) return ImageFormat.unknown;

    final raf = await f.open();
    final header = await raf.read(4096);
    await raf.close();

    if (header.length < 16) return ImageFormat.unknown;

    // Android sparse: magic 0xED26FF3A
    if (header[0] == 0x3A && header[1] == 0xFF &&
        header[2] == 0x26 && header[3] == 0xED) {
      return ImageFormat.sparse;
    }

    // EROFS: magic 0xE0F5E1E2 @ offset 1024
    if (header.length > 1028) {
      if (header[1024] == 0xE2 && header[1025] == 0xE1 &&
          header[1026] == 0xF5 && header[1027] == 0xE0) {
        return ImageFormat.erofs;
      }
    }

    // ext4: magic 0xEF53 @ offset 1080
    if (header.length > 1082) {
      if (header[1080] == 0x53 && header[1081] == 0xEF) {
        return ImageFormat.ext4;
      }
    }

    // Android boot: magic "ANDROID!"
    final magic = String.fromCharCodes(header.sublist(0, 8));
    if (magic == 'ANDROID!') return ImageFormat.boot;

    return ImageFormat.raw;
  }

  /// 转换 sparse → raw
  Future<ImageResult> simg2img({
    required String sparsePath,
    required String rawPath,
    void Function(String line)? onLine,
  }) async {
    final tool = toolPath('simg2img');
    if (tool == null) return ImageResult(false, 'simg2img 未找到');

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ Sparse → Raw');
    add('  ${p.basename(sparsePath)}');

    final code = await ProcessRunner.stream(
      tool,
      [sparsePath, rawPath],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    if (code == 0 && File(rawPath).existsSync()) {
      final sz = File(rawPath).lengthSync();
      add('✅ 转换完成: ${(sz / 1024 / 1024).toStringAsFixed(1)} MB');
      return ImageResult(true, rawPath, log);
    }
    return ImageResult(false, '转换失败（退出码 $code）', log);
  }

  /// 转换 raw → sparse
  Future<ImageResult> img2simg({
    required String rawPath,
    required String sparsePath,
    void Function(String line)? onLine,
  }) async {
    final tool = toolPath('img2simg');
    if (tool == null) return ImageResult(false, 'img2simg 未找到');

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ Raw → Sparse');
    final code = await ProcessRunner.stream(
      tool,
      [rawPath, sparsePath],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    if (code == 0 && File(sparsePath).existsSync()) {
      final sz = File(sparsePath).lengthSync();
      add('✅ 转换完成: ${(sz / 1024 / 1024).toStringAsFixed(1)} MB');
      return ImageResult(true, sparsePath, log);
    }
    return ImageResult(false, '转换失败（退出码 $code）', log);
  }

  /// 解包 EROFS
  Future<ImageResult> extractErofs({
    required String imagePath,
    required String outDir,
    void Function(String line)? onLine,
  }) async {
    final tool = toolPath('extract.erofs');
    if (tool == null) return ImageResult(false, 'extract.erofs 未找到');

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    Directory(outDir).createSync(recursive: true);
    add('══ 解包 EROFS');
    add('  ${p.basename(imagePath)} → $outDir');

    final code = await ProcessRunner.stream(
      tool,
      ['-i', imagePath, '-x', outDir],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('✅ 解包完成');
      return ImageResult(true, outDir, log);
    }
    return ImageResult(false, '解包失败（退出码 $code）', log);
  }

  /// 打包 EROFS
  Future<ImageResult> packErofs({
    required String srcDir,
    required String outImage,
    void Function(String line)? onLine,
  }) async {
    final tool = toolPath('mkfs.erofs');
    if (tool == null) return ImageResult(false, 'mkfs.erofs 未找到');

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 打包 EROFS');
    final code = await ProcessRunner.stream(
      tool,
      ['-z', 'lz4', outImage, srcDir],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0 && File(outImage).existsSync()) {
      final sz = File(outImage).lengthSync();
      add('✅ 打包完成: ${(sz / 1024 / 1024).toStringAsFixed(1)} MB');
      return ImageResult(true, outImage, log);
    }
    return ImageResult(false, '打包失败（退出码 $code）', log);
  }

  /// 检查 EROFS 镜像完整性
  Future<ImageResult> fsckErofs({
    required String imagePath,
    void Function(String line)? onLine,
  }) async {
    final tool = toolPath('fsck.erofs');
    if (tool == null) return ImageResult(false, 'fsck.erofs 未找到');

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ EROFS 完整性检查');
    final code = await ProcessRunner.stream(
      tool,
      ['--extract=$imagePath', imagePath],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    return ImageResult(code == 0, code == 0 ? '镜像正常' : '发现错误', log);
  }

  /// 列出 super.img 里的分区
  ///
  /// super.img 是 Android 动态分区容器，格式：
  ///   头部 metadata（geometry + 分区表） + 各分区数据
  Future<List<String>> listSuperPartitions(String superPath) async {
    final result = <String>[];
    final f = File(superPath);
    if (!f.existsSync()) return result;

    // 读前 4KB 找 metadata
    final raf = await f.open();
    final header = await raf.read(8192);
    await raf.close();

    // super 的 magic 是 0x616C6162 ("bal" 小端) @ offset 4096
    if (header.length > 4100) {
      final magic = header[4096] | (header[4097] << 8) |
          (header[4098] << 16) | (header[4099] << 24);
      if (magic != 0x616C6162) return result;
    }

    // 简化：只报告识别成功，完整解析需要 lpmake/lpunpack
    result.add('super.img 已识别（Android 动态分区）');
    result.add('完整解析需要 lpunpack 工具');
    return result;
  }
}
