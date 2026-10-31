import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/bl_unlock_service.dart';
import '../../services/device_provider.dart';
import '../../services/bl_knowledge.dart';
import '../../services/unlock_guide.dart';
import '../../services/xiaomi_unlock_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Bootloader 解锁
///
/// 汇总三种技术路线：
/// · 高通：fastboot oem unlock
/// · 联发科：seccfg 分区改写（BROM 漏洞）
/// · 华为：NVME 属性写入（需拆机短接）
class BlUnlockPage extends StatefulWidget {
  const BlUnlockPage({super.key});

  @override
  State<BlUnlockPage> createState() => _BlUnlockPageState();
}

class _BlUnlockPageState extends State<BlUnlockPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  BlUnlockMethod _method = BlUnlockMethod.fastbootOem;
  String _guideSearch = '';
  BrandUnlockInfo? _selectedBrand;
  bool _guideLoaded = false;
  final _guideSearchController = TextEditingController();

  // 技术资料库
  bool _kbLoaded = false;
  String _kbSearch = '';
  int _kbInitMode = 0;
  KnowledgeSection? _kbSection;
  int _kbMode = 0; // 0=章节 1=机型 2=方法
  final _kbSearchController = TextEditingController();
  bool _busy = false;
  bool? _lockState;
  String? _lockRaw;
  final _hisiCodeController = TextEditingController();
  String _lkPartition = 'lk';
  bool _lkWriteBack = false;
  final Set<String> _lkCategories = {
    'fastboot', 'dm_verity', 'orange_state', 'red_state'
  };

  // 骁龙小米解锁
  XiaomiSocModel _xiaomiModel = XiaomiSocModel.mi14;
  String? _factoryImagesDir;
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    var initialTab = 0;
    final envTab = Platform.environment['GAOJI_BL_TAB'];
    if (envTab != null) initialTab = int.tryParse(envTab) ?? 0;
    _tabController = TabController(length: 3, vsync: this, initialIndex: initialTab);
    _hisiCodeController.text = BlUnlockService.generateUnlockCode();
    _kbInitMode = int.tryParse(Platform.environment['GAOJI_KB_MODE'] ?? '') ?? 0;
    _kbMode = _kbInitMode;
    _loadGuide();
  }

  Future<void> _loadGuide() async {
    await UnlockGuide.instance.load();
    await BlKnowledge.instance.load();
    if (!mounted) return;
    setState(() {
      _guideLoaded = true;
      _kbLoaded = true;
    });
    // 自动匹配当前设备品牌
    final dp = context.read<DeviceProvider>();
    final d = dp.selectedDevice;
    if (d != null) {
      final id = UnlockGuide.instance
          .guessBrand(brand: d.brand, manufacturer: d.manufacturer);
      if (id != null) {
        setState(() => _selectedBrand = UnlockGuide.instance.byId(id));
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hisiCodeController.dispose();
    _guideSearchController.dispose();
    _kbSearchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _checkLock() async {
    setState(() => _busy = true);
    final (state, raw) = await BlUnlockService.instance.checkFastbootLock();
    if (!mounted) return;
    setState(() {
      _lockState = state;
      _lockRaw = raw;
      _busy = false;
    });
  }

  Future<void> _run() async {
    final ok = await _confirm(
      '确认操作',
      _confirmText(),
    );
    if (!ok) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    BlUnlockResult result;
    switch (_method) {
      case BlUnlockMethod.fastbootOem:
        result = await BlUnlockService.instance.fastbootUnlock(onLine: _addLog);
      case BlUnlockMethod.mtkSeccfg:
        result = await BlUnlockService.instance.mtkUnlock(onLine: _addLog);
      case BlUnlockMethod.mtkSeccfgLock:
        result =
            await BlUnlockService.instance.mtkUnlock(lock: true, onLine: _addLog);
      case BlUnlockMethod.hisiNvme:
        result = await BlUnlockService.instance.hisiUnlock(
          unlockCode: _hisiCodeController.text.trim(),
          onLine: _addLog,
        );
      case BlUnlockMethod.mtkLkPatch:
        result = await BlUnlockService.instance.mtkLkPatch(
          lkPartition: _lkPartition,
          categories: _lkCategories,
          writeBack: _lkWriteBack,
          onLine: _addLog,
        );
      case BlUnlockMethod.mtkLkAnalyze:
        result = await BlUnlockService.instance.mtkLkAnalyze(
          lkPartition: _lkPartition,
          onLine: _addLog,
        );
      case BlUnlockMethod.rpmbScan:
        result = await BlUnlockService.instance.scanRpmbMagic(
          lkPartition: _lkPartition,
          onLine: _addLog,
        );
      case BlUnlockMethod.valProtocol:
        result = await BlUnlockService.instance.valProtocolUnlock(
          lkPartition: _lkPartition,
          writeBack: _lkWriteBack,
          onLine: _addLog,
        );
      case BlUnlockMethod.xiaomiSoc:
        if (!mounted) return;
        final dev = context.read<DeviceProvider>().selectedDevice;
        if (dev == null) {
          result = BlUnlockResult(false, '未选中设备', []);
        } else if (_factoryImagesDir == null) {
          result = BlUnlockResult(false, '请先选择 factoryImages 目录', []);
        } else {
          result = await BlUnlockService.instance.xiaomiSocUnlock(
            serial: dev.serial,
            model: _xiaomiModel,
            factoryImagesDir: _factoryImagesDir!,
            onLine: _addLog,
          );
        }
    }

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(result.ok ? '✅ ${result.message}' : '❌ ${result.message}');
  }

  String _confirmText() {
    switch (_method) {
      case BlUnlockMethod.fastbootOem:
        return '将执行 fastboot flashing unlock / oem unlock。\n\n'
            '⚠️ 会清空所有用户数据！\n'
            '⚠️ 可能导致保修失效\n\n'
            '继续？';
      case BlUnlockMethod.mtkSeccfg:
        return '将改写 MTK 设备的 seccfg 分区（lock_state → 3=UNLOCK）。\n\n'
            '前置条件：\n'
            '· 设备处于 BROM 模式（关机 + 音量键 + USB）\n'
            '· 已装 MTK VCOM 驱动\n'
            '· 设备存在 BROM 漏洞（kamakiri）\n\n'
            '⚠️ 操作有变砖风险，请确认已备份！\n\n'
            '继续？';
      case BlUnlockMethod.mtkSeccfgLock:
        return '将把 seccfg 的 lock_state 改回 1（LOCKED）。\n\n'
            '⚠️ 上锁后可能无法启动已修改的系统！\n\n'
            '继续？';
      case BlUnlockMethod.hisiNvme:
        return '将写入华为麒麟设备的 NVME 属性（FBLOCK / WVLOCK / USRKEY）。\n\n'
            '⚠️ 必须已拆机短接测试点并进入 fastboot\n'
            '⚠️ 操作不当会导致设备无法启动\n\n'
            '继续？';
      case BlUnlockMethod.mtkLkPatch:
        return '将读取 $_lkPartition 分区 → lkpatcher 打补丁'
            '${_lkWriteBack ? " → 写回设备" : "（不写回，仅生成镜像）"}。\n\n'
            '补丁分类: ${_lkCategories.join(", ")}\n\n'
            '${_lkWriteBack ? "⚠️ 写回有变砖风险！\n\n" : ""}'
            '前置条件：\n'
            '· 设备处于 BROM 模式\n'
            '· 已装 Python + lkpatcher\n\n'
            '继续？';
      case BlUnlockMethod.mtkLkAnalyze:
        return '只读分析：读取 $_lkPartition 分区并分析安全策略。\n\n'
            '不写入任何数据，安全。\n\n'
            '继续？';
      case BlUnlockMethod.rpmbScan:
        return '只读扫描：读取 $_lkPartition 分区，查找 RPMB magic 字符串。\n\n'
            '不写入任何数据，安全。\n\n'
            '继续？';
      case BlUnlockMethod.xiaomiSoc:
        return '将执行骁龙小米解锁（${_xiaomiModel.displayName}）。\n\n'
            '⚠️ 会清空所有数据！\n'
            '⚠️ 会失去官方保修！\n'
            '⚠️ 操作失败可能变砖！\n\n'
            '技术路线：exploit 提权 → SELinux → 写工程 ABL → 改 GPT → 引导自定义镜像\n\n'
            '需要：factoryImages 目录（原厂镜像）\n'
            '当前: ${_factoryImagesDir ?? "未选择"}\n\n'
            '继续？';
      case BlUnlockMethod.valProtocol:
        return '将执行 Val Protocol 解锁流程（摩托罗拉 MTK 设备）。\n\n'
            '流程：读 LK → 打补丁 → 重签名'
            '${_lkWriteBack ? " → 写回设备" : "（不写回）"}\n\n'
            '${_lkWriteBack ? "⚠️ 写回有变砖风险！\n\n" : ""}'
            '前置条件：\n'
            '· 设备处于 BROM 模式\n'
            '· 已装 Python 3\n'
            '· tools/val-protocol/ 有脚本\n\n'
            '继续？';
    }
  }

  Future<bool> _confirm(String title, String content) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(content,
              style: const TextStyle(fontSize: 13, height: 1.6)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('确认执行'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: TabBar(
            controller: _tabController,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primary,
            labelStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(height: 42, text: '解锁操作'),
              Tab(height: 42, text: '品牌指南'),
              Tab(height: 42, text: '技术资料库'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildUnlockTab(),
              _buildGuideTab(),
              _buildKnowledgeTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ═══ Tab 1: 解锁操作 ═══
  Widget _buildUnlockTab() {
    final device = context.watch<DeviceProvider>().selectedDevice;

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 警告
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber,
                          size: 18, color: AppTheme.danger),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '解锁 Bootloader 会清空数据、可能失去保修，操作不当会变砖。\n'
                          '请确认已备份，并了解自己的设备型号。',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 当前状态
                AppCard(
                  title: '当前状态',
                  trailing: _busy
                      ? const InlineLoader()
                      : IconButton(
                          icon: const Icon(Icons.refresh, size: 16),
                          color: AppTheme.textSecondary,
                          visualDensity: VisualDensity.compact,
                          onPressed: _checkLock,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _lockState == null
                                ? Icons.help_outline
                                : (_lockState!
                                    ? Icons.lock_open
                                    : Icons.lock),
                            size: 20,
                            color: _lockState == null
                                ? AppTheme.textMuted
                                : (_lockState!
                                    ? AppTheme.success
                                    : AppTheme.warning),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _lockState == null
                                ? '未检测（需设备处于 fastboot 模式）'
                                : (_lockState! ? '已解锁' : '已锁定'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _lockState == null
                                  ? AppTheme.textMuted
                                  : (_lockState!
                                      ? AppTheme.success
                                      : AppTheme.warning),
                            ),
                          ),
                          const Spacer(),
                          if (device != null)
                            Text(device.displayName,
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.textMuted)),
                        ],
                      ),
                      if (_lockRaw != null && _lockRaw!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgElevated,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: SelectableText(
                            _lockRaw!,
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: AppTheme.textMuted,
                                height: 1.4),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 方式选择
                AppCard(
                  title: '解锁方式',
                  child: Column(
                    children: [
                      for (final m in BlUnlockMethod.values)
                        InkWell(
                          onTap: () => setState(() => _method = m),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 9),
                            child: Row(
                              children: [
                                Icon(
                                  _method == m
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 17,
                                  color: _method == m
                                      ? AppTheme.primary
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(m.label,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: _method == m
                                            ? AppTheme.textPrimary
                                            : AppTheme.textSecondary,
                                      )),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 华为专用：解锁码
                if (_method == BlUnlockMethod.hisiNvme)
                  AppCard(
                    title: '华为解锁码',
                    trailing: TextButton(
                      onPressed: () => setState(() => _hisiCodeController.text =
                          BlUnlockService.generateUnlockCode()),
                      child:
                          const Text('重新生成', style: TextStyle(fontSize: 11.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _hisiCodeController,
                          style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              letterSpacing: 2),
                          maxLength: 16,
                          decoration: const InputDecoration(
                            labelText: '16 位解锁码',
                            isDense: true,
                            counterText: '',
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '该码会写入 nve:WVLOCK，其 SHA256 写入 nve:USRKEY。\n'
                          '请务必记下，之后解锁需要用到。',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textMuted,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                if (_method == BlUnlockMethod.hisiNvme)
                  const SizedBox(height: 14),

                // 骁龙小米专用：机型 + factoryImages
                if (_method == BlUnlockMethod.xiaomiSoc) ...[
                  AppCard(
                    title: '选择机型',
                    child: Column(
                      children: [
                        for (final m in XiaomiSocModel.values)
                          InkWell(
                            onTap: () =>
                                setState(() => _xiaomiModel = m),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 7),
                              child: Row(
                                children: [
                                  Icon(
                                    _xiaomiModel == m
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    size: 16,
                                    color: _xiaomiModel == m
                                        ? AppTheme.primary
                                        : AppTheme.textMuted,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(m.displayName,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: _xiaomiModel == m
                                              ? AppTheme.textPrimary
                                              : AppTheme.textSecondary,
                                        )),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.bgElevated,
                                      borderRadius:
                                          BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'exploit: ${m.binDir}',
                                      style: const TextStyle(
                                          fontSize: 9.5,
                                          fontFamily: 'monospace',
                                          color: AppTheme.textMuted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  AppCard(
                    title: 'factoryImages 目录',
                    trailing: OutlinedButton(
                      onPressed: () async {
                        final dir = await FilePicker.platform
                            .getDirectoryPath(
                                dialogTitle: '选择机型的 factoryImages 目录');
                        if (dir != null) {
                          setState(() => _factoryImagesDir = dir);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                      child: const Text('选择',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _factoryImagesDir ??
                              '未选择（需要含 images/abl.elf 的目录）',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: _factoryImagesDir != null
                                ? AppTheme.textPrimary
                                : AppTheme.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '结构应为：\n'
                          '  <选择的目录>/images/abl.elf\n'
                          '  <选择的目录>/images/gpt_both4.bin\n\n'
                          '从 Mi8G3-Unlocker 的 Release 包里\n'
                          'unlockFolder/factoryImages/<机型>/ 复制出来',
                          style: TextStyle(
                              fontSize: 10.5,
                              color: AppTheme.textMuted,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // 技术说明
                AppCard(
                  title: '技术原理',
                  child: Text(
                    _techNote(),
                    style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textSecondary,
                        height: 1.7),
                  ),
                ),
                const SizedBox(height: 18),

                // 执行按钮
                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _run,
                    icon: Icon(
                        _busy ? Icons.hourglass_top : Icons.lock_open,
                        size: 18),
                    label: Text(_busy ? '执行中…' : '执行解锁'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.danger,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 日志
        Container(
          width: 360,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal, size: 15, color: AppTheme.accent),
                    const SizedBox(width: 8),
                    const Text('执行日志',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 15),
                      color: AppTheme.textMuted,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _log.clear()),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFF0A0C10),
                  child: _log.isEmpty
                      ? const Center(
                          child: Text('等待操作…',
                              style: TextStyle(
                                  fontSize: 12, color: AppTheme.textMuted)))
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(10),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final line = _log[i];
                            Color c = AppTheme.textSecondary;
                            if (line.contains('✅')) c = AppTheme.success;
                            if (line.contains('❌') || line.contains('⚠️')) {
                              c = AppTheme.danger;
                            }
                            if (line.startsWith('══')) c = AppTheme.accent;
                            return SelectableText(line,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: c,
                                    height: 1.45));
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
      );
  }


  // ═══ Tab 2: 品牌解锁指南 ═══
  Widget _buildGuideTab() {
    if (!_guideLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final brands = UnlockGuide.instance.search(_guideSearch);

    // 测试用：自动选第一个品牌
    if (_selectedBrand == null &&
        Platform.environment['GAOJI_AUTO_BRAND'] == '1' &&
        brands.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedBrand = brands.first);
      });
    }

    return Row(
      children: [
        Container(
          width: 230,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _guideSearchController,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: const InputDecoration(
                      hintText: '搜索品牌…',
                      prefixIcon: Icon(Icons.search, size: 15),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                    ),
                    onChanged: (v) => setState(() => _guideSearch = v),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: brands.length,
                  itemBuilder: (context, i) {
                    final b = brands[i];
                    final sel = _selectedBrand?.id == b.id;
                    return InkWell(
                      onTap: () => setState(() => _selectedBrand = b),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        color: sel
                            ? AppTheme.primary.withValues(alpha: 0.1)
                            : Colors.transparent,
                        child: Row(
                          children: [
                            Icon(
                              b.officialSupport
                                  ? Icons.check_circle_outline
                                  : Icons.block,
                              size: 14,
                              color: b.officialSupport
                                  ? AppTheme.success
                                  : AppTheme.danger,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                b.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: sel
                                      ? AppTheme.primary
                                      : AppTheme.textPrimary,
                                  fontWeight: sel
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: const Text(
                  '数据源：Bootloader Unlock Wall of Shame\nCC BY-NC-SA 4.0',
                  style: TextStyle(
                      fontSize: 9.5, color: AppTheme.textMuted, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _selectedBrand == null
              ? const EmptyState(
                  icon: Icons.menu_book_outlined,
                  title: '选择一个品牌',
                  subtitle: '查看该品牌的 Bootloader 解锁政策与可行性',
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _selectedBrand!.officialSupport
                                ? Icons.check_circle
                                : Icons.cancel,
                            size: 22,
                            color: _selectedBrand!.officialSupport
                                ? AppTheme.success
                                : AppTheme.danger,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _selectedBrand!.name,
                              style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: (_selectedBrand!.officialSupport
                                  ? AppTheme.success
                                  : AppTheme.danger)
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _selectedBrand!.verdictSummary,
                          style: TextStyle(
                            fontSize: 12,
                            color: _selectedBrand!.officialSupport
                                ? AppTheme.success
                                : AppTheme.danger,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 12),
                      ..._renderMarkdown(_selectedBrand!.markdown),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// 极简 Markdown 渲染
  List<Widget> _renderMarkdown(String md) {
    final widgets = <Widget>[];
    for (final raw in md.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }
      if (line.startsWith('# ')) continue;
      if (line.startsWith('## ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Text(line.substring(3).trim(),
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
        ));
        continue;
      }
      if (line.startsWith('### ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(line.substring(4).trim(),
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
        ));
        continue;
      }
      if (RegExp(r'^\s*[*-]\s').hasMatch(line)) {
        final text = line.replaceFirst(RegExp(r'^\s*[*-]\s+'), '');
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Icon(Icons.circle, size: 4, color: AppTheme.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_cleanInline(text),
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                        height: 1.6)),
              ),
            ],
          ),
        ));
        continue;
      }
      if (line.startsWith('>')) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border(
                left: BorderSide(
                    color: AppTheme.warning.withValues(alpha: 0.5), width: 3),
              ),
            ),
            child: Text(
              _cleanInline(line.replaceFirst(RegExp(r'^>+\s*'), '')),
              style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textSecondary,
                  height: 1.6),
            ),
          ),
        ));
        continue;
      }
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(_cleanInline(line),
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSecondary, height: 1.65)),
      ));
    }
    return widgets;
  }

  String _cleanInline(String s) {
    var t = s;
    // HTML 换行标签 → 空格（unlock_guide.json 里有 41 处 <br/>）
    t = t.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
    // 其他 HTML 标签直接去掉
    t = t.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');
    // 链接 [text](url) → text
    t = t.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
    // 加粗 **text** → text
    t = t.replaceAllMapped(
        RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1)!);
    // 行内代码 `text` → text
    t = t.replaceAllMapped(
        RegExp(r'`([^`]+)`'), (m) => m.group(1)!);
    // 多个空格合并
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ');
    return t.trim();
  }


  // ═══ Tab 3: 技术资料库 ═══
  Widget _buildKnowledgeTab() {
    if (!_kbLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // 模式切换
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              for (final (i, label) in [
                (0, '品牌详解'),
                (1, '小米机型表'),
                (2, '技术方法'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 11.5)),
                    selected: _kbMode == i,
                    onSelected: (_) => setState(() => _kbMode = i),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 30,
                  child: TextField(
                    controller: _kbSearchController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: '搜索…',
                      prefixIcon: Icon(Icons.search, size: 14),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 5),
                    ),
                    onChanged: (v) => setState(() => _kbSearch = v),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _kbMode == 0
              ? _buildSectionBrowser()
              : _kbMode == 1
                  ? _buildXiaomiTable()
                  : _buildMethodList(),
        ),
      ],
    );
  }

  // 模式 0：品牌详解
  Widget _buildSectionBrowser() {
    final list = BlKnowledge.instance.searchSections(_kbSearch);
    return Row(
      children: [
        Container(
          width: 210,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: AppTheme.border)),
          ),
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final sec = list[i];
              final sel = _kbSection?.title == sec.title;
              return InkWell(
                onTap: () => setState(() => _kbSection = sec),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  color: sel
                      ? AppTheme.primary.withValues(alpha: 0.1)
                      : Colors.transparent,
                  child: Text(
                    sec.title,
                    style: TextStyle(
                      fontSize: 12,
                      color: sel ? AppTheme.primary : AppTheme.textPrimary,
                      fontWeight:
                          sel ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _kbSection == null
              ? const EmptyState(
                  icon: Icons.library_books_outlined,
                  title: '选择左侧章节',
                  subtitle: '2026 全网最全 BL 解锁现状（20 个品牌）',
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _kbSection!.title,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary),
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 12),
                      ..._renderMarkdown(_kbSection!.content),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // 模式 1：小米机型表
  Widget _buildXiaomiTable() {
    final list = BlKnowledge.instance.searchXiaomi(_kbSearch);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: AppTheme.bgElevated,
          child: const Row(
            children: [
              Expanded(flex: 3, child: Text('机型', style: _hdr2)),
              SizedBox(width: 90, child: Text('代号', style: _hdr2)),
              SizedBox(width: 100, child: Text('系统', style: _hdr2)),
              SizedBox(width: 80, child: Text('状态', style: _hdr2)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = list[i];
              Color c;
              IconData icon;
              switch (d.status) {
                case 'open':
                  c = AppTheme.success;
                  icon = Icons.check_circle;
                case 'blocked':
                  c = AppTheme.danger;
                  icon = Icons.block;
                case 'unsupported':
                  c = AppTheme.textMuted;
                  icon = Icons.do_not_disturb;
                default:
                  c = AppTheme.warning;
                  icon = Icons.help_outline;
              }
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(d.name,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textPrimary)),
                    ),
                    SizedBox(
                      width: 90,
                      child: Text(d.code,
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppTheme.textMuted)),
                    ),
                    SizedBox(
                      width: 100,
                      child: Text(
                        d.os.length > 12
                            ? '${d.os.substring(0, 12)}…'
                            : d.os,
                        style: const TextStyle(
                            fontSize: 10.5, color: AppTheme.textMuted),
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: Row(
                        children: [
                          Icon(icon, size: 13, color: c),
                          const SizedBox(width: 5),
                          Text(d.statusText,
                              style: TextStyle(fontSize: 11, color: c)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.border)),
          ),
          child: Text(
            '共 ${list.length} 款 · 数据源：Xiaomi-HyperOS-BootLoader-Bypass (4813★)',
            style: const TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
          ),
        ),
      ],
    );
  }

  static const _hdr2 = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: AppTheme.textMuted,
  );

  // 模式 2：技术方法
  Widget _buildMethodList() {
    final list = BlKnowledge.instance.methods;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final m = list[i];
        Color riskColor;
        switch (m.risk) {
          case '低':
            riskColor = AppTheme.success;
          case '中':
            riskColor = AppTheme.warning;
          case '中高':
            riskColor = AppTheme.warning;
          default:
            riskColor = AppTheme.danger;
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(m.platform,
                        style: const TextStyle(
                            fontSize: 10, color: AppTheme.primary)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(m.name,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: riskColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('风险 ${m.risk}',
                        style: TextStyle(fontSize: 10, color: riskColor)),
                  ),
                  if (m.integrated) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('已集成',
                          style: TextStyle(
                              fontSize: 10, color: AppTheme.success)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              // 步骤
              for (var j = 0; j < m.steps.length; j++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 18,
                        child: Text('${j + 1}.',
                            style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: AppTheme.textMuted)),
                      ),
                      Expanded(
                        child: Text(m.steps[j],
                            style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.textSecondary,
                                height: 1.5)),
                      ),
                    ],
                  ),
                ),
              if (m.note.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.bgElevated,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(m.note,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                          height: 1.5)),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _techNote() {
    switch (_method) {
      case BlUnlockMethod.fastbootOem:
        return '高通设备标准方式，通过 fastboot 协议下发解锁命令。\n'
            '命令优先级：flashing unlock → oem unlock → flashing unlock_critical\n'
            '成功后会清空用户数据并重启。';
      case BlUnlockMethod.mtkSeccfg:
        return 'MTK 设备通过 BROM 漏洞（kamakiri）进入 DA 模式，'
            '读取 seccfg 分区并改写 lock_state 字段。\n\n'
            'seccfg V4 结构（28 字节头 + SHA256）：\n'
            '  magic        0x4D4D4D4D ("MMMM")\n'
            '  version      版本号\n'
            '  size         分区大小\n'
            '  lock_state   1=LOCK, 3=UNLOCK, 5=VERIFIED\n'
            '  dm_verity    dm-verity 状态\n'
            '  sboot_runtime\n'
            '  endflag      0x45454545 ("EEEE")\n'
            '  hash         前 28 字节的 SHA256（可能经 SEJ 加密）\n\n'
            '加密类型自动探测：SW / HW / HWXOR / V2 / V3 / V4';
      case BlUnlockMethod.mtkSeccfgLock:
        return '把 seccfg 的 lock_state 改回 1（LOCKED），同时关闭 dm-verity。\n'
            '上锁后如果系统被修改过，可能无法启动。';
      case BlUnlockMethod.mtkLkPatch:
        return 'LK（Little Kernel）是 MTK 设备的 bootloader 镜像。\n'
            '补丁原理：把特定字节序列替换为 00207047（ARM 的 bx lr，直接返回）。\n\n'
            '补丁分类：\n'
            '  fastboot      解锁 fastboot 命令限制\n'
            '  dm_verity     关闭 dm-verity 校验\n'
            '  orange_state  消除橙灯警告\n'
            '  red_state     消除红灯警告\n\n'
            '流程：mtk.exe 读分区 → lkpatcher 打补丁 → 可选写回\n'
            '工具：lkpatcher（R0rt1z2，406★，GPL-3.0）';
      case BlUnlockMethod.mtkLkAnalyze:
        return '只读分析 LK 分区的安全策略，不改动任何数据。\n\n'
            '输出包括：分区结构、证书、策略配置等。\n'
            '用于判断该机型是否值得打补丁。';
      case BlUnlockMethod.xiaomiSoc:
        return '骁龙小米解锁（HyperOS 2.0+），技术来源 Linuxoid-cn/Mi8G3-Unlocker（561★）。\n\n'
            '完整流程（8 步）：\n'
            '  1. 推 exploit + su 到 /data/local/tmp\n'
            '  2. 执行 exploit 提权，验证 uid=0(root)\n'
            '  3. 循环跑 exploit 直到 SELinux = Permissive\n'
            '  4. dd 写入工程 abl.elf 到 abl_a + abl_b\n'
            '  5. fastboot flash partition:4 unlockgpt_both4.bin\n'
            '  6. fastboot boot 8650-Ennea.img（引导自定义镜像）\n'
            '  7. fastboot flash partition:4 gpt_both4.bin（恢复 GPT）\n'
            '  8. fastboot oem device-info 验证 + fastboot erase frp\n\n'
            '原理：绕过小米服务器端解锁资格检查（30天1台/1年4台限制），\n'
            '直接用漏洞修改 GPT 引导自定义镜像完成解锁。\n\n'
            '支持 7 款骁龙 8 Gen3 机型：\n'
            '  Redmi K70 Pro / K80 / Xiaomi 14 / 14 Pro / 14 Ultra / MIX Flip / MIX Fold4';
      case BlUnlockMethod.valProtocol:
        return 'Val Protocol 是摩托罗拉 MTK 设备的解锁方案。\n\n'
            '原理：\n'
            '  · 摩托罗拉 MTK 的 LK（bootloader）存在证书校验缺陷\n'
            '  · 修补 LK 可绕过 fastboot 解锁校验、移除 FRP\n'
            '  · 可添加自定义 fastboot 命令\n\n'
            '流程：\n'
            '  1. mtk.exe 读 LK 分区\n'
            '  2. lk_keygen.py 生成密钥\n'
            '  3. lk_auto_patch.py 打补丁（绕过校验 + FRP）\n'
            '  4. lk_repack_signed.py 重签名\n'
            '  5. mtk.exe 写回 LK\n\n'
            '来源：Maikyxd/val-protocol (96★, AGPL-3.0)\n'
            'GUI 封装：crabcakes97/Valhalla (30★)';
      case BlUnlockMethod.rpmbScan:
        return 'HyperOS/MIUI 14+ 上 seccfg unlock 后重启仍锁定，原因是 LK 里存了 magic 标记，\n'
            '每次启动检查到已解锁就恢复锁定状态。\n\n'
            '扫描原理：在 LK 镜像里查找已知 magic 字符串（HYPEROS_LOCK / is_unlocked 等）。\n'
            '找到后可擦除，迫使 LK 回退到 seccfg 校验路径，实现持久解锁。\n\n'
            '注意：部分 preloader 每次启动会恢复 magic，导致解锁不持久。\n'
            '参考：Jz8Root/xiaomi-hyperos-bootloader-unlock（82★）';
      case BlUnlockMethod.hisiNvme:
        return '华为麒麟设备（Kirin 620/65x/95x/960）专用，源自 PotatoNV 项目。\n\n'
            '前置：必须拆机短接主板测试点进入 fastboot\n\n'
            '流程：\n'
            '  1. oem read_bsn          读板号\n'
            '  2. oem lock-state info   检查 FBLOCK 状态\n'
            '  3. nve:FBLOCK=0          关闭 FBLOCK\n'
            '  4. nve:WVLOCK=<16位码>   写入解锁码\n'
            '  5. nve:USRKEY=SHA256(码) 写入校验值\n\n'
            '注意：Kirin 710/710A/710F/810/970/980/985/990 及更新型号不支持。';
    }
  }
}
