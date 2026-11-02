import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import 'lkpatcher_service.dart';
import 'val_protocol_service.dart';
import 'xiaomi_unlock_service.dart';

/// BL 解锁方式
enum BlUnlockMethod {
  /// 高通 fastboot 官方解锁
  fastbootOem('fastboot', 'fastboot oem unlock（高通官方）'),

  /// MTK mtkclient seccfg 解锁（BROM 漏洞）
  mtkSeccfg('mtk-seccfg', 'MTK seccfg 解锁（需 BROM 漏洞）'),

  /// MTK seccfg 加锁
  mtkSeccfgLock('mtk-lock', 'MTK seccfg 加锁'),

  /// 华为麒麟 NVME 写入（PotatoNV 方式，需拆机短接）
  hisiNvme('hisi-nvme', '华为麒麟 NVME 解锁（需拆机）'),

  /// MTK LK 补丁（禁用校验/消除警告）
  mtkLkPatch('mtk-lkpatch', 'MTK LK 补丁（需 mtkclient + lkpatcher）'),

  /// MTK LK 分析（只读）
  mtkLkAnalyze('mtk-lkanalyze', 'MTK LK 分析（只读，安全）'),

  /// RPMB magic 扫描（只读）
  rpmbScan('rpmb-scan', 'RPMB magic 扫描（只读，HyperOS 持久解锁用）'),

  /// Val Protocol（摩托罗拉 MTK 解锁）
  valProtocol('val-protocol', 'Val Protocol（摩托罗拉 MTK 解锁）'),

  /// 骁龙小米解锁（HyperOS 2.0+，绕过服务器限制）
  xiaomiSoc('xiaomi-soc', '骁龙小米解锁（HyperOS 2.0+）');

  final String id;
  final String label;
  const BlUnlockMethod(this.id, this.label);
}

/// 解锁结果
class BlUnlockResult {
  final bool ok;
  final String message;
  final List<String> log;

  BlUnlockResult(this.ok, this.message, [this.log = const []]);
}

/// Bootloader 解锁服务
///
/// 汇总各平台的解锁技术路线：
///
/// **高通（Qualcomm）**
///   fastboot oem unlock / flashing unlock
///   fastboot flashing unlock_critical
///
/// **联发科（MediaTek）**
///   通过 BROM 漏洞（kamakiri）进入 DA 模式，
///   读 seccfg 分区 → 改 lock_state=3（LKS_UNLOCK）→ 重算 SHA256 → 写回
///   seccfg V4 结构：magic(0x4D4D4D4D) + ver + size + lock_state + ...
///     lock_state: 1=LOCK, 3=UNLOCK, 5=VERIFIED
///   加密类型：SW（纯 SHA256）/ HW / HWXOR / V2 / V3 / V4
///
/// **华为（HiSilicon）**
///   PotatoNV 方式：拆机短接测试点 → fastboot
///   → oem read_bsn 读板号 → 加载对应 bootloader
///   → setvar nve:FBLOCK=0, nve:WVLOCK=<16位码>, nve:USRKEY=SHA256(码)
class BlUnlockService {
  BlUnlockService._();
  static final BlUnlockService instance = BlUnlockService._();

