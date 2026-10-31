import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 骁龙小米机型
enum XiaomiSocModel {
  k70pro('Redmik70pro', 'Redmi K70 Pro', 'Redmik70pro', 'Xiaomi14', true),
  k80('Redmik80', 'Redmi K80', 'Redmik80', 'Redmik80', true),
  mi14('Xiaomi14', 'Xiaomi 14', 'Xiaomi14', 'Xiaomi14', true),
  mi14pro('Xiaomi14pro', 'Xiaomi 14 Pro', 'Xiaomi14pro', 'Xiaomi14', true),
  mi14ultra('Xiaomi14ultra', 'Xiaomi 14 Ultra', 'Xiaomi14ultra', 'Redmik80', true),
  mixflip('Xiaomimixflip', 'Xiaomi MIX Flip', 'Xiaomimixflip', 'Xiaomi14', true),
  mixfold4('Xiaomimixfold4', 'Xiaomi MIX Fold 4', 'Xiaomimixfold4', 'Redmik80', true);

  final String id;
  final String displayName;
  /// unlockGPT 目录名
  final String gptDir;
  /// bin 目录名（exploit/su）
  final String binDir;
  /// 是否需要 factoryImages（原厂镜像）
  final bool needFactoryImages;

  const XiaomiSocModel(
      this.id, this.displayName, this.gptDir, this.binDir, this.needFactoryImages);
}

/// 骁龙小米解锁结果
class XiaomiUnlockResult {
  final bool ok;
  final String message;
  final List<String> log;
  XiaomiUnlockResult(this.ok, this.message, [this.log = const []]);
}

/// 骁龙小米设备 BL 解锁（HyperOS 2.0+）
///
/// 技术来源：Linuxoid-cn/Mi8G3-Unlocker（561★）
/// 作者：酷安 @Kernix
///
/// 完整流程（8 步）：
///   1. 推送 exploit + su 到 /data/local/tmp
///   2. 执行 exploit 提权 → 验证 uid=0
///   3. 循环跑 exploit 直到 SELinux = Permissive
///   4. dd 写入工程 abl.elf 到 abl_a + abl_b
///   5. fastboot flash partition:4 unlockgpt_both4.bin
///   6. fastboot boot 8650-Ennea.img（引导自定义镜像）
///   7. fastboot flash partition:4 gpt_both4.bin（恢复 GPT）
///   8. fastboot oem device-info 验证 + fastboot erase frp
///
/// 原理：绕过小米服务器端解锁资格检查，直接修改 GPT 引导自定义镜像
class XiaomiUnlockService {
  XiaomiUnlockService._();
  static final XiaomiUnlockService instance = XiaomiUnlockService._();

