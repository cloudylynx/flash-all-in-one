import 'dart:io';
import 'dart:typed_data';

/// ARM64 内核镜像分析
///
/// 学习自 DualBootOneClick（岚启）的 InspectKernel：
/// ARM64 的 `b`（无条件跳转）指令编码是 `0x14000000 | imm26`，
/// 最高字节固定为 0x14。内核入口被改造成跳转桩后，前两条指令
/// 都会变成 `b`，这就是判断"有没有被注入过引导代码"的依据。
///
/// 支持的容器格式：
///   · 纯 ARM64 Image（Linux kernel Image，无头）
///   · 带 UNCOMPRESSED_IMG 头（offset 20 跳过 20 字节头）
///   · 带 EFI stub 头（开头是 "MZ"，PE 格式）
///   · arm64 boot header v0~v4 变体的 kernel 段
class KernelInspectService {
  KernelInspectService._();
  static final KernelInspectService instance = KernelInspectService._();

  /// ARM64 `b` 指令的最高字节
  static const int arm64BranchOpcode = 0x14;

  /// UNCOMPRESSED_IMG 魔数（Linux 压缩内核解压后的头）
  static const List<int> uncompressedImgMagic = [
    0x1f, 0x8b, 0x08, 0x00, // 实际是 gzip 头，这里仅占位
  ];

  /// PE 文件头 "MZ"
  static const int peMagicM = 0x4D;
  static const int peMagicZ = 0x5A;

  /// 分析内核镜像
  ///
  /// [path] 内核文件路径（kernel / Image / vmlinux 等）
  Future<KernelInfo?> inspect(String path) async {
    final f = File(path);
    if (!f.existsSync()) return null;

    final len = await f.length();
    if (len < 64) {
      return KernelInfo(
        path: path,
        size: len,
        format: KernelFormat.unknown,
        headerOffset: 0,
        patches: const [],
        canPatch: false,
        reason: '文件太小（$len 字节），不是有效内核',
      );
    }

    final raf = await f.open();
    try {
      await raf.setPosition(0);
      final head = await raf.read(128);
      if (head.length < 64) {
        return KernelInfo(
          path: path,
          size: len,
          format: KernelFormat.unknown,
          headerOffset: 0,
          patches: const [],
          canPatch: false,
          reason: '读取失败',
        );
      }

      return _analyze(path, len, head);
    } finally {
      await raf.close();
    }
  }