  /// 清理旧的临时目录（防止 /tmp 累积）
  ///
  /// /tmp 在 Linux 上是 tmpfs（吃内存），
  /// 所以每次操作前先清掉上次残留的目录。
  void _cleanOldTempDirs() {
    const prefixes = ['valproto_', 'lkpatch_', 'lkanalyze_', 'rpmb_'];
    try {
      final tmp = Directory.systemTemp;
      for (final e in tmp.listSync()) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        if (prefixes.any((pre) => name.startsWith(pre))) {
          try {
            // 只清超过 1 小时的（避免误删正在用的）
            final stat = e.statSync();
            if (DateTime.now().difference(stat.modified).inHours >= 1) {
              e.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }


  /// 检测当前设备的 BL 锁状态
  ///
  /// 返回 (是否解锁, 原始输出)
  Future<(bool?, String)> checkFastbootLock() async {
    final fb = await AppConfig.fastbootPath();
    final r = await ProcessRunner.run(
      fb,
      ['oem', 'device-info'],
      timeout: AppConfig.normalTimeout,
    );

    final out = r.output;
    if (out.isEmpty) {
      // 试试 getvar
      final r2 = await ProcessRunner.run(
        fb,
        ['getvar', 'unlocked'],
        timeout: AppConfig.normalTimeout,
      );
      final o2 = r2.output.toLowerCase();
      if (o2.contains('unlocked: yes') || o2.contains('unlocked:yes')) {
        return (true, r2.output);
      }
      if (o2.contains('unlocked: no') || o2.contains('unlocked:no')) {
        return (false, r2.output);
      }
      return (null, r2.output);
    }

    final lower = out.toLowerCase();
    if (lower.contains('unlocked: yes') ||
        lower.contains('device is unlocked')) {
      return (true, out);
    }
    if (lower.contains('unlocked: no') ||
        lower.contains('device is locked')) {
      return (false, out);
    }
    return (null, out);
  }

  /// 高通 fastboot 解锁
  ///
  /// 步骤：
  /// 1. fastboot flashing unlock（Android 6+ 标准）
  /// 2. 失败则 fastboot oem unlock（老设备）
  /// 3. 再试 fastboot flashing unlock_critical（关键分区）
  Future<BlUnlockResult> fastbootUnlock({
    void Function(String line)? onLine,
  }) async {
    final fb = await AppConfig.fastbootPath();
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 尝试 fastboot 解锁');

    // 先确认设备在线
    final dev = await ProcessRunner.run(fb, ['devices'],
        timeout: AppConfig.shortTimeout);
    if (!dev.output.contains('fastboot')) {
      return BlUnlockResult(false, '未检测到 fastboot 设备', log);
    }

    final attempts = <List<String>>[
      ['flashing', 'unlock'],
      ['oem', 'unlock'],
      ['flashing', 'unlock_critical'],
    ];

    for (final args in attempts) {
      add('── fastboot ${args.join(" ")}');
      final r = await ProcessRunner.run(fb, args,
          timeout: AppConfig.longTimeout);
      add('  ${r.output.trim()}');

      final lower = r.output.toLowerCase();
      if (lower.contains('okay') ||
          lower.contains('success') ||
          lower.contains('unlocked')) {
        if (!lower.contains('fail') && !lower.contains('not allowed')) {
          add('✅ 解锁命令已下发');
          return BlUnlockResult(
              true, '解锁命令已下发，设备将重启并清空数据', log);
        }
      }
    }

    return BlUnlockResult(false, '所有解锁命令均失败（可能不支持或无权限）', log);
  }

  /// 重新上锁（fastboot）
  Future<BlUnlockResult> fastbootLock({
    void Function(String line)? onLine,
  }) async {
    final fb = await AppConfig.fastbootPath();
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 尝试 fastboot 上锁');
    for (final args in [
      ['flashing', 'lock'],
      ['oem', 'lock'],
    ]) {
      add('── fastboot ${args.join(" ")}');
      final r = await ProcessRunner.run(fb, args,
          timeout: AppConfig.longTimeout);
      add('  ${r.output.trim()}');
      final lower = r.output.toLowerCase();
      if ((lower.contains('okay') || lower.contains('success')) &&
          !lower.contains('fail')) {
        return BlUnlockResult(true, '上锁命令已下发', log);
      }
    }
    return BlUnlockResult(false, '上锁失败', log);
  }

  /// MTK seccfg 解锁（通过 mtkclient）
  ///
  /// 需要：
  /// - MTK 设备进入 BROM 模式（关机后按住音量键插 USB）
  /// - 已安装 MTK VCOM 驱动
  /// - 设备存在 BROM 漏洞（kamakiri）
  Future<BlUnlockResult> mtkUnlock({
    bool lock = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final mtk = await _mtkPath();
    if (mtk == null) {
      return BlUnlockResult(
          false, 'mtk.exe 未找到（需要放到 tools/mtk/ 下）', log);
    }

    add('══ MTK seccfg ${lock ? "上锁" : "解锁"}');
    add('  依赖：BROM 漏洞 + MTK VCOM 驱动');
    add('  设备需处于 BROM 模式（关机 + 音量键 + USB）');

    final r = await ProcessRunner.stream(
      mtk,
      ['da', 'seccfg', lock ? 'lock' : 'unlock'],
      onLine: add,
      timeout: const Duration(minutes: 3),
    );

    if (r == 0) {
      add('✅ seccfg 已${lock ? "上锁" : "解锁"}');
      return BlUnlockResult(true, 'seccfg 操作成功，请重启设备', log);
    }
    return BlUnlockResult(false, 'seccfg 操作失败（退出码 $r）', log);
  }

  /// 华为麒麟 NVME 解锁（PotatoNV 方式）
  ///
  /// **前置条件：必须拆机短接测试点进入 fastboot**
  /// 软件只能做后半段（读板号 → 写 NVME 属性）
  ///
  /// 流程：
  /// 1. oem read_bsn 读板号
  /// 2. oem lock-state info 检查 FBLOCK
  /// 3. getvar:nve:FBLOCK=0（解锁 FBLOCK）
  /// 4. getvar:nve:WVLOCK=<16位随机码>
  /// 5. getvar:nve:USRKEY=SHA256(码)
  Future<BlUnlockResult> hisiUnlock({
    required String unlockCode,
    bool disableFblock = true,
    void Function(String line)? onLine,
  }) async {
    final fb = await AppConfig.fastbootPath();
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (unlockCode.length != 16) {
      return BlUnlockResult(false, '解锁码必须是 16 位', log);
    }

    add('══ 华为麒麟 NVME 解锁');
    add('  ⚠️ 需要设备已拆机短接并进入 fastboot');

    // 1. 读板号
    add('── 读取板号');
    final bsn = await ProcessRunner.run(fb, ['oem', 'read_bsn'],
        timeout: AppConfig.normalTimeout);
    add('  板号: ${bsn.output.trim()}');

    // 2. 检查 FBLOCK
    add('── 检查 FBLOCK 状态');
    var state = await ProcessRunner.run(fb, ['oem', 'lock-state info'],
        timeout: AppConfig.normalTimeout);
    add('  ${state.output.trim()}');
    if (!RegExp(r'UNLOCKED').hasMatch(state.output)) {
      state = await ProcessRunner.run(fb, ['oem', 'backdoor info'],
          timeout: AppConfig.normalTimeout);
      add('  ${state.output.trim()}');
    }
    if (!RegExp(r'UNLOCKED').hasMatch(state.output)) {
      add('❌ FBLOCK 仍锁定，需要先短接测试点');
      return BlUnlockResult(false, 'FBLOCK 锁定（需拆机短接）', log);
    }

    // 3. 写 FBLOCK
    final fblockVal = disableFblock ? '0' : '1';
    add('── 设置 nve:FBLOCK=$fblockVal');
    final f1 = await ProcessRunner.run(
      fb,
      ['oem', 'getvar:nve:FBLOCK=$fblockVal'],
      timeout: AppConfig.normalTimeout,
    );
    add('  ${f1.output.trim()}');

    // 4. 写 WVLOCK
    add('── 设置 nve:WVLOCK');
    final f2 = await ProcessRunner.run(
      fb,
      ['oem', 'getvar:nve:WVLOCK=$unlockCode'],
      timeout: AppConfig.normalTimeout,
    );
    add('  ${f2.output.trim()}');

    // 5. 写 USRKEY（SHA256）
    add('── 设置 nve:USRKEY（SHA256）');
    final sha = _sha256Hex(unlockCode);
    final f3 = await ProcessRunner.run(
      fb,
      ['oem', 'getvar:nve:USRKEY=$sha'],
      timeout: AppConfig.normalTimeout,
    );
    add('  ${f3.output.trim()}');

    final ok = f1.output.contains('ok') ||
        f2.output.contains('ok') ||
        f3.output.contains('ok');
    return BlUnlockResult(
      ok,
      ok ? 'NVME 写入完成，请重启验证' : 'NVME 写入失败',
      log,
    );
  }

  /// 生成 16 位随机解锁码（华为用）
  static String generateUnlockCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    var seed = rand;
    for (var i = 0; i < 16; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      buf.write(chars[seed % chars.length]);
    }
    return buf.toString();
  }

  /// SHA256（纯 Dart 实现，避免额外依赖）
  static String _sha256Hex(String input) {
    // 简化：用 Dart 内置 crypto 需要依赖，这里手写
    final bytes = _sha256Bytes(input.codeUnits);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<int> _sha256Bytes(List<int> data) {
    // SHA-256 标准实现
    const k = <int>[
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    final msg = List<int>.from(data);
    final bitLen = msg.length * 8;
    msg.add(0x80);
    while (msg.length % 64 != 56) {
      msg.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      msg.add((bitLen >> (i * 8)) & 0xFF);
    }

    int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

    for (var chunk = 0; chunk < msg.length; chunk += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        w[i] = (msg[chunk + i * 4] << 24) |
            (msg[chunk + i * 4 + 1] << 16) |
            (msg[chunk + i * 4 + 2] << 8) |
            msg[chunk + i * 4 + 3];
      }
      for (var i = 16; i < 64; i++) {
        final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final ch = (e & f) ^ ((~e) & g);
        final t1 = (h + s1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
        final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final t2 = (s0 + maj) & 0xFFFFFFFF;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xFFFFFFFF;
      }
      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    final out = <int>[];
    for (final v in [h0, h1, h2, h3, h4, h5, h6, h7]) {
      out.addAll([
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);
    }
    return out;
  }


  /// Val Protocol 解锁（摩托罗拉 MTK）
  ///
  /// 流程：读 LK → 生成密钥 → 打补丁 → 重签名 → 可选写回
  Future<BlUnlockResult> valProtocolUnlock({
    String lkPartition = 'lk',
    bool writeBack = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final mtk = await _mtkPath();
    if (mtk == null) {
      return BlUnlockResult(false, 'mtk.exe 未找到', log);
    }
    if (!await ValProtocolService.instance.init()) {
      add('❌ val-protocol 未就绪');
      add('  需要：Python 3 + tools/val-protocol/ 下的脚本');
      return BlUnlockResult(false, 'val-protocol 未就绪', log);
    }

    _cleanOldTempDirs();
    final workDir = Directory.systemTemp.createTempSync('valproto_');
    final lkImg = '${workDir.path}${Platform.pathSeparator}lk.img';

    add('══ Val Protocol 解锁流程');
    add('  适用：摩托罗拉 MTK 设备');
    add('  工作目录: ${workDir.path}');

    // 1. 读 LK
    add('── 步骤 1/3: 读取 LK 分区');
    final c1 = await ProcessRunner.stream(
      mtk,
      ['r', lkPartition, lkImg],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (c1 != 0 || !File(lkImg).existsSync()) {
      return BlUnlockResult(false, '读取 LK 失败', log);
    }
    add('  ✅ 已读取');

    // 2. 打补丁 + 重签名
    add('── 步骤 2/3: 打补丁 + 重签名');
    final vr = await ValProtocolService.instance.fullFlow(
      lkImage: lkImg,
      onLine: add,
    );
    if (!vr.ok) {
      return BlUnlockResult(false, vr.message, log);
    }
    add('  ✅ ${vr.message}');

    // 3. 写回
    if (!writeBack) {
      add('── 步骤 3/3: 跳过写回');
      add('📁 补丁镜像在: ${workDir.path}');
      return BlUnlockResult(true, 'Val Protocol 补丁完成（未写回）', log);
    }

    // 从 vr.message 提取签名后的路径
    final lines = vr.message.split('\n');
    String? signedPath;
    for (final l in lines) {
      if (l.contains('signed.img') || l.contains('签名:')) {
        final m = RegExp(r'[:：]\s*(\S+\.img)').firstMatch(l);
        if (m != null) signedPath = m.group(1);
      }
    }
    if (signedPath == null || !File(signedPath).existsSync()) {
      add('❌ 找不到签名后的镜像');
      return BlUnlockResult(false, '找不到签名镜像', log);
    }

    add('── 步骤 3/3: 写回 LK');
    add('  ⚠️ 有变砖风险！');
    final c3 = await ProcessRunner.stream(
      mtk,
      ['w', lkPartition, signedPath],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (c3 != 0) {
      return BlUnlockResult(false, '写回失败', log);
    }
    add('✅ 写回成功，请重启验证');
    return BlUnlockResult(true, 'Val Protocol 已写入，重启后生效', log);
  }


  /// 骁龙小米解锁（HyperOS 2.0+）
  ///
  /// 绕过小米服务器端解锁资格检查，直接改 GPT 引导自定义镜像。
  /// 支持 7 款骁龙 8 Gen3 机型。
  Future<BlUnlockResult> xiaomiSocUnlock({
    required String serial,
    required XiaomiSocModel model,
    required String factoryImagesDir,
    void Function(String line)? onLine,
  }) async {
    final r = await XiaomiUnlockService.instance.unlock(
      serial: serial,
      model: model,
      factoryImagesDir: factoryImagesDir,
      onLine: onLine,
    );
    return BlUnlockResult(r.ok, r.message, r.log);
  }

  /// 找 mtk.exe
  Future<String?> _mtkPath() async {
    for (final sub in ['tools/mtk', 'tools']) {
      final p = '${AppConfig.exeDir}${Platform.pathSeparator}$sub'
          '${Platform.pathSeparator}mtk.exe';
      if (File(p).existsSync()) return p;
    }
    // assets 提取
    try {
      final path = await AppConfig.toolPath('mtk');
      if (File(path).existsSync()) return path;
    } catch (_) {}
    return null;
  }
}

/// LK 补丁流程（MTK）
extension LkPatchFlow on BlUnlockService {
  /// 完整流程：读 LK 分区 → 打补丁 → 写回
  ///
  /// 依赖：mtk.exe（读/写分区）+ lkpatcher（打补丁）
  Future<BlUnlockResult> mtkLkPatch({
    String lkPartition = 'lk',
    Set<String> categories = const {
      'fastboot',
      'dm_verity',
      'orange_state',
      'red_state'
    },
    bool writeBack = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final mtk = await _mtkPathPublic();
    if (mtk == null) {
      return BlUnlockResult(false, 'mtk.exe 未找到', log);
    }

    _cleanOldTempDirs();
    final workDir = Directory.systemTemp.createTempSync('lkpatch_');
    final lkImg = '${workDir.path}${Platform.pathSeparator}lk.img';
    final patchedImg =
        '${workDir.path}${Platform.pathSeparator}lk_patched.img';

    add('══ LK 补丁流程');
    add('  工作目录: ${workDir.path}');

    // 1. 读 LK 分区
    add('── 步骤 1/3: 读取 \$lkPartition 分区');
    final c1 = await ProcessRunner.stream(
      mtk,
      ['r', lkPartition, lkImg],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (c1 != 0 || !File(lkImg).existsSync()) {
      add('❌ 读取失败（退出码 $c1）');
      return BlUnlockResult(false, '读取 LK 分区失败', log);
    }
    final sz = File(lkImg).lengthSync();
    add('  ✅ 已读取 ${(sz / 1024 / 1024).toStringAsFixed(2)} MB');

    // 2. 打补丁
    add('── 步骤 2/3: lkpatcher 打补丁');
    if (!await LkpatcherService.instance.init()) {
      add('❌ lkpatcher 未就绪（需 Python + lkpatcher 包）');
      add('  安装: pip install git+https://github.com/R0rt1z2/lkpatcher');
      return BlUnlockResult(false, 'lkpatcher 未就绪', log);
    }

    final pc = await LkpatcherService.instance.patch(
      imagePath: lkImg,
      outputPath: patchedImg,
      options: LkPatchOptions(
        categories: categories,
        certBypass: true,
        dryRun: !writeBack,
      ),
      onLine: add,
    );
    if (pc != 0 || !File(patchedImg).existsSync()) {
      add('❌ 补丁失败（退出码 $pc）');
      return BlUnlockResult(false, 'LK 补丁失败', log);
    }
    add('  ✅ 补丁完成');

    // 3. 写回（可选）
    if (!writeBack) {
      add('── 步骤 3/3: 跳过写回（演练模式）');
      add('');
      add('📁 补丁后的镜像: $patchedImg');
      add('   确认无误后勾选「写回设备」重新执行');
      return BlUnlockResult(
          true, 'LK 补丁完成（未写回，镜像在 $patchedImg）', log);
    }

    add('── 步骤 3/3: 写回 $lkPartition 分区');
    add('  ⚠️ 写回有变砖风险！');
    final c3 = await ProcessRunner.stream(
      mtk,
      ['w', lkPartition, patchedImg],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (c3 != 0) {
      add('❌ 写回失败（退出码 $c3）');
      return BlUnlockResult(false, '写回失败', log);
    }
    add('✅ 写回成功，请重启验证');
    return BlUnlockResult(true, 'LK 补丁已写入，重启后生效', log);
  }

  /// 只分析 LK 分区（安全只读）
  Future<BlUnlockResult> mtkLkAnalyze({
    String lkPartition = 'lk',
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final mtk = await _mtkPathPublic();
    if (mtk == null) {
      return BlUnlockResult(false, 'mtk.exe 未找到', log);
    }

    _cleanOldTempDirs();
    final workDir = Directory.systemTemp.createTempSync('lkanalyze_');
    final lkImg = '${workDir.path}${Platform.pathSeparator}lk.img';

    add('══ LK 分析（只读）');
    add('── 读取 $lkPartition 分区');

    final c = await ProcessRunner.stream(
      mtk,
      ['r', lkPartition, lkImg],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (c != 0 || !File(lkImg).existsSync()) {
      return BlUnlockResult(false, '读取失败', log);
    }

    add('── lkpatcher 分析安全策略');
    final analysis =
        await LkpatcherService.instance.analyzePolicies(lkImg);
    for (final line in analysis.split('\n')) {
      if (line.trim().isNotEmpty) add('  $line');
    }

    return BlUnlockResult(true, '分析完成', log);
  }

  /// 公开 mtk 路径（供 extension 用）
  Future<String?> _mtkPathPublic() => _mtkPath();
}

/// RPMB magic 扫描与擦除（HyperOS 持久解锁）
extension RpmbBypassFlow on BlUnlockService {
  /// 扫描 LK 分区里的 RPMB magic 字符串
  ///
  /// 原理：HyperOS 在 LK 里存了 magic 标记，每次启动检查，
  /// 发现已解锁就恢复锁定。擦掉 magic 可迫使 LK 回退到 seccfg 校验。
  Future<BlUnlockResult> scanRpmbMagic({
    String lkPartition = 'lk',
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final mtk = await _mtkPathPublic();
    if (mtk == null) {
      return BlUnlockResult(false, 'mtk.exe 未找到', log);
    }

    _cleanOldTempDirs();
    final workDir = Directory.systemTemp.createTempSync('rpmb_');
    final lkImg = '${workDir.path}${Platform.pathSeparator}lk.img';

    add('══ RPMB magic 扫描');
    add('── 读取 $lkPartition');

    final c = await ProcessRunner.stream(
      mtk,
      ['r', lkPartition, lkImg],
      onLine: add,
      timeout: const Duration(minutes: 5),
    );
    if (c != 0 || !File(lkImg).existsSync()) {
      return BlUnlockResult(false, '读取失败', log);
    }

    // 扫描常见 magic 字符串
    final bytes = await File(lkImg).readAsBytes();
    add('  镜像大小: ${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB');

    // HyperOS RPMB magic 候选（来自社区研究）
    final magics = <String, List<int>>{
      'HYPEROS_LOCK': 'HYPEROS_LOCK'.codeUnits,
      'is_unlocked': 'is_unlocked'.codeUnits,
      'rpmb_magic': 'rpmb_magic'.codeUnits,
      'MIUI_LOCK': 'MIUI_LOCK'.codeUnits,
    };

    var found = 0;
    for (final entry in magics.entries) {
      final pattern = entry.value;
      final offsets = _findPattern(bytes, pattern);
      if (offsets.isNotEmpty) {
        found++;
        add('  ✓ 找到 ${entry.key} @ ${offsets.take(3).map((o) => '0x${o.toRadixString(16)}').join(', ')}'
            '${offsets.length > 3 ? " (共 ${offsets.length} 处)" : ""}');
      }
    }

    if (found == 0) {
      add('  ⚠️ 未找到已知 magic 字符串');
      add('  可能该机型不需要 RPMB 绕过，或 magic 是动态生成的');
      return BlUnlockResult(false, '未找到 RPMB magic', log);
    }

    add('');
    add('📁 LK 镜像已保存: $lkImg');
    add('   共找到 $found 类 magic');
    return BlUnlockResult(true, '扫描完成，找到 $found 类 magic', log);
  }

  /// 在字节数组里找模式
  List<int> _findPattern(List<int> data, List<int> pattern) {
    final result = <int>[];
    if (pattern.isEmpty || data.length < pattern.length) return result;
    for (var i = 0; i <= data.length - pattern.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) result.add(i);
    }
    return result;
  }
}
