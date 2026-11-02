import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 一个 EDL loader 的元数据
///
/// 文件名格式（来自 bkerler/Loaders）：
///   `HWID_PKHASH[:8]_FHPRG[_机型].bin`
///   例：`000ba0e100720000_57158eaf1814d78f_fhprg_redmi7.bin`
class EdlLoader {
  /// 完整路径
  final String path;

  /// 硬件 ID（16 进制字符串，如 "000ba0e100720000"）
  /// 0000000000000000 表示未知
  final String hwid;

  /// 公钥哈希前 8 字节（16 进制）
  final String pkHash;

  /// 标准版 / 只读版 / 无签名版
  final EdlLoaderType type;

  /// 机型标注（如 "redmi7"），可能为空
  final String model;

  /// 文件大小（字节）
  final int size;

  /// 来自哪个插件（插件 id），内置的为 null
  final String? fromPlugin;

  EdlLoader({
    required this.path,
    required this.hwid,
    required this.pkHash,
    required this.type,
    required this.model,
    required this.size,
    this.fromPlugin,
  });

  bool get hwidKnown =>
      hwid.isNotEmpty && hwid != '0000000000000000';

  /// 能不能写（peek 版只能读）
  bool get canWrite => type != EdlLoaderType.peek;

  /// 显示用的名字
  String get displayName {
    final parts = <String>[];
    if (model.isNotEmpty) parts.add(model);
    parts.add(type.label);
    if (hwidKnown) parts.add('HWID $hwid');
    return parts.join(' · ');
  }

  @override
  String toString() => 'EdlLoader($displayName, $path)';
}

enum EdlLoaderType {
  /// 标准 Firehose programmer（能读写）
  fhprg('标准'),

  /// 只读探测版（program/erase 会被拒绝）
  peek('只读'),

  /// 无签名校验版（仅老设备）
  noauth('免签'),

  /// 不认识
  unknown('未知');

  final String label;
  const EdlLoaderType(this.label);
}

/// 匹配结果
class LoaderMatch {
  final EdlLoader? loader;
  final LoaderMatchMethod method;
  final String reason;
  final List<EdlLoader> candidates;

  LoaderMatch({
    this.loader,
    required this.method,
    required this.reason,
    this.candidates = const [],
  });

  bool get found => loader != null;
}

enum LoaderMatchMethod {
  /// HWID 精确匹配
  hwid('HWID 匹配'),

  /// PK_HASH 匹配
  pkHash('公钥哈希匹配'),

  /// 只有唯一候选
  singleCandidate('唯一候选'),

  /// 用户手动选
  manual('手动选择'),

  /// 没找到
  none('未找到');

  final String label;
  const LoaderMatchMethod(this.label);
}

/// EDL Loader 管理 + 自动匹配
///
/// 作用：让用户在 9008 页面不用手动找 loader 文件。
///
/// 匹配策略（按可靠性排序）：
///   1. HWID 精确匹配（快，但很多 loader 的 HWID 未知）
///   2. PK_HASH 匹配（对比 loader 公钥哈希与设备 OEM PK Hash）
///   3. 机型名匹配（用户填了机型时）
///   4. 返回候选列表让用户选
class EdlLoaderService {
  EdlLoaderService._();
  static final EdlLoaderService instance = EdlLoaderService._();

  /// 所有已知 loader 的索引（path → EdlLoader）
  final Map<String, EdlLoader> _index = {};

  /// 扫描过的目录
  final Set<String> _scannedDirs = {};

  /// 插件提供的 loader 目录
  final Map<String, String> _pluginDirs = {};

  List<EdlLoader> get all => _index.values.toList();

  /// 注册一个插件提供的 loader 目录
  ///
  /// 插件在 plugin.json 里声明：
  /// ```json
  /// { "type": "edl-loader-pack", "loaders": "loaders/" }
  /// ```
  void registerPluginDir(String pluginId, String dirPath) {
    if (!Directory(dirPath).existsSync()) return;
    _pluginDirs[pluginId] = dirPath;

    // ★ 优先读插件自带的预索引（878 个文件全扫描太慢）
    final pluginRoot = Directory(dirPath).parent.path;
    final indexFile = File(p.join(pluginRoot, 'loader-index.json'));
    if (indexFile.existsSync()) {
      try {
        final data = jsonDecode(indexFile.readAsStringSync())
            as Map<String, dynamic>;
        final list = data['loaders'] as List<dynamic>?;
        if (list != null) {
          for (final e in list) {
            final m = e as Map<String, dynamic>;
            final rel = m['path'] as String? ?? '';
            if (rel.isEmpty) continue;
            final full = p.join(dirPath, rel);
            if (!File(full).existsSync()) continue;

            _index[full] = EdlLoader(
              path: full,
              hwid: m['hwid'] as String? ?? '',
              pkHash: m['pkhash'] as String? ?? '',
              type: _parseType(m['type'] as String? ?? ''),
              model: m['model'] as String? ?? '',
              size: (m['size'] as num?)?.toInt() ?? 0,
              fromPlugin: pluginId,
            );
          }
          return; // 用了预索引就不扫描了
        }
      } catch (_) {
        // 索引坏了就回退到扫描
      }
    }

    _scanDir(dirPath, fromPlugin: pluginId);
  }

