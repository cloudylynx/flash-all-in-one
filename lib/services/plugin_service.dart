import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/process_runner.dart';
import 'edl_loader_service.dart';

/// 插件清单
class PluginManifest {
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String? homepage;
  final String? license;
  final String icon; // Material icon name
  final String category;
  final List<PluginTool> tools;
  final PluginUi ui;

  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    this.homepage,
    this.license,
    required this.icon,
    required this.category,
    required this.tools,
    required this.ui,
  });

  factory PluginManifest.fromJson(Map<String, dynamic> j) {
    return PluginManifest(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '未命名',
      version: j['version'] as String? ?? '0.0.0',
      description: j['description'] as String? ?? '',
      author: j['author'] as String? ?? '',
      homepage: j['homepage'] as String?,
      license: j['license'] as String?,
      icon: j['icon'] as String? ?? 'extension',
      category: j['category'] as String? ?? 'other',
      tools: (j['tools'] as List<dynamic>? ?? [])
          .map((e) => PluginTool.fromJson(e as Map<String, dynamic>))
          .toList(),
      ui: PluginUi.fromJson(j['ui'] as Map<String, dynamic>? ?? {}),
    );
  }
}

/// 插件内置工具
class PluginTool {
  final String name;
  final String path; // 相对插件目录
  final String platform; // linux / windows / any
  final bool executable;

  PluginTool({
    required this.name,
    required this.path,
    required this.platform,
    required this.executable,
  });

  factory PluginTool.fromJson(Map<String, dynamic> j) {
    return PluginTool(
      name: j['name'] as String? ?? '',
      path: j['path'] as String? ?? '',
      platform: j['platform'] as String? ?? 'any',
      executable: j['executable'] as bool? ?? false,
    );
  }
}

/// 插件 UI 定义
class PluginUi {
  final List<PluginInput> inputs;
  final List<PluginAction> actions;
  final List<PluginCard> cards;

  PluginUi({
    required this.inputs,
    required this.actions,
    required this.cards,
  });