  String? _assetsDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：从 assets 提取关键文件
  Future<bool> init() async {
    if (_available) return true;

    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'mi8g3'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // 提取核心文件
      const files = [
        '8650-Ennea.img',
        'bin/exploit_k80',
        'bin/su_k80',
        'bin/exploit_mi14',
        'bin/su_mi14',
        // unlockGPT 7 个
        'unlockgpt/Redmik70pro.bin',
        'unlockgpt/Redmik80.bin',
        'unlockgpt/Xiaomi14.bin',
        'unlockgpt/Xiaomi14pro.bin',
        'unlockgpt/Xiaomi14ultra.bin',
        'unlockgpt/Xiaomimixflip.bin',
        'unlockgpt/Xiaomimixfold4.bin',
        // gpt 恢复用 7 个
        'gpt/Redmik70pro.bin',
        'gpt/Redmik80.bin',
        'gpt/Xiaomi14.bin',
        'gpt/Xiaomi14pro.bin',
        'gpt/Xiaomi14ultra.bin',
        'gpt/Xiaomimixflip.bin',
        'gpt/Xiaomimixfold4.bin',
      ];

      var ok = 0;
      for (final f in files) {
        try {
          final target = File(p.join(dir.path, f));
          if (!target.parent.existsSync()) {
            target.parent.createSync(recursive: true);
          }
          if (!target.existsSync()) {
            final data =
                await rootBundle.load('assets/tools/windows/mi8g3/$f');
            await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
          }
          ok++;
        } catch (_) {}
      }

      if (ok > 0) {
        _assetsDir = dir.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  /// 文件路径
  String? filePath(String relative) {
    if (_assetsDir == null) return null;
    final f = File(p.join(_assetsDir!, relative));
    return f.existsSync() ? f.path : null;
  }

  /// 前置检查
  Future<List<String>> preflight(String serial) async {
    final issues = <String>[];
    final adb = await AppConfig.adbPath();

    // 1. 设备型号
    final modelRun = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.product.model']);
    final modelName = modelRun.output.trim();
    final brand = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.product.brand']);

    if (modelName.isEmpty) {
      issues.add('无法读取设备型号');
    }
    if (!brand.output.toLowerCase().contains('xiaomi') &&
        !brand.output.toLowerCase().contains('redmi') &&
        !brand.output.toLowerCase().contains('poco')) {
      issues.add('不是小米设备（brand: ${brand.output.trim()}）');
    }

    // 2. 芯片
    final soc = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.board.platform']);
    final socStr = soc.output.trim().toLowerCase();
    if (!socStr.contains('sm8650') && !socStr.contains('sun')) {
      issues.add('可能不是骁龙 8 Gen3（platform: $socStr）');
    }

    // 3. Android 版本
    final ver = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.build.version.release']);
    final verStr = ver.output.trim();
    if (verStr.isEmpty || int.tryParse(verStr.split('.').first) == null ||
        int.parse(verStr.split('.').first) < 14) {
      issues.add('Android 版本可能过低（$verStr），需要 HyperOS 2.0+');
    }

    return issues;
  }

  /// 完整解锁流程
  Future<XiaomiUnlockResult> unlock({
    required String serial,
    required XiaomiSocModel model,
    required String factoryImagesDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return XiaomiUnlockResult(false, '关键文件未就绪', log);
    }

    final adb = await AppConfig.adbPath();
    final fastboot = await AppConfig.fastbootPath();
    final exploitName = model.binDir == 'Redmik80' ? 'exploit_k80' : 'exploit_mi14';
    final suName = model.binDir == 'Redmik80' ? 'su_k80' : 'su_mi14';

    final exploit = filePath('bin/$exploitName');
    final su = filePath('bin/$suName');
    final unlockGpt = filePath('unlockgpt/${model.gptDir}.bin');
    final restoreGpt = filePath('gpt/${model.gptDir}.bin');
    final enneaImg = filePath('8650-Ennea.img');

    if (exploit == null || su == null) {
      return XiaomiUnlockResult(false, 'exploit/su 文件缺失', log);
    }
    if (unlockGpt == null || restoreGpt == null) {
      return XiaomiUnlockResult(false, 'GPT 文件缺失', log);
    }
    if (enneaImg == null) {
      return XiaomiUnlockResult(false, '8650-Ennea.img 缺失', log);
    }

    add('══ 骁龙小米解锁（${model.displayName}）');
    add('  技术来源：Linuxoid-cn/Mi8G3-Unlocker');
    add('');

    // ═══ 步骤 1: 推送 exploit + su ═══
    add('── 步骤 1/8: 推送 exploit + su');
    var r = await ProcessRunner.run(
        adb, ['-s', serial, 'push', exploit, '/data/local/tmp/exploit'],
        timeout: AppConfig.normalTimeout);
    if (!r.ok) {
      return XiaomiUnlockResult(false, '推送 exploit 失败: ${r.output}', log);
    }
    add('  ✓ exploit');

    r = await ProcessRunner.run(
        adb, ['-s', serial, 'push', su, '/data/local/tmp/su'],
        timeout: AppConfig.normalTimeout);
    if (!r.ok) {
      return XiaomiUnlockResult(false, '推送 su 失败: ${r.output}', log);
    }
    add('  ✓ su');
    add('');

    // ═══ 步骤 2: 提权 ═══
    add('── 步骤 2/8: 执行 exploit 提权');
    await ProcessRunner.run(adb,
        ['-s', serial, 'shell', 'chmod', '755', '/data/local/tmp/exploit',
         '/data/local/tmp/su'],
        timeout: AppConfig.normalTimeout);

    r = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', '/data/local/tmp/exploit'],
        timeout: AppConfig.longTimeout);
    add('  ${r.output.trim()}');
    add('');

    // ═══ 步骤 3: 验证 root ═══
    add('── 步骤 3/8: 验证 root');
    var rooted = false;
    for (var i = 0; i < 10; i++) {
      r = await ProcessRunner.run(
          adb,
          ['-s', serial, 'shell',
           '/data/local/tmp/su -c "id"'],
          timeout: AppConfig.normalTimeout);
      if (r.output.contains('uid=0(root)')) {
        rooted = true;
        add('  ✓ ${r.output.trim()}');
        break;
      }
      add('  重试 ${i + 1}/10…');
      await Future.delayed(const Duration(seconds: 2));
    }
    if (!rooted) {
      return XiaomiUnlockResult(false, 'root 提权失败', log);
    }
    add('');

    // ═══ 步骤 4: SELinux Permissive ═══
    add('── 步骤 4/8: 设置 SELinux = Permissive');
    var permissive = false;
    for (var i = 0; i < 10; i++) {
      await ProcessRunner.run(
          adb, ['-s', serial, 'shell', '/data/local/tmp/exploit'],
          timeout: AppConfig.normalTimeout);

      r = await ProcessRunner.run(
          adb,
          ['-s', serial, 'shell', '/data/local/tmp/su -c "getenforce"'],
          timeout: AppConfig.normalTimeout);
      if (r.output.toLowerCase().contains('permissive')) {
        permissive = true;
        add('  ✓ SELinux = Permissive');
        break;
      }
      add('  重试 ${i + 1}/10…');
      await Future.delayed(const Duration(seconds: 2));
    }
    if (!permissive) {
      return XiaomiUnlockResult(false, 'SELinux 设置失败', log);
    }
    add('');

    // ═══ 步骤 5: 写工程 ABL ═══
    add('── 步骤 5/8: 写入工程 ABL');
    final ablPath =
        p.join(factoryImagesDir, 'images', 'abl.elf');
    if (!File(ablPath).existsSync()) {
      add('  ⚠️ 找不到 abl.elf: $ablPath');
      add('  请确保已下载对应机型的 factoryImages');
      return XiaomiUnlockResult(false, '缺少 abl.elf', log);
    }

    r = await ProcessRunner.run(
        adb, ['-s', serial, 'push', ablPath, '/data/local/tmp/abl.elf'],
        timeout: AppConfig.longTimeout);
    if (!r.ok) {
      return XiaomiUnlockResult(false, '推送 abl.elf 失败', log);
    }

    for (final part in ['abl_a', 'abl_b']) {
      r = await ProcessRunner.run(
          adb,
          ['-s', serial, 'shell',
           '/data/local/tmp/su -c "dd if=/data/local/tmp/abl.elf of=/dev/block/by-name/$part"'],
          timeout: AppConfig.longTimeout);
      add('  写入 $part: ${r.ok ? "✓" : "✗"}');
      await Future.delayed(const Duration(seconds: 1));
    }
    add('');

    // ═══ 步骤 6: 进 fastboot ═══
    add('── 步骤 6/8: 重启到 fastboot');
    await ProcessRunner.run(
        adb, ['-s', serial, 'reboot', 'bootloader'],
        timeout: AppConfig.shortTimeout);
    add('  等待设备进入 fastboot…');
    await Future.delayed(const Duration(seconds: 8));

    // ═══ 步骤 7: 刷 unlockGPT ═══
    add('── 步骤 7/8: 刷 unlockGPT');
    r = await ProcessRunner.run(
        fastboot, ['flash', 'partition:4', unlockGpt],
        timeout: AppConfig.longTimeout);
    add('  ${r.output.trim()}');
    if (!r.ok) {
      return XiaomiUnlockResult(false, '刷 unlockGPT 失败', log);
    }

    // 引导自定义镜像
    add('  引导 8650-Ennea.img…');
    r = await ProcessRunner.run(
        fastboot, ['boot', enneaImg],
        timeout: AppConfig.longTimeout);
    add('  ${r.output.trim()}');
    await Future.delayed(const Duration(seconds: 5));

    // 恢复 GPT
    add('  恢复原厂 GPT…');
    r = await ProcessRunner.run(
        fastboot, ['flash', 'partition:4', restoreGpt],
        timeout: AppConfig.longTimeout);
    add('  ${r.output.trim()}');
    add('');

    // ═══ 步骤 8: 验证 + 清 FRP ═══
    add('── 步骤 8/8: 验证解锁状态');
    r = await ProcessRunner.run(fastboot, ['oem', 'device-info'],
        timeout: AppConfig.normalTimeout);
    add('  ${r.output.trim()}');

    final unlocked = r.output.contains('Device unlocked: true') ||
        r.output.toLowerCase().contains('unlocked: yes');

    add('  清 FRP…');
    r = await ProcessRunner.run(fastboot, ['erase', 'frp'],
        timeout: AppConfig.normalTimeout);
    add('  ${r.output.trim()}');

    add('');
    if (unlocked) {
      add('✅ 解锁成功！');
      return XiaomiUnlockResult(true, 'BL 已解锁，设备将重启', log);
    }
    add('⚠️ 未检测到解锁成功，请手动检查');
    return XiaomiUnlockResult(false, '解锁状态未知', log);
  }

  /// 检查 BL 状态（只读）
  Future<String> checkUnlockStatus() async {
    final fb = await AppConfig.fastbootPath();
    final r = await ProcessRunner.run(fb, ['oem', 'device-info'],
        timeout: AppConfig.normalTimeout);
    if (r.output.contains('Device unlocked: true')) {
      return '已解锁';
    }
    if (r.output.contains('Device unlocked: false')) {
      return '未解锁';
    }
    return '未知（${r.output.trim()}）';
  }
}
