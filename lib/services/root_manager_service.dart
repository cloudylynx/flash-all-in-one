import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// Root 管理器信息
class RootManager {
  final String id;
  final String name;
  final String description;
  final String assetPath;
  final String packageName;

  const RootManager({
    required this.id,
    required this.name,
    required this.description,
    required this.assetPath,
    required this.packageName,
  });
}

/// Root 管理器安装结果
class RootInstallResult {
  final bool ok;
  final String message;
  final List<String> log;
  RootInstallResult(this.ok, this.message, [this.log = const []]);
}

/// Root 管理器服务
///
/// 内置 7 个 Root 管理器 APK，可直接推送到设备安装：
///   · Magisk 官方 / Delta（狐狸面具）/ Alpha
///   · KernelSU / KernelSU Next / SukiSU Ultra
///   · APatch
///
/// 来源：QN 工具箱 2.7.9 内置版本
class RootManagerService {
  RootManagerService._();
  static final RootManagerService instance = RootManagerService._();

  /// 所有可用的 Root 管理器
  static const List<RootManager> managers = [
    RootManager(
      id: 'magisk-official',
      name: 'Magisk 官方 28.1',
      description: '最通用，systemless 修改',
      assetPath: 'assets/apk/magisk-official-28.1.apk',
      packageName: 'com.topjohnwu.magisk',
    ),
    RootManager(
      id: 'magisk-delta',
      name: '狐狸面具 Delta 27',
      description: 'Magisk 分支，支持 Zygisk Next',
      assetPath: 'assets/apk/magisk-delta-27.apk',
      packageName: 'io.github.huskydg.magisk',
    ),
    RootManager(
      id: 'magisk-alpha',
      name: 'Magisk Alpha 30700',
      description: '隐藏性更强的分支',
      assetPath: 'assets/apk/magisk-alpha-30700.apk',
      packageName: 'io.github.vvb2060.magisk',
    ),
    RootManager(
      id: 'kernelsu',
      name: 'KernelSU',
      description: '内核级 Root，需内核支持',
      assetPath: 'assets/apk/kernelsu.apk',
      packageName: 'me.weishu.kernelsu',
    ),
    RootManager(
      id: 'kernelsu-next',
      name: 'KernelSU Next',
      description: 'KernelSU 增强版，内核覆盖更广',
      assetPath: 'assets/apk/kernelsu-next.apk',
      packageName: 'com.rifsxd.ksunext',
    ),
    RootManager(
      id: 'sukisu',
      name: 'SukiSU Ultra',
      description: 'KernelSU 分支，内置 SUSFS',
      assetPath: 'assets/apk/sukisu-ultra.apk',
      packageName: 'com.sukisu.ultra',
    ),
    RootManager(
      id: 'apatch',
      name: 'APatch',
      description: '内核补丁式 Root，不需要完整内核源码',
      assetPath: 'assets/apk/apatch.apk',
      packageName: 'me.bmax.apatch',
    ),
  ];