  factory PluginUi.fromJson(Map<String, dynamic> j) {
    return PluginUi(
      inputs: (j['inputs'] as List<dynamic>? ?? [])
          .map((e) => PluginInput.fromJson(e as Map<String, dynamic>))
          .toList(),
      actions: (j['actions'] as List<dynamic>? ?? [])
          .map((e) => PluginAction.fromJson(e as Map<String, dynamic>))
          .toList(),
      cards: (j['cards'] as List<dynamic>? ?? [])
          .map((e) => PluginCard.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 插件输入项
class PluginInput {
  final String id;
  final String type; // text / file / dir / select / bool
  final String label;
  final String? hint;
  final String? defaultValue;
  final List<Map<String, String>> options;
  final String? filter; // 文件扩展名过滤

  PluginInput({
    required this.id,
    required this.type,
    required this.label,
    this.hint,
    this.defaultValue,
    required this.options,
    this.filter,
  });

  factory PluginInput.fromJson(Map<String, dynamic> j) {
    return PluginInput(
      id: j['id'] as String? ?? '',
      type: j['type'] as String? ?? 'text',
      label: j['label'] as String? ?? '',
      hint: j['hint'] as String?,
      defaultValue: j['default'] as String?,
      options: (j['options'] as List<dynamic>? ?? [])
          .map((e) => {
                'value': (e as Map)['value']?.toString() ?? '',
                'label': e['label']?.toString() ?? '',
              })
          .toList(),
      filter: j['filter'] as String?,
    );
  }
}

/// 插件操作
class PluginAction {
  final String label;
  final String? description;
  final String tool;
  final List<String> args;
  final String? confirm;
  final bool danger;
  final String? icon;
  final String? workDir;

  PluginAction({
    required this.label,
    this.description,
    required this.tool,
    required this.args,
    this.confirm,
    this.danger = false,
    this.icon,
    this.workDir,
  });

  factory PluginAction.fromJson(Map<String, dynamic> j) {
    return PluginAction(
      label: j['label'] as String? ?? '',
      description: j['description'] as String?,
      tool: j['tool'] as String? ?? '',
      args: (j['args'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      confirm: j['confirm'] as String?,
      danger: j['danger'] as bool? ?? false,
      icon: j['icon'] as String?,
      workDir: j['workDir'] as String?,
    );
  }
}

/// 插件卡片（分组）
class PluginCard {
  final String title;
  final List<PluginAction> actions;

  PluginCard({required this.title, required this.actions});

  factory PluginCard.fromJson(Map<String, dynamic> j) {
    return PluginCard(
      title: j['title'] as String? ?? '',
      actions: (j['actions'] as List<dynamic>? ?? [])
          .map((e) => PluginAction.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 已安装的插件
class InstalledPlugin {
  final String dir;
  final PluginManifest manifest;
  final bool valid;
  final String? error;

  InstalledPlugin({
    required this.dir,
    required this.manifest,
    this.valid = true,
    this.error,
  });
}

/// 插件执行结果
class PluginResult {
  final bool ok;
  final String message;
  final List<String> log;
  PluginResult(this.ok, this.message, [this.log = const []]);
}

/// 插件服务
///
/// 插件是声明式的：用 JSON 定义 UI 和命令，由本引擎解释执行。
/// 不加载任何外部代码，安全可控。
///
/// 插件目录：
///   Linux:   ~/.local/share/io.github.flashallinone/plugins/
///   Windows: %APPDATA%\Flash All In One\Flash All In One\plugins\
class PluginService {
  PluginService._();
  static final PluginService instance = PluginService._();

  String? _pluginsDir;
  final List<InstalledPlugin> _plugins = [];
  List<InstalledPlugin> get plugins => List.unmodifiable(_plugins);

  /// 插件根目录
  Future<String?> pluginsDir() async {
    if (_pluginsDir != null) return _pluginsDir;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'plugins'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _pluginsDir = dir.path;
      return _pluginsDir;
    } catch (_) {
      return null;
    }
  }

  /// 扫描已安装插件
  Future<List<InstalledPlugin>> scan() async {
    _plugins.clear();
    final dir = await pluginsDir();
    if (dir == null) return [];

    final root = Directory(dir);
    if (!root.existsSync()) return [];

    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final manifestFile = File(p.join(entity.path, 'plugin.json'));
      if (!manifestFile.existsSync()) continue;

      try {
        final json = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
        final manifest = PluginManifest.fromJson(json);
        if (manifest.id.isEmpty) {
          _plugins.add(InstalledPlugin(
            dir: entity.path,
            manifest: manifest,
            valid: false,
            error: '缺少 id 字段',
          ));
          continue;
        }
        _plugins.add(InstalledPlugin(dir: entity.path, manifest: manifest));

        // 如果这个插件提供 EDL loader，注册给 EdlLoaderService
        final loaderDir = json['loaders'];
        if (loaderDir is String && loaderDir.isNotEmpty) {
          EdlLoaderService.instance.registerPluginDir(
            manifest.id,
            p.join(entity.path, loaderDir),
          );
        }
      } catch (e) {
        _plugins.add(InstalledPlugin(
          dir: entity.path,
          manifest: PluginManifest(
            id: p.basename(entity.path),
            name: p.basename(entity.path),
            version: '?',
            description: '清单解析失败',
            author: '',
            icon: 'error',
            category: 'other',
            tools: [],
            ui: PluginUi(inputs: [], actions: [], cards: []),
          ),
          valid: false,
          error: '$e',
        ));
      }
    }

    _plugins.sort((a, b) => a.manifest.name.compareTo(b.manifest.name));
    return _plugins;
  }

  /// 从 ZIP 导入插件
  Future<PluginResult> importFromZip({
    required String zipPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final dir = await pluginsDir();
    if (dir == null) return PluginResult(false, '无法获取插件目录', log);

    if (!File(zipPath).existsSync()) {
      return PluginResult(false, '文件不存在', log);
    }

    add('══ 导入插件');
    add('  文件: ${p.basename(zipPath)}');

    try {
      final bytes = File(zipPath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 先找 plugin.json 的位置（可能在根目录或子目录）
      String? manifestPath;
      for (final f in archive.files) {
        if (f.name == 'plugin.json' || f.name.endsWith('/plugin.json')) {
          manifestPath = f.name;
          break;
        }
      }

      if (manifestPath == null) {
        add('❌ 压缩包里没有 plugin.json');
        return PluginResult(false, '缺少 plugin.json', log);
      }

      // 解析清单
      final manifestFile = archive.files.firstWhere((f) => f.name == manifestPath);
      final content = utf8.decode(manifestFile.content as List<int>);
      final json = jsonDecode(content) as Map<String, dynamic>;
      final manifest = PluginManifest.fromJson(json);

      if (manifest.id.isEmpty) {
        add('❌ plugin.json 缺少 id 字段');
        return PluginResult(false, '缺少 id', log);
      }

      add('  插件: ${manifest.name} v${manifest.version}');
      add('  ID: ${manifest.id}');

      // 检查是否已存在
      final targetDir = Directory(p.join(dir, manifest.id));
      if (targetDir.existsSync()) {
        add('');
        add('⚠️ 插件已存在，将覆盖');
        targetDir.deleteSync(recursive: true);
      }
      targetDir.createSync(recursive: true);

      // 计算前缀（如果是子目录）
      final prefix = manifestPath == 'plugin.json'
          ? ''
          : manifestPath.substring(0, manifestPath.length - 'plugin.json'.length);

      // 解压
      var count = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        if (!f.name.startsWith(prefix)) continue;

        final relPath = f.name.substring(prefix.length);
        if (relPath.isEmpty) continue;

        final targetPath = p.join(targetDir.path, relPath);
        final target = File(targetPath);
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(f.content as List<int>);
        count++;

        // 可执行权限
        if (Platform.isLinux && relPath.startsWith('tools/')) {
          try {
            await Process.run('chmod', ['+x', targetPath]);
          } catch (_) {}
        }
      }

      add('');
      add('✅ 解压 $count 个文件');
      add('  位置: ${targetDir.path}');

      await scan();
      return PluginResult(true, '${manifest.name} 已安装', log);
    } catch (e) {
      add('❌ 导入失败: $e');
      return PluginResult(false, '导入失败: $e', log);
    }
  }

  /// 卸载插件
  Future<PluginResult> uninstall(String pluginId) async {
    final dir = await pluginsDir();
    if (dir == null) return PluginResult(false, '无法获取插件目录', []);

    final target = Directory(p.join(dir, pluginId));
    if (!target.existsSync()) {
      return PluginResult(false, '插件不存在', []);
    }

    try {
      target.deleteSync(recursive: true);
      await scan();
      return PluginResult(true, '已卸载', []);
    } catch (e) {
      return PluginResult(false, '卸载失败: $e', []);
    }
  }

  /// 找到插件的工具路径
  String? toolPath(InstalledPlugin plugin, String toolName) {
    for (final t in plugin.manifest.tools) {
      if (t.name != toolName) continue;
      if (t.platform != 'any' && t.platform != Platform.operatingSystem) {
        continue;
      }
      final path = p.join(plugin.dir, t.path);
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 执行插件操作
  Future<PluginResult> runAction({
    required InstalledPlugin plugin,
    required PluginAction action,
    required Map<String, String> inputs,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final exe = toolPath(plugin, action.tool);
    if (exe == null) {
      add('❌ 找不到工具: ${action.tool}');
      return PluginResult(false, '工具不存在', log);
    }

    // 替换参数里的占位符
    final args = <String>[];
    final unresolved = <String>{};
    for (final arg in action.args) {
      var resolved = arg;
      // {input:id}
      for (final entry in inputs.entries) {
        resolved = resolved.replaceAll('{input:${entry.key}}', entry.value);
      }
      // {pluginDir}
      resolved = resolved.replaceAll('{pluginDir}', plugin.dir);
      // {toolDir}
      resolved = resolved.replaceAll(
          '{toolDir}', p.join(plugin.dir, 'tools'));

      // 检查残留的 {input:xxx} —— 说明用户没填对应字段
      for (final m in RegExp(r'\{input:([^}]+)\}').allMatches(resolved)) {
        unresolved.add(m.group(1)!);
      }
      args.add(resolved);
    }

    // 有未填写的必填项时，不把乱码传给工具
    if (unresolved.isNotEmpty) {
      final labels = <String>[];
      for (final id in unresolved) {
        final inp = plugin.manifest.ui.inputs
            .where((i) => i.id == id)
            .firstOrNull;
        labels.add(inp != null ? '「${inp.label}」' : '「$id」');
      }
      add('❌ 还有 ${labels.length} 个参数没填：${labels.join('、')}');
      add('   请在「参数」区填写后重试。');
      return PluginResult(false, '参数未填写完整', log);
    }

    add('══ ${action.label}');
    add('  ${p.basename(exe)} ${args.join(' ')}');
    add('');

    final workDir = action.workDir != null
        ? p.join(plugin.dir, action.workDir!)
        : plugin.dir;

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 30),
      workingDirectory: workDir,
    );

    if (code == 0) {
      add('');
      add('✅ 完成');
      return PluginResult(true, '${action.label} 完成', log);
    }
    return PluginResult(false, '${action.label} 失败（退出码 $code）', log);
  }

  /// 生成插件模板
  static String generateTemplate(String id, String name) {
    return const JsonEncoder.withIndent('  ').convert({
      'id': id,
      'name': name,
      'version': '1.0.0',
      'description': '插件说明',
      'author': '你的名字',
      'homepage': 'https://github.com/you/repo',
      'license': 'MIT',
      'icon': 'extension',
      'category': 'flashing',
      'tools': [
        {
          'name': 'mytool',
          'path': 'tools/mytool',
          'platform': 'any',
          'executable': true,
        }
      ],
      'ui': {
        'inputs': [
          {
            'id': 'target',
            'type': 'text',
            'label': '目标',
            'hint': '例如 /dev/ttyUSB0',
            'default': '',
          }
        ],
        'cards': [
          {
            'title': '操作',
            'actions': [
              {
                'label': '执行',
                'description': '执行示例命令',
                'tool': 'mytool',
                'args': ['--target', '{input:target}'],
                'confirm': '确认执行？',
                'danger': false,
                'icon': 'play_arrow',
              }
            ]
          }
        ]
      }
    });
  }

  /// ★ 替换参数里的占位符（抽成静态方法便于单测）
  ///
  /// 支持的占位符：
  ///   {input:id}   → 用户填的值
  ///   {pluginDir}  → 插件目录绝对路径
  ///   {toolDir}    → 插件工具目录绝对路径
  ///
  /// 返回 (解析后的参数列表, 未填写的字段 id 集合)
  ///
  /// 未填写的字段不会被替换，留在结果里供调用方检测。
  static (List<String>, Set<String>) resolveArgs({
    required List<String> args,
    required Map<String, String> inputs,
    required String pluginDir,
    required String toolDir,
  }) {
    final out = <String>[];
    final unresolved = <String>{};

    for (final raw in args) {
      var resolved = raw;

      // 按 key 长度降序替换，避免 {input:a} 被 {input:ab} 干扰
      final keys = inputs.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final k in keys) {
        resolved = resolved.replaceAll('{input:$k}', inputs[k]!);
      }

      resolved = resolved.replaceAll('{pluginDir}', pluginDir);
      resolved = resolved.replaceAll('{toolDir}', toolDir);

      // 检查残留的 {input:xxx}
      for (final m in RegExp(r'\{input:([^}]+)\}').allMatches(resolved)) {
        unresolved.add(m.group(1)!);
      }

      out.add(resolved);
    }

    return (out, unresolved);
  }

}