  KernelInfo _analyze(String path, int size, Uint8List head) {
    final patches = <KernelPatch>[];
    var format = KernelFormat.plainArm64;
    var headerOffset = 0;

    // ① 检查 EFI stub（"MZ" 开头，PE/COFF）
    if (head[0] == peMagicM && head[1] == peMagicZ) {
      format = KernelFormat.efiStub;
      // PE 头后面才是真正的 ARM64 代码，先不清跳，只标记
    }

    // ② 检查 arm64 boot header 的 magic
    //    arm64_image_header.magic = "ARM\x64" (0x644d5241) @ offset 56
    if (head.length >= 60) {
      final bd = ByteData.sublistView(head);
      final magic = bd.getUint32(56, Endian.little);
      if (magic == 0x644d5241) {
        // "ARMd" —— 这是标准 arm64 Image
        format = KernelFormat.arm64Image;
      }
    }

    // ③ 检查 UNCOMPRESSED_IMG（kernel 被解压过）
    //    某些工具会在前面加 20 字节头
    if (head.length >= 20) {
      // 检查 offset 20 处是不是有效指令
      // 简单判断：offset 0 的 4 字节如果是 0x00000000 或明显不像指令
      final w0 = ByteData.sublistView(head).getUint32(0, Endian.little);
      if (w0 == 0) {
        headerOffset = 20;
        format = KernelFormat.uncompressedImg;
      }
    }

    // ④ 核心：检测两条入口指令
    final off = headerOffset;
    if (off + 8 > head.length) {
      return KernelInfo(
        path: path,
        size: size,
        format: format,
        headerOffset: off,
        patches: const [],
        canPatch: false,
        reason: '头部不足 8 字节',
      );
    }

    final insn0 = ByteData.sublistView(head).getUint32(off, Endian.little);
    final insn1 = ByteData.sublistView(head).getUint32(off + 4, Endian.little);

    final isBranch0 = _isBranch(insn0);
    final isBranch1 = _isBranch(insn1);

    // 已打补丁 = 两条都是 b
    if (isBranch0 && isBranch1) {
      patches.add(KernelPatch(
        offset: off,
        original: insn0,
        patched: insn0,
        kind: KernelPatchKind.dualBoot,
        description: '入口两条都是跳转指令（典型双系统/引导注入特征）',
      ));
      return KernelInfo(
        path: path,
        size: size,
        format: format,
        headerOffset: off,
        patches: patches,
        canPatch: false,
        reason: '内核已被注入引导代码（两条都是 b），'
            '可尝试用新的 shellcode 重新打补丁，但风险较高',
        alreadyPatched: true,
      );
    }

    // 只有第二条是 b，第一条是 MZ 起始 → EFI stub 的正常形态
    final looksEfi = head[off] == peMagicM && head[off + 1] == peMagicZ;
    if (!isBranch0 && isBranch1 && looksEfi) {
      return KernelInfo(
        path: path,
        size: size,
        format: KernelFormat.efiStub,
        headerOffset: off,
        patches: patches,
        canPatch: true,
        reason: 'EFI stub 内核（正常形态），可以注入',
      );
    }

    // 第一条是 b，第二条不是 → 部分补丁？异常状态
    if (isBranch0 && !isBranch1) {
      return KernelInfo(
        path: path,
        size: size,
        format: format,
        headerOffset: off,
        patches: patches,
        canPatch: false,
        reason: '入口第一条是跳转但第二条不是，状态异常，不建议改动',
      );
    }

    // 两条都不是 b → 干净内核，可以打补丁
    return KernelInfo(
      path: path,
      size: size,
      format: format,
      headerOffset: off,
      patches: patches,
      canPatch: true,
      reason: '干净内核（入口无跳转指令），可以注入引导代码',
    );
  }

  /// 判断一条 ARM64 指令是不是 `b`（无条件跳转）
  ///
  /// `b` 的编码：bits[31:26] = 0b000101
  /// 即 `(insn & 0xFC000000) == 0x14000000`
  /// 简化判断：最高字节 == 0x14
  bool _isBranch(int insn) {
    return (insn >> 24) == arm64BranchOpcode;
  }

  /// 解析 `b` 指令的跳转目标（相对偏移）
  int branchTarget(int insn, int insnOffset) {
    if (!_isBranch(insn)) return -1;
    var imm26 = insn & 0x03FFFFFF;
    // 符号扩展（26 位有符号）
    if ((imm26 & 0x02000000) != 0) {
      imm26 = imm26 - 0x04000000;
    }
    final target = insnOffset + imm26 * 4;
    return target < 0 ? 0 : target;
  }

  /// 把一段字节解析成 ARM64 指令列表（粗略，只识别常见指令）
  List<String> disassemble(Uint8List data, {int start = 0, int count = 32}) {
    final out = <String>[];
    for (var i = 0; i < count; i++) {
      final off = start + i * 4;
      if (off + 4 > data.length) break;
      final insn = ByteData.sublistView(data).getUint32(off, Endian.little);
      out.add('0x${off.toRadixString(16).padLeft(4, '0')}  '
          '${insn.toRadixString(16).padLeft(8, '0')}  '
          '${_decode(insn, off)}');
    }
    return out;
  }

