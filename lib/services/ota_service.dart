import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// OTA 操作结果
class OtaResult {
  final bool ok;
  final String message;
  final List<String> log;
  OtaResult(this.ok, this.message, [this.log = const []]);
}

/// OTA 造包与重签服务
///
/// 技术来源：
///   · rhythmcache/payload_packer（19★，Apache-2.0）—— 生成 payload.bin
///   · chenxiaolong/avbroot（982★，GPL-3.0）—— AVB/OTA 重签 + Magisk 注入
///
/// 这两个是互补的：
///   payload_packer 造 payload.bin（全量/增量）
///   avbroot 签 AVB/OTA（用自己密钥）
class OtaService {
  OtaService._();
  static final OtaService instance = OtaService._();

  String? _packerPath;
  String? _avbrootPath;
  bool _available = false;

  bool get isAvailable => _available;
  bool get hasPacker => _packerPath != null;
  bool get hasAvbroot => _avbrootPath != null;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    final exeSuffix = Platform.isWindows ? '.exe' : '';

    // payload_packer
    _packerPath = await ToolExtractor.extractFile(
      assetPath:
          'assets/tools/${Platform.isWindows ? "windows" : "linux"}/ota/payload_packer$exeSuffix',
      subDir: 'ota',
      fileName: 'payload_packer$exeSuffix',
      executable: true,
    );

    // avbroot
    _avbrootPath = await ToolExtractor.extractFile(
      assetPath:
          'assets/tools/${Platform.isWindows ? "windows" : "linux"}/ota/avbroot$exeSuffix',
      subDir: 'ota',
      fileName: 'avbroot$exeSuffix',
      executable: true,
    );

