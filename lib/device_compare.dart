import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final DateTime modified;
  final String root; // carpeta elegida en la que se encontró
  LocalMatch(this.path, this.size, this.level, this.drive, this.key,
      {DateTime? modified, this.root = ''})
      : modified = modified ?? DateTime.fromMillisecondsSinceEpoch(0);

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

enum FileKind { image, video, audio, doc, archive, other }

const kindNames = {
  FileKind.image: 'Imágenes',
  FileKind.video: 'Videos',
  FileKind.audio: 'Audio',
  FileKind.doc: 'Documentos',
  FileKind.archive: 'Comprimidos / APK',
  FileKind.other: 'Otros',
};

const _exts = {
  FileKind.image: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff', 'raw', 'dng', 'svg'],
  FileKind.video: ['mp4', 'mov', 'mkv', 'avi', '3gp', 'webm', 'm4v', 'wmv', 'mts', 'flv'],
  FileKind.audio: ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma', 'amr', 'mid'],
  FileKind.doc: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv', 'odt', 'ods', 'odp', 'rtf', 'md', 'epub', 'html', 'json', 'xml'],
  FileKind.archive: ['zip', 'rar', '7z', 'tar', 'gz', 'apk', 'xapk', 'iso', 'exe', 'msi'],
};

FileKind kindOf(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return FileKind.other;
  final e = name.substring(i + 1).toLowerCase();
  for (final k in _exts.entries) {
    if (k.value.contains(e)) return k.key;
  }
  return FileKind.other;
}

enum MatchSort { size, name, folder, modified, level, account }

const matchSortNames = {
  MatchSort.size: 'Tamaño',
  MatchSort.name: 'Nombre',
  MatchSort.folder: 'Carpeta del equipo',
  MatchSort.modified: 'Fecha de modificación',
  MatchSort.level: 'Nivel de coincidencia',
  MatchSort.account: 'Cuenta de Drive',
};

