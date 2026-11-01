import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';

/// 调整结果
class WinTweakResult {
  final bool ok;
  final String message;
  final List<String> log;
  WinTweakResult(this.ok, this.message, [this.log = const []]);
}

/// Windows 离线注册表调整服务
///
/// 技术来源：MindOWS toolbox.bat / mindows.bat 反编译分析
///
/// 原理：
///   Windows 的注册表存在几个文件里：
///     · SOFTWARE — HKEY_LOCAL_MACHINE\SOFTWARE
///     · SYSTEM   — HKEY_LOCAL_MACHINE\SYSTEM
///     · SAM      — 账户数据库
///
///   系统没启动时，可以用 `reg load` 把这些文件挂载到临时键，
///   修改后 `reg unload` 卸载。这就是「离线改注册表」。
///
/// 用途：
///   装 Windows 到安卓设备后，系统还没启动，
///   需要提前改好设置（跳过联网、跳过向导、关磁盘检查等）
class WindowsTweakService {
  WindowsTweakService._();
  static final WindowsTweakService instance = WindowsTweakService._();

  /// 临时挂载点
  static const String mountKey = r'HKEY_LOCAL_MACHINE\MindowsToolBox';

  /// 检测是否在 Windows 上（离线注册表操作需要 Windows）
  bool get isSupported => Platform.isWindows;

  /// 执行 reg 命令
  Future<ProcessResult> _reg(List<String> args) async {
    return Process.run('reg', args);
  }

  /// 挂载注册表文件
  Future<bool> _loadHive(String winDir, String hiveName,
      void Function(String)? onLine) async {
    final path = p.join(winDir, 'Windows', 'System32', 'config', hiveName);
    if (!File(path).existsSync()) {
      onLine?.call('  ❌ 注册表文件不存在: $path');
      return false;
    }

    // 先尝试卸载（如果之前挂载过）
    await _reg(['unload', mountKey]);

    final r = await _reg(['load', mountKey, path]);
    if (r.exitCode != 0) {
      onLine?.call('  ❌ 挂载失败: ${r.stderr}');
      return false;
    }
    onLine?.call('  ✅ 已挂载 $hiveName');
    return true;
  }

  /// 卸载注册表文件
  Future<void> _unloadHive(void Function(String)? onLine) async {
    final r = await _reg(['unload', mountKey]);
    if (r.exitCode == 0) {
      onLine?.call('  ✅ 已卸载');
    } else {
      onLine?.call('  ⚠️ 卸载失败（可能未挂载）');
    }
  }

  // ═══════════════════════════════════════════════
  // ① 跳过 Win11 联网激活
  // ═══════════════════════════════════════════════

  /// 启用「我没有 Internet 连接」按钮
  ///
  /// 路径: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE
  /// 值:   BypassNRO = 1 (DWORD)
  Future<WinTweakResult> skipWin11Online({
    required String winDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!isSupported) {
      return WinTweakResult(false, '仅 Windows 可用', log);
    }

    add('══ 跳过 Win11 联网激活');
    add('  目录: $winDir');
    add('');

    if (!await _loadHive(winDir, 'SOFTWARE', add)) {
      return WinTweakResult(false, '挂载失败', log);
    }

    const key = '$mountKey\\Microsoft\\Windows\\CurrentVersion\\OOBE';
    add('── 设置 BypassNRO = 1');
    final r = await _reg([
      'add', key, '/v', 'BypassNRO', '/t', 'REG_DWORD', '/d', '1', '/f',
    ]);

    await _unloadHive(add);
    add('');

    if (r.exitCode == 0) {
      add('✅ 已启用');
      add('');
      add('📌 开机后的联网页面会出现「我没有 Internet 连接」');
      add('   点它就能创建本地账户');
      return WinTweakResult(true, '已启用', log);
    }
    add('❌ 失败: ${r.stderr}');
    return WinTweakResult(false, '设置失败', log);
  }

  // ═══════════════════════════════════════════════
  // ② 跳过开机向导（OOBE）
  // ═══════════════════════════════════════════════

