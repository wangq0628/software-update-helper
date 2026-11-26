import 'dart:convert';

const String appVersion = '2.0.0';

/// 全局设置
class AppConfig {
  List<String> roots;
  List<String> excludeDirs;
  int maxDepth;
  int timeout;
  int maxDownloadMb;
  String proxyMode; // none / system / custom
  String httpProxy;
  String httpsProxy;
  String socksProxy;
  String githubToken;
  bool deleteOldDefault;
  bool writeSha256;
  String userAgent;

  AppConfig({
    List<String>? roots,
    List<String>? excludeDirs,
    this.maxDepth = 6,
    this.timeout = 40,
    this.maxDownloadMb = 4096,
    this.proxyMode = 'none',
    this.httpProxy = '',
    this.httpsProxy = '',
    this.socksProxy = '',
    this.githubToken = '',
    this.deleteOldDefault = false,
    this.writeSha256 = true,
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  })  : roots = roots ?? <String>[r'D:\应用程序', r'D:\驱动'],
        excludeDirs = excludeDirs ?? <String>[
          r'$RECYCLE.BIN',
          'System Volume Information',
          'node_modules',
          '__pycache__',
          '.git',
          'Office2019激活脚本_files',
        ];

  factory AppConfig.fromJson(Map<String, dynamic> j) {
    return AppConfig(
      roots: (j['roots'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[r'D:\应用程序', r'D:\驱动'],
      excludeDirs: (j['exclude_dirs'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[],
      maxDepth: (j['max_depth'] as num?)?.toInt() ?? 6,
      timeout: (j['timeout'] as num?)?.toInt() ?? 40,
      maxDownloadMb: (j['max_download_mb'] as num?)?.toInt() ?? 4096,
      proxyMode: j['proxy']?['mode']?.toString() ?? 'none',
      httpProxy: j['proxy']?['http']?.toString() ?? '',
      httpsProxy: j['proxy']?['https']?.toString() ?? '',
      socksProxy: j['proxy']?['socks']?.toString() ?? '',
      githubToken: j['github_token']?.toString() ?? '',
      deleteOldDefault: j['delete_old_default'] as bool? ?? false,
      writeSha256: j['write_sha256'] as bool? ?? true,
      userAgent: j['user_agent']?.toString() ??
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'roots': roots,
        'exclude_dirs': excludeDirs,
        'max_depth': maxDepth,
        'timeout': timeout,
        'max_download_mb': maxDownloadMb,
        'proxy': <String, dynamic>{
          'mode': proxyMode,
          'http': httpProxy,
          'https': httpsProxy,
          'socks': socksProxy,
        },
        'github_token': githubToken,
        'delete_old_default': deleteOldDefault,
        'write_sha256': writeSha256,
        'user_agent': userAgent,
      };
}

/// 一个软件的官方源定义
class SourceDef {
  final String id;
  final String name;
  final List<String> keywords;
  final String sourceType; // github / html / json / unavailable
  final String versionUrl;
  final String downloadRegex;
  final String versionRegex;
  final String assetRegex;
  final String tagPrefix;
  final List<String> officialHosts;
  final String nameTemplate;
  final String downloadUrlTemplate;
  final String officialPage;
  final String notes;
  final String nameRegex;
  final String excludeRegex;
  final bool enabled;

  SourceDef({
    required this.id,
    required this.name,
    required this.keywords,
    required this.sourceType,
    required this.versionUrl,
    required this.downloadRegex,
    required this.versionRegex,
    required this.assetRegex,
    required this.tagPrefix,
    required this.officialHosts,
    required this.nameTemplate,
    required this.downloadUrlTemplate,
    required this.officialPage,
    required this.notes,
    required this.nameRegex,
    required this.excludeRegex,
    required this.enabled,
  });

  factory SourceDef.fromJson(Map<String, dynamic> j) {
    return SourceDef(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      keywords: (j['keywords'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[],
      sourceType: j['source_type']?.toString() ?? 'unavailable',
      versionUrl: j['version_url']?.toString() ?? '',
      downloadRegex: j['download_regex']?.toString() ?? '',
      versionRegex: j['version_regex']?.toString() ?? '',
      assetRegex: j['asset_regex']?.toString() ?? '',
      tagPrefix: j['tag_prefix']?.toString() ?? '',
      officialHosts: (j['official_hosts'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[],
      nameTemplate: j['name_template']?.toString() ?? '',
      downloadUrlTemplate: j['download_url_template']?.toString() ?? '',
      officialPage: j['official_page']?.toString() ?? '',
      notes: j['notes']?.toString() ?? '',
      nameRegex: j['name_regex']?.toString() ?? '',
      excludeRegex: j['exclude_regex']?.toString() ?? '',
      enabled: j['enabled'] as bool? ?? true,
    );
  }

  /// 允许下载的官方域名；GitHub 官方资产托管域名自动加入白名单。
  List<String> get allowedHosts {
    final out = <String>[...officialHosts];
    if (sourceType == 'github') {
      for (final h in <String>['github.com', 'githubusercontent.com', 'github.io']) {
        if (!out.contains(h)) out.add(h);
      }
    }
    return out;
  }

  static List<SourceDef> parseList(String raw) {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(SourceDef.fromJson)
        .toList();
  }
}

/// 扫描到的一条软件记录
class UpdateItem {
  final String sourceId;
  final String name;
  final String oldPath;
  final String targetDir;
  final String localVersion;
  String latestVersion;
  String downloadUrl;
  String officialSha256;
  String status;
  String note;
  final String officialPage;
  final String sourceNote;
  String savedPath;
  bool selected;
  bool deleteOld;

  UpdateItem({
    required this.sourceId,
    required this.name,
    required this.oldPath,
    required this.targetDir,
    required this.localVersion,
    this.latestVersion = '',
    this.downloadUrl = '',
    this.officialSha256 = '',
    this.status = '待检查',
    this.note = '',
    this.officialPage = '',
    this.sourceNote = '',
    this.savedPath = '',
    this.selected = false,
    this.deleteOld = false,
  });

  bool get hasUpdate =>
      latestVersion.isNotEmpty && versionGreater(latestVersion, localVersion);

  String get key => '$sourceId|$oldPath';
}

/// 版本比较：数字段逐个比较，rc/beta 等后缀低于正式版。
List<dynamic> _versionKey(String raw) {
  final parts = raw.trim().toLowerCase().split(RegExp(r'[.\-_+\s]'));
  final nums = <int>[];
  var suffix = '';
  for (final p in parts) {
    if (p.isNotEmpty && RegExp(r'^\d+$').hasMatch(p)) {
      nums.add(int.parse(p));
    } else if (p.isNotEmpty) {
      suffix = p;
      break;
    }
  }
  while (nums.length < 6) nums.add(0);
  final rank = (suffix.isEmpty ||
          suffix == 'final' ||
          suffix == 'stable' ||
          suffix == 'r' ||
          suffix == 'release')
      ? 1
      : 0;
  return <dynamic>[...nums.sublist(0, 6), rank, suffix];
}

bool versionGreater(String a, String b) {
  if (a.isEmpty) return false;
  if (b.isEmpty) return true;
  final ka = _versionKey(a);
  final kb = _versionKey(b);
  for (var i = 0; i < 6; i++) {
    if ((ka[i] as int) != (kb[i] as int)) {
      return (ka[i] as int) > (kb[i] as int);
    }
  }
  return (ka[6] as int) != (kb[6] as int)
      ? (ka[6] as int) > (kb[6] as int)
      : false;
}

/// 从任意文本中取第一个点分版本号
final RegExp _versionPattern = RegExp(r'(?<!\d)(\d{1,5}(?:\.\d{1,6}){1,5})(?!\d)');

String versionFromText(String text) {
  final m = _versionPattern.firstMatch(text);
  return m?.group(1) ?? '';
}
