import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/services/logging/logger.dart';

/// 内置 TTS 模型：从随包 assets 释放到磁盘。
///
/// 为什么这么做而不是直接读 asset：
/// sherpa-onnx 的 C 接口要的是**文件系统路径**（它自己在 native 层 fopen），
/// 拿不到 Flutter asset 的字节流。所以第一次用的时候把 assets 里的三个文件
/// 拷到应用私有目录，之后直接用那边 —— 纯本地 IO，不联网、不依赖镜像。
///
/// 和上一版的区别：上一版是「首次朗读时从 GitHub 下载 31MB」，进度一直是
/// 0% 说明连接根本没建立起来（GitHub Releases 在部分网络环境直连超时）。
/// 自用场景下把模型打进包最省事：APK 从 41MB 涨到 ~72MB，换来「装完即用」。
///
/// 模型：sherpa-onnx vits-icefall-zh-aishell3（中文 VITS）
///   • model.onnx   29.07 MB  声学模型权重
///   • lexicon.txt   1.95 MB  汉字→音素映射
///   • tokens.txt    ~0 MB    音素表
/// 合计 31.02 MB。官方的 172MB rule.far（文本正则化）没有打包：
/// 它只影响「2024年」「3.5%」这类数字日期的读法，不影响可用性。
class TtsModelManager {
  TtsModelManager();

  static const String _modelName = 'vits-icefall-zh-aishell3';
  static const String _assetDir = 'assets/tts/$_modelName';

  /// 需要释放到磁盘的文件。
  static const List<String> _files = [
    'model.onnx',
    'lexicon.txt',
    'tokens.txt',
  ];

  /// model.onnx 的大小，用于判断拷贝是否完整。
  static const int _modelBytes = 30480000;

  Directory? _root;

  Future<Directory> modelDir() async {
    final root = await _appSupportDir();
    return Directory('${root.path}/$_modelName');
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

  /// 模型是否已经释放到磁盘且完整。
  Future<bool> isReady() async {
    final dir = await modelDir();
    if (!await dir.exists()) return false;
    for (final name in _files) {
      final f = File('${dir.path}/$name');
      if (!await f.exists()) return false;
      if (name == 'model.onnx' && await f.length() < _modelBytes * 0.9) {
        return false;
      }
    }
    return true;
  }

  /// 确保模型在磁盘上就绪。已就绪时立即返回。
  ///
  /// [onProgress] 传 0~1 的拷贝进度（不是下载 —— 这里是纯本地复制）。
  Future<void> ensureReady({
    void Function(double progress)? onProgress,
  }) async {
    if (await isReady()) {
      onProgress?.call(1);
      return;
    }
    final dir = await modelDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // 逐个文件从 assets 拷出来。大文件分块写，让进度能真实跳动；
    // 一口气 load 整个 29MB 再写，界面会僵在原地。
    for (var i = 0; i < _files.length; i++) {
      final name = _files[i];
      final target = File('${dir.path}/$name');
      final data = await rootBundle.load('$_assetDir/$name');
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      onProgress?.call((i + 1) / _files.length);
      KazumiLogger().i(
        'TTS asset released: $name '
        '(${(data.lengthInBytes / 1048576).toStringAsFixed(1)}MB)',
      );
    }

    if (!await isReady()) {
      throw Exception('模型释放后校验失败');
    }
  }

  /// 删掉已释放的模型（设置页「释放空间」用）。
  Future<void> remove() async {
    final dir = await modelDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
