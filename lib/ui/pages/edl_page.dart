import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/edl_service.dart';
import '../../services/gpt_parser.dart';
import '../../services/qdl_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// EDL (9008) 深度刷机
///
/// 高通深度刷机模式，可救砖。
/// 功能对标 GeekFlashTool：解析 rawprogram.xml → 分区列表 → 勾选刷入。
class EdlPage extends StatefulWidget {
  const EdlPage({super.key});

  @override
  State<EdlPage> createState() => _EdlPageState();
}

class _EdlPageState extends State<EdlPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 设备
  List<EdlDevice> _devices = [];
  String? _selectedPort;
  final _portController = TextEditingController();
  bool _scanning = false;

  // 刷机文件
  String? _elfPath;
  String? _xmlPath;
  EdlFlashPlan? _plan;
  final Set<String> _selectedLabels = {};

  // GPT 实时读取
  GptTable? _gptTable;
  bool _gptLoading = false;
  EdlStorage _storage = EdlStorage.ufs;
  bool _resetAfter = true;

  // 刷机引擎：qdl（推荐）或 fh_loader
  String _engine = Platform.isWindows ? 'fh_loader' : 'qdl';
  bool _qdlReady = false;
  String? _qdlVersion;
  QdlBackend _qdlBackend = QdlBackend.qud;

  // 执行
  bool _flashing = false;
  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (Platform.isWindows) _scan();
    _initQdl();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _initQdl() async {
    final ok = await QdlService.instance.init();
    String? ver;
    if (ok) ver = await QdlService.instance.version();
    if (!mounted) return;
    setState(() {
      _qdlReady = ok;
      _qdlVersion = ver;
    });
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final list = await EdlService.instance.scanDevices();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _scanning = false;
      if (list.isNotEmpty && _selectedPort == null) {
        _selectedPort = list.first.comPort;
        _portController.text = list.first.comPort;
      }
    });
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickElf() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 firehose ELF（prog_firehose_*.elf）',
      type: FileType.any,
    );
    if (r != null && r.files.single.path != null) {
      setState(() => _elfPath = r.files.single.path);
      _tryAutoXml();
    }
  }


  /// 实时读取设备 GPT（优先）
  Future<void> _readGpt() async {
    final port = _portController.text.trim();
    if (port.isEmpty) {
      _snack('请先填写 COM 口');
      return;
    }
    if (_elfPath == null) {
      _snack('请先选择 firehose ELF（读 GPT 需要先加载 firehose）');
      return;
    }

    setState(() {
      _gptLoading = true;
      _log.clear();
    });
    _tabController.animateTo(2);

    final workDir = File(_elfPath!).parent.path;

    // 先加载 firehose
    _addLog('══ 步骤 1: 加载 firehose');
    final c1 = await EdlService.instance.loadFirehose(
      comPort: port,
      elfPath: _elfPath!,
      onLine: _addLog,
    );
    if (c1 != 0) {
      _addLog('❌ firehose 加载失败（退出码 $c1）');
      if (mounted) {
        setState(() {
          _gptLoading = false;
        });
      }
      return;
    }
    _addLog('✅ firehose 已加载');
    await Future.delayed(const Duration(seconds: 2));

    // 读 GPT（带重试降级）
    _addLog('══ 步骤 2: 读取分区表');
    final table = await EdlService.instance.readDeviceGptWithFallback(
      comPort: port,
      workDir: workDir,
      onLine: _addLog,
    );

    if (!mounted) return;

    if (table != null && table.partitions.isNotEmpty) {
      setState(() {
        _gptTable = table;
        _gptLoading = false;
        _selectedLabels.clear();
        _selectedLabels.addAll(table.partitions.map((p) => p.name));
      });
      _addLog('✅ 实时分区表就绪：${table.partitions.length} 个分区');
      _tabController.animateTo(1);
    } else {
      // 降级到 XML
      _addLog('⚠️ 实时读取失败，降级到 rawprogram.xml');
      setState(() {
        _gptLoading = false;
      });
      if (_xmlPath != null) {
        await _loadXml(_xmlPath!);

      } else {
        _snack('实时读取失败，且未选择 rawprogram.xml');
      }
    }
  }

  /// 用 rawprogram.xml（降级方案）
  Future<void> _useXmlFallback() async {
    if (_xmlPath == null) {
      await _pickXml();
      return;
    }
    await _loadXml(_xmlPath!);
  }

  Future<void> _pickXml() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 rawprogram XML',
      type: FileType.custom,
      allowedExtensions: ['xml'],
    );
    if (r == null || r.files.single.path == null) return;
    await _loadXml(r.files.single.path!);
  }

  /// ELF 选好后自动找同目录的 rawprogram0.xml
  Future<void> _tryAutoXml() async {
    if (_elfPath == null) return;
    final dir = File(_elfPath!).parent;
    for (final name in [
      'rawprogram0.xml',
      'rawprogram1.xml',
      'rawprogram_unsparse0.xml',
    ]) {
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      if (f.existsSync()) {
        await _loadXml(f.path);
        return;
      }
    }
  }

  Future<void> _loadXml(String path) async {
    setState(() => _xmlPath = path);
    final plan = await EdlService.instance.parseRawprogramXml(path);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _selectedLabels.clear();
      if (plan != null) {
        // 默认全选（除了 patch-only 的）
        _selectedLabels.addAll(plan.flashable.map((e) => e.label));
      }
    });
    if (plan != null) {
      setState(() => _gptTable = null);
      _tabController.animateTo(1);
    }
  }

  Future<void> _startFlash() async {
    final port = _portController.text.trim();
    if (port.isEmpty) {
      _snack('请填写 COM 口');
      return;
    }
    if (_elfPath == null) {
      _snack('请选择 firehose ELF');
      return;
    }
    if (_plan == null || _selectedLabels.isEmpty) {
      _snack('请选择要刷的分区');
      return;
    }

    final ok = await _confirm(
      '开始刷机',
      '端口: $port\n'
      '存储: ${_storage.value}\n'
      'ELF: ${_elfPath!.split(Platform.pathSeparator).last}\n'
      '分区: ${_selectedLabels.length} 个\n\n'
      '⚠️ 刷机有风险，请勿断开 USB！',
    );
    if (!ok) return;

    setState(() {
      _flashing = true;
      _log.clear();
      _tabController.animateTo(2);
    });

    // 1. 生成筛选后的 XML
    _addLog('══ 生成分区清单（${_selectedLabels.length} 个）');
    final filteredXml = await EdlService.instance
        .buildFilteredXml(_plan!.xmlPath, _selectedLabels);
    _addLog('  → $filteredXml');
    _addLog('');

    // ═══ 用 qdl 引擎 ═══
    if (_engine == 'qdl' && _qdlReady) {
      _addLog('══ 使用 qdl 引擎（${_qdlBackend.label}）');

      // qdl 需要 patch XML
      final patchXmls = <String>[];
      final elfDir = File(_elfPath!).parent.path;
      for (final name in ['patch0.xml', 'patch1.xml', 'patch2.xml', 'patch3.xml']) {
        final f = File('$elfDir${Platform.pathSeparator}$name');
        if (f.existsSync()) patchXmls.add(f.path);
      }

      final r = await QdlService.instance.flash(
        loaderPath: _elfPath!,
        xmlPaths: [filteredXml, ...patchXmls],
        imageDir: elfDir,
        backend: _qdlBackend,
        onLine: _addLog,
      );

      // 清理临时 XML
      try {
        File(filteredXml).deleteSync();
      } catch (_) {}

      if (mounted) setState(() => _flashing = false);
      _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
      return;
    }

    // ═══ 用 fh_loader 引擎（原方案）═══

    // 2. Sahara 加载 ELF
    final c1 = await EdlService.instance.loadFirehose(
      comPort: port,
      elfPath: _elfPath!,
      onLine: _addLog,
    );
    if (c1 != 0) {
      _addLog('❌ Sahara 加载失败（退出码 $c1）');
      if (mounted) setState(() => _flashing = false);
      return;
    }
    _addLog('✅ Sahara 加载成功');
    await Future.delayed(const Duration(seconds: 2));

    // 3. fh_loader 刷入
    final c2 = await EdlService.instance.flashPartitions(
      comPort: port,
      elfDir: File(_elfPath!).parent.path,
      xmlPath: filteredXml,
      storage: _storage,
      resetAfter: _resetAfter,
      onLine: _addLog,
    );

    // 清理临时 XML
    try {
      File(filteredXml).deleteSync();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _flashing = false);
    _addLog(c2 == 0 ? '✅ 刷机完成' : '❌ 刷机失败（退出码 $c2）');
  }

  Future<bool> _confirm(String title, String content) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text(title),
        content:
            Text(content, style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始')),
        ],
      ),
    );
    return r ?? false;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    // qdl 是跨平台的，没有 qdl 且非 Windows 时才提示不支持
    if (!Platform.isWindows && !_qdlReady) {
      return EmptyState(
        icon: Icons.desktop_access_disabled,
        title: 'EDL 刷机需要 qdl 或 Windows',
        subtitle: 'Windows：自带 QSaharaServer / fh_loader\n'
            'Linux/macOS：需要 qdl（跨平台 EDL 工具）\n\n'
            'qdl 下载：github.com/linux-msm/qdl/releases\n'
            '放到应用目录 tools/qdl/ 下即可',
        action: ElevatedButton.icon(
          onPressed: _initQdl,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重新检测 qdl'),
        ),
      );
    }

    return Column(
      children: [
        // Tab 栏
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
              Tab(height: 42, text: '① 设备与文件'),
              Tab(height: 42, text: '② 分区表'),
              Tab(height: 42, text: '③ 刷机日志'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSetupTab(),
              _buildPartitionTab(),
              _buildLogTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ═══ Tab 1: 设备与文件 ═══
  Widget _buildSetupTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 警告
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: AppTheme.warning.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber, size: 18, color: AppTheme.warning),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'EDL 是高通深度刷机模式，操作有风险。\n'
                    '进入方式：关机后按住音量上下 + 插 USB，设备管理器显示「Qualcomm HS-USB QDLoader 9008」',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 设备
          AppCard(
            title: 'EDL 设备',
            trailing: IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              color: AppTheme.textSecondary,
              visualDensity: VisualDensity.compact,
              onPressed: _scanning ? null : _scan,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_scanning)
                  const InlineLoader(text: '扫描中')
                else if (_devices.isEmpty)
                  const Text(
                    '未检测到 9008 设备\n\n'
                    '· 关机后按住音量上下 + 插 USB\n'
                    '· 或 adb reboot edl / fastboot oem edl\n'
                    '· 需装 Qualcomm USB Driver',
                    style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                        height: 1.7),
                  )
                else
                  Column(
                    children: [
                      for (final d in _devices)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.usb,
                              size: 16, color: AppTheme.success),
                          title: Text(d.comPort,
                              style: const TextStyle(
                                  fontSize: 12.5, fontFamily: 'monospace')),
                          subtitle: Text(d.description,
                              style: const TextStyle(fontSize: 11)),
                          trailing: Icon(
                            _selectedPort == d.comPort
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: _selectedPort == d.comPort
                                ? AppTheme.primary
                                : AppTheme.textMuted,
                          ),
                          onTap: () {
                            setState(() => _selectedPort = d.comPort);
                            _portController.text = d.comPort;
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _portController,
                  style:
                      const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'COM 口（可手动填写）',
                    hintText: 'COM3',
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 文件
          AppCard(
            title: '刷机文件',
            child: Column(
              children: [
                _fileRow(
                  label: 'firehose ELF',
                  value: _elfPath,
                  hint: 'prog_firehose_ddr.elf',
                  onPick: _pickElf,
                ),
                const SizedBox(height: 12),
                _fileRow(
                  label: 'rawprogram XML',
                  value: _xmlPath,
                  hint: 'rawprogram0.xml（选 ELF 后自动找）',
                  onPick: _pickXml,
                ),
                if (_plan != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.check_circle,
                          size: 15, color: AppTheme.success),
                      const SizedBox(width: 8),
                      Text(
                        '已解析 ${_plan!.entries.length} 项'
                        '（${_plan!.flashable.length} 个可刷）',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                      if (_plan!.patchXmlPath != null) ...[
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('patch.xml 已找到',
                              style: TextStyle(
                                  fontSize: 10.5, color: AppTheme.accent)),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 选项
          AppCard(
            title: '刷机选项',
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('存储类型',
                        style: TextStyle(
                            fontSize: 12.5, color: AppTheme.textSecondary)),
                    const SizedBox(width: 16),
                    SegmentedButton<EdlStorage>(
                      segments: const [
                        ButtonSegment(
                            value: EdlStorage.ufs, label: Text('UFS')),
                        ButtonSegment(
                            value: EdlStorage.emmc, label: Text('EMMC')),
                      ],
                      selected: {_storage},
                      onSelectionChanged: (s) =>
                          setState(() => _storage = s.first),
                      style: const ButtonStyle(
                          visualDensity: VisualDensity.compact),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: _resetAfter,
                      onChanged: (v) => setState(() => _resetAfter = v ?? true),
                      visualDensity: VisualDensity.compact,
                    ),
                    const Text('刷完自动重启',
                        style: TextStyle(fontSize: 12.5)),
                  ],
                ),
                const Divider(height: 20),
                // 引擎选择
                Row(
                  children: [
                    const Text('刷机引擎',
                        style: TextStyle(
                            fontSize: 12.5, color: AppTheme.textSecondary)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'qdl',
                            label: Text(
                              _qdlReady ? 'qdl v${_qdlVersion ?? ""}' : 'qdl（未就绪）',
                              style: const TextStyle(fontSize: 11),
                            ),
                            enabled: _qdlReady,
                          ),
                          if (Platform.isWindows)
                            const ButtonSegment(
                              value: 'fh_loader',
                              label: Text('fh_loader',
                                  style: TextStyle(fontSize: 11)),
                            ),
                        ],
                        selected: {_engine},
                        onSelectionChanged: (v) =>
                            setState(() => _engine = v.first),
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_engine == 'qdl') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('qdl 后端',
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textMuted)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SegmentedButton<QdlBackend>(
                          segments: const [
                            ButtonSegment(
                              value: QdlBackend.qud,
                              label: Text('QDLoader COM',
                                  style: TextStyle(fontSize: 10.5)),
                            ),
                            ButtonSegment(
                              value: QdlBackend.usb,
                              label: Text('libusb',
                                  style: TextStyle(fontSize: 10.5)),
                            ),
                          ],
                          selected: {_qdlBackend},
                          onSelectionChanged: (v) =>
                              setState(() => _qdlBackend = v.first),
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _qdlBackend == QdlBackend.qud
                        ? '✓ QDLoader COM 走官方驱动，不需要 Zadig'
                        : '⚠️ libusb 需要 Zadig 把设备绑到 WinUSB',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: _qdlBackend == QdlBackend.qud
                          ? AppTheme.success
                          : AppTheme.warning,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═══ Tab 2: 分区表 ═══
  Widget _buildPartitionTab() {
    final hasGpt = _gptTable != null && _gptTable!.partitions.isNotEmpty;
    final hasXml = _plan != null && _plan!.flashable.isNotEmpty;

    if (!hasGpt && !hasXml) {
      return EmptyState(
        icon: Icons.table_chart,
        title: '还没有分区表',
        subtitle: '推荐：在「① 设备与文件」页选好 ELF 后点「读取分区表」\n'
            '（从设备实时读取 GPT，最准确）\n\n'
            '备选：选择 rawprogram.xml 作为降级方案',
        action: _gptLoading
            ? const InlineLoader(text: '读取中…')
            : ElevatedButton.icon(
                onPressed: _readGpt,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('读取设备分区表'),
              ),
      );
    }

    // 统一成显示用的条目
    final items = <_PartRow>[];
    if (hasGpt) {
      for (final p in _gptTable!.partitions) {
        items.add(_PartRow(
          name: p.name,
          file: null,
          sizeText: p.sizeText(_gptTable!.sectorSize),
          startLba: p.firstLba,
          sectors: p.sectors,
        ));
      }
    } else if (hasXml) {
      for (final e in _plan!.flashable) {
        items.add(_PartRow(
          name: e.label,
          file: e.filename,
          sizeText: e.sizeText,
          startLba: e.startSector,
          sectors: e.numSectors,
        ));
      }
    }

    return Column(
      children: [
        // 来源横幅
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: hasGpt
                ? AppTheme.success.withValues(alpha: 0.08)
                : AppTheme.warning.withValues(alpha: 0.08),
            border: const Border(
                bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              Icon(
                hasGpt ? Icons.verified : Icons.info_outline,
                size: 15,
                color: hasGpt ? AppTheme.success : AppTheme.warning,
              ),
              const SizedBox(width: 8),
              Text(
                hasGpt
                    ? '实时分区表（从设备 GPT 读取，${_gptTable!.sectorSize} 字节扇区）'
                    : '降级方案（rawprogram.xml，可能与真机不符）',
                style: TextStyle(
                  fontSize: 12,
                  color: hasGpt ? AppTheme.success : AppTheme.warning,
                ),
              ),
              const Spacer(),
              if (!hasGpt && _xmlPath == null)
                TextButton(
                  onPressed: _useXmlFallback,
                  child: const Text('选择 XML',
                      style: TextStyle(fontSize: 11.5)),
                ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                color: AppTheme.textSecondary,
                visualDensity: VisualDensity.compact,
                tooltip: '重新读取',
                onPressed: _gptLoading ? null : _readGpt,
              ),
            ],
          ),
        ),

        // 工具条
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() {
                  if (_selectedLabels.length == items.length) {
                    _selectedLabels.clear();
                  } else {
                    _selectedLabels
                      ..clear()
                      ..addAll(items.map((e) => e.name));
                  }
                }),
                icon: Icon(
                  _selectedLabels.length == items.length
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 16,
                ),
                label: const Text('全选', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              Text('已选 ${_selectedLabels.length} / ${items.length}',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              const Spacer(),
              if (_gptLoading) const InlineLoader(text: '读取中'),
            ],
          ),
        ),

        // 表头
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: AppTheme.bgElevated,
          child: const Row(
            children: [
              SizedBox(width: 32),
              Expanded(flex: 3, child: Text('分区名', style: _hdr)),
              Expanded(flex: 3, child: Text('镜像文件', style: _hdr)),
              SizedBox(width: 90, child: Text('大小', style: _hdr)),
              SizedBox(width: 100, child: Text('起始 LBA', style: _hdr)),
            ],
          ),
        ),

        // 列表
        Expanded(
          child: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = items[i];
              final sel = _selectedLabels.contains(e.name);
              return InkWell(
                onTap: () => setState(() {
                  if (sel) {
                    _selectedLabels.remove(e.name);
                  } else {
                    _selectedLabels.add(e.name);
                  }
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  color: sel
                      ? AppTheme.primary.withValues(alpha: 0.05)
                      : Colors.transparent,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 32,
                        child: Icon(
                          sel
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 16,
                          color: sel ? AppTheme.primary : AppTheme.textMuted,
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(e.name,
                            style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: AppTheme.textPrimary)),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(e.file ?? '—',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: e.file != null
                                    ? AppTheme.textSecondary
                                    : AppTheme.textMuted),
                            overflow: TextOverflow.ellipsis),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(e.sizeText,
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textMuted)),
                      ),
                      SizedBox(
                        width: 100,
                        child: Text('${e.startLba ?? "—"}',
                            style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: AppTheme.textMuted)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // 底部操作
        Container(
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              Icon(
                hasGpt ? Icons.lightbulb_outline : Icons.warning_amber,
                size: 15,
                color: hasGpt ? AppTheme.textMuted : AppTheme.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasGpt
                      ? '勾选要刷入的分区（实时 GPT 模式下需要 rawprogram.xml 提供镜像文件名）'
                      : '勾选后会用临时 XML 只刷选中的分区',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textMuted),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  onPressed: (_flashing ||
                          _selectedLabels.isEmpty ||
                          (hasGpt && !hasXml))
                      ? null
                      : _startFlash,
                  icon: Icon(
                      _flashing ? Icons.hourglass_top : Icons.flash_on,
                      size: 17),
                  label: Text(_flashing
                      ? '刷机中…'
                      : (hasGpt && !hasXml)
                          ? '需要 XML 才能刷'
                          : '刷入选中（${_selectedLabels.length}）'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.danger,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _hdr = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: AppTheme.textMuted,
  );

  // ═══ Tab 3: 日志 ═══
  Widget _buildLogTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 15, color: AppTheme.accent),
              const SizedBox(width: 8),
              const Text('刷机输出',
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
                    child: Text('等待开始…',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (context, i) {
                      final line = _log[i];
                      Color c = AppTheme.textSecondary;
                      if (line.contains('✅')) c = AppTheme.success;
                      if (line.contains('❌') || line.contains('ERROR')) {
                        c = AppTheme.danger;
                      }
                      if (line.startsWith('══')) c = AppTheme.accent;
                      return SelectableText(line,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: c,
                              height: 1.45));
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _fileRow({
    required String label,
    required String? value,
    required String hint,
    required VoidCallback onPick,
  }) {
    final name = value?.split(Platform.pathSeparator).last;
    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12.5, color: AppTheme.textSecondary)),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: AppTheme.bgElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              name ?? hint,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: name != null ? AppTheme.textPrimary : AppTheme.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: onPick,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          child: const Text('选择'),
        ),
      ],
    );
  }
}


/// 分区表显示行（统一 GPT 和 XML 两种来源）
class _PartRow {
  final String name;
  final String? file;
  final String sizeText;
  final int? startLba;
  final int? sectors;

  _PartRow({
    required this.name,
    this.file,
    required this.sizeText,
    this.startLba,
    this.sectors,
  });
}
