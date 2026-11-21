import 'package:flutter/material.dart';

import 'accounts.dart';
import 'actions.dart';
import 'explorer.dart';
import 'drive_index.dart';
import 'side_tree.dart';

class Perm {
  final String id;
  final String type; // user, group, domain, anyone
  final String role;
  final String? email;
  final String? name;
  Perm(this.id, this.type, this.role, this.email, this.name);

  String get label => switch (type) {
        'anyone' => 'Cualquiera con el link',
        'domain' => 'Dominio ${name ?? ''}',
        _ => email ?? name ?? type,
      };

  String get roleLabel => switch (role) {
        'writer' => 'puede editar',
        'commenter' => 'puede comentar',
        'reader' => 'puede ver',
        'fileOrganizer' || 'organizer' => 'organiza',
        _ => role,
      };
}

class SharedFile {
  final Account account;
  final String id;
  final String name;
  final String mime;
  final List<Perm> perms;
  SharedFile(this.account, this.id, this.name, this.mime, this.perms);

  bool get isPublic => perms.any((p) => p.type == 'anyone' || p.type == 'domain');
  List<Perm> externals(Set<String> own) => perms
      .where((p) => (p.type == 'user' || p.type == 'group') && !own.contains(p.email?.toLowerCase()))
      .toList();
  List<Perm> internals(Set<String> own) =>
      perms.where((p) => p.type == 'user' && own.contains(p.email?.toLowerCase())).toList();
}

enum AuditFilter { all, public, external, own }

/// Auditoría de compartidos: qué está público o compartido, en todas las cuentas.
class AuditPage extends StatefulWidget {
  const AuditPage({super.key});

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  static List<SharedFile>? _cache; // resultado del último análisis
  bool _scanning = false;
  String _status = '';
  AuditFilter _filter = AuditFilter.all;
  final Set<SharedFile> _sel = {};