  String _decode(int insn, int off) {
    // b / bl
    if ((insn & 0xFC000000) == 0x14000000) {
      var imm26 = insn & 0x03FFFFFF;
      if ((imm26 & 0x02000000) != 0) imm26 -= 0x04000000;
      final t = off + imm26 * 4;
      return t >= 0 ? 'b 0x${t.toRadixString(16)}' : 'b 0x${t.toRadixString(16)}';
    }
    if ((insn & 0xFC000000) == 0x94000000) {
      var imm26 = insn & 0x03FFFFFF;
      if ((imm26 & 0x02000000) != 0) imm26 -= 0x04000000;
      return 'bl 0x${(off + imm26 * 4).toRadixString(16)}';
    }
    // movz
    if ((insn & 0xFFC00000) == 0xD2800000) {
      final rd = insn & 0x1F;
      final imm = (insn >> 5) & 0xFFFF;
      return 'mov x$rd, #0x${imm.toRadixString(16)}';
    }
    // movk
    if ((insn & 0xFFC00000) == 0xF2800000) {
      final rd = insn & 0x1F;
      final imm = (insn >> 5) & 0xFFFF;
      return 'movk x$rd, #0x${imm.toRadixString(16)}, lsl 16';
    }
    if (insn == 0xD503201F) return 'nop';
    if (insn == 0xD65F03C0) return 'ret';
    if ((insn & 0xFFFFFC1F) == 0xD61F0000) {
      return 'br x${(insn >> 5) & 0x1F}';
    }
    if ((insn & 0xFFFFFC1F) == 0xD63F0000) {
      return 'blr x${(insn >> 5) & 0x1F}';
    }
    if ((insn & 0xFFC00000) == 0xB9400000) {
      return 'ldr w${insn & 0x1F}, [x${(insn >> 5) & 0x1F}]';
    }
    if ((insn & 0xFFC00000) == 0xB9000000) {
      return 'str w${insn & 0x1F}, [x${(insn >> 5) & 0x1F}]';
    }
    return '.word 0x${insn.toRadixString(16).padLeft(8, '0')}';
  }

  /// 生成可读报告
  String formatReport(KernelInfo info) {
    final sb = StringBuffer();
    sb.writeln('══ 内核分析');
    sb.writeln('');
    sb.writeln('  文件: ${info.path.split(Platform.pathSeparator).last}');
    final mb = info.size / 1024 / 1024;
    sb.writeln('  大小: ${mb.toStringAsFixed(2)} MB');
    sb.writeln('  格式: ${info.format.label}');
    if (info.headerOffset > 0) {
      sb.writeln('  头部: 跳过 ${info.headerOffset} 字节');
    }
    sb.writeln('');
    sb.writeln('  ${info.canPatch ? "✅" : "⚠️"} ${info.reason}');
    if (info.patches.isNotEmpty) {
      sb.writeln('');
      sb.writeln('  检测到的补丁:');
      for (final p in info.patches) {
        sb.writeln('    · ${p.description}');
        sb.writeln('      @0x${p.offset.toRadixString(16)}: '
            '0x${p.original.toRadixString(16).padLeft(8, '0')}');
      }
    }
    return sb.toString();
  }
}

/// 内核容器格式
enum KernelFormat {
  /// 纯 ARM64 Image（无头）
  plainArm64('ARM64 Image'),

  /// 标准 arm64_image_header
  arm64Image('arm64 标准头'),

  /// 前面有 20 字节头的解压内核
  uncompressedImg('UNCOMPRESSED_IMG'),

  /// EFI stub（PE/COFF，"MZ" 开头）
  efiStub('EFI stub'),

  unknown('未知');

  final String label;
  const KernelFormat(this.label);
}

/// 检测到的一处补丁
class KernelPatch {
  final int offset;
  final int original;
  final int patched;
  final KernelPatchKind kind;
  final String description;

  KernelPatch({
    required this.offset,
    required this.original,
    required this.patched,
    required this.kind,
    required this.description,
  });
}

enum KernelPatchKind {
  /// 双系统 / UEFI 引导注入
  dualBoot('双系统注入'),

  /// Magisk root 补丁（不改入口，改 ramdisk）
  magisk('Magisk'),

  /// 未知
  unknown('未知');

  final String label;
  const KernelPatchKind(this.label);
}

/// 内核分析结果
class KernelInfo {
  final String path;
  final int size;
  final KernelFormat format;
  final int headerOffset;
  final List<KernelPatch> patches;
  final bool canPatch;
  final String reason;

  /// 是否已被打过补丁
  final bool alreadyPatched;

  KernelInfo({
    required this.path,
    required this.size,
    required this.format,
    required this.headerOffset,
    required this.patches,
    required this.canPatch,
    required this.reason,
    this.alreadyPatched = false,
  });
}
