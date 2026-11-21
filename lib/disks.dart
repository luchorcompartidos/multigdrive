import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'side_tree.dart';
import 'unified.dart';
import 'upload.dart';

class DiskMember {
  final String email;
  final String folderId;
  DiskMember(this.email, this.folderId);
  Map<String, dynamic> toJson() => {'email': email, 'folder': folderId};
  factory DiskMember.fromJson(Map<String, dynamic> j) =>
      DiskMember(j['email'] as String, j['folder'] as String);
}

/// Disco virtual: una carpeta "base" en cada una de sus cuentas, vistas y usadas como un disco.
class Disk {
  String name;
  int color;
  final List<DiskMember> members;
  Disk(this.name, this.color, this.members);

  Map<String, dynamic> toJson() =>
      {'name': name, 'color': color, 'members': members.map((m) => m.toJson()).toList()};
  factory Disk.fromJson(Map<String, dynamic> j) => Disk(
        j['name'] as String,
        (j['color'] as num).toInt(),
        [for (final m in j['members'] as List) DiskMember.fromJson(m as Map<String, dynamic>)],
      );

  List<Account> get accounts => [
        for (final a in DriveActions.store.accounts)
          if (members.any((m) => m.email == a.email)) a
      ];

  MergedFolder get root => MergedFolder(name, [
        for (final m in members)
          for (final a in DriveActions.store.accounts)
            if (a.email == m.email && DriveActions.indexes.loaded[a.email] != null)
              Spot(a, DriveActions.indexes.loaded[a.email]!, m.folderId)
      ]);

  int get used => root.total;

  /// Lugar libre: el libre de sus cuentas (si una cuenta está en varios discos, lo comparten).
  int get free => accounts.fold<int>(0, (s, a) {
        final q = a.quota;
        return q?.limit == null ? s : s + (q!.limit! - q.usage).clamp(0, q.limit!).toInt();
      });
}

class Disks {
  static const _key = 'mgd_disks';
  static final List<Disk> list = [];
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      for (final j in jsonDecode(raw) as List) {
        list.add(Disk.fromJson(j as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  static Future<void> save() async => (await SharedPreferences.getInstance())
      .setString(_key, jsonEncode(list.map((d) => d.toJson()).toList()));
}

/// Mueve un elemento a un disco: elige la cuenta del disco con más lugar.
Future<void> moveToDisk(Account a, DriveItem it, Disk d) async {
  final target = pickAccountFor(d.accounts, it.total, {});
  if (target == null) throw Exception('El disco "${d.name}" no tiene lugar para "${it.name}"');
  final member = d.members.firstWhere((m) => m.email == target.email);
  if (target.email == a.email) {
    await DriveActions.move(a, it, member.folderId);
    return;
  }
  final r = await DriveActions.transferToAccount(a, it, target);
  if (r.failed.isNotEmpty) throw Exception('No se pudo pasar todo a ${target.title}');
  final moved = DriveActions.indexes.loaded[target.email]?.items[it.id] ?? it;
  await DriveActions.move(target, moved, member.folderId);
}

/// Botón "Mover a un disco" para la hoja de detalle.
List<Widget> diskButtons(
    BuildContext context, Account a, AccountIndex idx, DriveItem it, VoidCallback close) {
  if (Disks.list.isEmpty || it.isVirtual || !it.mine || it.trashed) return const [];
  return [
    OutlinedButton.icon(
      icon: const Icon(Icons.album_outlined),
      label: const Text('Mover a un disco'),
      onPressed: () async {
        close();
        final d = await showDialog<Disk>(
          context: context,
          builder: (ctx) => SimpleDialog(title: const Text('Mover a…'), children: [
            for (final d in Disks.list)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, d),
                child: Row(children: [
                  Icon(Icons.album, color: Color(d.color)),
                  const SizedBox(width: 12),
                  Expanded(child: Text('${d.name} · libre ${formatBytes(d.free)}')),
                ]),
              ),
          ]),
        );
        if (d == null || !context.mounted) return;
        runAction(context, 'Movido al disco ${d.name}', () => moveToDisk(a, it, d));
      },
    ),
  ];
}

/// Pantalla de discos virtuales.
class DisksPage extends StatefulWidget {
  const DisksPage({super.key});

