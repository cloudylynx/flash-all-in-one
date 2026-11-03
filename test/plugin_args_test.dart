// 插件参数替换测试
//
// 关键点：用户没填的字段不能被当成字面量传给工具，
// 否则工具会收到 "{input:key}" 这种乱码并报奇怪错误。

import 'package:flutter_test/flutter_test.dart';
import 'package:flashallinone/services/plugin_service.dart';

void main() {
  const pluginDir = '/opt/plugins/demo';
  const toolDir = '/opt/plugins/demo/tools';

  (List<String>, Set<String>) resolve(
    List<String> args,
    Map<String, String> inputs,
  ) =>
      PluginService.resolveArgs(
        args: args,
        inputs: inputs,
        pluginDir: pluginDir,
        toolDir: toolDir,
      );

  group('基本替换', () {
    test('单个 input', () {
      final (args, missing) = resolve(
        ['--file', '{input:file}'],
        {'file': '/tmp/boot.img'},
      );
      expect(args, ['--file', '/tmp/boot.img']);
      expect(missing, isEmpty);
    });

    test('多个 input', () {
      final (args, missing) = resolve(
        ['-i', '{input:src}', '-o', '{input:dst}'],
        {'src': '/a.img', 'dst': '/b.img'},
      );
      expect(args, ['-i', '/a.img', '-o', '/b.img']);
      expect(missing, isEmpty);
    });

    test('一个参数里多个占位符', () {
      final (args, missing) = resolve(
        ['{input:host}:{input:port}'],
        {'host': '127.0.0.1', 'port': '5037'},
      );
      expect(args, ['127.0.0.1:5037']);
      expect(missing, isEmpty);
    });

    test('pluginDir / toolDir', () {
      final (args, missing) = resolve(
        ['{pluginDir}', '{toolDir}/bin'],
        {},
      );
      expect(args, [pluginDir, '$toolDir/bin']);
      expect(missing, isEmpty);
    });
  });

  group('未填字段检测', () {
    test('缺一个字段', () {
      final (args, missing) = resolve(
        ['--file', '{input:file}'],
        {}, // 没填
      );
      expect(missing, {'file'});
      expect(args.first, '--file');
      // 占位符保留在参数里（供调用方识别）
      expect(args[1], contains('{input:file}'));
    });

    test('缺多个字段', () {
      final (args, missing) = resolve(
        ['-i', '{input:src}', '-o', '{input:dst}'],
        {'src': '/a.img'}, // 只填了 src
      );
      expect(missing, {'dst'});
    });

    test('全部缺', () {
      final (args, missing) = resolve(
        ['{input:a}', '{input:b}', '{input:c}'],
        {},
      );
      expect(missing, {'a', 'b', 'c'});
    });

    test('填了空字符串也算填了', () {
      final (args, missing) = resolve(
        ['--opt', '{input:opt}'],
        {'opt': ''},
      );
      expect(missing, isEmpty);
      expect(args, ['--opt', '']);
    });
  });

  group('边界与安全', () {
    test('空参数列表', () {
      final (args, missing) = resolve([], {'a': '1'});
      expect(args, isEmpty);
      expect(missing, isEmpty);
    });

    test('参数里没有占位符', () {
      final (args, missing) = resolve(['--help'], {});
      expect(args, ['--help']);
      expect(missing, isEmpty);
    });

    test('key 前缀冲突（input:a vs input:ab）', () {
      // 如果按长度降序替换，{input:ab} 优先，不会被 {input:a} 破坏
      final (args, missing) = resolve(
        ['{input:ab}'],
        {'a': 'AAA', 'ab': 'ABAB'},
      );
      expect(args, ['ABAB']);
      expect(missing, isEmpty);
    });

    test('值里含占位符语法时会被标记（防止路径拼错）', () {
      // 用户填的值里如果出现 {input:xxx}，说明可能填错了，
      // 残留下来的会被识别为"未填"并提醒用户 —— 这是预期行为。
      final (args, missing) = resolve(
        ['{input:path}', '{input:other}'],
        {
          'path': '/tmp/{input:other}',
          'other': 'X',
        },
      );
      // path 里的 {input:other} 被保留，于是被识别为未填
      expect(missing, contains('other'));
      expect(args[0], '/tmp/{input:other}');
      expect(args[1], 'X');
    });

    test('值里的普通花括号不误判', () {
      final (args, missing) = resolve(
        ['--label', '{input:label}'],
        {'label': 'a{b}c'}, // 普通花括号，不是占位符语法
      );
      expect(args, ['--label', 'a{b}c']);
      expect(missing, isEmpty);
    });

    test('不存在的占位符不报缺失，但会留在参数里', () {
      final (args, missing) = resolve(
        ['{input:notdefined}'],
        {'defined': 'x'},
      );
      // 会被识别为未填
      expect(missing, {'notdefined'});
    });
  });

  group('真实插件场景', () {
    test('payload-dumper 参数', () {
      final (args, missing) = resolve(
        ['-o', '{input:outdir}', '{input:payload}'],
        {
          'outdir': '/home/user/out',
          'payload': '/home/user/ota.zip',
          'parts': '',
        },
      );
      expect(args, ['-o', '/home/user/out', '/home/user/ota.zip']);
      expect(missing, isEmpty);
    });

    test('缺少必填参数应被拦截', () {
      final (_, missing) = resolve(
        ['-o', '{input:outdir}', '{input:payload}'],
        {'outdir': '/tmp/out'}, // 没给 payload
      );
      expect(missing, contains('payload'));
      expect(missing.length, 1);
    });
  });
}
