import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'side_tree.dart';

enum SortBy { size, name, date }

String fmtDay(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

IconData iconFor(DriveItem it) {
  if (it.id == trashId) return Icons.delete_outline;
  if (it.id == otherId) return Icons.folder_shared_outlined;
  if (it.isFolder) return Icons.folder;
  final m = it.mime;
  if (m.startsWith('image/')) return Icons.image_outlined;
  if (m.startsWith('video/')) return Icons.movie_outlined;
  if (m.startsWith('audio/')) return Icons.music_note_outlined;
  if (m.contains('pdf')) return Icons.picture_as_pdf_outlined;
  if (m.contains('spreadsheet') || m.contains('excel')) return Icons.table_chart_outlined;
  if (m.contains('presentation') || m.contains('powerpoint')) return Icons.slideshow_outlined;
  if (m.contains('document') || m.contains('word') || m.startsWith('text/')) {
    return Icons.description_outlined;
  }
  if (m.contains('zip') || m.contains('compressed') || m.contains('rar')) {
    return Icons.folder_zip_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

void openInDrive(DriveItem it) {
  if (it.isVirtual) return;
  launchUrl(Uri.parse('https://drive.google.com/open?id=${it.id}'),
      mode: LaunchMode.externalApplication);
}

void showItemDetails(BuildContext context, Account account, AccountIndex idx, DriveItem it) {
  final accountTitle = account.title;
  final path = idx.pathTo(idx.parentOf[it.id] ?? topId).map((p) => p.name).join(' / ');
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Row(children: [
            Icon(iconFor(it)),
            const SizedBox(width: 12),
            Expanded(child: Text(it.name, style: Theme.of(ctx).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 12),
          Text('Cuenta: $accountTitle'),
          if (path.isNotEmpty) Text('Ubicación: $path'),
          Text(it.isFolder
              ? 'Ocupa: ${formatBytes(it.total)} · ${it.files} archivos'
              : 'Tamaño: ${formatBytes(it.size)}'
                  '${it.mine ? '' : ' · no ocupa tu espacio (no sos el dueño)'}'),
          if (it.modified > 0) Text('Modificado: ${fmtDay(it.modifiedAt)}'),
          if (it.trashed) const Text('Está en la papelera'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!it.isVirtual)
              FilledButton.icon(
                onPressed: () => openInDrive(it),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Abrir en Drive'),
              ),
            ...actionButtons(context, account, idx, it, () => Navigator.pop(ctx)),
          ]),
        ]),
      ),
    ),
  );
}

/// Explorador de una cuenta: carpetas con lo que ocupa cada una.
class ExplorerPage extends StatefulWidget {
  final Account account;
  final AccountIndex index;
  final String startId;
  const ExplorerPage(
      {super.key, required this.account, required this.index, this.startId = topId});

  @override
  State<ExplorerPage> createState() => _ExplorerPageState();
}

class _ExplorerPageState extends State<ExplorerPage> {
  late String _current = widget.startId;
  SortBy _sort = SortBy.size;

  AccountIndex get idx => widget.index;

  void _onChange() {
    if (!mounted) return;
    setState(() {
      if (!idx.items.containsKey(_current)) _current = topId;
    });
  }

  @override
  void initState() {
    super.initState();
    indexChanged.addListener(_onChange);
  }

  @override
  void dispose() {
    indexChanged.removeListener(_onChange);
    super.dispose();
  }