    _available = _packerPath != null || _avbrootPath != null;
    return _available;
  }

  /// payload_packer 版本
  Future<String?> packerVersion() async {
    if (!await init() || _packerPath == null) return null;
    final r = await ProcessRunner.run(_packerPath!, ['--version'],
        timeout: AppConfig.shortTimeout);
    final m = RegExp(r'([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// avbroot 版本
  Future<String?> avbrootVersion() async {
    if (!await init() || _avbrootPath == null) return null;
    final r = await ProcessRunner.run(_avbrootPath!, ['--version'],
        timeout: AppConfig.shortTimeout);
    final m = RegExp(r'avbroot\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 生成全量 payload.bin
  ///
  /// [targetDir] 包含所有新 .img 文件的目录
  /// [output] 输出 payload.bin 路径
  Future<OtaResult> packFull({
    required String targetDir,
    required String output,
    List<String>? partitions,
    String compression = 'xz',
    int level = 6,
    void Function(String line)? onLine,
  }) async {
    return _runPacker(
      targetDir: targetDir,
      output: output,
      partitions: partitions,
      compression: compression,
      level: level,
      delta: false,
      onLine: onLine,
    );
  }

  /// 生成增量 payload.bin
  ///
  /// [sourceDir] 旧镜像目录
  /// [targetDir] 新镜像目录
  Future<OtaResult> packDelta({
    required String sourceDir,
    required String targetDir,
    required String output,
    List<String>? partitions,
    String compression = 'xz',
    int level = 6,
    void Function(String line)? onLine,
  }) async {
    return _runPacker(
      sourceDir: sourceDir,
      targetDir: targetDir,
      output: output,
      partitions: partitions,
      compression: compression,
      level: level,
      delta: true,
      onLine: onLine,
    );
  }

  Future<OtaResult> _runPacker({
    String? sourceDir,
    required String targetDir,
    required String output,
    List<String>? partitions,
    required String compression,
    required int level,
    required bool delta,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _packerPath == null) {
      return OtaResult(false, 'payload_packer 未就绪', log);
    }

    if (!Directory(targetDir).existsSync()) {
      return OtaResult(false, '目标目录不存在', log);
    }
    if (delta && (sourceDir == null || !Directory(sourceDir).existsSync())) {
      return OtaResult(false, '增量模式需要源目录', log);
    }

    add('══ payload_packer');
    add('  模式: ${delta ? "增量" : "全量"}');
    if (sourceDir != null) add('  源目录: $sourceDir');
    add('  目标目录: $targetDir');
    add('  压缩: $compression (level $level)');
    if (partitions != null && partitions.isNotEmpty) {
      add('  分区: ${partitions.join(", ")}');
    }
    add('');

    final args = <String>['-t', targetDir, '-o', output];
    if (delta) {
      args.add('--delta');
      args.addAll(['-s', sourceDir!]);
    }
    if (partitions != null && partitions.isNotEmpty) {
      args.addAll(['-p', partitions.join(',')]);
    }
    args.addAll(['-m', compression, '-l', '$level']);

    final code = await ProcessRunner.stream(
      _packerPath!,
      args,
      onLine: add,
      timeout: const Duration(minutes: 30),
    );

    if (code == 0 && File(output).existsSync()) {
      final size = File(output).lengthSync();
      add('');
      add('✅ 生成完成: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      add('');
      add('⚠️ 注意：payload.bin 未签名，需要用 avbroot 签名后才能刷入');
      return OtaResult(true, 'payload.bin 已生成', log);
    }
    return OtaResult(false, '生成失败（退出码 $code）', log);
  }

  /// 检查 OTA zip
  Future<OtaResult> verifyOta({
    required String otaPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _avbrootPath == null) {
      return OtaResult(false, 'avbroot 未就绪', log);
    }

    add('══ OTA 校验');
    add('  文件: ${p.basename(otaPath)}');
    add('');

    final code = await ProcessRunner.stream(
      _avbrootPath!,
      ['ota', 'verify', '--input', otaPath],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('');
      add('✅ 签名验证通过');
      return OtaResult(true, 'OTA 有效', log);
    }
    return OtaResult(false, '校验失败（退出码 $code）', log);
  }

  /// 列出 OTA 内容
  Future<OtaResult> listOta({
    required String otaPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _avbrootPath == null) {
      return OtaResult(false, 'avbroot 未就绪', log);
    }

    add('══ OTA 内容列表');

    final code = await ProcessRunner.stream(
      _avbrootPath!,
      ['ota', 'list', '--input', otaPath],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    return OtaResult(code == 0, code == 0 ? '已列出' : '失败', log);
  }

  /// 解包 OTA
  Future<OtaResult> extractOta({
    required String otaPath,
    required String outputDir,
    bool fastboot = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _avbrootPath == null) {
      return OtaResult(false, 'avbroot 未就绪', log);
    }

    Directory(outputDir).createSync(recursive: true);

    add('══ 解包 OTA');
    add('  输出: $outputDir');
    if (fastboot) add('  模式: 生成 fastboot 刷机脚本');
    add('');

    final args = ['ota', 'extract', '--input', otaPath, '--directory', outputDir];
    if (fastboot) args.add('--fastboot');

    final code = await ProcessRunner.stream(
      _avbrootPath!,
      args,
      onLine: add,
      timeout: const Duration(minutes: 20),
    );

    if (code == 0) {
      var count = 0;
      try {
        count = Directory(outputDir).listSync().whereType<File>().length;
      } catch (_) {}
      add('');
      add('✅ 解包完成，$count 个文件');
      return OtaResult(true, '解包完成（$count 个文件）', log);
    }
    return OtaResult(false, '解包失败（退出码 $code）', log);
  }

  /// 生成 AVB 密钥
  Future<OtaResult> generateKeys({
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _avbrootPath == null) {
      return OtaResult(false, 'avbroot 未就绪', log);
    }

    Directory(outputDir).createSync(recursive: true);
    final avbKey = p.join(outputDir, 'avb.key');
    final otaKey = p.join(outputDir, 'ota.key');
    final otaCrt = p.join(outputDir, 'ota.crt');

    add('══ 生成 AVB 密钥');

    // 1. AVB key
    add('── 生成 avb.key (RSA-4096)');
    var code = await ProcessRunner.stream(
      _avbrootPath!,
      ['key', 'generate-key', '-t', 'rsa4096', '-o', avbKey],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (code != 0) return OtaResult(false, '生成 avb.key 失败', log);

    // 2. OTA key
    add('── 生成 ota.key (RSA-4096)');
    code = await ProcessRunner.stream(
      _avbrootPath!,
      ['key', 'generate-key', '-t', 'rsa4096', '-o', otaKey],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (code != 0) return OtaResult(false, '生成 ota.key 失败', log);

    // 3. OTA cert
    add('── 生成 ota.crt');
    code = await ProcessRunner.stream(
      _avbrootPath!,
      ['key', 'generate-cert', '-k', otaKey, '-o', otaCrt],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (code != 0) return OtaResult(false, '生成 ota.crt 失败', log);

    add('');
    add('✅ 密钥已生成:');
    add('  $avbKey');
    add('  $otaKey');
    add('  $otaCrt');
    add('');
    add('⚠️ 请妥善保管这些密钥！丢失后无法签署 OTA');
    return OtaResult(true, '密钥已生成', log);
  }

  /// 重签 OTA（可选注入 Magisk）
  Future<OtaResult> patchOta({
    required String inputOta,
    required String outputOta,
    required String avbKey,
    required String otaKey,
    required String otaCrt,
    String? magiskApk,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _avbrootPath == null) {
      return OtaResult(false, 'avbroot 未就绪', log);
    }

    for (final f in [inputOta, avbKey, otaKey, otaCrt]) {
      if (!File(f).existsSync()) {
        return OtaResult(false, '文件不存在: $f', log);
      }
    }

    add('══ OTA 重签');
    add('  输入: ${p.basename(inputOta)}');
    add('  输出: ${p.basename(outputOta)}');
    if (magiskApk != null) add('  注入 Magisk: ${p.basename(magiskApk)}');
    add('');
    add('⚠️ 操作错误可能导致设备无法启动');
    add('⚠️ 刷入后不要立即重启，先验证');
    add('');

    final args = [
      'ota', 'patch',
      '--input', inputOta,
      '--output', outputOta,
      '--key-avb', avbKey,
      '--key-ota', otaKey,
      '--cert-ota', otaCrt,
    ];
    if (magiskApk != null) {
      args.addAll(['--magisk', magiskApk]);
    }

    final code = await ProcessRunner.stream(
      _avbrootPath!,
      args,
      onLine: add,
      timeout: const Duration(minutes: 60),
    );

    if (code == 0 && File(outputOta).existsSync()) {
      final size = File(outputOta).lengthSync();
      add('');
      add('✅ 重签完成: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      return OtaResult(true, 'OTA 已重签', log);
    }
    return OtaResult(false, '重签失败（退出码 $code）', log);
  }

  /// AVB 镜像操作（pack/unpack/inspect）
  Future<OtaResult> avbInspect({
    required String imagePath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _avbrootPath == null) {
      return OtaResult(false, 'avbroot 未就绪', log);
    }

    add('══ AVB 镜像信息');
    add('  文件: ${p.basename(imagePath)}');
    add('');

    final code = await ProcessRunner.stream(
      _avbrootPath!,
      ['avb', 'info', '--input', imagePath],
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    return OtaResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }
}