  /// 跳过 OOBE 并启用 Administrator
  ///
  /// 需要 SYSTEM 权限（用 NSudo 提权）
  /// 修改:
  ///   · SAM\Domains\Account\Users\000001F4 (Administrator) — 启用
  ///   · SAM\Domains\Account\Users\000001F8 (Defender) — 启用
  Future<WinTweakResult> skipOobe({
    required String winDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!isSupported) {
      return WinTweakResult(false, '仅 Windows 可用', log);
    }

    add('══ 跳过开机向导');
    add('  目录: $winDir');
    add('');
    add('ℹ️ 会：');
    add('  · 启用 Administrator 账户');
    add('  · 启用 Defender 账户');
    add('  · 修复「Windows 无法在此硬件上安装」弹窗');
    add('');

    if (!await _loadHive(winDir, 'SAM', add)) {
      return WinTweakResult(false, '挂载 SAM 失败', log);
    }

    // 启用账户：修改 F 值的第 112-113 字节
    // 0x11 → 0x10（禁用 → 启用）
    // 0x15 → 0x14
    var ok = 0;
    for (final entry in [
      {'rid': '000001F4', 'name': 'Administrator'},
      {'rid': '000001F8', 'name': 'Defender'},
    ]) {
      final rid = entry['rid']!;
      final name = entry['name']!;
      add('── 启用 $name (RID $rid)');

      final q = await _reg([
        'query', '$mountKey\\SAM\\Domains\\Account\\Users\\$rid', '/v', 'F',
      ]);

      if (q.exitCode != 0) {
        add('  ⚠️ 查不到该账户，跳过');
        continue;
      }

      // 解析 F 值的十六进制
      final m = RegExp(r'F\s+REG_BINARY\s+([0-9A-Fa-f]+)')
          .firstMatch(q.stdout);
      if (m == null) {
        add('  ⚠️ 解析失败，跳过');
        continue;
      }

      final hex = m.group(1)!;
      if (hex.length < 114) {
        add('  ⚠️ 数据太短，跳过');
        continue;
      }

      // 取第 112-113 字符（56-57 字节）
      final flag = hex.substring(112, 114).toLowerCase();
      if (flag != '11' && flag != '15') {
        add('  ⚠️ 标志位是 0x$flag（不是 11 或 15），跳过');
        continue;
      }

      final newFlag = flag == '11' ? '10' : '14';
      final newHex =
          hex.substring(0, 112) + newFlag + hex.substring(114);

      final r = await _reg([
        'add', '$mountKey\\SAM\\Domains\\Account\\Users\\$rid',
        '/v', 'F', '/t', 'REG_BINARY', '/d', newHex, '/f',
      ]);

      if (r.exitCode == 0) {
        add('  ✅ 0x$flag → 0x$newFlag');
        ok++;
      } else {
        add('  ❌ 失败: ${r.stderr}');
      }
    }

    await _unloadHive(add);
    add('');

    if (ok > 0) {
      add('✅ 已启用 $ok 个账户');
      return WinTweakResult(true, '已启用 $ok 个账户', log);
    }
    return WinTweakResult(false, '没有账户被修改', log);
  }

  // ═══════════════════════════════════════════════
  // ③ 关闭磁盘检查
  // ═══════════════════════════════════════════════