  List<DriveItem> _entries() {
    final list = _current == topId
        ? [idx.root, idx.items[otherId]!, idx.items[trashId]!]
        : List.of(idx.children[_current] ?? const <DriveItem>[]);
    if (_current != topId) {
      switch (_sort) {
        case SortBy.size:
          list.sort((a, b) => b.shownSize.compareTo(a.shownSize));
        case SortBy.name:
          list.sort((a, b) {
            if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        case SortBy.date:
          list.sort((a, b) => b.modified.compareTo(a.modified));
      }
    }
    return list;
  }

  void _up() {
    setState(() => _current = idx.parentOf[_current] ?? topId);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final path = _current == topId ? <DriveItem>[] : idx.pathTo(_current);
    final here = _current == topId ? null : idx.items[_current];
    final t = Theme.of(context).textTheme;

    return PopScope(
      canPop: _current == topId,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.account.title, overflow: TextOverflow.ellipsis),
          actions: [
            sidebarButton(context),
            PopupMenuButton<SortBy>(
              tooltip: 'Ordenar',
              icon: const Icon(Icons.sort),
              initialValue: _sort,
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: SortBy.size, child: Text('Por tamaño')),
                PopupMenuItem(value: SortBy.name, child: Text('Por nombre')),
                PopupMenuItem(value: SortBy.date, child: Text('Por fecha')),
              ],
            ),
          ],
        ),
        drawer: sidebarDrawer(context),
        body: withSidebar(context, Column(children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                TextButton(
                    onPressed: () => setState(() => _current = topId),
                    child: const Text('Ubicaciones')),
                for (final p in path) ...[
                  const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    onPressed: () => setState(() => _current = p.id),
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ],
            ),
          ),
          if (here != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                Expanded(
                    child: Text('${formatBytes(here.total)} · ${here.files} archivos',
                        style: t.titleSmall)),
                if (here.id == trashId && here.files > 0)
                  TextButton.icon(
                    onPressed: () async {
                      if (await confirm(
                          context,
                          'Vaciar papelera',
                          'Se borran DEFINITIVAMENTE ${here.files} archivos '
                              '(${formatBytes(here.total)}) de ${widget.account.title}. '
                              'No se puede deshacer.',
                          'Vaciar')) {
                        if (!context.mounted) return;
                        runAction(context, 'Papelera vaciada',
                            () => DriveActions.emptyTrash(widget.account));
                      }
                    },
                    icon: const Icon(Icons.delete_forever, size: 18),
                    label: const Text('Vaciar papelera'),
                  ),
                if (!here.isVirtual && !here.trashed)
                  IconButton(
                    tooltip: 'Nueva carpeta',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () async {
                      final name = await askText(context, 'Nueva carpeta', 'Nombre', '');
                      if (name == null || name.isEmpty || !context.mounted) return;
                      runAction(context, 'Carpeta creada: $name',
                          () => FolderOps.createFolder(widget.account, here.id, name));
                    },
                  ),
                if (!here.isVirtual)
                  TextButton.icon(
                    onPressed: () => openInDrive(here),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Abrir en Drive'),
                  ),
              ]),
            ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('Carpeta vacía'))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final it = entries[i];
                      final parentTotal = here?.total ?? 0;
                      final share = (parentTotal > 0 && it.isFolder) ? it.total / parentTotal : null;
                      return ListTile(
                        leading: Icon(iconFor(it),
                            color: it.isFolder ? Theme.of(context).colorScheme.primary : null),
                        title: Text(it.name, overflow: TextOverflow.ellipsis),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text([
                            if (it.isFolder) '${it.files} archivos',
                            if (it.modified > 0) fmtDay(it.modifiedAt),
                            if (!it.isFolder && !it.mine) 'no es tuyo',
                          ].join(' · ')),
                          if (share != null && share > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: LinearProgressIndicator(value: share, minHeight: 4),
                            ),
                        ]),
                        trailing: Text(formatBytes(it.shownSize)),
                        onTap: it.isFolder
                            ? () => setState(() => _current = it.id)
                            : () => showItemDetails(context, widget.account, idx, it),
                        onLongPress: () =>
                            showItemDetails(context, widget.account, idx, it),
                      );
                    },
                  ),
          ),
        ])),
      ),
    );
  }
}

class _Hit {
  final Account account;
  final AccountIndex index;
  final DriveItem item;
  _Hit(this.account, this.index, this.item);
}

/// Búsqueda por nombre en todas las cuentas indexadas.
class SearchPage extends StatefulWidget {
  final List<Account> accounts;
  final IndexStore indexes;
  const SearchPage({super.key, required this.accounts, required this.indexes});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _limit = 300;
  List<_Hit> _hits = [];
  int _found = 0;
  String _q = '';

  void _onChange() {
    if (mounted) _search(_q);
  }

  @override
  void initState() {
    super.initState();
    indexChanged.addListener(_onChange);
  }

  @override
  void dispose() {
    indexChanged.removeListener(_onChange);
    super.dispose();
  }

  void _search(String q) {
    _q = q.trim();
    final words = normalize(_q).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final hits = <_Hit>[];
    if (words.isNotEmpty && _q.length >= 2) {
      for (final a in widget.accounts) {
        final idx = widget.indexes.loaded[a.email];
        if (idx == null) continue;
        for (final it in idx.items.values) {
          if (it.isVirtual) continue;
          final n = normalize(it.name);
          if (words.every(n.contains)) hits.add(_Hit(a, idx, it));
        }
      }
      hits.sort((x, y) => y.item.shownSize.compareTo(x.item.shownSize));
    }
    setState(() {
      _found = hits.length;
      _hits = hits.take(_limit).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final indexed = widget.accounts.where((a) => widget.indexes.loaded.containsKey(a.email)).length;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Buscar en todas las cuentas', border: InputBorder.none),
          onChanged: _search,
        ),
        actions: [sidebarButton(context)],
      ),
      drawer: sidebarDrawer(context),
      body: withSidebar(context, Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _q.length < 2
                  ? 'Busca por nombre en $indexed de ${widget.accounts.length} cuentas indexadas.'
                  : '$_found resultados${_found > _limit ? ' (se muestran los $_limit más pesados)' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: _hits.length,
            itemBuilder: (context, i) {
              final h = _hits[i];
              final it = h.item;
              final parentId = h.index.parentOf[it.id] ?? topId;
              final path = h.index.pathTo(parentId).map((p) => p.name).join(' / ');
              return ListTile(
                leading: Icon(iconFor(it), color: Color(h.account.color)),
                title: Text(it.name, overflow: TextOverflow.ellipsis),
                subtitle: Text('${h.account.title} · $path',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text(formatBytes(it.shownSize)),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ExplorerPage(
                        account: h.account,
                        index: h.index,
                        startId: it.isFolder ? it.id : parentId),
                  ),
                ),
                onLongPress: () => showItemDetails(context, h.account, h.index, it),
              );
            },
          ),
        ),
      ])),
    );
  }
}