  @override
  State<DisksPage> createState() => _DisksPageState();
}

class _DisksPageState extends State<DisksPage> {
  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    indexChanged.addListener(_refresh);
    Disks.load().then((_) => _refresh());
  }

  @override
  void dispose() {
    indexChanged.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _create([Disk? edit]) async {
    final accounts = DriveActions.store.accounts
        .where((a) => DriveActions.indexes.loaded[a.email] != null)
        .toList();
    final name = TextEditingController(text: edit?.name ?? '');
    var color = edit?.color ?? accountColors[Disks.list.length % accountColors.length];
    final chosen = <String>{...?edit?.members.map((m) => m.email)};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(edit == null ? 'Nuevo disco virtual' : 'Editar disco'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Fotos, Trabajo, Archivo'),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                for (final c in accountColors)
                  InkWell(
                    onTap: () => setLocal(() => color = c),
                    child: CircleAvatar(
                        radius: 14,
                        backgroundColor: Color(c),
                        child: c == color ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                  ),
              ]),
              const SizedBox(height: 12),
              const Text('Cuentas que forman el disco:'),
              for (final a in accounts)
                CheckboxListTile(
                  dense: true,
                  value: chosen.contains(a.email),
                  title: Text(a.title),
                  subtitle: Text(a.quota?.free == null ? '' : 'Libre ${formatBytes(a.quota!.free)}'),
                  onChanged: (v) => setLocal(() => v == true ? chosen.add(a.email) : chosen.remove(a.email)),
                ),
              const Text('En cada cuenta se usa (o se crea) una carpeta con el nombre del disco en Mi unidad.'),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    final n = name.text.trim();
    if (ok != true || n.isEmpty || chosen.isEmpty || !mounted) return;
    await runAction(context, 'Disco "$n" listo', () async {
      final members = <DiskMember>[];
      for (final a in accounts.where((a) => chosen.contains(a.email))) {
        final keep = edit?.members.where((m) => m.email == a.email).firstOrNull;
        if (keep != null && edit!.name == n) {
          members.add(keep);
          continue;
        }
        final idx = DriveActions.indexes.loaded[a.email]!;
        final folder = await ensureFolderPath(a, idx, idx.rootId, [n]);
        members.add(DiskMember(a.email, folder));
        await DriveActions.notifyChanged(a.email);
      }
      if (edit != null) Disks.list.remove(edit);
      Disks.list.add(Disk(n, color, members));
      await Disks.save();
    });
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Discos virtuales'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(),
        icon: const Icon(Icons.add),
        label: const Text('Nuevo disco'),
      ),
      body: withSidebar(
        context,
        ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Un disco virtual junta una carpeta de varias cuentas y la usa como un solo disco: '
                'su capacidad es la suma del lugar libre, y lo que subas o muevas a él va a la cuenta '
                'con más espacio.'),
          ),
          if (Disks.list.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Todavía no hay discos.', textAlign: TextAlign.center),
            ),
          for (final d in Disks.list)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: ListTile(
                leading: Icon(Icons.album, color: Color(d.color), size: 36),
                title: Text(d.name, style: t.titleMedium),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${formatBytes(d.used)} usados · ${formatBytes(d.free)} libres'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: (d.used + d.free) == 0 ? 0 : d.used / (d.used + d.free),
                    color: Color(d.color),
                    minHeight: 6,
                  ),
                  const SizedBox(height: 4),
                  Text(d.accounts.map((a) => a.title).join(' · '), style: t.bodySmall),
                ]),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => UnifiedPage(root: d.root, title: d.name)),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'editar') {
                      await _create(d);
                    } else {
                      Disks.list.remove(d);
                      await Disks.save();
                      _refresh();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'editar', child: Text('Editar')),
                    PopupMenuItem(value: 'quitar', child: Text('Quitar disco (no borra archivos)')),
                  ],
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
