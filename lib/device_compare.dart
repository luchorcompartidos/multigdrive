import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'accounts.dart';
import 'actions.dart';
import 'analyzer.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'side_tree.dart';

bool get deviceCompareSupported => !kIsWeb && (Platform.isAndroid || Platform.isWindows);

enum MatchLevel { exact, identical, similar }

const levelNames = {
  MatchLevel.exact: 'Exacto',
  MatchLevel.identical: 'Idéntico (otro nombre)',
  MatchLevel.similar: 'Parecido',
};

class LocalMatch {
  final String path;
  final int size;
  final MatchLevel level;
  final List<FileRef> drive;
  final String key; // mismo contenido = misma clave (huella, o nombre+tamaño si no hay huella)
  LocalMatch(this.path, this.size, this.level, this.drive, this.key);

  String get name => path.split(Platform.pathSeparator).last;
  String get folder {
    final parts = path.split(Platform.pathSeparator);
    return parts.sublist(0, parts.length - 1).join(Platform.pathSeparator);
  }
}

/// Huellas (MD5) ya calculadas de archivos del equipo: ruta → [tamaño, fecha, md5].
class _HashCache {
  static Map<String, List<dynamic>> data = {};
  static File? _file;

  static Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}${Platform.pathSeparator}huellas-locales.json');
    if (await _file!.exists()) {
      try {
        data = (jsonDecode(await _file!.readAsString()) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as List<dynamic>));
      } catch (_) {
        data = {};
      }
    }
  }

  static Future<void> save() async {
    if (_file != null) await _file!.writeAsString(jsonEncode(data));
  }
}

Future<String> _md5File(String path) async {
  final digest = await md5.bind(File(path).openRead()).first;
  return digest.toString();
}

/// La huella se calcula en segundo plano para no trabar la pantalla.
Future<String> _md5Of(String path) => compute(_md5File, path);

String _base(String name) {
  final i = name.lastIndexOf('.');
  return normalize(i > 0 ? name.substring(0, i) : name);
}

/// Carpetas sugeridas del equipo.
List<String> suggestedFolders() {
  if (kIsWeb) return [];
  final sep = Platform.pathSeparator;
  final List<String> base;
  if (Platform.isAndroid) {
    const root = '/storage/emulated/0';
    base = [
      '$root/DCIM',
      '$root/Pictures',
      '$root/Download',
      '$root/Documents',
      '$root/Music',
      '$root/Movies',
      '$root/Android/media/com.whatsapp/WhatsApp/Media',
    ];
  } else {
    final home = Platform.environment['USERPROFILE'] ?? '';
    base = [for (final f in ['Pictures', 'Downloads', 'Documents', 'Music', 'Videos']) '$home$sep$f'];
  }
  return base.where((p) => Directory(p).existsSync()).toList();
}

/// Comparación Celular / PC ↔ Drive.
class DeviceComparePage extends StatefulWidget {
  const DeviceComparePage({super.key});

  @override
  State<DeviceComparePage> createState() => _DeviceComparePageState();
}

class _DeviceComparePageState extends State<DeviceComparePage> {
  late final List<String> _folders = suggestedFolders();
  late final Set<String> _on = _folders
      .where((f) => !f.contains('Music') && !f.contains('Movies') && !f.contains('Videos'))
      .toSet();
  bool _running = false;
  bool _includeShared = false; // archivos compartidos conmigo (no son míos): solo si se piden
  final Map<String, String> _owner = {}; // id de archivo → "Dueño: … · Lo compartió: …"
  String _status = '';
  List<LocalMatch>? _matches;
  MatchLevel? _filter;
  final Set<LocalMatch> _sel = {};

