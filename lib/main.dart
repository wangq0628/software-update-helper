import 'dart:io';

import 'package:flutter/material.dart';

import 'core.dart';
import 'models.dart';

void main() {
  runApp(const UpdateHelperApp());
}

class UpdateHelperApp extends StatelessWidget {
  const UpdateHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '软件更新助手',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2563EB),
        fontFamily: 'Microsoft YaHei',
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late AppConfig cfg;
  List<SourceDef> sources = <SourceDef>[];
  List<UpdateItem> items = <UpdateItem>[];
  final List<String> logs = <String>[];
  bool busy = false;
  double progress = 0;
  String status = '就绪';

  late TextEditingController rootController;
  late TextEditingController proxyController;
  late TextEditingController tokenController;
  late TextEditingController logController;
  String proxyMode = 'none';
  bool deleteOldDefault = false;

  @override
  void initState() {
    super.initState();
    cfg = loadConfig();
    sources = loadSources();
    rootController = TextEditingController(text: cfg.roots.join('; '));
    proxyController = TextEditingController(text: cfg.httpProxy);
    tokenController = TextEditingController(text: cfg.githubToken);
    logController = TextEditingController();
    log('已加载 ${sources.length} 个官方源定义。仅检查模式不会下载或删除任何文件。');
  }

  @override
  void dispose() {
    rootController.dispose();
    proxyController.dispose();
    tokenController.dispose();
    logController.dispose();
    super.dispose();
  }

  void log(String text) {
    if (!mounted) return;
    setState(() {
      logs.add(text);
      if (logs.length > 2000) logs.removeRange(0, logs.length - 1000);
      logController.text = logs.join('\n');
      logController.selection =
          TextSelection.collapsed(offset: logController.text.length);
    });
  }

  void setBusy(bool value) {
    if (!mounted) return;
    setState(() {
      busy = value;
      status = value ? '工作中…' : status;
    });
  }

  void syncConfig() {
    cfg.roots = rootController.text
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    cfg.proxyMode = proxyMode;
    cfg.httpProxy = proxyController.text.trim();
    cfg.httpsProxy = proxyController.text.trim();
    cfg.githubToken = tokenController.text.trim();
    cfg.deleteOldDefault = deleteOldDefault;
  }

  Future<void> saveSettings() async {
    syncConfig();
    saveConfig(cfg);
    log('设置已保存。');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }

  Future<void> _testProxy() async {
    syncConfig();
    log('正在测试代理…');
    final ok = await testProxy(cfg);
    log(ok ? '代理测试成功。' : '代理测试失败，请检查地址或网络。');
  }

  Future<void> scanAndCheck() async {
    if (busy) return;
    syncConfig();
    saveConfig(cfg);
    setBusy(true);
    setState(() {
      items = <UpdateItem>[];
      progress = 0;
      status = '正在扫描目录…';
      logs.clear();
      logController.clear();
    });

    try {
      final found = findItems(cfg, sources, log: log);
      log('识别到 ${found.length} 个软件，开始逐一查询官方源…');
      if (!mounted) return;
      setState(() => items = found);

      const batchSize = 6;
      for (var start = 0; start < found.length; start += batchSize) {
        final end = (start + batchSize < found.length)
            ? start + batchSize
            : found.length;
        final batch = found.sublist(start, end);
        final checked = await Future.wait(batch.map((item) async {
          final src = sources
              .where((s) => s.id == item.sourceId)
              .cast<SourceDef?>()
              .firstOrNull;
          if (src == null) {
            item.status = '未找到新版';
            item.note = '没有匹配的官方源定义';
            return item;
          }
          return checkItem(item, src, cfg);
        }));
        for (final it in checked) {
          it.selected = it.hasUpdate;
          it.deleteOld = cfg.deleteOldDefault && it.hasUpdate;
          log('${it.name}：${it.status} — ${it.note}');
        }
        if (!mounted) return;
        setState(() {
          progress = end / (found.length == 0 ? 1 : found.length);
        });
      }
      final updates = items.where((i) => i.hasUpdate).length;
      final notFound = items.where((i) => i.status == '未找到新版').length;
      setState(() {
        status = '检查完成：发现新版 $updates 项，未找到新版 $notFound 项。';
      });
      log('$status（本次未下载、未删除任何文件）');
    } catch (e) {
      setState(() => status = '检查失败');
      log('检查失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> downloadChosen() async {
    if (busy) return;
    final chosen = items.where((i) => i.selected && i.hasUpdate).toList();
    if (chosen.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先检查，并勾选需要下载的软件。')),
      );
      return;
    }
    final delCount = chosen.where((i) => i.deleteOld).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认下载'),
        content: Text(
          '将下载 ${chosen.length} 个软件，全部来自官方白名单域名，保存到各自旧版本所在文件夹。\n'
          '其中 $delCount 项勾选了“删旧版”，下载成功后会移入回收站（可还原）。\n\n继续？',
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续')),
        ],
      ),
    );
    if (confirmed != true) return;

    setBusy(true);
    setState(() => progress = 0);
    var ok = 0, fail = 0;
    try {
      for (var idx = 0; idx < chosen.length; idx++) {
        final it = chosen[idx];
        final src = sources
            .where((s) => s.id == it.sourceId)
            .cast<SourceDef?>()
            .firstOrNull;
        if (src == null) {
          log('${it.name}：缺少官方源定义，跳过');
          fail++;
          continue;
        }
        setState(() => status = '正在下载 ${it.name} ${it.latestVersion}');
        log('[${idx + 1}/${chosen.length}] 下载 ${it.name} ${it.latestVersion} …');
        final result = await downloadItem(it, src, cfg, onProgress: (written, total) {
          if (total > 0) {
            setState(() => progress =
                (idx + written / total) / chosen.length);
          }
        });
        log('${it.name}：${result.message}');
        if (result.ok) {
          ok++;
          if (it.deleteOld) {
            final recycle = toRecycleBin(it.oldPath);
            log('${it.name} 旧版本：${recycle.message} — ${it.oldPath}');
          }
        } else {
          fail++;
        }
        if (!mounted) return;
        setState(() {});
      }
      final report = writeReport(items, cfg);
      log('报告：$report');
      setState(() => status = '下载完成：成功 $ok，失败 $fail。未勾选的项目没有被删除。');
    } catch (e) {
      setState(() => status = '下载异常');
      log('下载异常：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> exportReport() async {
    final path = writeReport(items, cfg);
    log('报告：$path');
  }

  Future<void> openAppDir() async {
    try {
      await Process.run('explorer.exe', <String>[appDirectory().path]);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final updates = items.where((i) => i.hasUpdate).length;
    final notFound = items.where((i) => i.status == '未找到新版').length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('软件更新助手'),
        actions: <Widget>[
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F0FE),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFBFDBFE)),
            ),
            child: const Text('仅官方源 · Windows 专用',
                style: TextStyle(fontSize: 12, color: Color(0xFF1D4ED8))),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            _settingsCard(),
            const SizedBox(height: 12),
            _actionBar(updates, notFound),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            Expanded(child: _tableCard()),
            const SizedBox(height: 12),
            _logCard(),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('设置（修改后请点“保存设置”）',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: <Widget>[
                SizedBox(
                  width: 460,
                  child: TextField(
                    controller: rootController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: '扫描目录（多个用分号分隔）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    initialValue: proxyMode,
                    decoration: const InputDecoration(
                      labelText: '代理模式',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'none', child: Text('不使用代理')),
                      DropdownMenuItem(value: 'system', child: Text('使用系统代理')),
                      DropdownMenuItem(value: 'custom', child: Text('自定义代理')),
                    ],
                    onChanged: (v) => setState(() => proxyMode = v ?? 'none'),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: proxyController,
                    decoration: const InputDecoration(
                      labelText: 'HTTP 代理（如 http://127.0.0.1:7890）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: tokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'GitHub Token（可选）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<bool>(
                    initialValue: deleteOldDefault,
                    decoration: const InputDecoration(
                      labelText: '下载后旧版本',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const <DropdownMenuItem<bool>>[
                      DropdownMenuItem(value: false, child: Text('默认保留')),
                      DropdownMenuItem(value: true, child: Text('默认移入回收站')),
                    ],
                    onChanged: (v) =>
                        setState(() => deleteOldDefault = v ?? false),
                  ),
                ),
                FilledButton.tonal(
                    onPressed: saveSettings, child: const Text('保存设置')),
                OutlinedButton(
                    onPressed: _testProxy, child: const Text('测试代理')),
                OutlinedButton(
                    onPressed: openAppDir, child: const Text('打开程序目录')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionBar(int updates, int notFound) {
    return Row(
      children: <Widget>[
        FilledButton.icon(
          onPressed: busy ? null : scanAndCheck,
          icon: const Icon(Icons.search),
          label: const Text('① 扫描并检查官方新版'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  for (final i in items) {
                    if (i.hasUpdate) i.selected = true;
                  }
                }),
          child: const Text('全选有更新'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  for (final i in items) {
                    i.selected = false;
                  }
                }),
          child: const Text('取消全选'),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(
          onPressed: busy ? null : downloadChosen,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.download, size: 18),
              SizedBox(width: 6),
              Text('② 下载选中（官方源）'),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
            onPressed: exportReport, child: const Text('导出报告')),
        const Spacer(),
        Text(status, style: const TextStyle(color: Colors.grey)),
      ],
    );
  }

  Widget _tableCard() {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (items.isEmpty)
            const Expanded(
              child: Center(
                child: Text('尚未检查。点击上方“扫描并检查官方新版”开始。',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                child: DataTable(
                  columnSpacing: 12,
                  headingRowHeight: 36,
                  dataRowMinHeight: 40,
                  dataRowMaxHeight: 64,
                  columns: const <DataColumn>[
                    DataColumn(label: Text('更新')),
                    DataColumn(label: Text('软件')),
                    DataColumn(label: Text('本地版本')),
                    DataColumn(label: Text('官方版本')),
                    DataColumn(label: Text('状态')),
                    DataColumn(label: Text('说明 / 路径')),
                    DataColumn(label: Text('删旧版')),
                  ],
                  rows: items.map(_buildRow).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  DataRow _buildRow(UpdateItem it) {
    final color = it.hasUpdate
        ? const Color(0xFFC62828)
        : (it.status == '未找到新版' || it.status == '已是最新')
            ? Colors.grey
            : const Color(0xFF15803D);
    return DataRow(cells: <DataCell>[
      DataCell(Checkbox(
        value: it.selected,
        onChanged: (v) => setState(() => it.selected = v ?? false),
      )),
      DataCell(Text(it.name, style: const TextStyle(fontWeight: FontWeight.w600))),
      DataCell(Text(it.localVersion.isEmpty ? '-' : it.localVersion)),
      DataCell(Text(it.latestVersion.isEmpty ? '-' : it.latestVersion)),
      DataCell(Text(it.status, style: TextStyle(color: color, fontSize: 12))),
      DataCell(SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(it.note, style: const TextStyle(fontSize: 12)),
            Text(it.oldPath,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            if (it.officialPage.isNotEmpty)
              InkWell(
                onTap: () => Process.run('explorer.exe', <String>[it.officialPage]),
                child: const Text('官网核查 ↗',
                    style: TextStyle(fontSize: 11, color: Color(0xFF2563EB))),
              ),
          ],
        ),
      )),
      DataCell(Checkbox(
        value: it.deleteOld,
        onChanged: (v) => setState(() => it.deleteOld = v ?? false),
      )),
    ]);
  }

  Widget _logCard() {
    return SizedBox(
      height: 150,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('运行日志',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              Expanded(
                child: TextField(
                  controller: logController,
                  readOnly: true,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(
                      fontFamily: 'Consolas', fontSize: 12, color: Colors.grey),
                  decoration: const InputDecoration(
                      border: InputBorder.none, isDense: true),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
