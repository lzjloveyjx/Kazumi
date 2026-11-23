import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/services/logging/logger.dart';

/// 内置 TTS 模型的下载与就绪检查。
///
/// 为什么不打包进 APK：模型压缩后 30MB、解压后 31MB（其中 29MB 是 onnx 权重）。
/// 打进包会让每个用户都付这份代价，而绝大多数人可能根本不开朗读。所以做成
/// 「第一次用朗读时下载」，下完缓存在应用目录，卸载应用才清掉。
///
/// 模型选的是 sherpa-onnx 官方的 vits-icefall-zh-aishell3：
///   • 中文 VITS，纯离线，无网络依赖
///   • 压缩包 30MB，是中文模型里最小的可用档（其它普遍 60~160MB）
///   • 无需 espeak-ng 数据（v2.0 起 dataDir 已废弃），自带 lexicon
///   • 那个 172MB 的 rule.far 是可选的文本正则化规则，不下也能正常合成
///     —— 只是「2024年」这类数字/日期不会自动读成中文，会按字面读。
///     我们自己在切句时处理常见数字，所以不拉它。
class TtsModelManager {
  TtsModelManager({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const String _modelName = 'vits-icefall-zh-aishell3';

  /// 官方 release 里的压缩包地址。
  static String get archiveUrl =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
      '$_modelName.tar.bz2';

  Directory? _root;

  /// 模型所在目录（解压后的）。未下载时返回预期路径，不保证存在。
  Future<Directory> modelDir() async {
    final root = await _appSupportDir();
    return Directory('${root.path}/tts/$_modelName');
  }

  Future<Directory> _appSupportDir() async {
    if (_root != null) return _root!;
    final dir = await getApplicationSupportDirectory();
    final ttsRoot = Directory('${dir.path}/tts');
    if (!await ttsRoot.exists()) {
      await ttsRoot.create(recursive: true);
    }
    _root = ttsRoot;
    return ttsRoot;
  }

  /// 判断模型是否已经下载完整。
  ///
  /// 用「关键文件都在且大小合理」作为判据，而不是只看目录存在 ——
  /// 下载中断会留下半个目录，那种情况下加载会崩在 native 层（拿不到
  /// 有用的错误信息），所以宁可重新下。
  Future<bool> isReady() async {
    final dir = await modelDir();
    if (!await dir.exists()) return false;
    final model = File('${dir.path}/model.onnx');
    final tokens = File('${dir.path}/tokens.txt');
    final lexicon = File('${dir.path}/lexicon.txt');
    if (!await model.exists() || !await tokens.exists() ||
        !await lexicon.exists()) {
      return false;
    }
    // 29MB 的权重，小于 20MB 说明没下完。
    final size = await model.length();
    return size > 20 * 1024 * 1024;
  }

  /// 下载并解压。已就绪时直接返回。
  ///
  /// [onProgress] 传 0~1 的下载进度，用于 UI 显示。
  Future<void> ensureReady({
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (await isReady()) {
      onProgress?.call(1);
      return;
    }
    final root = await _appSupportDir();
    final archive = File('${root.path}/$_modelName.tar.bz2');
    final target = await modelDir();

    // 下载
    if (!await archive.exists() ||
        await archive.length() < 20 * 1024 * 1024) {
      await _dio.download(
        archiveUrl,
        archive.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
    }

    // 解压
    onProgress?.call(1);
    await _extract(archive, root);
    await archive.delete();

    if (!await isReady()) {
      throw Exception('模型下载后校验失败，请重试');
    }
    KazumiLogger().i('TTS model ready at ${target.path}');
  }

  /// 解压 .tar.bz2。
  ///
  /// Flutter 没有内置的 bz2 解压，这里用系统 tar —— Android 5.0+ 与常见的
  /// 桌面系统都自带。失败时**不静默**：抛出去让 UI 提示，而不是留一个
  /// 半截目录让后面莫名其妙崩。
  Future<void> _extract(File archive, Directory root) async {
    final target = await modelDir();
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    if (!Platform.isWindows) {
      // Android / Linux / macOS
      final result = await Process.run(
        'tar',
        ['-xjf', archive.path, '-C', root.path],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw Exception('解压失败：${result.stderr}');
      }
      return;
    }
    // Windows 10+ 自带 bsdtar，支持 bz2
    final result = await Process.run(
      'tar',
      ['-xjf', archive.path, '-C', root.path],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw Exception('解压失败：${result.stderr}');
    }
  }

  /// 删掉已下载的模型（设置页提供「释放空间」）。
  Future<void> remove() async {
    final dir = await modelDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    final root = await _appSupportDir();
    final archive = File('${root.path}/$_modelName.tar.bz2');
    if (await archive.exists()) {
      await archive.delete();
    }
  }
}