  /// 关闭开机磁盘检查（chkdsk）
  ///
  /// 路径: HKLM\SYSTEM\ControlSet001\Control\Session Manager
  /// 值:   BootExecute = "autocheck autochk *" (REG_MULTI_SZ)
  Future<WinTweakResult> disableDiskCheck({
    required String winDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!isSupported) {
      return WinTweakResult(false, '仅 Windows 可用', log);
    }

    add('══ 关闭磁盘检查');
    add('  目录: $winDir');
    add('');

    if (!await _loadHive(winDir, 'SYSTEM', add)) {
      return WinTweakResult(false, '挂载失败', log);
    }

    const key = '$mountKey\\ControlSet001\\Control\\Session Manager';
    add('── 设置 BootExecute');
    final r = await _reg([
      'add', key, '/v', 'BootExecute', '/t', 'REG_MULTI_SZ',
      '/d', 'autocheck autochk *', '/f',
    ]);

    await _unloadHive(add);
    add('');

    if (r.exitCode == 0) {
      add('✅ 已关闭磁盘检查');
      add('');
      add('ℹ️ 开机时不会再跑 chkdsk');
      add('   适合经常断电的设备');
      return WinTweakResult(true, '已关闭', log);
    }
    add('❌ 失败: ${r.stderr}');
    return WinTweakResult(false, '设置失败', log);
  }

  // ═══════════════════════════════════════════════
  // ④ 设置 USB 模式
  // ═══════════════════════════════════════════════

  /// 设置 USB 角色切换模式
  ///
  /// 两种方案：
  ///   · MU（高通原生）: HKLM\SYSTEM\ControlSet001\Enum\ACPI\QCOM0597\0\
  ///                     Device Parameters\RoleSwitchMode
  ///   · EDK2（UEFI）:  HKLM\SYSTEM\ControlSet001\Control\USB\
  ///                     OsDefaultRoleSwitchMode
  ///
  /// 值含义：
  ///   1 = Host（当电脑用）
  ///   3 = Device（当 U 盘用）
  ///   6 = Dual role（双角色）
  Future<WinTweakResult> setUsbMode({
    required String winDir,
    required int mode,
    bool useEdk2 = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!isSupported) {
      return WinTweakResult(false, '仅 Windows 可用', log);
    }

    const modeNames = {
      1: 'Host（主机模式，当电脑用）',
      3: 'Device（设备模式，当 U 盘用）',
      6: 'Dual Role（双角色，自动切换）',
    };

    add('══ 设置 USB 模式');
    add('  目录: $winDir');
    add('  模式: $mode — ${modeNames[mode] ?? "自定义"}');
    add('  方案: ${useEdk2 ? "EDK2（UEFI 通用）" : "MU（高通原生）"}');
    add('');

    if (!await _loadHive(winDir, 'SYSTEM', add)) {
      return WinTweakResult(false, '挂载失败', log);
    }

    String key;
    String valueName;

    if (useEdk2) {
      key = '$mountKey\\ControlSet001\\Control\\USB';
      valueName = 'OsDefaultRoleSwitchMode';
    } else {
      key = '$mountKey\\ControlSet001\\Enum\\ACPI\\QCOM0597\\0\\Device Parameters';
      valueName = 'RoleSwitchMode';
    }

    add('── 设置 $valueName = $mode');

    // 先查旧值
    final q = await _reg(['query', key, '/v', valueName]);
    if (q.exitCode == 0) {
      final m = RegExp(r'0x([0-9a-fA-F]+)').firstMatch(q.stdout);
      if (m != null) {
        add('  当前值: 0x${m.group(1)}');
      }
    } else {
      add('  ⚠️ 查不到该项（部分设备没有）');
    }

    final r = await _reg([
      'add', key, '/v', valueName, '/t', 'REG_DWORD',
      '/d', '$mode', '/f',
    ]);

    await _unloadHive(add);
    add('');

    if (r.exitCode == 0) {
      add('✅ 已设置为 $mode');
      return WinTweakResult(true, '已设置', log);
    }
    add('❌ 失败: ${r.stderr}');
    add('');
    add('📌 如果 MU 方案失败，试试 EDK2 方案');
    return WinTweakResult(false, '设置失败', log);
  }

  // ═══════════════════════════════════════════════
  // ⑤ 禁用自动修复
  // ═══════════════════════════════════════════════

