import 'package:hive_ce/hive.dart';

part 'novel_shelf_module.g.dart';

/// 一本小说的本地记录：书架状态 + 阅读进度。
///
/// 为什么书架和进度用同一张表：一本书要么在书架上、要么只是读过，两者的
/// 身份信息（书名/封面/作者）和进度完全一样，拆两张表就要维护两份副本，
/// 而且「读了但没加书架」和「加了书架但没读」还得互相同步。一个
/// [onShelf] 布尔值就能区分，代价为零。
///
/// 主键用 [bookKey]（书籍详情页 URL），不是书名 —— 同名书在不同站点、
/// 甚至同一站点不同版本都存在，书名做键会互相覆盖。
@HiveType(typeId: 9)
class NovelBookRecord {
  /// 来源规则名（Plugin.name）。换源后同一本书是两个不同的记录。
  @HiveField(0)
  String pluginName;

  /// 书籍详情页 URL，本记录的身份。
  @HiveField(1)
  String bookKey;

  @HiveField(2)
  String title;

  @HiveField(3)
  String cover;

  @HiveField(4)
  String author;

  /// 上次读到第几卷（对应规则引擎解析出的 Road 下标）。
  @HiveField(5)
  int lastRoadIndex;

  /// 上次读到该卷内的第几章。
  @HiveField(6)
  int lastChapterIndex;

  /// 上次读到的那一章的 URL。章节索引可能因为站点改版而错位，
  /// URL 是更可靠的兜底依据。
  @HiveField(7)
  String lastChapterUrl;

  @HiveField(8)
  String lastChapterTitle;

  /// 上次阅读时间（毫秒时间戳）。0 表示从未读过。
  @HiveField(9)
  int lastReadAtMs;

  /// 打开这本书时解析到的章节总数，用于显示「读到 3/234」。
  @HiveField(10)
  int chapterCount;

  /// 是否在书架上。
  @HiveField(11)
  bool onShelf;

  /// 加入书架的时间（毫秒）。书架按这个倒序排。
  @HiveField(12)
  int addedAtMs;

  NovelBookRecord({
    required this.pluginName,
    required this.bookKey,
    required this.title,
    this.cover = '',
    this.author = '',
    this.lastRoadIndex = 0,
    this.lastChapterIndex = 0,
    this.lastChapterUrl = '',
    this.lastChapterTitle = '',
    this.lastReadAtMs = 0,
    this.chapterCount = 0,
    this.onShelf = false,
    this.addedAtMs = 0,
  });

  /// 书架/历史表的键。同名规则 + 同一本书 = 同一条记录。
  static String keyOf(String pluginName, String bookKey) =>
      '${pluginName.toLowerCase()}::$bookKey';

  String get key => keyOf(pluginName, bookKey);

  /// 读过（有进度）才有资格出现在历史里。
  bool get hasProgress => lastReadAtMs > 0;

  /// 进度百分比 0~1。章数未知时返回 null，由 UI 决定不显示进度条。
  double? get progressRatio {
    if (chapterCount <= 0) return null;
    final done = lastChapterIndex + 1;
    return (done / chapterCount).clamp(0.0, 1.0);
  }

  @override
  String toString() =>
      'NovelBookRecord($title, shelf: $onShelf, chapter: $lastChapterIndex)';
}
