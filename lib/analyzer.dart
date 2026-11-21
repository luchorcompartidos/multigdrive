import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'actions.dart';
import 'cleanup.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'platform/platform.dart' as platform;
import 'side_tree.dart';

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

String _csvCell(Object? v, [String sep = ';']) {
  final s = '${v ?? ''}';
  return (s.contains(sep) || s.contains(',') || s.contains('"') || s.contains('\n'))
      ? '"${s.replaceAll('"', '""')}"'
      : s;
}

String _csv(List<String> header, Iterable<List<Object?>> rows, {String sep = ';'}) {
  final b = StringBuffer()..writeln(header.map((c) => _csvCell(c, sep)).join(sep));
  for (final r in rows) {
    b.writeln(r.map((c) => _csvCell(c, sep)).join(sep));
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
  Set<String>? _sel; // "email|id" seleccionados (null = sin modo selección)
  final Map<String, FileRef> _refs = {};

  String _k(FileRef f) => '${f.account.email}|${f.item.id}';

  Widget _selectionBar(BuildContext context) {
    final refs = [for (final k in _sel ?? const <String>{}) if (_refs[k] != null) _refs[k]!];
    final bytes = refs.fold<int>(0, (s, f) => s + f.item.quota);
    final inTrash = _tab.index == 4;
    final pairs = [for (final f in refs) (f.account, f.item)];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(children: [
          Expanded(child: Text('${refs.length} seleccionados · ${formatBytes(bytes)}')),
          FilledButton.tonalIcon(
            icon: Icon(inTrash ? Icons.restore_from_trash : Icons.delete_outline),
            label: Text(inTrash ? 'Restaurar' : 'Papelera'),
            onPressed: refs.isEmpty
                ? null
                : () async {
                    if (!inTrash &&
                        !await confirm(context, 'Mover a la papelera',
                            '¿Mandar ${refs.length} archivos (${formatBytes(bytes)}) a la papelera?',
                            'A la papelera')) {
                      return;
                    }
                    if (!context.mounted) return;
                    await runBatch(context, inTrash ? 'Restaurando' : 'Mandando a la papelera',
                        pairs, (a, it) => DriveActions.setTrashed(a, it, !inTrash),
                        done: inTrash ? 'Restaurados' : 'Enviados a la papelera');
                    if (mounted) setState(() => _sel = null);
                  },
          ),
        ]),
      ),
    );
  }

  Future<void> _emptyAllTrash() async {
    final accounts = DriveActions.store.accounts;
    if (!await confirm(
        context,
        'Vaciar todas las papeleras',
        'Se borra DEFINITIVAMENTE el contenido de la papelera de las ${accounts.length} cuentas. '
            'No se puede deshacer.',
        'Vaciar todas')) {
      return;
    }
    if (!mounted) return;
    final dummy = DriveItem.virtual(trashId, 'Papelera');
    await runBatch(context, 'Vaciando papeleras', [for (final a in accounts) (a, dummy)],
        (a, _) => DriveActions.emptyTrash(a),
        done: 'Papeleras vaciadas');
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    indexChanged.addListener(_onChange);
    _tab.addListener(() {
      if (_sel != null && mounted) setState(() => _sel = null);
    });
  }

  @override
  void dispose() {
    indexChanged.removeListener(_onChange);
    _tab.dispose();
    super.dispose();
  }

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

  /// Datos de la pestaña actual: nombre, encabezado y filas (MB con coma decimal).
  (String, List<String>, List<List<Object?>>) _table() {
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
    switch (_tab.index) {
      case 0:
        return ('mas-pesados', fileHeader, _heaviest().map(fileRow).toList());
      case 1:
        final rows = <List<Object?>>[];
        var g = 0;
        for (final d in _duplicates()) {
          g++;
          for (final f in d.files) {
            rows.add([g, _mb(d.recoverable), ...fileRow(f)]);
          }
        }
        return ('duplicados', ['Grupo', 'MB recuperables', ...fileHeader], rows);
      case 2:
        return ('por-tipo', ['Tipo', 'Archivos', 'MB'],
            _byType().map((t) => <Object?>[t.type, t.count, _mb(t.bytes)]).toList());
      case 3:
        return ('viejos-$_years-anios', fileHeader, _old().map(fileRow).toList());
      default:
        return ('papelera', fileHeader, _trash().map(fileRow).toList());
    }
  }

  Future<void> _export() async {
    final day = DateTime.now();
    final stamp = '${day.year}${day.month.toString().padLeft(2, '0')}'
        '${day.day.toString().padLeft(2, '0')}';
    final target = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Archivo CSV en este equipo'),
            onTap: () => Navigator.pop(ctx, 'csv'),
          ),
          for (final a in DriveActions.store.accounts)
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: Text('Google Sheets en ${a.title}'),
              subtitle: const Text('Se crea una planilla nueva en Mi unidad'),
              onTap: () => Navigator.pop(ctx, a),
            ),
        ]),
      ),
    );
    if (target == null || !mounted) return;
    final (name, header, rows) = _table();
    final fileName = 'multigdrive-$name-$stamp';
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (target is Account) {
        messenger.showSnackBar(const SnackBar(content: Text('Creando la planilla…')));
        final url = await DriveActions.createSheet(target, fileName, _csv(header, rows, sep: ','));
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: const Duration(seconds: 8),
            content: Text('Planilla creada en ${target.title}'),
            action: SnackBarAction(
                label: 'Abrir',
                onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)),
          ));
      } else {
        final msg = await platform.saveCsv('$fileName.csv', _csv(header, rows));
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
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

  Widget _fileTile(FileRef f, {bool showAccount = true}) {
    _refs[_k(f)] = f;
    final selecting = _sel != null;
    final k = _k(f);
    return ListTile(
        leading: selecting
            ? Checkbox(
                value: _sel!.contains(k),
                onChanged: (v) => setState(() => v == true ? _sel!.add(k) : _sel!.remove(k)),
              )
            : Icon(iconFor(f.item), color: Color(f.account.color)),
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
        onTap: selecting
            ? () => setState(() => _sel!.contains(k) ? _sel!.remove(k) : _sel!.add(k))
            : () => showItemDetails(context, f.account, f.index, f.item),
        onLongPress: selecting ? null : () => _openFolderOf(f),
      );
  }

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
      if (groups.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: FilledButton.icon(
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('Limpiar duplicados'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => DuplicatesCleanupPage(groups: groups)),
            ),
          ),
        ),
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
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.delete_forever),
          label: const Text('Vaciar las papeleras de todas las cuentas'),
          onPressed: _emptyAllTrash,
        ),
      ),
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
          sidebarButton(context),
          IconButton(
            tooltip: _sel == null ? 'Seleccionar varios' : 'Terminar selección',
            icon: Icon(_sel == null ? Icons.checklist : Icons.close),
            onPressed: () => setState(() => _sel = _sel == null ? <String>{} : null),
          ),
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
      drawer: sidebarDrawer(context),
      bottomNavigationBar: _sel == null ? null : _selectionBar(context),
      body: withSidebar(context, indexed.isEmpty
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
            ])),
    );
  }
}
