import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'models.dart';

/// 返回程序目录（发布时 data/ 与 exe 同级；开发时取项目根目录）
Directory appDirectory() {
  final candidates = <Directory>[
    File(Platform.resolvedExecutable).parent,
    Directory.current,
  ];
  for (final d in candidates) {
    if (File('${d.path}${Platform.pathSeparator}data${Platform.pathSeparator}catalog.json')
        .existsSync()) {
      return d;
    }
  }
  return candidates.first;
}

AppConfig loadConfig() {
  final f = File('${appDirectory().path}${Platform.pathSeparator}data${Platform.pathSeparator}config.json');
  if (!f.existsSync()) return AppConfig();
  try {
    return AppConfig.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  } catch (_) {
    return AppConfig();
  }
}

void saveConfig(AppConfig cfg) {
  final f = File('${appDirectory().path}${Platform.pathSeparator}data${Platform.pathSeparator}config.json');
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      encoding: utf8);
}

List<SourceDef> loadSources() {
  final f = File('${appDirectory().path}${Platform.pathSeparator}data${Platform.pathSeparator}catalog.json');
  if (!f.existsSync()) return <SourceDef>[];
  try {
    return SourceDef.parseList(f.readAsStringSync());
  } catch (_) {
    return <SourceDef>[];
  }
}

// ---------------------------------------------------------------------------
// 路径与匹配工具
// ---------------------------------------------------------------------------
String basenameOf(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.isEmpty ? '' : parts.last;
}

String dirnameOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final i = normalized.lastIndexOf('/');
  if (i < 0) return '.';
  if (i == 0) return '/';
  return normalized.substring(0, i);
}

String stemOf(String path) {
  final name = basenameOf(path);
  final i = name.lastIndexOf('.');
  return i > 0 ? name.substring(0, i) : name;
}

String normalizeName(String text) {
  return text
      .replaceAll(RegExp(r'[\s_\-.（）()\[\]【】]+'), '')
      .toLowerCase();
}

bool hostAllowed(String url, List<String> hosts) {
  final host = (Uri.tryParse(url)?.host ?? '').toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (host.isEmpty) return false;
  for (final raw in hosts) {
    final h = raw.toLowerCase().trim().replaceAll(RegExp(r'^\.'), '');
    if (h.isEmpty) continue;
    if (host == h || host.endsWith('.$h')) return true;
  }
  return false;
}

String fillTemplate(String template, String version) {
  return template
      .replaceAll('{version_underscore}', version.replaceAll('.', '_'))
      .replaceAll('{version_compact}', version.replaceAll('.', ''))
      .replaceAll('{version}', version);
}

final Set<String> _allowedExt = <String>{
  '.exe', '.msi', '.zip', '.rar', '.7z', '.apk', '.tar', '.gz', '.xz'
};

// ---------------------------------------------------------------------------
// HTTP：代理 + 官方域名白名单 + 手工跳转校验
// ---------------------------------------------------------------------------
HttpClient _makeClient(AppConfig cfg) {
  final client = HttpClient();
  client.connectionTimeout = Duration(seconds: cfg.timeout);
  client.findProxy = (Uri uri) {
    if (cfg.proxyMode == 'custom') {
      final p = cfg.httpProxy.trim();
      if (p.isNotEmpty) {
        final hostPort = p.replaceFirst(RegExp(r'^https?://'), '');
        return 'PROXY $hostPort';
      }
      final s = cfg.socksProxy.trim();
      if (s.isNotEmpty) {
        return 'SOCKS ${s.replaceFirst(RegExp(r'^socks5?://'), '')}';
      }
    }
    if (cfg.proxyMode == 'system') {
      final env = Platform.environment;
      final p = env['HTTPS_PROXY'] ??
          env['https_proxy'] ??
          env['HTTP_PROXY'] ??
          env['http_proxy'];
      if (p != null && p.isNotEmpty) {
        return 'PROXY ${p.replaceFirst(RegExp(r'^https?://'), '')}';
      }
    }
    return 'DIRECT';
  };
  return client;
}