  EdlLoaderType _parseType(String s) {
    switch (s) {
      case 'fhprg':
        return EdlLoaderType.fhprg;
      case 'peek':
        return EdlLoaderType.peek;
      case 'noauth':
        return EdlLoaderType.noauth;
      default:
        return EdlLoaderType.unknown;
    }
  }

  /// 扫描目录，索引其中所有 loader
  void _scanDir(String dirPath, {String? fromPlugin}) {
    if (_scannedDirs.contains(dirPath)) return;
    _scannedDirs.add(dirPath);

    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    for (final f in dir.listSync(recursive: true)) {
      if (f is! File) continue;
      final ext = p.extension(f.path).toLowerCase();
      if (ext != '.bin' && ext != '.elf' && ext != '.mbn') continue;

      final loader = parseLoaderFile(f, fromPlugin: fromPlugin);
      if (loader != null) {
        _index[f.path] = loader;
      }
    }
  }

  /// 从文件名解析 loader 元数据
  ///
  /// 支持两种命名：
  ///   `000ba0e100720000_57158eaf1814d78f_fhprg_redmi7.bin`   （bkerler 格式）
  ///   `prog_firehose_ddr.elf`                                 （传统格式，无元数据）
  EdlLoader? parseLoaderFile(File f, {String? fromPlugin}) {
    final name = p.basenameWithoutExtension(f.path);
    final lower = name.toLowerCase();

    // 传统命名（无 HWID/PKHASH）—— 仍可用，但无法自动匹配
    if (!RegExp(r'^[0-9a-fA-F]{8,16}_').hasMatch(name)) {
      return EdlLoader(
        path: f.path,
        hwid: '',
        pkHash: '',
        type: _guessType(lower),
        model: _guessModel(lower),
        size: f.lengthSync(),
        fromPlugin: fromPlugin,
      );
    }

    // bkerler 格式：HWID_PKHASH_类型[_机型]
    final parts = name.split('_');
    if (parts.length < 2) return null;

    final hwid = parts[0];
    final pkHash = parts[1];

    // 类型和机型
    var type = EdlLoaderType.fhprg;
    var model = '';
    if (parts.length >= 3) {
      final typeStr = parts[2].toLowerCase();
      if (typeStr.contains('peek')) {
        type = EdlLoaderType.peek;
      } else if (typeStr.contains('noauth')) {
        type = EdlLoaderType.noauth;
      } else if (typeStr.contains('fhprg')) {
        type = EdlLoaderType.fhprg;
      }
      // 第 4 段起是机型
      if (parts.length >= 4) {
        model = parts.sublist(3).join('_');
      }
    }

    return EdlLoader(
      path: f.path,
      hwid: hwid,
      pkHash: pkHash,
      type: type,
      model: model,
      size: f.lengthSync(),
      fromPlugin: fromPlugin,
    );
  }

  EdlLoaderType _guessType(String lower) {
    if (lower.contains('peek')) return EdlLoaderType.peek;
    if (lower.contains('noauth')) return EdlLoaderType.noauth;
    if (lower.contains('fhprg') || lower.contains('firehose')) {
      return EdlLoaderType.fhprg;
    }
    return EdlLoaderType.unknown;
  }

  String _guessModel(String lower) {
    // 从传统命名里猜机型（prog_firehose_ddr → 无机型信息）
    if (lower.contains('redmi')) return 'redmi';
    if (lower.contains('mi_')) return 'mi';
    return '';
  }

