import 'package:flutter/material.dart';

import 'accounts.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'platform/platform.dart' as platform;

/// Un archivo con su cuenta e índice, para listas que cruzan cuentas.
class FileRef {
  final Account account;
  final AccountIndex index;
  final DriveItem item;
  FileRef(this.account, this.index, this.item);

  String get path =>
      index.pathTo(index.parentOf[item.id] ?? topId).map((p) => p.name).join(' / ');
}

class DupGroup {
  final String md5;
  final List<FileRef> files;
  DupGroup(this.md5, this.files);
  int get size => files.first.item.size;
  int get recoverable => size * (files.length - 1);
  int get accounts => files.map((f) => f.account.email).toSet().length;
}

class TypeStat {
  final String type;
  int bytes = 0;
  int count = 0;
  TypeStat(this.type);
}

String typeOf(DriveItem it) {
  final m = it.mime;
  if (m.startsWith('image/')) return 'Imágenes';
  if (m.startsWith('video/')) return 'Videos';
  if (m.startsWith('audio/')) return 'Audio';
  if (m.contains('pdf')) return 'PDF';
  if (m.contains('spreadsheet') || m.contains('excel') || m.contains('csv')) return 'Planillas';
  if (m.contains('presentation') || m.contains('powerpoint')) return 'Presentaciones';
  if (m.contains('document') || m.contains('word') || m.startsWith('text/')) return 'Documentos';
  if (m.contains('zip') || m.contains('compressed') || m.contains('rar') || m.contains('7z') ||
      m.contains('tar')) {
    return 'Comprimidos';
  }
  if (m.contains('android.package') || m.contains('msdownload') || m.contains('executable')) {
    return 'Instaladores';
  }
  return 'Otros';
}

String _csvCell(Object? v) {
  final s = '${v ?? ''}';
  return (s.contains(';') || s.contains('"') || s.contains('\n'))
      ? '"${s.replaceAll('"', '""')}"'
      : s;
}

String _csv(List<String> header, Iterable<List<Object?>> rows) {
  final b = StringBuffer()..writeln(header.map(_csvCell).join(';'));
  for (final r in rows) {
    b.writeln(r.map(_csvCell).join(';'));
  }
  return b.toString();
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2).replaceAll('.', ',');

/// Analizador: más pesados, duplicados, por tipo, viejos y papelera.
class AnalyzerPage extends StatefulWidget {
  final List<Account> accounts;
  final IndexStore indexes;
  const AnalyzerPage({super.key, required this.accounts, required this.indexes});

  @override
  State<AnalyzerPage> createState() => _AnalyzerPageState();
}

class _AnalyzerPageState extends State<AnalyzerPage> with SingleTickerProviderStateMixin {
  static const _tabs = ['Más pesados', 'Duplicados', 'Por tipo', 'Viejos', 'Papelera'];
  static const _top = 200;
  late final TabController _tab = TabController(length: _tabs.length, vsync: this);
  String? _only; // email filtrado, o todas
  int _years = 3;

  List<Account> get _accounts => widget.accounts
      .where((a) => widget.indexes.loaded.containsKey(a.email))
      .where((a) => _only == null || a.email == _only)
      .toList();

  Iterable<FileRef> _files({bool trashed = false}) sync* {
    for (final a in _accounts) {
      final idx = widget.indexes.loaded[a.email]!;
      for (final it in idx.items.values) {
        if (it.isFolder || it.isVirtual || !it.mine || it.trashed != trashed) continue;
        yield FileRef(a, idx, it);
      }
    }
  }

  List<FileRef> _heaviest() {
    final l = _files().toList()..sort((x, y) => y.item.quota.compareTo(x.item.quota));
    return l.take(_top).toList();
  }

  List<DupGroup> _duplicates() {
    final byMd5 = <String, List<FileRef>>{};
    for (final f in _files()) {
      final md5 = f.item.md5;
      if (md5 == null || f.item.size == 0) continue;
      (byMd5[md5] ??= []).add(f);
    }
    final groups = [
      for (final e in byMd5.entries)
        if (e.value.length > 1) DupGroup(e.key, e.value)
    ]..sort((x, y) => y.recoverable.compareTo(x.recoverable));
    return groups;
  }

  List<TypeStat> _byType() {
    final m = <String, TypeStat>{};
    for (final f in _files()) {
      final s = m.putIfAbsent(typeOf(f.item), () => TypeStat(typeOf(f.item)));
      s.bytes += f.item.quota;
      s.count++;
    }
    return m.values.toList()..sort((x, y) => y.bytes.compareTo(x.bytes));
  }

  List<FileRef> _old() {
    final limit = DateTime.now().subtract(Duration(days: 365 * _years)).millisecondsSinceEpoch;
    final l = _files().where((f) => f.item.modified > 0 && f.item.modified < limit).toList()
      ..sort((x, y) => y.item.quota.compareTo(x.item.quota));
    return l;
  }

  List<FileRef> _trash() =>
      _files(trashed: true).toList()..sort((x, y) => y.item.quota.compareTo(x.item.quota));