const Set<int> _redirectCodes = <int>{301, 302, 303, 307, 308};

Future<(HttpClientResponse, Uri)> _openChecked(
  String url,
  AppConfig cfg,
  List<String> hosts, {
  Map<String, String> headers = const <String, String>{},
}) async {
  var current = Uri.parse(url);
  if (hosts.isNotEmpty && !hostAllowed(current.toString(), hosts)) {
    throw StateError('地址不在官方白名单内：$url');
  }
  final client = _makeClient(cfg);
  for (var hop = 0; hop < 12; hop++) {
    final req = await client.getUrl(current);
    req.headers.set('User-Agent', cfg.userAgent);
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
    headers.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close();
    if (_redirectCodes.contains(resp.statusCode)) {
      final loc = resp.headers.value('location');
      if (loc != null && loc.isNotEmpty) {
        final next = current.resolve(loc);
        if (hosts.isNotEmpty && !hostAllowed(next.toString(), hosts)) {
          await resp.drain<void>();
          client.close();
          throw StateError(
              '拒绝下载：官方源跳转到非官方域名 ${next.host}');
        }
        await resp.drain<void>();
        current = next;
        continue;
      }
    }
    return (resp, current);
  }
  client.close();
  throw StateError('官方源跳转次数过多');
}

Future<String> fetchText(
  String url,
  AppConfig cfg,
  List<String> hosts, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final (resp, _) = await _openChecked(url, cfg, hosts, headers: headers);
  final bytes = <int>[];
  await for (final chunk in resp) {
    bytes.addAll(chunk);
    if (bytes.length > 4 * 1024 * 1024) break;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Future<bool> testProxy(AppConfig cfg) async {
  try {
    final text = await fetchText('https://api.github.com', cfg, <String>['github.com']);
    return text.isNotEmpty;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// 扫描与识别
// ---------------------------------------------------------------------------
typedef LogFn = void Function(String);

List<UpdateItem> findItems(AppConfig cfg, List<SourceDef> sources, {LogFn? log}) {
  final exclude = cfg.excludeDirs.toSet();
  final prepared = <Map<String, dynamic>>[];
  for (final s in sources) {
    if (!s.enabled) continue;
    prepared.add(<String, dynamic>{
      'src': s,
      'keys': s.keywords
          .map(normalizeName)
          .where((k) => k.length >= 3)
          .toList(),
    });
  }

  UpdateItem? matchSource(String text) {
    if (text.isEmpty) return null;
    final nt = normalizeName(text);
    for (final p in prepared) {
      final src = p['src'] as SourceDef;
      if (src.excludeRegex.isNotEmpty) {
        try {
          if (RegExp(src.excludeRegex, caseSensitive: false).hasMatch(text)) continue;
        } catch (_) {}
      }
      bool hit;
      if (src.nameRegex.isNotEmpty) {
        try {
          hit = RegExp(src.nameRegex, caseSensitive: false).hasMatch(text);
        } catch (_) {
          hit = false;
        }
      } else {
        hit = (p['keys'] as List<String>).any(nt.contains);
      }
      if (!hit) continue;

      var ver = versionFromText(text);
      // 7-Zip 官网用 7z2407 表示 24.07
      if (src.id == '7zip' && ver.isEmpty) {
        final m = RegExp(r'7z(\d{4})', caseSensitive: false).firstMatch(basenameOf(text));
        if (m != null) {
          final v = m.group(1)!;
          ver = '${v.substring(0, 2)}.${v.substring(2)}';
        }
      }
      final parent = dirnameOf(text);
      return UpdateItem(
        sourceId: src.id,
        name: src.name,
        oldPath: text,
        targetDir: parent == '.' ? text : parent,
        localVersion: ver,
        officialPage: src.officialPage,
        sourceNote: src.notes,
      );
    }
    return null;
  }

  final items = <UpdateItem>[];
  final seen = <String>{};

  void scanDir(String dir, int depth, bool isRoot) {
    if (depth > cfg.maxDepth) return;
    final dirName = basenameOf(dir);
    UpdateItem? dirHit;
    if (!isRoot && dirName.isNotEmpty) {
      dirHit = matchSource(dirName);
      if (dirHit != null) {
        final key = '${dirHit.sourceId}|${dirnameOf(dir)}|dir';
        if (!seen.contains(key)) {
          seen.add(key);
          final item = UpdateItem(
            sourceId: dirHit.sourceId,
            name: dirHit.name,
            oldPath: dir,
            targetDir: dirnameOf(dir),
            localVersion: dirHit.localVersion,
            officialPage: dirHit.officialPage,
            sourceNote: dirHit.sourceNote,
          );
          items.add(item);
        }
      }
    }
    final dirMatchedIds = dirHit == null
        ? <String>{}
        : <String>{dirHit.sourceId};

    Iterable<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } catch (e) {
      log?.call('无法读取目录：$dir ($e)');
      return;
    }
    for (final entity in children) {
      if (entity is Directory) {
        if (exclude.contains(basenameOf(entity.path))) continue;
        scanDir(entity.path, depth + 1, false);
      } else if (entity is File) {
        final ext = stemOf(entity.path) == basenameOf(entity.path)
            ? ''
            : basenameOf(entity.path).substring(basenameOf(entity.path).lastIndexOf('.')).toLowerCase();
        if (!_allowedExt.contains(ext)) continue;
        final hit = matchSource(stemOf(entity.path));
        if (hit == null || dirMatchedIds.contains(hit.sourceId)) continue;
        final key = '${hit.sourceId}|${dirnameOf(entity.path)}|${basenameOf(entity.path)}';
        if (seen.contains(key)) continue;
        seen.add(key);
        var ver = hit.localVersion;
        if (ver.isEmpty) {
          final pv = versionFromText(dirName);
          ver = pv;
        }
        items.add(UpdateItem(
          sourceId: hit.sourceId,
          name: hit.name,
          oldPath: entity.path,
          targetDir: dirnameOf(entity.path),
          localVersion: ver,
          officialPage: hit.officialPage,
          sourceNote: hit.sourceNote,
        ));
      }
    }
  }

  for (final root in cfg.roots) {
    if (root.trim().isEmpty) continue;
    final d = Directory(root);
    if (!d.existsSync()) {
      log?.call('跳过不存在的目录：$root');
      continue;
    }
    log?.call('扫描：$root');
    scanDir(d.path.replaceAll('\\', '/'), 0, true);
  }

  items.sort((a, b) {
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return c != 0 ? c : a.oldPath.toLowerCase().compareTo(b.oldPath.toLowerCase());
  });
  return items;
}

// ---------------------------------------------------------------------------
// 官方源检查
// ---------------------------------------------------------------------------
Future<UpdateItem> checkItem(UpdateItem item, SourceDef src, AppConfig cfg) async {
  item.latestVersion = '';
  item.downloadUrl = '';
  item.officialSha256 = '';

  if (src.sourceType == 'unavailable') {
    item.status = '未找到新版';
    item.note = '官网未提供可核查的官方直链：${src.notes.isEmpty ? '需登录或仅在线安装' : src.notes}';
    return item;
  }

  String ver = '', url = '', err = '', sha = '';
  try {
    if (src.sourceType == 'github') {
      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };
      if (cfg.githubToken.trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${cfg.githubToken.trim()}';
      }
      final text = await fetchText(src.versionUrl, cfg, src.allowedHosts,
          headers: headers);
      final data = jsonDecode(text) as Map<String, dynamic>;
      var tag = (data['tag_name'] ?? '').toString();
      if (src.tagPrefix.isNotEmpty &&
          tag.toLowerCase().startsWith(src.tagPrefix.toLowerCase())) {
        tag = tag.substring(src.tagPrefix.length);
      }
      ver = versionFromText(tag);
      if (ver.isEmpty) {
        err = '官方发布标签中未解析到版本号';
      } else {
        final assets = (data['assets'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
        RegExp? pat;
        if (src.assetRegex.isNotEmpty) {
          try {
            pat = RegExp(src.assetRegex, caseSensitive: false);
          } catch (e) {
            err = '官方源匹配规则无效：$e';
          }
        }
        if (err.isEmpty && pat != null) {
          for (final a in assets) {
            final name = (a['name'] ?? '').toString();
            final download = (a['browser_download_url'] ?? '').toString();
            if (pat.hasMatch(name) && download.isNotEmpty) {
              url = download;
              final digest = (a['digest'] ?? '').toString();
              if (digest.startsWith('sha256:')) {
                sha = digest.substring(7).trim().toLowerCase();
              }
              break;
            }
          }
        }
        if (err.isEmpty && url.isEmpty && src.downloadUrlTemplate.isNotEmpty) {
          url = fillTemplate(src.downloadUrlTemplate, ver);
        }
        if (err.isEmpty && url.isEmpty) {
          err = '官方发布页未找到匹配的 Windows 安装包';
        }
      }
    } else if (src.sourceType == 'html' || src.sourceType == 'json') {
      final text = await fetchText(src.versionUrl, cfg, src.allowedHosts);
      if (src.versionRegex.isNotEmpty) {
        try {
          final m = RegExp(src.versionRegex,
                  caseSensitive: false, dotAll: true)
              .firstMatch(text);
          if (m != null) ver = m.group(1)?.trim() ?? '';
        } catch (e) {
          err = '版本规则无效：$e';
        }
      }
      if (ver.isEmpty && err.isEmpty) {
        ver = versionFromText(text.length > 20000 ? text.substring(0, 20000) : text);
      }
      if (ver.isEmpty && err.isEmpty) {
        err = '官网页面未解析到版本号';
      }
      if (err.isEmpty && src.downloadRegex.isNotEmpty) {
        try {
          final m = RegExp(src.downloadRegex,
                  caseSensitive: false, dotAll: true)
              .firstMatch(text);
          if (m != null) {
            final link = m.group(1)?.trim() ?? '';
            if (link.isNotEmpty) {
              url = Uri.parse(src.versionUrl).resolve(link).toString();
            }
          }
        } catch (e) {
          err = '下载地址规则无效：$e';
        }
      }
      if (err.isEmpty && url.isEmpty && src.downloadUrlTemplate.isNotEmpty) {
        url = fillTemplate(src.downloadUrlTemplate, ver);
      }
      if (err.isEmpty && url.isEmpty) {
        err = '官网页面未解析到官方下载地址';
      }
    } else {
      err = '未知源类型：${src.sourceType}';
    }
  } on SocketException catch (e) {
    err = '官方源访问失败：${e.message}';
  } catch (e) {
    final msg = e.toString();
    err = msg.length > 100 ? msg.substring(0, 100) : msg;
  }

  if (err.isNotEmpty) {
    item.status = '未找到新版';
    item.note = err;
    return item;
  }
  if (url.isEmpty || !hostAllowed(url, src.allowedHosts)) {
    item.status = '未找到新版';
    item.note = '官方返回的下载地址不在白名单内，已拒绝';
    return item;
  }

  item.latestVersion = ver;
  item.downloadUrl = url;
  item.officialSha256 = sha;
  if (versionGreater(ver, item.localVersion)) {
    item.status = item.localVersion.isEmpty ? '本地版本未知' : '发现新版';
    item.note = '本地 ${item.localVersion.isEmpty ? '未知' : item.localVersion} → 官方 $ver';
  } else {
    item.status = '已是最新';
    item.note = '官方最新版 $ver';
  }
  return item;
}

// ---------------------------------------------------------------------------
// 安全下载
// ---------------------------------------------------------------------------
class DownloadResult {
  final bool ok;
  final String message;
  DownloadResult(this.ok, this.message);
}

String safeFileName(String name) {
  var n = basenameOf(name.replaceAll('\\', '/'));
  n = n.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_').trim();
  return n.isEmpty ? 'download.bin' : n;
}

String buildFileName(SourceDef src, String url, String version) {
  var name = src.nameTemplate.isNotEmpty
      ? fillTemplate(src.nameTemplate, version)
      : (Uri.tryParse(url)?.pathSegments.isNotEmpty == true
          ? Uri.parse(url).pathSegments.last
          : '${src.name} $version.exe');
  name = safeFileName(name);
  if (version.isNotEmpty && !name.contains(version)) {
    final i = name.lastIndexOf('.');
    name = i > 0
        ? '${name.substring(0, i)} v$version${name.substring(i)}'
        : '$name v$version';
  }
  return name;
}

Future<DownloadResult> downloadItem(
  UpdateItem item,
  SourceDef src,
  AppConfig cfg, {
  void Function(int written, int total)? onProgress,
}) async {
  if (item.downloadUrl.isEmpty) return DownloadResult(false, '没有可用的官方下载地址');
  if (!hostAllowed(item.downloadUrl, src.allowedHosts)) {
    return DownloadResult(false, '下载地址不在官方白名单内，已拒绝');
  }
  final targetDir = Directory(item.targetDir);
  if (!targetDir.existsSync()) {
    return DownloadResult(false, '目标文件夹不存在：${item.targetDir}');
  }

  var finalPath = '${targetDir.path}${Platform.pathSeparator}'
      '${buildFileName(src, item.downloadUrl, item.latestVersion)}';
  var file = File(finalPath);
  for (var i = 1; file.existsSync() && i < 100; i++) {
    final dot = finalPath.lastIndexOf('.');
    final candidate = dot > 0
        ? '${finalPath.substring(0, dot)}($i)${finalPath.substring(dot)}'
        : '$finalPath($i)';
    file = File(candidate);
    finalPath = candidate;
  }
  final tmp = File('$finalPath.downloading');
  final maxBytes = cfg.maxDownloadMb * 1024 * 1024;

  try {
    final (resp, finalUri) = await _openChecked(item.downloadUrl, cfg, src.allowedHosts,
        headers: <String, String>{'Accept': '*/*'});
    if (!hostAllowed(finalUri.toString(), src.allowedHosts)) {
      return DownloadResult(false, '下载被重定向到非官方域名');
    }
    final totalHeader = resp.headers.value('content-length');
    final total = totalHeader == null ? 0 : int.tryParse(totalHeader) ?? 0;
    if (total > maxBytes) {
      return DownloadResult(false, '官方文件过大（${total ~/ 1048576} MB），已取消');
    }

    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var written = 0;
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await for (final chunk in resp) {
        written += chunk.length;
        if (written > maxBytes) {
          return DownloadResult(false, '下载内容超过大小限制，已取消');
        }
        raf.writeFromSync(chunk);
        hashSink.add(chunk);
        onProgress?.call(written, total);
      }
    } finally {
      await raf.close();
      hashSink.close();
    }

    final digest = digestSink.digest?.toString() ?? '';
    final official = item.officialSha256.trim().toLowerCase();
    if (official.isNotEmpty && digest != official) {
      if (tmp.existsSync()) await tmp.delete();
      return DownloadResult(false, '下载文件的 SHA256 与官方公布值不一致，已丢弃该文件');
    }
    if (tmp.existsSync()) await tmp.rename(finalPath);
    item.savedPath = finalPath;

    if (cfg.writeSha256) {
      final shaFile = File('$finalPath.sha256.txt');
      final officialLine = official.isNotEmpty ? '官方校验值：$official\n' : '';
      await shaFile.writeAsString(
        '$digest  ${basenameOf(finalPath)}\n来源：${item.downloadUrl}\n$officialLine',
        encoding: utf8,
      );
    }
    final verified = official.isNotEmpty ? '，SHA256 与官方一致' : '';
    return DownloadResult(
        true, '已下载到 ${basenameOf(finalPath)}（SHA256 ${digest.substring(0, digest.length < 16 ? digest.length : 16)}…$verified）');
  } catch (e) {
    if (tmp.existsSync()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    final msg = e.toString();
    return DownloadResult(false, '下载失败：${msg.length > 120 ? msg.substring(0, 120) : msg}');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// 回收站（Windows Shell API，可还原）
// ---------------------------------------------------------------------------
final class _ShellFileOpStruct extends Struct {
  external Pointer<Void> hwnd;
  @Uint32()
  external int wFunc;
  external Pointer<Uint16> pFrom;
  external Pointer<Uint16> pTo;
  @Uint32()
  external int fFlags;
  @Uint32()
  external int fAnyOperationsAborted;
  external Pointer<Void> hNameMappings;
  external Pointer<Uint16> lpszProgressTitle;
}

class RecycleResult {
  final bool ok;
  final String message;
  RecycleResult(this.ok, this.message);
}

RecycleResult toRecycleBin(String path) {
  final exists = File(path).existsSync() || Directory(path).existsSync();
  if (!exists) return RecycleResult(false, '文件已不存在');
  final absolute = File(path).absolute.path.replaceAll('/', r'\');
  final buffer = calloc<Uint16>(absolute.length + 2);
  final op = calloc<_ShellFileOpStruct>();
  try {
    for (var i = 0; i < absolute.length; i++) {
      buffer[i] = absolute.codeUnitAt(i);
    }
    buffer[absolute.length] = 0;
    buffer[absolute.length + 1] = 0;

    op.ref.wFunc = 3; // FO_DELETE
    op.ref.pFrom = buffer;
    op.ref.pTo = nullptr;
    op.ref.fFlags = 0x40 | 0x10 | 0x400; // ALLOWUNDO | NOCONFIRMATION | NOERRORUI
    op.ref.fAnyOperationsAborted = 0;

    final shell = DynamicLibrary.open('shell32.dll');
    final fn = shell.lookupFunction<
        Int32 Function(Pointer<_ShellFileOpStruct>),
        int Function(Pointer<_ShellFileOpStruct>)>('SHFileOperationW');
    final rc = fn(op);
    if (rc == 0 && op.ref.fAnyOperationsAborted == 0) {
      return RecycleResult(true, '已移入回收站（可还原）');
    }
    return RecycleResult(false, '移入回收站失败（代码 $rc）');
  } catch (e) {
    return RecycleResult(false, '移入回收站失败：$e');
  } finally {
    calloc.free(op);
    calloc.free(buffer);
  }
}

// ---------------------------------------------------------------------------
// 报告
// ---------------------------------------------------------------------------
String writeReport(List<UpdateItem> items, AppConfig cfg) {
  final now = DateTime.now();
  final stamp = '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}_'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  final out = File(
      '${appDirectory().path}${Platform.pathSeparator}检查报告_$stamp.txt');
  final lines = <String>[
    '软件更新助手 v$appVersion 检查报告',
    '生成时间：$now',
    '扫描目录：${cfg.roots.join(', ')}',
    '代理模式：${cfg.proxyMode}',
    '',
    '${'软件'.padRight(24)}${'本地版本'.padRight(16)}${'官方版本'.padRight(16)}${'状态'.padRight(14)}说明',
    '-' * 110,
  ];
  for (final i in items) {
    lines.add('${_pad(i.name, 24)}${_pad(i.localVersion, 16)}'
        '${_pad(i.latestVersion, 16)}${_pad(i.status, 14)}${i.note}');
    lines.add('    路径：${i.oldPath}');
    if (i.downloadUrl.isNotEmpty) lines.add('    官方地址：${i.downloadUrl}');
    if (i.savedPath.isNotEmpty) lines.add('    已下载：${i.savedPath}');
  }
  lines.add('');
  lines.add('说明：未找到新版的软件未做任何下载；更新文件均来自官方白名单域名。');
  out.writeAsStringSync('\uFEFF${lines.join('\n')}', encoding: utf8);
  return out.path;
}

String _pad(String text, int width) {
  // 中文按两个字符宽度估算，保持列对齐
  var w = 0;
  for (final c in text.runes) {
    w += c > 127 ? 2 : 1;
  }
  if (w >= width) return text;
  return text + ' ' * (width - w);
}
