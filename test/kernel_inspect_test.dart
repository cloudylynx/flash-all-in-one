// ARM64 内核入口补丁检测测试
//
// 原理：ARM64 的 b 指令编码是 0x14000000 | imm26，最高字节固定 0x14。
// 内核入口被改成跳转桩后，前两条指令都会是 b。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flashallinone/services/kernel_inspect_service.dart';

void main() {
  final svc = KernelInspectService.instance;

  /// 造一个假的 ARM64 内核文件
  Future<File> makeKernel(List<int> firstInstructions,
      {int totalSize = 4096}) async {
    final bytes = <int>[];
    for (final insn in firstInstructions) {
      // 小端写入
      bytes.addAll([
        insn & 0xFF,
        (insn >> 8) & 0xFF,
        (insn >> 16) & 0xFF,
        (insn >> 24) & 0xFF,
      ]);
    }
    while (bytes.length < totalSize) {
      bytes.add(0);
    }
    final f = File(
        '${Directory.systemTemp.path}/kernel_test_${DateTime.now().microsecondsSinceEpoch}.img');
    await f.writeAsBytes(bytes);
    return f;
  }

  group('指令识别', () {
    test('0x14 开头是 b 指令', () {
      // b +0x40 = 0x14000010
      expect(svc.branchTarget(0x14000010, 0), 0x40);
    });

    test('非 b 指令返回 -1', () {
      // mov x0, xzr = 0xD2800000
      expect(svc.branchTarget(0xD2800000, 0), -1);
    });

    test('负偏移的 b 指令', () {
      // b -4 (imm26 = 0x3FFFFFF)
      expect(svc.branchTarget(0x17FFFFFF, 0x100), isNonNegative);
    });
  });

  group('干净内核', () {
    test('两条都不是 b → 可注入', () async {
      // mov x0, xzr; mov x1, xzr
      final f = await makeKernel([0xD2800000, 0xD2800021]);
      try {
        final info = await svc.inspect(f.path);
        expect(info, isNotNull);
        expect(info!.canPatch, isTrue);
        expect(info.alreadyPatched, isFalse);
        expect(info.patches, isEmpty);
        expect(info.reason, contains('干净'));
      } finally {
        f.deleteSync();
      }
    });
  });

  group('已注入内核', () {
    test('两条都是 b → 检测到注入', () async {
      // b +0x40; b +0x04
      final f = await makeKernel([0x14000010, 0x14000001]);
      try {
        final info = await svc.inspect(f.path);
        expect(info, isNotNull);
        expect(info!.alreadyPatched, isTrue);
        expect(info.canPatch, isFalse);
        expect(info.patches, isNotEmpty);
        expect(info.patches.first.kind, KernelPatchKind.dualBoot);
        expect(info.reason, contains('注入'));
      } finally {
        f.deleteSync();
      }
    });
  });

  group('异常状态', () {
    test('只有第一条是 b → 拒绝改动', () async {
      // b +0x40; mov x1, xzr
      final f = await makeKernel([0x14000010, 0xD2800021]);
      try {
        final info = await svc.inspect(f.path);
        expect(info, isNotNull);
        expect(info!.canPatch, isFalse);
        expect(info.alreadyPatched, isFalse);
        expect(info.reason, contains('异常'));
      } finally {
        f.deleteSync();
      }
    });
  });

  group('边界情况', () {
    test('文件不存在返回 null', () async {
      expect(await svc.inspect('/nonexistent/kernel'), isNull);
    });

    test('太小的文件返回不可注入', () async {
      final f = File('${Directory.systemTemp.path}/tiny_kernel.img');
      await f.writeAsBytes(List.filled(10, 0));
      try {
        final info = await svc.inspect(f.path);
        expect(info, isNotNull);
        expect(info!.canPatch, isFalse);
        expect(info.reason, contains('太小'));
      } finally {
        f.deleteSync();
      }
    });

    test('空文件不崩', () async {
      final f = File('${Directory.systemTemp.path}/empty_kernel.img');
      await f.writeAsBytes([]);
      try {
        final info = await svc.inspect(f.path);
        expect(info, isNotNull);
        expect(info!.canPatch, isFalse);
      } finally {
        f.deleteSync();
      }
    });
  });

  group('真实 shellcode（岚启样本）', () {
    test('ShellCode.Cepheus.bin 识别为已注入', () async {
      const path =
          '/home/justinlee/data2/dev/reference-src/lanqi-dualboot/shellcodes/ShellCode.Cepheus.bin';
      if (!File(path).existsSync()) {
        return; // 样本不在就跳过
      }
      final info = await svc.inspect(path);
      expect(info, isNotNull);
      expect(info!.alreadyPatched, isTrue);
      expect(info.patches.first.original, 0x14000010);
    });
  });

  group('反汇编', () {
    test('能解出 mov / movk', () async {
      final f = await makeKernel([0xD2820004, 0xF2A072C4]);
      try {
        final data = await f.readAsBytes();
        final lines = svc.disassemble(data, start: 0, count: 2);
        expect(lines.length, 2);
        expect(lines[0], contains('mov'));
        expect(lines[1], contains('movk'));
      } finally {
        f.deleteSync();
      }
    });

    test('能解出 b 指令', () async {
      final f = await makeKernel([0x14000010]);
      try {
        final data = await f.readAsBytes();
        final lines = svc.disassemble(data, start: 0, count: 1);
        expect(lines.first, contains('b 0x40'));
      } finally {
        f.deleteSync();
      }
    });

    test('能解出 ret / nop', () async {
      final f = await makeKernel([0xD65F03C0, 0xD503201F]);
      try {
        final data = await f.readAsBytes();
        final lines = svc.disassemble(data, start: 0, count: 2);
        expect(lines[0], contains('ret'));
        expect(lines[1], contains('nop'));
      } finally {
        f.deleteSync();
      }
    });

    test('未知指令输出 .word', () async {
      final f = await makeKernel([0xDEADBEEF]);
      try {
        final data = await f.readAsBytes();
        final lines = svc.disassemble(data, start: 0, count: 1);
        expect(lines.first, contains('.word'));
      } finally {
        f.deleteSync();
      }
    });
  });

  group('格式识别', () {
    test('普通 ARM64 Image', () async {
      final f = await makeKernel([0xD2800000, 0xD2800021]);
      try {
        final info = await svc.inspect(f.path);
        expect(info!.format, isNotNull);
      } finally {
        f.deleteSync();
      }
    });

    test('EFI stub（MZ 开头）', () async {
      // 0x5A4D = "MZ" 小端
      final f = await makeKernel([0x00005A4D]);
      try {
        final info = await svc.inspect(f.path);
        expect(info, isNotNull);
        expect(info!.format, KernelFormat.efiStub);
      } finally {
        f.deleteSync();
      }
    });
  });
}