  /// 按 id 查找
  static RootManager? byId(String id) {
    for (final m in managers) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 检查设备是否已安装某个管理器
  Future<bool> isInstalled(String serial, RootManager manager) async {
    final adb = await AppConfig.adbPath();
    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'pm', 'list', 'packages', manager.packageName],
      timeout: AppConfig.normalTimeout,
    );
    return r.output.contains(manager.packageName);
  }

  /// 获取设备上已安装的 Root 管理器列表
  Future<List<RootManager>> detectInstalled(String serial) async {
    final installed = <RootManager>[];
    for (final m in managers) {
      if (await isInstalled(serial, m)) {
        installed.add(m);
      }
    }
    return installed;
  }

  /// 安装 Root 管理器到设备
  Future<RootInstallResult> install({
    required String serial,
    required RootManager manager,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 安装 ${manager.name}');
    add('  包名: ${manager.packageName}');

    // 1. 提取 APK
    add('── 提取 APK');
    final localPath = await ToolExtractor.extractFile(
      assetPath: manager.assetPath,
      subDir: 'root-managers',
      fileName: '${manager.id}.apk',
    );

    if (localPath == null) {
      add('❌ APK 提取失败');
      return RootInstallResult(false, 'APK 提取失败', log);
    }

    final size = File(localPath).lengthSync();
    add('  ✅ ${(size / 1024 / 1024).toStringAsFixed(1)} MB');

    // 2. 推送到设备
    add('── 推送到设备');
    final adb = await AppConfig.adbPath();
    const remotePath = '/data/local/tmp/root-manager.apk';

    var r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'push', localPath, remotePath],
      timeout: AppConfig.longTimeout,
    );
    if (!r.ok) {
      add('❌ 推送失败: ${r.output.trim()}');
      return RootInstallResult(false, '推送失败', log);
    }
    add('  ✅ $remotePath');

    // 3. 安装
    add('── 安装');
    r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'pm', 'install', '-r', remotePath],
      timeout: const Duration(minutes: 3),
    );

    // 4. 清理
    await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'rm', '-f', remotePath],
      timeout: AppConfig.shortTimeout,
    );

    if (r.output.contains('Success')) {
      add('');
      add('✅ 安装成功');
      add('');
      add('📌 下一步：');
      add('  打开「${manager.name}」完成初始化');
      add('  然后在软件里点「授权」授予 Root 权限');
      return RootInstallResult(true, '${manager.name} 已安装', log);
    }

    add('❌ 安装失败: ${r.output.trim()}');
    return RootInstallResult(false, '安装失败', log);
  }

  /// 卸载 Root 管理器
  Future<RootInstallResult> uninstall({
    required String serial,
    required RootManager manager,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 卸载 ${manager.name}');
    final adb = await AppConfig.adbPath();
    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'uninstall', manager.packageName],
      timeout: AppConfig.normalTimeout,
    );

    add(r.ok ? '✅ 已卸载' : '❌ 卸载失败: ${r.output.trim()}');
    return RootInstallResult(r.ok, r.ok ? '已卸载' : '卸载失败', log);
  }

  /// 检查设备 Root 状态（su 是否可用）
  Future<Map<String, dynamic>> checkRootStatus(String serial) async {
    final adb = await AppConfig.adbPath();
    final result = <String, dynamic>{};

    // 1. su 命令
    final su = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'which', 'su'],
      timeout: AppConfig.shortTimeout,
    );
    result['hasSu'] = su.output.contains('su') && !su.output.contains('not found');
    result['suPath'] = result['hasSu'] as bool ? su.output.trim() : null;

    // 2. 实际提权测试
    if (result['hasSu'] as bool) {
      final id = await ProcessRunner.run(
        adb,
        ['-s', serial, 'shell', 'su', '-c', 'id'],
        timeout: AppConfig.normalTimeout,
      );
      result['isRooted'] = id.output.contains('uid=0');
      result['idOutput'] = id.output.trim();
    } else {
      result['isRooted'] = false;
    }

    // 3. 已安装的管理器
    result['managers'] = await detectInstalled(serial);

    return result;
  }

  /// 推送 Magisk boot_patch.sh 并修补 boot.img
  ///
  /// 注意：这需要设备上已有 Magisk（用 magiskboot）
  Future<RootInstallResult> patchBoot({
    required String serial,
    required String bootImagePath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ Magisk 修补 boot.img');
    add('  镜像: ${p.basename(bootImagePath)}');
    add('');
    add('⚠️ 此功能需要：');
    add('  · 设备已 root（有 magiskboot 权限）');
    add('  · 或使用 PC 端 magiskboot');
    add('');
    add('📌 推荐流程：');
    add('  1. 从设备拉取 boot.img');
    add('  2. 用 Magisk App 的「安装 → 选择并修补文件」');
    add('  3. fastboot flash boot <修补后的镜像>');

    return RootInstallResult(false, '请用 Magisk App 修补', log);
  }
}
