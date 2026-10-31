import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';

/// Val Protocol 结果
class ValResult {
  final bool ok;
  final String message;
  ValResult(this.ok, this.message);
}

/// Val Protocol 服务（摩托罗拉 MTK 设备解锁）
///
/// 来源：Maikyxd/val-protocol (96★, AGPL-3.0)
///
/// 原理：
///   摩托罗拉 MTK 设备的 LK（bootloader）里存在证书校验缺陷。
///   Val Protocol 通过修补 LK 镜像实现：
///     · 绕过 fastboot 解锁校验
///     · 移除 FRP（恢复出厂保护）
///     · 添加自定义 fastboot 命令
///
/// 流程：
///   1. dump LK 分区
///   2. lk_keygen.py 生成密钥
///   3. lk_auto_patch.py 打补丁
///   4. lk_repack_signed.py 重签名
///   5. 写回 LK 分区
class ValProtocolService {
  ValProtocolService._();
  static final ValProtocolService instance = ValProtocolService._();

  String? _python;
  String? _toolDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    // 1. 找 Python
    for (final cmd in ['python', 'python3', 'py']) {
      try {
        final r = await ProcessRunner.run(cmd, ['--version'],
            timeout: const Duration(seconds: 5));
        if (r.output.contains('Python 3')) {
          _python = cmd;
          break;
        }
      } catch (_) {}
    }
    if (_python == null) {
      _available = false;
      return false;
    }

    // 2. 找 val-protocol 目录
    for (final sub in ['tools/val-protocol', 'tools/val_protocol']) {
      final dir = p.join(AppConfig.exeDir, sub);
      if (File(p.join(dir, 'lk_auto_patch.py')).existsSync()) {
        _toolDir = dir;
        _available = true;
        return true;
      }
    }

    _available = false;
    return false;
  }

  /// 版本信息
  Future<String> describe() async {
    if (!await init()) {
      return '未就绪：需要 Python 3 + val-protocol 脚本（tools/val-protocol/）';
    }
    return 'val-protocol 就绪（$_python）';
  }

  /// 生成密钥
  Future<ValResult> generateKey({
    required String outputPath,
    String? deviceId,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return ValResult(false, 'val-protocol 未就绪');
    }

    final args = <String>['lk_keygen.py'];
    if (deviceId != null && deviceId.isNotEmpty) {
      args.addAll(['--device-id', deviceId]);
    }
    args.addAll(['-o', outputPath]);

    onLine?.call('══ 生成密钥: $outputPath');
    final code = await ProcessRunner.stream(
      _python!,
      args,
      onLine: onLine ?? (_) {},
      workingDirectory: _toolDir,
      timeout: const Duration(minutes: 2),
    );

    if (code == 0 && File(outputPath).existsSync()) {
      return ValResult(true, '密钥已生成: $outputPath');
    }
    return ValResult(false, '密钥生成失败（退出码 $code）');
  }

  /// 打补丁
  Future<ValResult> autoPatch({
    required String lkImage,
    String? outputImage,
    String? keyFile,
    bool skipKeyValidator = false,
    String? frpValue,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return ValResult(false, 'val-protocol 未就绪');
    }
    if (!File(lkImage).existsSync()) {
      return ValResult(false, 'LK 镜像不存在: $lkImage');
    }

    final out = outputImage ??
        p.join(p.dirname(lkImage), '${p.basenameWithoutExtension(lkImage)}.patched.img');

    final args = <String>['lk_auto_patch.py', lkImage, '-o', out];
    if (keyFile != null && keyFile.isNotEmpty) {
      args.addAll(['--key-file', keyFile]);
    }
    if (skipKeyValidator) {
      args.add('--no-key-validator');
    }
    if (frpValue != null) {
      args.addAll(['--frp-value', frpValue]);
    }

    onLine?.call('══ 打补丁: ${p.basename(lkImage)}');
    onLine?.call('  输出: $out');

    final code = await ProcessRunner.stream(
      _python!,
      args,
      onLine: onLine ?? (_) {},
      workingDirectory: _toolDir,
      timeout: const Duration(minutes: 5),
    );

    if (code == 0 && File(out).existsSync()) {
      final sz = File(out).lengthSync();
      return ValResult(true, '补丁完成: $out (${(sz / 1024 / 1024).toStringAsFixed(2)} MB)');
    }
    return ValResult(false, '打补丁失败（退出码 $code）');
  }

  /// 重签名
  Future<ValResult> repackSigned({
    required String patchedImage,
    String? outputImage,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return ValResult(false, 'val-protocol 未就绪');
    }

    final out = outputImage ??
        p.join(p.dirname(patchedImage),
            '${p.basenameWithoutExtension(patchedImage)}.signed.img');

    onLine?.call('══ 重签名');
    final code = await ProcessRunner.stream(
      _python!,
      ['lk_repack_signed.py', patchedImage, '-o', out],
      onLine: onLine ?? (_) {},
      workingDirectory: _toolDir,
      timeout: const Duration(minutes: 3),
    );

    if (code == 0 && File(out).existsSync()) {
      return ValResult(true, '重签名完成: $out');
    }
    return ValResult(false, '重签名失败（退出码 $code）');
  }

  /// 完整流程（打补丁 + 重签名）
  Future<ValResult> fullFlow({
    required String lkImage,
    String? keyFile,
    void Function(String line)? onLine,
  }) async {
    final patchResult = await autoPatch(
      lkImage: lkImage,
      keyFile: keyFile,
      onLine: onLine,
    );
    if (!patchResult.ok) return patchResult;

    // 从 message 里提取输出路径
    final patchedPath = patchResult.message.split(': ').last.split(' (')[0];

    final signResult = await repackSigned(
      patchedImage: patchedPath,
      onLine: onLine,
    );
    if (!signResult.ok) return signResult;

    return ValResult(
        true, '完整流程完成\n补丁: $patchedPath\n签名: ${signResult.message}');
  }
}