  /// ★ 自动匹配 loader
  ///
  /// 参数：
  ///   hwid     — 设备 HWID（Sahara 读到的，可为 null）
  ///   pkHash   — 设备 OEM PK Hash（可为 null）
  ///   model    — 用户填的机型（可为 null）
  LoaderMatch match({
    String? hwid,
    String? pkHash,
    String? model,
    bool onlyWritable = false,
  }) {
    var pool = _index.values.toList();
    if (onlyWritable) {
      pool = pool.where((l) => l.canWrite).toList();
    }

    if (pool.isEmpty) {
      return LoaderMatch(
        method: LoaderMatchMethod.none,
        reason: '没有可用的 loader（请先安装 loader 插件）',
      );
    }

    // ① HWID 精确匹配
    if (hwid != null && hwid.isNotEmpty) {
      final matched = pool.where((l) =>
          l.hwidKnown && l.hwid.toLowerCase() == hwid.toLowerCase());
      if (matched.length == 1) {
        return LoaderMatch(
          loader: matched.first,
          method: LoaderMatchMethod.hwid,
          reason: 'HWID $hwid 精确匹配',
        );
      }
      if (matched.length > 1) {
        // 多个候选：按 pkHash 去重（同一 loader 被多个厂商目录收录）
        final byHash = <String, EdlLoader>{};
        for (final l in matched) {
          final key = l.pkHash.isNotEmpty ? l.pkHash : l.path;
          byHash.putIfAbsent(key, () => l);
        }

        if (byHash.length == 1) {
          // 去重后只剩一个 → 就是它
          return LoaderMatch(
            loader: byHash.values.first,
            method: LoaderMatchMethod.hwid,
            reason: 'HWID $hwid 匹配（${matched.length} 个副本，去重后唯一）',
          );
        }

        // 去重后还有多个：优先标准版（能写），再按插件/大小排
        final sorted = byHash.values.toList()
          ..sort((a, b) {
            // 标准版优先
            if (a.canWrite != b.canWrite) return a.canWrite ? -1 : 1;
            // 免签版次之（老设备用）
            if (a.type != b.type) {
              if (a.type == EdlLoaderType.noauth) return -1;
              if (b.type == EdlLoaderType.noauth) return 1;
            }
            // 同类型按大小（大的通常功能全）
            return b.size.compareTo(a.size);
          });

        return LoaderMatch(
          loader: sorted.first,
          method: LoaderMatchMethod.hwid,
          reason: 'HWID $hwid 匹配（${byHash.length} 个不同 loader，已选最优）',
          candidates: sorted,
        );
      }
    }

    // ② PK_HASH 匹配
    if (pkHash != null && pkHash.isNotEmpty) {
      final prefix = pkHash.length >= 8 ? pkHash.substring(0, 8) : pkHash;
      final matched = pool.where((l) =>
          l.pkHash.isNotEmpty &&
          l.pkHash.toLowerCase().startsWith(prefix.toLowerCase()));
      if (matched.length == 1) {
        return LoaderMatch(
          loader: matched.first,
          method: LoaderMatchMethod.pkHash,
          reason: '公钥哈希 $prefix… 匹配',
        );
      }
      if (matched.length > 1) {
        return LoaderMatch(
          method: LoaderMatchMethod.none,
          reason: '公钥哈希匹配到 ${matched.length} 个，需要选择',
          candidates: matched.toList(),
        );
      }
    }

    // ③ 机型名匹配
    if (model != null && model.isNotEmpty) {
      final key = model.toLowerCase();
      final matched = pool.where((l) =>
          l.model.toLowerCase().contains(key) ||
          p.basename(l.path).toLowerCase().contains(key));
      if (matched.isNotEmpty) {
        if (matched.length == 1) {
          return LoaderMatch(
            loader: matched.first,
            method: LoaderMatchMethod.singleCandidate,
            reason: '机型「$model」匹配',
          );
        }
        return LoaderMatch(
          method: LoaderMatchMethod.none,
          reason: '机型「$model」匹配到 ${matched.length} 个',
          candidates: matched.toList(),
        );
      }
    }

    // ④ 只有一个候选就直接用
    if (pool.length == 1) {
      return LoaderMatch(
        loader: pool.first,
        method: LoaderMatchMethod.singleCandidate,
        reason: '只有 1 个 loader 可用',
      );
    }

    // ⑤ 全都不行，返回候选
    return LoaderMatch(
      method: LoaderMatchMethod.none,
      reason: '无法自动匹配，共 ${pool.length} 个候选，请手动选择',
      candidates: pool.toList(),
    );
  }

  /// 清空索引
  void clear() {
    _index.clear();
    _scannedDirs.clear();
    _pluginDirs.clear();
  }

  /// 按机型分组统计（给 UI 用）
  Map<String, int> get statsByModel {
    final m = <String, int>{};
    for (final l in _index.values) {
      final key = l.model.isEmpty ? '（未标注）' : l.model;
      m[key] = (m[key] ?? 0) + 1;
    }
    return m;
  }
}