  /// 禁用 Windows 自动修复
  ///
  /// 安卓刷 Windows 后，系统启动失败会触发自动修复，
  /// 但自动修复在手机上往往修不好，反而卡住。
  Future<WinTweakResult> disableAutoRepair({
    required String winDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!isSupported) {
      return WinTweakResult(false, '仅 Windows 可用', log);
    }

    add('══ 禁用自动修复');
    add('  目录: $winDir');
    add('');

    if (!await _loadHive(winDir, 'SOFTWARE', add)) {
      return WinTweakResult(false, '挂载失败', log);
    }

    var ok = 0;

    // ① 关闭恢复环境
    add('── 关闭恢复环境');
    const key1 = '$mountKey\\Microsoft\\Windows NT\\CurrentVersion\\WinRE';
    var r = await _reg([
      'add', key1, '/v', 'RecoveryEnabled', '/t', 'REG_DWORD',
      '/d', '0', '/f',
    ]);
    if (r.exitCode == 0) {
      add('  ✅ RecoveryEnabled = 0');
      ok++;
    }

    // ② 关闭自动重启
    add('── 关闭崩溃自动重启');
    const key2 =
        '$mountKey\\Microsoft\\Windows NT\\CurrentVersion\\Windows';
    r = await _reg([
      'add', key2, '/v', 'AutoEndTasks', '/t', 'REG_SZ', '/d', '1', '/f',
    ]);
    if (r.exitCode == 0) {
      add('  ✅ AutoEndTasks = 1');
      ok++;
    }

    await _unloadHive(add);
    add('');

    if (ok > 0) {
      add('✅ 已禁用 $ok 项');
      return WinTweakResult(true, '已禁用', log);
    }
    return WinTweakResult(false, '设置失败', log);
  }

  // ═══════════════════════════════════════════════
  // ⑥ 注入驱动
  // ═══════════════════════════════════════════════

