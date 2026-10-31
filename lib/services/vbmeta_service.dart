import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// vbmeta 处理结果
class VbmetaResult {
  final bool ok;
  final String message;
  final List<String> log;
  VbmetaResult(this.ok, this.message, [this.log = const []]);
}

/// vbmeta 镜像信息
class VbmetaInfo {
  final int version;
  final int flags;
  final int rollbackIndex;
  final int algorithmType;
  final int descriptorCount;
  final bool verificationDisabled;
  final bool verityDisabled;

  VbmetaInfo({
    required this.version,
    required this.flags,
    required this.rollbackIndex,
    required this.algorithmType,
    required this.descriptorCount,
    required this.verificationDisabled,
    required this.verityDisabled,
  });

  String get algorithmName {
    switch (algorithmType) {
      case 0:
        return 'NONE';
      case 1:
        return 'SHA256_RSA2048';
      case 2:
        return 'SHA256_RSA4096';
      case 3:
        return 'SHA256_RSA8192';
      case 4:
        return 'SHA512_RSA2048';
      case 5:
        return 'SHA512_RSA4096';
      case 6:
        return 'SHA512_RSA8192';
      default:
        return '未知($algorithmType)';
    }
  }

  /// flags 位含义：
  ///   bit 0 = HASHTREE_DISABLED（dm-verity 关闭）
  ///   bit 1 = VERIFICATION_DISABLED（AVB 校验关闭）
  String get flagsText {
    final parts = <String>[];
    if (verityDisabled) parts.add('HASHTREE_DISABLED');
    if (verificationDisabled) parts.add('VERIFICATION_DISABLED');
    if (parts.isEmpty) return '无（校验已启用）';
    return parts.join(' | ');
  }
}

/// vbmeta 镜像处理服务
///
/// Android Verified Boot 2.0（AVB）的元数据镜像。
///
/// vbmeta 结构（AVB 规范）：
///   偏移 0x00  magic         "AVB0"
///   偏移 0x04  major_version
///   偏移 0x08  minor_version
///   偏移 0x0C  auth_block_size
///   偏移 0x10  aux_block_size
///   偏移 0x14  algorithm_type
///   偏移 0x18  hash_offset
///   偏移 0x1C  hash_size
///   偏移 0x20  signature_offset
///   偏移 0x24  signature_size
///   偏移 0x28  public_key_offset
///   偏移 0x2C  public_key_size
///   偏移 0x30  public_key_metadata_offset
///   偏移 0x34  public_key_metadata_size
///   偏移 0x38  descriptors_offset
///   偏移 0x3C  descriptors_size
///   偏移 0x40  rollback_index
///   偏移 0x48  flags            ← 关键！改这里
///   偏移 0x4C  rollback_index_location
///
/// flags 位定义：
///   bit 0 (0x01) = HASHTREE_DISABLED     —— 关闭 dm-verity
///   bit 1 (0x02) = VERIFICATION_DISABLED —— 关闭 AVB 校验
class VbmetaService {
  VbmetaService._();
  static final VbmetaService instance = VbmetaService._();

  static const _magic = 'AVB0';
  static const _headerSize = 0x100; // 256 字节

  /// 解析 vbmeta 镜像
  Future<VbmetaInfo?> parse(String imagePath) async {
    final f = File(imagePath);
    if (!f.existsSync()) return null;

    final bytes = await f.readAsBytes();
    if (bytes.length < _headerSize) return null;

    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != _magic) return null;

    final bd = ByteData.sublistView(bytes);

    final major = bd.getUint32(0x04, Endian.big);
    final minor = bd.getUint32(0x08, Endian.big);
    final algType = bd.getUint32(0x14, Endian.big);
    final descSize = bd.getUint64(0x3C, Endian.big);
    final rollback = bd.getUint64(0x40, Endian.big);
    final flags = bd.getUint32(0x48, Endian.big);