  Set<String> get _own => DriveActions.store.accounts.map((a) => a.email.toLowerCase()).toSet();

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _sel.clear();
    });
    final out = <SharedFile>[];
    try {
      for (final a in DriveActions.store.accounts) {
        String? page;
        var n = 0;
        do {
          final j = await DriveActions.api(a, 'GET', '/drive/v3/files', query: {
            'q': "'me' in owners and trashed = false",
            'pageSize': '200',
            'fields': 'nextPageToken,files(id,name,mimeType,shared,'
                'permissions(id,type,role,emailAddress,displayName,domain))',
            if (page != null) 'pageToken': page,
          });
          for (final f in (j['files'] as List? ?? [])) {
            final m = f as Map<String, dynamic>;
            n++;
            if (m['shared'] != true) continue;
            final perms = [
              for (final p in (m['permissions'] as List? ?? []))
                if ((p as Map)['role'] != 'owner')
                  Perm(p['id'] as String, p['type'] as String, p['role'] as String,
                      (p['emailAddress'] as String?), (p['displayName'] ?? p['domain']) as String?)
            ];
            if (perms.isNotEmpty) {
              out.add(SharedFile(a, m['id'] as String, (m['name'] as String?) ?? '',
                  (m['mimeType'] as String?) ?? '', perms));
            }
          }
          page = j['nextPageToken'] as String?;
          if (mounted) setState(() => _status = '${a.title}: $n revisados · ${out.length} compartidos');
        } while (page != null);
      }
      _cache = out;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  List<SharedFile> get _visible {
    final own = _own;
    final list = _cache ?? const <SharedFile>[];
    return switch (_filter) {
      AuditFilter.all => list,
      AuditFilter.public => list.where((f) => f.isPublic).toList(),
      AuditFilter.external => list.where((f) => f.externals(own).isNotEmpty).toList(),
      AuditFilter.own => list.where((f) => f.internals(own).isNotEmpty).toList(),
    };
  }

  Future<void> _removePerms(List<SharedFile> files, bool Function(Perm) which, String what) async {
    final jobs = <(Account, DriveItem)>[];
    final permsOf = <String, List<Perm>>{};
    for (final f in files) {
      final ps = f.perms.where(which).toList();
      if (ps.isEmpty) continue;
      permsOf[f.id] = ps;
      jobs.add((f.account, DriveItem(f.id, f.name, f.mime, 0, 0, null, 0, null, false, true)));
    }
    if (jobs.isEmpty) return;
    if (!await confirm(context, what, '$what en ${jobs.length} archivos.', 'Confirmar')) return;
    if (!mounted) return;
    await runBatch(context, what, jobs, (a, it) async {
      for (final p in permsOf[it.id]!) {
        await DriveActions.api(a, 'DELETE', '/drive/v3/files/${it.id}/permissions/${p.id}');
      }
      for (final f in files) {
        if (f.id == it.id) f.perms.removeWhere((p) => permsOf[it.id]!.contains(p));
      }
    }, done: 'Accesos quitados');
    _cache?.removeWhere((f) => f.perms.isEmpty);
    if (mounted) setState(_sel.clear);
  }

  void _details(SharedFile f) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          Text(f.name, style: Theme.of(ctx).textTheme.titleMedium),
          Text('Cuenta: ${f.account.title}'),
          const SizedBox(height: 8),
          for (final p in f.perms)
            ListTile(
              dense: true,
              leading: Icon(p.type == 'anyone' ? Icons.public : Icons.person_outline),
              title: Text(p.label),
              subtitle: Text(p.roleLabel),
              trailing: TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _removePerms([f], (x) => x.id == p.id, 'Quitar acceso');
                },
                child: const Text('Quitar'),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Abrir en Drive'),
            onPressed: () => openInDrive(DriveItem(f.id, f.name, f.mime, 0, 0, null, 0, null, false, true)),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final own = _own;
    final list = _visible;
    final all = _cache;
    final t = Theme.of(context).textTheme;
    int count(bool Function(SharedFile) f) => (all ?? const <SharedFile>[]).where(f).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Auditoría de compartidos'), actions: [
        sidebarButton(context),
        IconButton(
          tooltip: 'Analizar de nuevo',
          onPressed: _scanning ? null : _scan,
          icon: const Icon(Icons.refresh),
        ),
      ]),
      drawer: sidebarDrawer(context),
      bottomNavigationBar: _sel.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                  Text('${_sel.length} seleccionados'),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.public_off),
                    label: const Text('Quitar acceso público'),
                    onPressed: () => _removePerms(_sel.toList(),
                        (p) => p.type == 'anyone' || p.type == 'domain', 'Quitar acceso público'),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.person_off_outlined),
                    label: const Text('Quitar a personas externas'),
                    onPressed: () => _removePerms(
                        _sel.toList(),
                        (p) => (p.type == 'user' || p.type == 'group') &&
                            !own.contains(p.email?.toLowerCase()),
                        'Quitar a personas externas'),
                  ),
                ]),
              ),
            ),
      body: withSidebar(
        context,
        all == null && !_scanning
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Revisa todos tus archivos en todas las cuentas y muestra los que están '
                        'públicos o compartidos con otras personas.', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: _scan, icon: const Icon(Icons.policy_outlined), label: const Text('Analizar')),
                  ]),
                ),
              )
            : ListView(children: [
                if (_scanning)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [const LinearProgressIndicator(), const SizedBox(height: 8), Text(_status)]),
                  ),
                if (all != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Wrap(spacing: 8, runSpacing: 4, children: [
                      ChoiceChip(
                          label: Text('Todos (${all.length})'),
                          selected: _filter == AuditFilter.all,
                          onSelected: (_) => setState(() => _filter = AuditFilter.all)),
                      ChoiceChip(
                          label: Text('Públicos (${count((f) => f.isPublic)})'),
                          selected: _filter == AuditFilter.public,
                          onSelected: (_) => setState(() => _filter = AuditFilter.public)),
                      ChoiceChip(
                          label: Text('Con otras personas (${count((f) => f.externals(own).isNotEmpty)})'),
                          selected: _filter == AuditFilter.external,
                          onSelected: (_) => setState(() => _filter = AuditFilter.external)),
                      ChoiceChip(
                          label: Text('Entre mis cuentas (${count((f) => f.internals(own).isNotEmpty)})'),
                          selected: _filter == AuditFilter.own,
                          onSelected: (_) => setState(() => _filter = AuditFilter.own)),
                    ]),
                  ),
                if (all != null && list.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Row(children: [
                      Expanded(child: Text('${list.length} archivos', style: t.titleSmall)),
                      TextButton(
                        onPressed: () => setState(() =>
                            _sel.length == list.length ? _sel.clear() : _sel.addAll(list)),
                        child: Text(_sel.length == list.length ? 'Ninguno' : 'Seleccionar todos'),
                      ),
                    ]),
                  ),
                for (final f in list)
                  ListTile(
                    leading: Checkbox(
                      value: _sel.contains(f),
                      onChanged: (v) => setState(() => v == true ? _sel.add(f) : _sel.remove(f)),
                    ),
                    title: Text(f.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      f.account.title,
                      if (f.isPublic) '🌐 público',
                      if (f.externals(own).isNotEmpty)
                        '${f.externals(own).length} persona(s): '
                            '${f.externals(own).take(2).map((p) => p.label).join(', ')}'
                            '${f.externals(own).length > 2 ? '…' : ''}',
                      if (f.internals(own).isNotEmpty) 'con tus cuentas',
                    ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _details(f),
                  ),
              ]),
      ),
    );
  }
}