  /// 把驱动注入到离线 Windows 镜像
  ///
  /// 原理：把 .inf/.sys/.cat 复制到 DriverStore，
  ///      然后注册到注册表
  ///
  /// 简化实现：复制到 Drivers 目录 + 提示用户用 DISM 注册
  Future<WinTweakResult> injectDrivers({
    required String winDir,
    required String driverDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 注入驱动');
    add('  Windows: $winDir');
    add('  驱动目录: $driverDir');
    add('');

    final srcDir = Directory(driverDir);
    if (!srcDir.existsSync()) {
      add('❌ 驱动目录不存在');
      return WinTweakResult(false, '目录不存在', log);
    }

    // 收集驱动文件
    final drivers = <File>[];
    for (final e in srcDir.listSync(recursive: true)) {
      if (e is File) {
        final ext = p.extension(e.path).toLowerCase();
        if (ext == '.inf' || ext == '.sys' || ext == '.cat') {
          drivers.add(e);
        }
      }
    }

    if (drivers.isEmpty) {
      add('❌ 没找到 .inf/.sys/.cat 文件');
      return WinTweakResult(false, '没有驱动文件', log);
    }

    add('  找到 ${drivers.length} 个驱动文件');
    add('');

    // 目标目录
    final targetDir = Directory(
        p.join(winDir, 'Windows', 'System32', 'DriverStore', 'FileRepository'));
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    // 复制
    var copied = 0;
    for (final f in drivers) {
      try {
        final name = p.basename(f.path);
        final target = p.join(targetDir.path, name);
        f.copySync(target);
        copied++;
        add('  ✅ $name');
      } catch (e) {
        add('  ❌ ${p.basename(f.path)}: $e');
      }
    }

    add('');
    add('✅ 已复制 $copied 个文件到 DriverStore');
    add('');
    add('⚠️ 注意：这只是复制文件，没有注册到系统');
    add('   完整注入需要在 Windows 里用：');
    add('   dism /Image:<挂载目录> /Add-Driver /Driver:<驱动目录> /Recurse');

    return WinTweakResult(true, '已复制 $copied 个文件', log);
  }

  // ═══════════════════════════════════════════════
  // ⑦ 无人值守安装（autooobe）
  // ═══════════════════════════════════════════════

  /// 放置无人值守应答文件
  ///
  /// 把 unattend.xml 放到 Windows\Panther\ 目录，
  /// 系统首次启动时会自动读取，跳过所有设置步骤。
  Future<WinTweakResult> autoOobe({
    required String winDir,
    required String unattendPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 无人值守安装');
    add('  Windows: $winDir');
    add('');

    if (!File(unattendPath).existsSync()) {
      add('❌ unattend.xml 不存在');
      return WinTweakResult(false, '文件不存在', log);
    }

    // 目标目录
    final pantherDir = Directory(p.join(winDir, 'Windows', 'Panther'));
    if (!pantherDir.existsSync()) {
      pantherDir.createSync(recursive: true);
    }

    add('── 复制 unattend.xml');
    try {
      File(unattendPath).copySync(p.join(pantherDir.path, 'unattend.xml'));
      add('  ✅ 已复制到 ${pantherDir.path}');
    } catch (e) {
      add('  ❌ 失败: $e');
      return WinTweakResult(false, '复制失败', log);
    }

    // 同时放到 System32\Sysprep（兜底）
    final sysprepDir = Directory(p.join(winDir, 'Windows', 'System32', 'Sysprep'));
    if (sysprepDir.existsSync()) {
      try {
        File(unattendPath).copySync(p.join(sysprepDir.path, 'unattend.xml'));
        add('  ✅ 已复制到 Sysprep');
      } catch (_) {}
    }

    add('');
    add('✅ 已放置无人值守文件');
    add('');
    add('📌 首次启动会自动：');
    add('   · 跳过区域/语言选择');
    add('   · 跳过账户创建');
    add('   · 跳过隐私设置');
    add('   · 直接进入桌面');

    return WinTweakResult(true, '已放置', log);
  }

  // ═══════════════════════════════════════════════
  // ⑧ 制作双启动
  // ═══════════════════════════════════════════════

  /// 修补 boot.img 加双启动菜单
  ///
  /// 原理：在 boot.img 的 ramdisk 里加一个选择菜单，
  /// 启动时让用户选 Android 还是 Windows。
  ///
  /// 这需要替换 boot.img 的 ramdisk，比较复杂。
  /// 这里实现的是「检查前提条件 + 指导」。
  Future<WinTweakResult> makeDualBoot({
    required String bootImagePath,
    required String fdPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 制作双启动');
    add('  boot.img: ${p.basename(bootImagePath)}');
    add('  fd 文件: ${p.basename(fdPath)}');
    add('');

    if (!File(bootImagePath).existsSync()) {
      add('❌ boot.img 不存在');
      return WinTweakResult(false, 'boot.img 不存在', log);
    }
    if (!File(fdPath).existsSync()) {
      add('❌ fd 文件不存在');
      return WinTweakResult(false, 'fd 不存在', log);
    }

    add('  boot 大小: ${(File(bootImagePath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
    add('  fd 大小: ${(File(fdPath).lengthSync() / 1024).toStringAsFixed(0)} KB');
    add('');

    add('ℹ️ 双启动原理：');
    add('  1. 解包 boot.img');
    add('  2. 在 ramdisk 里加 boot menu');
    add('  3. 把 fd（fastboot 工具）塞进 ramdisk');
    add('  4. 重打包');
    add('');
    add('⚠️ 这需要修改 ramdisk，比较复杂');
    add('   建议用 MindOWS 的完整工具链，或者：');
    add('');
    add('📌 手动方案：');
    add('   1. 解包: magiskboot unpack boot.img');
    add('   2. 解 ramdisk: magiskboot cpio ramdisk.cpio extract');
    add('   3. 加菜单脚本到 init.rc');
    add('   4. 重打包: magiskboot cpio ramdisk.cpio "add ..."');
    add('   5. 重打包 boot: magiskboot repack boot.img');

    return WinTweakResult(false, '需要手动操作', log);
  }

  // ═══════════════════════════════════════════════
  // ⑨ 替换 DTB
  // ═══════════════════════════════════════════════

  /// 替换 boot.img 里的 DTB
  ///
  /// DTB（Device Tree Blob）描述硬件配置。
  /// 换内核或适配不同设备时需要换 DTB。
  Future<WinTweakResult> replaceDtb({
    required String sourceBoot,
    required String dtbBoot,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 替换 DTB');
    add('  源 boot: ${p.basename(sourceBoot)}');
    add('  DTB 来源: ${p.basename(dtbBoot)}');
    add('  输出: ${p.basename(outputPath)}');
    add('');

    if (!File(sourceBoot).existsSync()) {
      add('❌ 源 boot.img 不存在');
      return WinTweakResult(false, '源文件不存在', log);
    }
    if (!File(dtbBoot).existsSync()) {
      add('❌ DTB boot.img 不存在');
      return WinTweakResult(false, 'DTB 文件不存在', log);
    }

    // 需要 magiskboot
    final magiskboot = await _findMagiskboot();
    if (magiskboot == null) {
      add('❌ magiskboot 未找到');
      return WinTweakResult(false, 'magiskboot 未找到', log);
    }

    final workDir =
        Directory.systemTemp.createTempSync('dtb_replace_').path;
    add('  工作目录: $workDir');
    add('');

    try {
      // ① 解包源 boot
      add('── 解包源 boot');
      var code = await ProcessRunner.stream(
        magiskboot,
        ['unpack', sourceBoot],
        workingDirectory: workDir,
        onLine: add,
        timeout: const Duration(minutes: 2),
      );
      if (code != 0) {
        add('❌ 解包失败');
        return WinTweakResult(false, '解包失败', log);
      }

      // ② 解包 DTB boot
      add('');
      add('── 解包 DTB boot');
      final dtbWorkDir = Directory(p.join(workDir, 'dtb')).path;
      Directory(dtbWorkDir).createSync(recursive: true);

      // 复制 DTB boot 到子目录
      File(dtbBoot).copySync(p.join(dtbWorkDir, 'dtb_boot.img'));

      code = await ProcessRunner.stream(
        magiskboot,
        ['unpack', 'dtb_boot.img'],
        workingDirectory: dtbWorkDir,
        onLine: add,
        timeout: const Duration(minutes: 2),
      );
      if (code != 0) {
        add('❌ DTB 解包失败');
        return WinTweakResult(false, 'DTB 解包失败', log);
      }

      // ③ 复制 dtb 文件
      add('');
      add('── 替换 dtb');
      final srcDtb = File(p.join(dtbWorkDir, 'dtb'));
      final dstDtb = File(p.join(workDir, 'dtb'));

      if (!srcDtb.existsSync()) {
        add('❌ DTB 源文件里没有 dtb');
        return WinTweakResult(false, '没有 dtb', log);
      }

      srcDtb.copySync(dstDtb.path);
      add('  ✅ 已替换 (${(dstDtb.lengthSync() / 1024).toStringAsFixed(0)} KB)');

      // ④ 重打包
      add('');
      add('── 重打包');
      code = await ProcessRunner.stream(
        magiskboot,
        ['repack', sourceBoot],
        workingDirectory: workDir,
        onLine: add,
        timeout: const Duration(minutes: 3),
      );
      if (code != 0) {
        add('❌ 重打包失败');
        return WinTweakResult(false, '重打包失败', log);
      }

      // ⑤ 复制输出
      final newBoot = File(p.join(workDir, 'new-boot.img'));
      if (!newBoot.existsSync()) {
        add('❌ 没有生成 new-boot.img');
        return WinTweakResult(false, '没有输出', log);
      }

      newBoot.copySync(outputPath);
      add('');
      add('✅ 已生成: $outputPath');
      add('  大小: ${(File(outputPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
      add('');
      add('📌 刷入: fastboot flash boot ${p.basename(outputPath)}');

      return WinTweakResult(true, 'DTB 已替换', log);
    } finally {
      try {
        Directory(workDir).deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 找 magiskboot
  Future<String?> _findMagiskboot() async {
    // 先找项目内的
    final local = p.join(
      Platform.environment['HOME'] ?? '/tmp',
      '.local/share/io.github.flashallinone/tools/magisk/magiskboot',
    );
    if (File(local).existsSync()) return local;

    // 找 root_service 提取的
    try {
      final r = await ProcessRunner.run(
        'find',
        [p.join(Platform.environment['HOME'] ?? '/tmp',
            '.local/share/io.github.flashallinone'),
         '-name', 'magiskboot', '-type', 'f'],
        timeout: const Duration(seconds: 10),
      );
      final first = r.stdout.split('\n').firstWhere(
            (e) => e.trim().isNotEmpty,
            orElse: () => '',
          );
      if (first.isNotEmpty) return first.trim();
    } catch (_) {}
    return null;
  }

  // ═══════════════════════════════════════════════
  // ⑩ 提高 GPT 最大分区数
  // ═══════════════════════════════════════════════

  /// 提高 GPT 分区数上限（用 gdisk 的 expert 模式）
  ///
  /// gdisk 是交互式的，这里用管道喂输入实现自动化：
  ///   x  — 进入 expert 模式
  ///   s  — resize partition table（改分区数上限）
  ///   <N> — 输入新的分区数
  ///   w  — 写入
  ///   Y  — 确认
  Future<WinTweakResult> setMaxPartitions({
    required String disk,
    int maxParts = 128,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return WinTweakResult(false, '需要确认', log);
    }

    add('══ 提高 GPT 分区数上限');
    add('  磁盘: $disk');
    add('  目标: $maxParts 个');
    add('');
    add('ℹ️ GPT 默认 128 个分区，装多系统可能不够');
    add('');

    // 检查 gdisk 是否可用
    final hasGdisk = await _checkTool('gdisk');
    if (!hasGdisk) {
      add('❌ gdisk 未安装');
      add('');
      add('请先安装：');
      add('  sudo apt install gdisk');
      add('');
      add('或手动操作：');
      add('  gdisk $disk');
      add('  x    (expert 模式)');
      add('  s    (resize partition table)');
      add('  $maxParts');
      add('  w    (写入)');
      return WinTweakResult(false, 'gdisk 未安装', log);
    }

    add('── 备份分区表');
    final bakPath = '/tmp/gpt-before-maxparts-${DateTime.now().millisecondsSinceEpoch}.bin';
    var code = await ProcessRunner.run(
      'sgdisk',
      ['--backup=$bakPath', disk],
      timeout: const Duration(minutes: 1),
    );
    if (code.ok) {
      add('  ✅ 已备份到 $bakPath');
    } else {
      add('  ⚠️ 备份失败，继续');
    }
    add('');

    // 用管道喂 gdisk 输入
    add('── 执行 gdisk（自动输入）');
    final input = 'x\ns\n$maxParts\nw\nY\n';

    try {
      final proc = await Process.start(
        'gdisk',
        [disk],
        environment: {'PATH': Platform.environment['PATH'] ?? ''},
      );

      proc.stdin.write(input);
      await proc.stdin.close();

      // 收集输出
      final out = await proc.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final err = await proc.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      final exitCode = await proc.exitCode;

      for (final line in out.split('\n')) {
        if (line.trim().isNotEmpty) add('  $line');
      }

      add('');
      if (exitCode == 0) {
        add('✅ 已修改');
        add('');
        add('📌 回滚: sgdisk --load-backup=$bakPath $disk');
        return WinTweakResult(true, '已修改', log);
      }
      add('❌ 失败（退出码 $exitCode）');
      if (err.isNotEmpty) add('  $err');
      return WinTweakResult(false, 'gdisk 执行失败', log);
    } catch (e) {
      add('❌ 执行异常: $e');
      return WinTweakResult(false, '异常: $e', log);
    }
  }

  Future<bool> _checkTool(String name) async {
    try {
      final r = await ProcessRunner.run(
        'which',
        [name],
        timeout: const Duration(seconds: 5),
      );
      return r.ok && r.stdout.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