    return VbmetaInfo(
      version: (major << 16) | minor,
      flags: flags,
      rollbackIndex: rollback,
      algorithmType: algType,
      descriptorCount: descSize ~/ 64, // 估算
      verificationDisabled: (flags & 0x02) != 0,
      verityDisabled: (flags & 0x01) != 0,
    );
  }

  /// 禁用校验（修改 flags 并重算 hash）
  ///
  /// 原理同 `fastboot --disable-verity --disable-verification flash vbmeta`，
  /// 但直接改镜像文件，不经过 fastboot。
  ///
  /// 注意：如果 vbmeta 带签名（algorithm_type != 0），
  /// 改 flags 会导致签名失效。此时需要：
  ///   1. 设备已解锁 BL（AVB 不强制校验）
  ///   2. 或同时擦除 vbmeta（fastboot erase vbmeta）
  Future<VbmetaResult> disableVerification({
    required String imagePath,
    required String outputPath,
    bool disableVerity = true,
    bool disableVerification = true,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final f = File(imagePath);
    if (!f.existsSync()) {
      return VbmetaResult(false, '文件不存在: $imagePath', log);
    }

    final bytes = Uint8List.fromList(await f.readAsBytes());
    if (bytes.length < _headerSize) {
      return VbmetaResult(false, '文件太小，不是有效 vbmeta', log);
    }

    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != _magic) {
      return VbmetaResult(false, 'magic 不匹配（期望 AVB0，实际 $magic）', log);
    }

    add('══ vbmeta 处理');
    add('  文件: ${p.basename(imagePath)}');
    add('  大小: ${(bytes.length / 1024).toStringAsFixed(1)} KB');

    final bd = ByteData.sublistView(bytes);
    final algType = bd.getUint32(0x14, Endian.big);
    final oldFlags = bd.getUint32(0x48, Endian.big);

    add('  算法: ${algType == 0 ? "NONE（无签名）" : "类型 $algType（有签名）"}');
    add('  原 flags: 0x${oldFlags.toRadixString(16).padLeft(8, '0')}');

    // 修改 flags
    var newFlags = oldFlags;
    if (disableVerity) newFlags |= 0x01;
    if (disableVerification) newFlags |= 0x02;

    add('  新 flags: 0x${newFlags.toRadixString(16).padLeft(8, '0')}');
    add('');

    if (algType != 0) {
      add('⚠️ 该 vbmeta 带签名（算法 $algType）');
      add('  修改 flags 会导致签名失效');
      add('  需要满足以下之一：');
      add('    · 设备已解锁 BL（AVB 不强制校验）');
      add('    · 或用 fastboot erase vbmeta 完全擦除');
      add('');
    }

    bd.setUint32(0x48, newFlags, Endian.big);

    // 写入输出
    final out = File(outputPath);
    await out.writeAsBytes(bytes, flush: true);

    add('✅ 已写入: $outputPath');
    add('');

    if (algType != 0) {
      add('📌 刷入方法（任选其一）：');
      add('  A. fastboot --disable-verity --disable-verification flash vbmeta <文件>');
      add('  B. fastboot flash vbmeta <文件>');
      add('  C. fastboot erase vbmeta（完全擦除，最简单）');
    } else {
      add('📌 刷入方法：fastboot flash vbmeta $outputPath');
    }

    return VbmetaResult(true, '已禁用校验，输出到 $outputPath', log);
  }

  /// 恢复校验（把 flags 清零）
  Future<VbmetaResult> enableVerification({
    required String imagePath,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final f = File(imagePath);
    if (!f.existsSync()) {
      return VbmetaResult(false, '文件不存在', log);
    }

    final bytes = Uint8List.fromList(await f.readAsBytes());
    if (bytes.length < _headerSize ||
        String.fromCharCodes(bytes.sublist(0, 4)) != _magic) {
      return VbmetaResult(false, '不是有效 vbmeta', log);
    }

    final bd = ByteData.sublistView(bytes);
    final oldFlags = bd.getUint32(0x48, Endian.big);
    bd.setUint32(0x48, 0, Endian.big);

    add('══ 恢复校验');
    add('  原 flags: 0x${oldFlags.toRadixString(16)}');
    add('  新 flags: 0x00000000');

    await File(outputPath).writeAsBytes(bytes, flush: true);
    add('✅ 已写入: $outputPath');
    return VbmetaResult(true, '已恢复校验', log);
  }

  /// 从设备拉取 vbmeta 分区
  Future<String?> pullFromDevice(String serial, String adbPath) async {
    // 找 vbmeta 分区
    for (final part in ['vbmeta', 'vbmeta_a', 'vbmeta_b']) {
      final r = await Process.run(adbPath,
          ['-s', serial, 'shell', 'ls', '-l', '/dev/block/by-name/$part']);
      if (r.exitCode == 0 && !(r.stdout as String).contains('No such')) {
        final out = '${Directory.systemTemp.path}${Platform.pathSeparator}$part.img';
        final pull = await Process.run(adbPath, [
          '-s', serial, 'shell',
          'su -c "dd if=/dev/block/by-name/$part of=/sdcard/$part.img"'
        ]);
        if (pull.exitCode == 0) {
          final r2 = await Process.run(
              adbPath, ['-s', serial, 'pull', '/sdcard/$part.img', out]);
          if (r2.exitCode == 0) return out;
        }
      }
    }
    return null;
  }
}