  Future<bool> _permission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return true;
    final s = await Permission.storage.request();
    return s.isGranted;
  }

  Future<void> _addFolder() async {
    final p = await FilePicker.platform.getDirectoryPath();
    if (p == null) return;
    setState(() {
      if (!_folders.contains(p)) _folders.add(p);
      _on.add(p);
    });
  }

  Future<void> _run() async {
    if (!await _permission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Hace falta el permiso "Acceso a todos los archivos" para comparar.')));
      }
      return;
    }
    setState(() {
      _running = true;
      _matches = null;
      _sel.clear();
    });
    await _HashCache.load();
    // Drive: tamaño → archivos
    final bySize = <int, List<FileRef>>{};
    for (final a in DriveActions.store.accounts) {
      final idx = DriveActions.indexes.loaded[a.email];
      if (idx == null) continue;
      for (final it in idx.items.values) {
        if (it.isFolder || it.isVirtual || it.trashed || it.size <= 0) continue;
        (bySize[it.size] ??= []).add(FileRef(a, idx, it));
      }
    }
    final out = <LocalMatch>[];
    var seen = 0, hashed = 0;
    for (final folder in _on) {
      try {
        await for (final e in Directory(folder).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final path = e.path;
          if (path.contains('${Platform.pathSeparator}.') ||
              path.contains('${Platform.pathSeparator}Android${Platform.pathSeparator}data')) {
            continue;
          }
          seen++;
          if (seen % 200 == 0 && mounted) {
            setState(() => _status = '$seen archivos revisados · $hashed comparados · ${out.length} coincidencias');
          }
          FileStat st;
          try {
            st = await e.stat();
          } catch (_) {
            continue;
          }
          final cands = bySize[st.size];
          if (cands == null) continue;
          final name = path.split(Platform.pathSeparator).last;
          final withMd5 = cands.where((c) => c.item.md5 != null).toList();
          if (withMd5.isNotEmpty) {
            final mtime = st.modified.millisecondsSinceEpoch;
            final cached = _HashCache.data[path];
            String hash;
            if (cached != null && cached[0] == st.size && cached[1] == mtime) {
              hash = cached[2] as String;
            } else {
              try {
                hash = await _md5Of(path);
              } catch (_) {
                continue;
              }
              _HashCache.data[path] = [st.size, mtime, hash];
              hashed++;
            }
            final same = withMd5.where((c) => c.item.md5 == hash).toList();
            if (same.isNotEmpty) {
              final exact = same.any((c) => c.item.name.toLowerCase() == name.toLowerCase());
              out.add(LocalMatch(
                  path, st.size, exact ? MatchLevel.exact : MatchLevel.identical, same, hash));
              continue;
            }
          }
          final similar = cands
              .where((c) => c.item.md5 == null && _base(c.item.name) == _base(name))
              .toList();
          if (similar.isNotEmpty) {
            out.add(LocalMatch(path, st.size, MatchLevel.similar, similar, 'sim:${_base(name)}:${st.size}'));
          }
        }
      } catch (_) {}
    }
    await _HashCache.save();
    out.sort((a, b) => b.size.compareTo(a.size));
    if (mounted) {
      setState(() {
        _matches = out;
        _running = false;
        _status = '$seen archivos revisados · $hashed huellas nuevas';
      });
    }
    _fetchOwners();
  }

  /// Dueño y quién compartió cada archivo de Drive que no es tuyo (para saber a quién pedírselo).
  Future<void> _fetchOwners() async {
    final pending = <String, FileRef>{};
    for (final m in _matches ?? const <LocalMatch>[]) {
      for (final f in m.drive) {
        if (!f.item.mine && !_owner.containsKey(f.item.id)) pending[f.item.id] = f;
      }
    }
    var n = 0;
    for (final f in pending.values) {
      if (n++ >= 300) break;
      try {
        final j = await DriveActions.api(f.account, 'GET', '/drive/v3/files/${f.item.id}',
            query: {'fields': 'owners(displayName,emailAddress),sharingUser(displayName,emailAddress)'});
        String who(Map? u) =>
            u == null ? '' : '${u['displayName'] ?? ''} <${u['emailAddress'] ?? '?'}>'.trim();
        final owners = (j['owners'] as List? ?? []).map((o) => who(o as Map)).join(', ');
        final sharer = who(j['sharingUser'] as Map?);
        _owner[f.item.id] = [
          if (owners.isNotEmpty) 'Dueño: $owners',
          if (sharer.isNotEmpty && sharer != owners) 'Lo compartió: $sharer',
        ].join(' · ');
      } catch (_) {
        _owner[f.item.id] = 'Dueño: no disponible (puede que ya no tengas acceso)';
      }
      if (mounted && n % 10 == 0) setState(() {});
    }
    if (mounted) setState(() {});
  }

  /// Copias en Drive a mostrar: sin repetir el mismo archivo (si lo ven varias de tus cuentas)
  /// y, salvo que se pida, sin los compartidos conmigo.
  List<FileRef> _shown(LocalMatch m) {
    final byId = <String, FileRef>{};
    for (final f in m.drive) {
      if (!_includeShared && !f.item.mine) continue;
      final prev = byId[f.item.id];
      if (prev == null || (!prev.item.mine && f.item.mine)) byId[f.item.id] = f;
    }
    final list = byId.values.toList()
      ..sort((a, b) => (a.item.mine ? 0 : 1) - (b.item.mine ? 0 : 1));
    return list;
  }

  /// Cuentas tuyas desde las que se ve ese mismo archivo.
  List<Account> _seenFrom(LocalMatch m, String id) =>
      m.drive.where((f) => f.item.id == id).map((f) => f.account).toSet().toList();

  bool _onlyShared(LocalMatch m) => !m.drive.any((f) => f.item.mine);

  /// Todas las copias en el equipo de un mismo contenido.
  List<LocalMatch> _copiesOnDevice(LocalMatch m) =>
      (_matches ?? const <LocalMatch>[]).where((x) => x.key == m.key).toList();

  String _drivePath(FileRef f) {
    var p = f.path;
    if (f.index.parentOf[f.item.id] == otherId) {
      p = f.item.mine ? 'Sin carpeta (tuyo)' : 'Compartido conmigo';
    }
    return p.isEmpty ? f.item.name : '$p / ${f.item.name}';
  }

  String _driveFolderLink(FileRef f) {
    final parent = f.item.parent;
    final idx = f.index;
    if (parent == null || parent == idx.rootId) return 'https://drive.google.com/drive/my-drive';
    return 'https://drive.google.com/drive/folders/$parent';
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copiado')));
    }
  }

  String _summary(LocalMatch m) {
    final dev = _copiesOnDevice(m);
    final b = StringBuffer()
      ..writeln('Archivo: ${m.name}')
      ..writeln('Coincidencia: ${levelNames[m.level]} · ${formatBytes(m.size)}')
      ..writeln('En el equipo (${dev.length}):');
    for (final d in dev) {
      b.writeln('  ${d.path}');
    }
    b.writeln('En Drive (${m.drive.length}):');
    for (final f in _shown(m)) {
      b.writeln('  ${f.account.email}: ${_drivePath(f)}');
      if (!f.item.mine) b.writeln('    No es tuyo · ${_owner[f.item.id] ?? ''}');
      b.writeln('    ${_driveFolderLink(f)}');
    }
    return b.toString();
  }

  static const _channel = MethodChannel('mgd/carpetas');

  /// Abre la carpeta del equipo: Windows en el Explorador; Android ofrece los exploradores instalados.
  Future<void> _openFolder(String folder) async {
    if (Platform.isWindows) {
      await launchUrl(Uri.file(folder));
      return;
    }
    bool ok = false;
    try {
      ok = await _channel.invokeMethod<bool>('abrir', {'path': folder}) ?? false;
    } catch (_) {}
    if (!ok) {
      await _copy(folder, 'No hay un explorador compatible. Ruta');
    }
  }

  Widget _copyBtn(String tooltip, String text, String what) => IconButton(
        tooltip: tooltip,
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () => _copy(text, what),
      );

  List<LocalMatch> get _all => (_matches ?? const <LocalMatch>[])
      .where((m) => _includeShared || !_onlyShared(m))
      .toList();

  List<LocalMatch> get _visible =>
      _all.where((m) => _filter == null || m.level == _filter).toList();

  Future<void> _deleteLocal(List<LocalMatch> list) async {
    final risky = list.where(_onlyShared).toList();
    if (risky.isNotEmpty) {
      final keep = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber),
          title: const Text('Cuidado: no son tuyos en Drive'),
          content: Text('${risky.length} de estos archivos están en Drive solo como "compartidos conmigo". '
              'Si el dueño los borra o te quita el acceso, los perdés. Se recomienda NO borrarlos del equipo.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Conservarlos (recomendado)')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Borrarlos igual')),
          ],
        ),
      );
      if (keep == null) return;
      if (keep) list = list.where((m) => !_onlyShared(m)).toList();
      if (list.isEmpty || !mounted) return;
    }
    final bytes = list.fold<int>(0, (s, m) => s + m.size);
    if (!await confirm(
        context,
        'Dejar solo en Drive',
        'Se BORRAN de este equipo ${list.length} archivos (${formatBytes(bytes)}). '
            'Siguen estando en Drive. Esto no se puede deshacer desde la app.',
        'Borrar del equipo')) {
      return;
    }
    var ok = 0;
    for (final m in list) {
      try {
        await File(m.path).delete();
        _HashCache.data.remove(m.path);
        _matches?.remove(m);
        ok++;
      } catch (_) {}
    }
    await _HashCache.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$ok de ${list.length} borrados del equipo')));
    setState(_sel.clear);
  }

  Future<void> _trashDrive(List<LocalMatch> list) async {
    final pairs = <(Account, DriveItem)>[
      for (final m in list)
        for (final f in m.drive)
          if (f.item.mine) (f.account, f.item)
    ];
    final bytes = pairs.fold<int>(0, (s, p) => s + p.$2.quota);
    if (!await confirm(
        context,
        'Dejar solo en el equipo',
        'Se mandan a la papelera de Drive ${pairs.length} copias (${formatBytes(bytes)}). '
            'Se pueden restaurar.',
        'A la papelera')) {
      return;
    }
    if (!mounted) return;
    await runBatch(context, 'Mandando copias de Drive a la papelera', pairs,
        (a, it) => DriveActions.setTrashed(a, it, true),
        done: 'Copias de Drive en la papelera');
    if (mounted) {
      setState(() {
        _matches?.removeWhere(list.contains);
        _sel.clear();
      });
    }
  }

  void _details(LocalMatch m) {
    final dev = _copiesOnDevice(m);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 8, 16), children: [
            Row(children: [
              Expanded(child: Text(m.name, style: Theme.of(ctx).textTheme.titleMedium)),
              _copyBtn('Copiar nombre', m.name, 'Nombre'),
            ]),
            Text('${levelNames[m.level]} · ${formatBytes(m.size)}'),
            const SizedBox(height: 12),
            Text('En el equipo: ${dev.length} ${dev.length == 1 ? 'carpeta' : 'carpetas'}',
                style: Theme.of(ctx).textTheme.titleSmall),
            for (final d in dev)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(d.folder,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.primary, decoration: TextDecoration.underline)),
                onTap: () => _openFolder(d.folder),
                subtitle: d.name == m.name ? null : Text('como "${d.name}"'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _copyBtn('Copiar carpeta', d.folder, 'Carpeta'),
                  _copyBtn('Copiar ruta completa', d.path, 'Ruta'),
                  IconButton(
                    tooltip: 'Abrir carpeta',
                    icon: const Icon(Icons.folder_open, size: 18),
                    onPressed: () => _openFolder(d.folder),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            Text('En Drive: ${_shown(m).length} ${_shown(m).length == 1 ? 'ubicación' : 'ubicaciones'}',
                style: Theme.of(ctx).textTheme.titleSmall),
            if (_onlyShared(m))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('⚠ Solo está en Drive como compartido conmigo: no ocupa tu espacio y no lo '
                    'controlás. Si el dueño lo borra o te quita el acceso, lo perdés.',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ),
            for (final f in _shown(m))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(iconFor(f.item), color: Color(f.account.color)),
                title: Text('${f.account.title} · ${_drivePath(f)}'),
                subtitle: Text([
                  if (f.item.name != m.name) 'como "${f.item.name}"',
                  if (f.item.mine) 'Tuyo · ocupa espacio en ${f.account.title}',
                  if (!f.item.mine) 'No es tuyo · no ocupa tu espacio',
                  if (!f.item.mine) _owner[f.item.id] ?? 'Buscando dueño…',
                  if (_seenFrom(m, f.item.id).length > 1)
                    'Lo ven ${_seenFrom(m, f.item.id).length} de tus cuentas: '
                        '${_seenFrom(m, f.item.id).map((a) => a.title).join(', ')}',
                ].join('\n')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _copyBtn('Copiar ruta en Drive', '${f.account.email}: ${_drivePath(f)}', 'Ruta de Drive'),
                  _copyBtn('Copiar link de la carpeta', _driveFolderLink(f), 'Link de la carpeta'),
                  IconButton(
                    tooltip: 'Abrir la carpeta en Drive',
                    icon: const Icon(Icons.folder_open, size: 18),
                    onPressed: () => launchUrl(Uri.parse(_driveFolderLink(f)),
                        mode: LaunchMode.externalApplication),
                  ),
                  IconButton(
                    tooltip: 'Abrir el archivo en Drive',
                    icon: const Icon(Icons.open_in_new, size: 18),
                    onPressed: () => openInDrive(f.item),
                  ),
                ]),
              ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.content_copy),
                label: const Text('Copiar todo'),
                onPressed: () => _copy(_summary(m), 'Resumen'),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Abrir el del equipo'),
                onPressed: () => OpenFilex.open(m.path),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.phone_android),
                label: const Text('Dejar solo en Drive'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _deleteLocal([m]);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.cloud_off),
                label: const Text('Dejar solo en el equipo'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _trashDrive([m]);
                },
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final all = _matches == null ? null : _all;
    final hiddenShared = (_matches ?? const <LocalMatch>[]).where(_onlyShared).length;
    final list = _visible;
    int bytesOf(Iterable<LocalMatch> l) => l.fold<int>(0, (s, m) => s + m.size);
    final device = Platform.isAndroid ? 'celular' : 'PC';
    return Scaffold(
      appBar: AppBar(title: Text('${Platform.isAndroid ? 'Celular' : 'PC'} ↔ Drive'), actions: [
        sidebarButton(context),
      ]),
      drawer: sidebarDrawer(context),
      bottomNavigationBar: _sel.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('${_sel.length} · ${formatBytes(bytesOf(_sel))}'),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Dejar solo en Drive'),
                    onPressed: () => _deleteLocal(_sel.toList()),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.cloud_off),
                    label: Text('Dejar solo en el $device'),
                    onPressed: () => _trashDrive(_sel.toList()),
                  ),
                ]),
              ),
            ),
      body: withSidebar(
        context,
        ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Muestra los archivos del $device que también están en alguna cuenta de Drive, '
                'para que decidas dónde dejarlos y liberes espacio.'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final f in _folders)
                FilterChip(
                  label: Text(f.split(Platform.pathSeparator).last),
                  selected: _on.contains(f),
                  onSelected: (v) => setState(() => v ? _on.add(f) : _on.remove(f)),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Otra carpeta'),
                onPressed: _addFolder,
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              icon: const Icon(Icons.compare),
              label: const Text('Comparar'),
              onPressed: _running || _on.isEmpty ? null : _run,
            ),
          ),
          if (_running) const LinearProgressIndicator(),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Text(_status, style: t.bodySmall),
            ),
          if (all != null) ...[
            SwitchListTile(
              dense: true,
              title: const Text('Incluir archivos "compartidos conmigo"'),
              subtitle: Text('No son tuyos ni ocupan tu espacio; el dueño puede quitarte el acceso.'
                  '${hiddenShared > 0 && !_includeShared ? ' Hay $hiddenShared ocultos.' : ''}'),
              value: _includeShared,
              onChanged: (v) => setState(() {
                _includeShared = v;
                _sel.clear();
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('${all.length} archivos del $device (${formatBytes(bytesOf(all))}) también están en Drive',
                  style: t.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                ChoiceChip(
                    label: Text('Todos (${all.length})'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null)),
                for (final l in MatchLevel.values)
                  ChoiceChip(
                    label: Text('${levelNames[l]} (${all.where((m) => m.level == l).length})'),
                    selected: _filter == l,
                    onSelected: (_) => setState(() => _filter = l),
                  ),
              ]),
            ),
            if (list.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _sel.length == list.length ? _sel.clear() : _sel.addAll(list)),
                  child: Text(_sel.length == list.length ? 'Ninguno' : 'Seleccionar todos'),
                ),
              ),
            for (final m in list.take(500))
              ListTile(
                leading: Checkbox(
                  value: _sel.contains(m),
                  onChanged: (v) => setState(() => v == true ? _sel.add(m) : _sel.remove(m)),
                ),
                title: Text(m.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${levelNames[m.level]} · ${m.folder.split(Platform.pathSeparator).last} → '
                  '${_shown(m).map((f) => f.account.title).toSet().join(', ')}'
                  '${m.level == MatchLevel.identical ? ' (“${_shown(m).first.item.name}”)' : ''}'
                  '${_onlyShared(m) ? ' · ⚠ compartido conmigo' : ''}\n'
                  'Equipo: ${_copiesOnDevice(m).length} ${_copiesOnDevice(m).length == 1 ? 'carpeta' : 'carpetas'}'
                  ' · Drive: ${_shown(m).length} ${_shown(m).length == 1 ? 'ubicación' : 'ubicaciones'}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                trailing: Text(formatBytes(m.size)),
                onTap: () => _details(m),
                onLongPress: () => _copy(m.name, 'Nombre'),
              ),
          ],
          const SizedBox(height: 80),
        ]),
      ),
    );
  }
}