  Future<void> _export() async {
    final day = DateTime.now();
    final stamp = '${day.year}${day.month.toString().padLeft(2, '0')}'
        '${day.day.toString().padLeft(2, '0')}';
    List<Object?> fileRow(FileRef f) => [
          f.account.email,
          f.item.name,
          typeOf(f.item),
          _mb(f.item.quota),
          f.item.modified > 0 ? fmtDay(f.item.modifiedAt) : '',
          f.path,
          'https://drive.google.com/open?id=${f.item.id}',
        ];
    const fileHeader = ['Cuenta', 'Nombre', 'Tipo', 'MB', 'Modificado', 'Ubicación', 'Link'];
    String name;
    String content;
    switch (_tab.index) {
      case 0:
        name = 'mas-pesados';
        content = _csv(fileHeader, _heaviest().map(fileRow));
      case 1:
        name = 'duplicados';
        final rows = <List<Object?>>[];
        var g = 0;
        for (final d in _duplicates()) {
          g++;
          for (final f in d.files) {
            rows.add([g, _mb(d.recoverable), ...fileRow(f)]);
          }
        }
        content = _csv(['Grupo', 'MB recuperables', ...fileHeader], rows);
      case 2:
        name = 'por-tipo';
        content = _csv(['Tipo', 'Archivos', 'MB'],
            _byType().map((t) => [t.type, t.count, _mb(t.bytes)]));
      case 3:
        name = 'viejos-$_years-anios';
        content = _csv(fileHeader, _old().map(fileRow));
      default:
        name = 'papelera';
        content = _csv(fileHeader, _trash().map(fileRow));
    }
    try {
      final msg = await platform.saveCsv('multigdrive-$name-$stamp.csv', content);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
      }
    }
  }

  void _openFolderOf(FileRef f) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ExplorerPage(
            account: f.account, index: f.index, startId: f.index.parentOf[f.item.id] ?? topId),
      ),
    );
  }

  Widget _fileTile(FileRef f, {bool showAccount = true}) => ListTile(
        leading: Icon(iconFor(f.item), color: Color(f.account.color)),
        title: Text(f.item.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (showAccount) f.account.title,
            if (f.item.modified > 0) fmtDay(f.item.modifiedAt),
            f.path,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(formatBytes(f.item.quota)),
        onTap: () => showItemDetails(context, f.index, f.item, f.account.title),
        onLongPress: () => _openFolderOf(f),
      );

  Widget _summary(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _heaviestView() {
    final l = _heaviest();
    final sum = l.fold<int>(0, (s, f) => s + f.item.quota);
    return ListView(children: [
      _summary('Los ${l.length} archivos más pesados ocupan ${formatBytes(sum)}.'),
      for (final f in l) _fileTile(f),
    ]);
  }

  Widget _duplicatesView() {
    final groups = _duplicates();
    final total = groups.fold<int>(0, (s, g) => s + g.recoverable);
    return ListView(children: [
      _summary('${groups.length} grupos de archivos idénticos. '
          'Dejando una sola copia de cada uno liberarías ${formatBytes(total)}.'),
      for (final g in groups.take(_top))
        ExpansionTile(
          leading: Icon(iconFor(g.files.first.item)),
          title: Text(g.files.first.item.name, overflow: TextOverflow.ellipsis),
          subtitle: Text('${g.files.length} copias · ${g.accounts} '
              '${g.accounts == 1 ? 'cuenta' : 'cuentas'} · '
              'liberás ${formatBytes(g.recoverable)}'),
          children: [for (final f in g.files) _fileTile(f)],
        ),
    ]);
  }

  Widget _typeView() {
    final stats = _byType();
    final total = stats.fold<int>(0, (s, t) => s + t.bytes);
    return ListView(children: [
      _summary('Tus archivos (sin papelera) ocupan ${formatBytes(total)}.'),
      for (final t in stats)
        ListTile(
          title: Text(t.type),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.count} archivos · ${total == 0 ? 0 : (t.bytes * 100 / total).round()} %'),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: total == 0 ? 0 : t.bytes / total, minHeight: 6),
          ]),
          trailing: Text(formatBytes(t.bytes)),
        ),
    ]);
  }

  Widget _oldView() {
    final l = _old();
    final sum = l.fold<int>(0, (s, f) => s + f.item.quota);
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Sin cambios hace más de'),
          for (final y in [1, 2, 3, 5])
            ChoiceChip(
              label: Text('$y ${y == 1 ? 'año' : 'años'}'),
              selected: _years == y,
              onSelected: (_) => setState(() => _years = y),
            ),
        ]),
      ),
      _summary('${l.length} archivos · ${formatBytes(sum)}'),
      for (final f in l.take(_top)) _fileTile(f),
    ]);
  }

  Widget _trashView() {
    final l = _trash();
    final sum = l.fold<int>(0, (s, f) => s + f.item.quota);
    return ListView(children: [
      _summary('${l.length} archivos en la papelera ocupan ${formatBytes(sum)}. '
          'Vaciarla en cada cuenta libera ese espacio.'),
      for (final f in l.take(_top)) _fileTile(f),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final indexed =
        widget.accounts.where((a) => widget.indexes.loaded.containsKey(a.email)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analizador'),
        actions: [
          IconButton(
            tooltip: 'Exportar esta pestaña a CSV',
            onPressed: indexed.isEmpty ? null : _export,
            icon: const Icon(Icons.download),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in _tabs) Tab(text: t)],
        ),
      ),
      body: indexed.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Primero indexá al menos una cuenta desde el panel.',
                    textAlign: TextAlign.center),
              ),
            )
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: DropdownButton<String?>(
                  value: _only,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem<String?>(
                        value: null, child: Text('Todas las cuentas (${indexed.length})')),
                    for (final a in indexed)
                      DropdownMenuItem<String?>(value: a.email, child: Text(a.title)),
                  ],
                  onChanged: (v) => setState(() => _only = v),
                ),
              ),
              Expanded(
                child: TabBarView(controller: _tab, children: [
                  _heaviestView(),
                  _duplicatesView(),
                  _typeView(),
                  _oldView(),
                  _trashView(),
                ]),
              ),
            ]),
    );
  }
}
