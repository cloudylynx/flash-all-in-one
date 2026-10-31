import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// APK 操作结果
class ApkResult {
  final bool ok;
  final String message;
  final List<String> log;
  ApkResult(this.ok, this.message, [this.log = const []]);
}

/// APK 工具链服务
///
/// 技术来源：
///   · iBotPeaches/Apktool（26852★，Apache-2.0）—— 反编译/重打包
///   · patrickfav/uber-apk-signer（2797★，Apache-2.0）—— 签名 + zipalign
///   · REAndroid/APKEditor（2395★，Apache-2.0）—— split APK 合并
///
/// 注意：三者都需要 JRE。本服务会先检测 java 可用性。
class ApkService {
  ApkService._();
  static final ApkService instance = ApkService._();

  String? _apktoolJar;
  String? _signerJar;
  String? _editorJar;
  bool _available = false;
  String? _javaVersion;

  bool get isAvailable => _available;
  String? get javaVersion => _javaVersion;

  /// 初始化：提取 jar + 检测 java
  Future<bool> init() async {
    if (_available) return true;

    // 1. 检测 java
    try {
      final r = await ProcessRunner.run('java', ['-version'],
          timeout: AppConfig.shortTimeout);
      // java -version 输出走 stderr
      final text = '${r.stdout} ${r.stderr}';
      final m = RegExp(r'version "([^"]+)"').firstMatch(text);
      _javaVersion = m?.group(1);
      if (_javaVersion == null) return false;
    } catch (_) {
      return false;
    }

    // 2. 提取 jar
    _apktoolJar = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/apk/apktool.jar',
      subDir: 'apk',
      fileName: 'apktool.jar',
    );
    _signerJar = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/apk/uber-apk-signer.jar',
      subDir: 'apk',
      fileName: 'uber-apk-signer.jar',
    );
    _editorJar = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/apk/APKEditor.jar',
      subDir: 'apk',
      fileName: 'APKEditor.jar',
    );

    _available = _apktoolJar != null || _signerJar != null;
    return _available;
  }

  /// apktool 版本
  Future<String?> apktoolVersion() async {
    if (!await init() || _apktoolJar == null) return null;
    final r = await ProcessRunner.run('java', ['-jar', _apktoolJar!, '--version'],
        timeout: AppConfig.normalTimeout);
    return r.output.trim().split('\n').first.trim();
  }

  /// 反编译 APK
  Future<ApkResult> decode({
    required String apkPath,
    required String outputDir,
    bool force = true,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return ApkResult(false, 'APK 工具未就绪（需要 Java）', log);
    }
    if (_apktoolJar == null) {
      return ApkResult(false, 'apktool.jar 未找到', log);
    }
    if (!File(apkPath).existsSync()) {
      return ApkResult(false, 'APK 不存在', log);
    }

    add('══ APK 反编译');
    add('  文件: ${p.basename(apkPath)}');
    add('  输出: $outputDir');
    add('');

    final args = ['-jar', _apktoolJar!, 'd'];
    if (force) args.add('-f');
    args.addAll([apkPath, '-o', outputDir]);

    final code = await ProcessRunner.stream(
      'java',
      args,
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      var files = 0;
      try {
        files = Directory(outputDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length;
      } catch (_) {}
      add('');
      add('✅ 反编译完成，$files 个文件');
      return ApkResult(true, '反编译完成（$files 个文件）', log);
    }
    return ApkResult(false, '反编译失败（退出码 $code）', log);
  }

  /// 重新打包 APK
  Future<ApkResult> build({
    required String srcDir,
    required String outputApk,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _apktoolJar == null) {
      return ApkResult(false, 'apktool 未就绪', log);
    }

    add('══ APK 重打包');
    add('  目录: $srcDir');
    add('  输出: $outputApk');
    add('');

    final code = await ProcessRunner.stream(
      'java',
      ['-jar', _apktoolJar!, 'b', srcDir, '-o', outputApk],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0 && File(outputApk).existsSync()) {
      final size = File(outputApk).lengthSync();
      add('');
      add('✅ 打包完成: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      add('');
      add('📌 下一步：需要签名才能安装');
      return ApkResult(true, '打包完成', log);
    }
    return ApkResult(false, '打包失败（退出码 $code）', log);
  }

  /// 签名 APK
  ///
  /// ⚠️ 已签名的 APK 必须加 --allowResign，否则会被静默 SKIP
  Future<ApkResult> sign({
    required String apkPath,
    String? outputDir,
    bool allowResign = true,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _signerJar == null) {
      return ApkResult(false, 'uber-apk-signer 未就绪', log);
    }

    add('══ APK 签名');
    add('  文件: ${p.basename(apkPath)}');
    add('  重新签名: ${allowResign ? "是" : "否"}');
    add('');

    final args = ['-jar', _signerJar!, '-a', apkPath];
    if (outputDir != null) args.addAll(['-o', outputDir]);
    if (allowResign) args.add('--allowResign');

    final code = await ProcessRunner.stream(
      'java',
      args,
      onLine: add,
      timeout: const Duration(minutes: 5),
    );

    if (code == 0) {
      add('');
      add('✅ 签名完成');
      return ApkResult(true, '签名完成', log);
    }
    return ApkResult(false, '签名失败（退出码 $code）', log);
  }

  /// 合并 split APK（XAPK/APKM/APKS）
  Future<ApkResult> mergeSplit({
    required String inputDir,
    required String outputApk,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _editorJar == null) {
      return ApkResult(false, 'APKEditor 未就绪', log);
    }

    add('══ 合并 split APK');
    add('  目录: $inputDir');
    add('  输出: $outputApk');
    add('');

    final code = await ProcessRunner.stream(
      'java',
      ['-jar', _editorJar!, 'm', '-i', inputDir, '-o', outputApk],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0 && File(outputApk).existsSync()) {
      final size = File(outputApk).lengthSync();
      add('');
      add('✅ 合并完成: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      return ApkResult(true, '合并完成', log);
    }
    return ApkResult(false, '合并失败（退出码 $code）', log);
  }

  /// 解包 APK（仅资源，APKEditor 更快）
  Future<ApkResult> extract({
    required String apkPath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init() || _editorJar == null) {
      return ApkResult(false, 'APKEditor 未就绪', log);
    }

    add('══ 解包 APK（快速）');
    add('  文件: ${p.basename(apkPath)}');
    add('');

    final code = await ProcessRunner.stream(
      'java',
      ['-jar', _editorJar!, 'd', '-i', apkPath, '-o', outputDir, '-t', 'xml'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('✅ 解包完成');
      return ApkResult(true, '解包完成', log);
    }
    return ApkResult(false, '解包失败（退出码 $code）', log);
  }

  /// 读取 APK 基本信息（用 aapt 或 unzip 兜底）
  Future<Map<String, String>?> readInfo(String apkPath) async {
    if (!File(apkPath).existsSync()) return null;

    final info = <String, String>{};
    info['文件'] = p.basename(apkPath);
    info['大小'] =
        '${(File(apkPath).lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB';

    // 用 APKEditor 的 info 命令
    if (await init() && _editorJar != null) {
      final r = await ProcessRunner.run(
        'java',
        ['-jar', _editorJar!, 'info', '-i', apkPath],
        timeout: AppConfig.normalTimeout,
      );
      if (r.ok) {
        for (final line in r.output.split('\n')) {
          final m = RegExp(r'^(\w[\w\s]*):\s*(.+)$').firstMatch(line.trim());
          if (m != null) {
            info[m.group(1)!.trim()] = m.group(2)!.trim();
          }
        }
      }
    }

    return info;
  }
}