const _sizeSteps = {0: 'Cualquiera', 1 << 20: '1 MB', 10 << 20: '10 MB', 100 << 20: '100 MB', 1 << 30: '1 GB'};

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
  // Buscador, filtros y orden de los resultados
  final _qCtrl = TextEditingController();
  String _q = '';
  MatchSort _sort = MatchSort.size;
  bool _desc = true;
  final Set<FileKind> _kinds = {};
  final Set<String> _accounts = {}; // emails
  String? _root;
  int _minSize = 0;
  bool _multiOnly = false; // solo con más de una copia en el equipo
  final Map<LocalMatch, String> _hay = {}; // texto para buscar (caché)

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

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
                  path, st.size, exact ? MatchLevel.exact : MatchLevel.identical, same, hash,
                  modified: st.modified, root: folder));
              continue;
            }
          }
          final similar = cands
              .where((c) => c.item.md5 == null && _base(c.item.name) == _base(name))
              .toList();
          if (similar.isNotEmpty) {
            out.add(LocalMatch(path, st.size, MatchLevel.similar, similar, 'sim:${_base(name)}:${st.size}',
                modified: st.modified, root: folder));
          }
        }
      } catch (_) {}
    }
    await _HashCache.save();
    out.sort((a, b) => b.size.compareTo(a.size));
    if (mounted) {
      setState(() {
        _matches = out;
        _hay.clear();
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
  static const _explorerKey = 'mgd_explorador_carpetas';

  /// Abre la carpeta del equipo con el archivo [file] a la vista si se puede:
  /// Windows en el Explorador con el archivo seleccionado; Android pregunta con qué explorador
  /// (solo los que abren la carpeta, no el archivo), puede recordar la elección y copia el nombre
  /// del archivo para pegarlo en la lupa del explorador.
  Future<void> _openFolder(String folder, {String? file}) async {
    if (Platform.isWindows) {
      if (file != null && await File(file).exists()) {
        // explorer devuelve código 1 aunque funcione: no se revisa el resultado
        await Process.start('explorer.exe', ['/select,', file]);
      } else {
        await launchUrl(Uri.file(folder));
      }
      return;
    }
    var apps = <Map<String, dynamic>>[];
    try {
      final r = await _channel
          .invokeMethod<List<dynamic>>('exploradores', {'path': folder, 'file': file});
      apps = [for (final e in r ?? const []) Map<String, dynamic>.from(e as Map)];
    } catch (_) {}
    if (!mounted) return;
    if (apps.isEmpty) {
      await _copy(folder, 'No encontré un explorador de archivos compatible. Ruta');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_explorerKey);
    for (final a in apps) {
      if (a['id'] == saved) {
        await _launchExplorer(a, folder, file: file, remembered: true);
        return;
      }
    }
    final pick = await _pickExplorer(apps, file ?? folder);
    if (pick == null) return;
    if (pick.$2) {
      await prefs.setString(_explorerKey, pick.$1['id'] as String);
    }
    await _launchExplorer(pick.$1, folder, file: file, remembered: pick.$2);
  }

  Future<void> _launchExplorer(Map<String, dynamic> app, String folder,
      {String? file, bool remembered = false}) async {
    // Se copia el nombre del archivo (para buscarlo con la lupa del explorador) o, si no hay, la ruta.
    final name = file?.split(Platform.pathSeparator).last;
    await Clipboard.setData(ClipboardData(text: name ?? folder));
    var ok = false;
    try {
      ok = await _channel.invokeMethod<bool>('abrirCon', {'id': app['id']}) ?? false;
    } catch (_) {}
    if (!ok && remembered) {
      await (await SharedPreferences.getInstance()).remove(_explorerKey);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(ok
          ? (name != null
              ? 'Abriendo la carpeta con ${app['label']}. "$name" quedó copiado: tocá la lupa y pegalo.'
              : 'Abriendo la carpeta con ${app['label']} (la ruta quedó copiada).')
          : 'No se pudo abrir con ${app['label']}. ${name != null ? 'El nombre' : 'La ruta'} quedó copiado.'),
      action: remembered || !ok
          ? SnackBarAction(
              label: 'Elegir otra app',
              onPressed: () async {
                await (await SharedPreferences.getInstance()).remove(_explorerKey);
                _openFolder(folder, file: file);
              },
            )
          : null,
    ));
  }

  /// Qué hace la opción de prueba en cada app (probado en v0.3.6): etiqueta y descripción.
  static const _pruebas = {
    'com.amaze.filemanager': ('(Abrir Archivo con...)', 'Abre Ventana para dar paso a "Abrir con..."'),
    'com.alphainventor.filemanager': (
      '(Reproducir Audio en Carpeta)',
      'Abre la Carpeta y Reproduce Automáticamente al archivo de Audio'
    ),
    'com.lonelycatgames.Xplore': (
      '(Abrir Archivo en carpeta, con...)',
      'Abre Cuadro de Diálogo "Abrir con..." (Reproducir) y la Carpeta en 2do Plano'
    ),
  };

  Future<(Map<String, dynamic>, bool)?> _pickExplorer(List<Map<String, dynamic>> apps, String folder) {
    var remember = false;
    for (final a in apps) {
      final p = _pruebas[a['pkg']];
      if (a['nivel'] == 3 && p != null) a['label'] = '${a['nombre']} ${p.$1}';
    }
    String hint(Map<String, dynamic> a) => switch (a['nivel']) {
          3 when _pruebas.containsKey(a['pkg']) => _pruebas[a['pkg']]!.$2,
          0 => 'Abre carpetas',
          1 => 'Explorador: se le pasa la carpeta',
          3 => 'Prueba: intenta abrir la carpeta con el archivo marcado (puede abrir el archivo)',
          _ => 'Alternativa: si la otra opción no anda',
        };
    return showModalBottomSheet<(Map<String, dynamic>, bool)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
            child: ListView(shrinkWrap: true, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('Abrir la carpeta con…', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(folder, style: Theme.of(ctx).textTheme.bodySmall),
              ),
              for (final a in apps)
                ListTile(
                  leading: a['icono'] is Uint8List
                      ? Image.memory(a['icono'] as Uint8List, width: 36, height: 36)
                      : const Icon(Icons.folder),
                  title: Text('${a['label']}'),
                  subtitle: Text(hint(a)),
                  onTap: () => Navigator.pop(ctx, (a, remember)),
                ),
              CheckboxListTile(
                value: remember,
                onChanged: (v) => setSheet(() => remember = v ?? false),
                title: const Text('Recordar mi elección'),
                subtitle: const Text('Se puede cambiar con "Elegir otra app" en el aviso.'),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _copyBtn(String tooltip, String text, String what) => IconButton(
        tooltip: tooltip,
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () => _copy(text, what),
      );

  List<LocalMatch> get _all => (_matches ?? const <LocalMatch>[])
      .where((m) => _includeShared || !_onlyShared(m))
      .toList();

  String _hayOf(LocalMatch m) => _hay[m] ??= normalize([
        m.path,
        for (final f in m.drive) '${f.item.name} ${f.account.title} ${f.account.email} ${_drivePath(f)}',
      ].join(' '));

  int get _activeFilters =>
      _kinds.length + _accounts.length + (_root != null ? 1 : 0) + (_minSize > 0 ? 1 : 0) + (_multiOnly ? 1 : 0);

  List<LocalMatch> get _visible {
    final words = normalize(_q).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final copies = <String, int>{};
    if (_multiOnly) {
      for (final m in _matches ?? const <LocalMatch>[]) {
        copies[m.key] = (copies[m.key] ?? 0) + 1;
      }
    }
    final out = _all.where((m) {
      if (_filter != null && m.level != _filter) return false;
      if (_minSize > 0 && m.size < _minSize) return false;
      if (_kinds.isNotEmpty && !_kinds.contains(kindOf(m.name))) return false;
      if (_root != null && m.root != _root) return false;
      if (_accounts.isNotEmpty && !_shown(m).any((f) => _accounts.contains(f.account.email))) return false;
      if (_multiOnly && (copies[m.key] ?? 0) < 2) return false;
      if (words.isNotEmpty) {
        final hay = _hayOf(m);
        if (!words.every(hay.contains)) return false;
      }
      return true;
    }).toList();
    String acc(LocalMatch m) {
      final s = _shown(m);
      return s.isEmpty ? '' : normalize(s.first.account.title);
    }

    int cmp(LocalMatch a, LocalMatch b) => switch (_sort) {
          MatchSort.size => a.size.compareTo(b.size),
          MatchSort.name => normalize(a.name).compareTo(normalize(b.name)),
          MatchSort.folder => normalize(a.folder).compareTo(normalize(b.folder)),
          MatchSort.modified => a.modified.compareTo(b.modified),
          MatchSort.level => b.level.index.compareTo(a.level.index),
          MatchSort.account => acc(a).compareTo(acc(b)),
        };
    out.sort((a, b) {
      final c = _desc ? cmp(b, a) : cmp(a, b);
      return c != 0 ? c : b.size.compareTo(a.size);
    });
    return out;
  }

  /// Cambia búsqueda/filtros/orden y deja seleccionados solo los que siguen a la vista.
  void _update(VoidCallback fn) {
    setState(() {
      fn();
      final v = _visible.toSet();
      _sel.retainWhere(v.contains);
    });
  }

  void _clearFilters() => _update(() {
        _kinds.clear();
        _accounts.clear();
        _root = null;
        _minSize = 0;
        _multiOnly = false;
        _filter = null;
        _q = '';
        _qCtrl.clear();
      });

  void _filtersSheet() {
    final all = _all;
    final roots = {for (final m in all) m.root}.where((r) => r.isNotEmpty).toList()..sort();
    final emails = {for (final m in all) for (final f in _shown(m)) f.account.email};
    final accounts = DriveActions.store.accounts.where((a) => emails.contains(a.email)).toList();
    final kindCount = <FileKind, int>{};
    for (final m in all) {
      final k = kindOf(m.name);
      kindCount[k] = (kindCount[k] ?? 0) + 1;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void change(VoidCallback fn) {
          _update(fn);
          setSheet(() {});
        }

        final t = Theme.of(ctx).textTheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              Text('Filtros · ${_visible.length} de ${all.length}', style: t.titleMedium),
              const SizedBox(height: 12),
              Text('Tipo de archivo', style: t.titleSmall),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final k in FileKind.values)
                  if ((kindCount[k] ?? 0) > 0)
                    FilterChip(
                      label: Text('${kindNames[k]} (${kindCount[k]})'),
                      selected: _kinds.contains(k),
                      onSelected: (v) => change(() => v ? _kinds.add(k) : _kinds.remove(k)),
                    ),
              ]),
              const SizedBox(height: 12),
              Text('Cuenta de Drive', style: t.titleSmall),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final a in accounts)
                  FilterChip(
                    avatar: CircleAvatar(backgroundColor: Color(a.color), radius: 6),
                    label: Text(a.title),
                    selected: _accounts.contains(a.email),
                    onSelected: (v) => change(() => v ? _accounts.add(a.email) : _accounts.remove(a.email)),
                  ),
              ]),
              if (roots.length > 1) ...[
                const SizedBox(height: 12),
                Text('Carpeta del equipo', style: t.titleSmall),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  ChoiceChip(
                    label: const Text('Todas'),
                    selected: _root == null,
                    onSelected: (_) => change(() => _root = null),
                  ),
                  for (final r in roots)
                    ChoiceChip(
                      label: Text(r.split(Platform.pathSeparator).last),
                      selected: _root == r,
                      onSelected: (_) => change(() => _root = r),
                    ),
                ]),
              ],
              const SizedBox(height: 12),
              Text('Tamaño mínimo', style: t.titleSmall),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final e in _sizeSteps.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _minSize == e.key,
                    onSelected: (_) => change(() => _minSize = e.key),
                  ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Solo con más de una copia en el equipo'),
                value: _multiOnly,
                onChanged: (v) => change(() => _multiOnly = v),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => change(() {
                    _kinds.clear();
                    _accounts.clear();
                    _root = null;
                    _minSize = 0;
                    _multiOnly = false;
                  }),
                  child: const Text('Limpiar filtros'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo')),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  Widget _toolbar(List<LocalMatch> list, List<LocalMatch> all) {
    final filtered = list.length != all.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _qCtrl,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search),
            hintText: 'Buscar por nombre, carpeta o cuenta',
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Borrar búsqueda',
                    icon: const Icon(Icons.clear),
                    onPressed: () => _update(() {
                      _qCtrl.clear();
                      _q = '';
                    }),
                  ),
          ),
          onChanged: (v) => _update(() => _q = v),
        ),
        const SizedBox(height: 4),
        Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          PopupMenuButton<MatchSort>(
            tooltip: 'Ordenar',
            initialValue: _sort,
            onSelected: (s) => _update(() {
              if (s == _sort) {
                _desc = !_desc;
              } else {
                _sort = s;
                _desc = s == MatchSort.size || s == MatchSort.modified;
              }
            }),
            itemBuilder: (_) => [
              for (final s in MatchSort.values) PopupMenuItem(value: s, child: Text(matchSortNames[s]!)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.sort, size: 20),
                const SizedBox(width: 4),
                Text('Ordenar: ${matchSortNames[_sort]}'),
              ]),
            ),
          ),
          IconButton(
            tooltip: _desc ? 'De mayor a menor (tocar para invertir)' : 'De menor a mayor (tocar para invertir)',
            icon: Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward, size: 20),
            onPressed: () => _update(() => _desc = !_desc),
          ),
          TextButton.icon(
            icon: Badge(
              isLabelVisible: _activeFilters > 0,
              label: Text('$_activeFilters'),
              child: const Icon(Icons.filter_list),
            ),
            label: const Text('Filtros'),
            onPressed: _filtersSheet,
          ),
          if (_activeFilters > 0 || _q.isNotEmpty || _filter != null)
            TextButton(onPressed: _clearFilters, child: const Text('Limpiar')),
        ]),
        if (filtered)
          Text('Mostrando ${list.length} (${formatBytes(list.fold<int>(0, (s, m) => s + m.size))})',
              style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

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
                onTap: () => _openFolder(d.folder, file: d.path),
                subtitle: d.name == m.name ? null : Text('como "${d.name}"'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _copyBtn('Copiar carpeta', d.folder, 'Carpeta'),
                  _copyBtn('Copiar ruta completa', d.path, 'Ruta'),
                  IconButton(
                    tooltip: 'Abrir carpeta',
                    icon: const Icon(Icons.folder_open, size: 18),
                    onPressed: () => _openFolder(d.folder, file: d.path),
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
                icon: const Icon(Icons.folder_open),
                label: const Text('Abrir su carpeta'),
                onPressed: () => _openFolder(m.folder, file: m.path),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Abrir el archivo'),
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
              onChanged: (v) => _update(() {
                _includeShared = v;
                _sel.clear();
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('${all.length} archivos del $device (${formatBytes(bytesOf(all))}) también están en Drive',
                  style: t.titleSmall),
            ),
            _toolbar(list, all),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                ChoiceChip(
                    label: Text('Todos (${all.length})'),
                    selected: _filter == null,
                    onSelected: (_) => _update(() => _filter = null)),
                for (final l in MatchLevel.values)
                  ChoiceChip(
                    label: Text('${levelNames[l]} (${all.where((m) => m.level == l).length})'),
                    selected: _filter == l,
                    onSelected: (_) => _update(() => _filter = l),
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
            if (list.isEmpty && all.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Ningún resultado con esta búsqueda o estos filtros.'),
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
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(formatBytes(m.size)),
                  IconButton(
                    tooltip: 'Abrir la carpeta del equipo',
                    icon: const Icon(Icons.folder_open, size: 20),
                    onPressed: () => _openFolder(m.folder, file: m.path),
                  ),
                ]),
                onTap: () => _details(m),
                onLongPress: () => _copy(m.name, 'Nombre'),
              ),
            if (list.length > 500)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Se muestran los primeros 500: usá el buscador o los filtros para ver el resto.'),
              ),
          ],
          const SizedBox(height: 80),
        ]),
      ),
    );
  }
}
