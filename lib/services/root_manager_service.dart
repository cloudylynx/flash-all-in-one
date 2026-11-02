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
  /// Magisk 修补 boot.img（完整实现）
  ///
  /// 从 Magisk APK 提取的官方工具链：
  ///   · magiskboot     — 解包/重打包 boot.img
  ///   · magiskinit     — 替换 ramdisk 里的 /init
  ///   · magisk         — Magisk 主程序
  ///   · boot_patch.sh  — 官方修补脚本
  ///   · util_functions.sh
  ///   · stub.apk       — Magisk App 存根
  ///
  /// 流程（在设备上执行）：
  ///   ① 推送工具链到 /data/local/tmp/magisk-patch/
  ///   ② 推送待修补的 boot.img
  ///   ③ 执行 boot_patch.sh
  ///   ④ 拉回修补后的 new-boot.img
  ///
  /// 不需要设备已 root，只需要 adb shell 能执行
  ///
  /// ─────────────────────────────────────────────────────
  /// ⚠️ 当前 UI 未使用此方法（root_page 走的是 PC 端路线
  ///    `RootService.patchBoot`，用 PC 上的 magiskboot 本地处理）。
  ///
  /// 保留原因：这是设备端修补路线，与 PC 端互补——
  ///   · PC 端：需要 PC 有 magiskboot，本地快，适合批量
  ///   · 设备端：只需 adb，适合 PC 缺工具或要把处理放在手机上
  ///
  /// 将来若要做「纯 adb 模式 root」，直接接这个即可。
  /// ─────────────────────────────────────────────────────
  Future<RootInstallResult> patchBoot({
    required String serial,
    required String bootImagePath,
    String? outputPath,
    bool keepVerity = false,
    bool keepForceEncrypt = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ Magisk 修补 boot.img');
    add('  镜像: ${p.basename(bootImagePath)}');
    if (!File(bootImagePath).existsSync()) {
      add('❌ 文件不存在');
      return RootInstallResult(false, '文件不存在', log);
    }
    add('  大小: ${(File(bootImagePath).lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB');
    add('');

    // ① 提取工具链
    add('── 提取 Magisk 工具链');
    const tools = [
      'magiskboot', 'magiskinit', 'magisk',
      'boot_patch.sh', 'util_functions.sh', 'stub.apk',
    ];
    String? localDir;
    for (final t in tools) {
      final path = await ToolExtractor.extractFile(
        assetPath: 'assets/tools/android/magisk/$t',
        subDir: 'magisk',
        fileName: t,
        executable: !t.endsWith('.apk') && !t.endsWith('.sh'),
      );
      if (path == null) {
        add('❌ 提取 $t 失败');
        return RootInstallResult(false, '工具提取失败', log);
      }
      localDir ??= File(path).parent.path;
    }
    add('  ✅ ${tools.length} 个文件已就绪');
    add('');

    final adb = await AppConfig.adbPath();
    const remoteDir = '/data/local/tmp/magisk-patch';

    // ② 推送工具链
    add('── 推送到设备');
    await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'rm -rf $remoteDir && mkdir -p $remoteDir'],
      timeout: const Duration(seconds: 30),
    );

    for (final t in tools) {
      final local = p.join(localDir!, t);
      final push = await ProcessRunner.run(
        adb,
        ['-s', serial, 'push', local, '$remoteDir/$t'],
        timeout: const Duration(minutes: 1),
      );
      if (!push.ok) {
        add('  ❌ 推送 $t 失败');
        return RootInstallResult(false, '推送失败', log);
      }
    }
    add('  ✅ 工具链已推送');

    // ③ 推送 boot.img
    add('── 推送 boot.img');
    final pushBoot = await ProcessRunner.run(
      adb,
      ['-s', serial, 'push', bootImagePath, '$remoteDir/boot.img'],
      timeout: const Duration(minutes: 5),
    );
    if (!pushBoot.ok) {
      add('  ❌ 推送失败');
      return RootInstallResult(false, '推送 boot 失败', log);
    }
    add('  ✅ 已推送');
    add('');

    // ④ 设置权限
    add('── 设置执行权限');
    await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell',
       'cd $remoteDir && chmod 755 magiskboot magiskinit magisk boot_patch.sh util_functions.sh'],
      timeout: const Duration(seconds: 30),
    );
    add('  ✅ 已设置');
    add('');

    // ⑤ 执行修补
    add('── 执行 boot_patch.sh');
    add('  KEEPVERITY=$keepVerity');
    add('  KEEPFORCEENCRYPT=$keepForceEncrypt');
    add('');

    final envPrefix =
        'KEEPVERITY=$keepVerity KEEPFORCEENCRYPT=$keepForceEncrypt';
    final code = await ProcessRunner.stream(
      adb,
      ['-s', serial, 'shell',
       'cd $remoteDir && $envPrefix sh boot_patch.sh boot.img 2>&1'],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code != 0) {
      add('');
      add('❌ 修补失败（退出码 $code）');
      return RootInstallResult(false, '修补失败', log);
    }

    // ⑥ 拉回结果
    add('');
    add('── 拉回修补后的镜像');
    final savePath = outputPath ??
        p.join(
          p.dirname(bootImagePath),
          'magisk_patched_${DateTime.now().millisecondsSinceEpoch}.img',
        );

    final pull = await ProcessRunner.run(
      adb,
      ['-s', serial, 'pull', '$remoteDir/new-boot.img', savePath],
      timeout: const Duration(minutes: 5),
    );

    if (!pull.ok) {
      add('❌ 拉取失败');
      return RootInstallResult(false, '拉取失败', log);
    }

    final size = File(savePath).lengthSync();
    add('  ✅ ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
    add('  路径: $savePath');
    add('');

    // ⑦ 清理
    await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'rm -rf $remoteDir'],
      timeout: const Duration(seconds: 30),
    );

    add('✅ Magisk 修补完成');
    add('');
    add('📌 下一步：');
    add('   1. 重启到 fastboot：adb reboot bootloader');
    add('   2. 刷入：fastboot flash boot ${p.basename(savePath)}');
    add('   3. 重启：fastboot reboot');
    add('');
    add('⚠️ 如果设备有 A/B 分区，还要刷到 boot_b：');
    add('   fastboot flash boot_b ${p.basename(savePath)}');

    return RootInstallResult(true, '修补完成', log);

  }
}
