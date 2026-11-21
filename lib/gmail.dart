import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'actions.dart';
import 'auth/auth.dart' as auth;
import 'config.dart';
import 'side_tree.dart';

class Mail {
  final Account account;
  final String id;
  final String subject;
  final String from;
  final DateTime? date;
  final int size;
  Mail(this.account, this.id, this.subject, this.from, this.date, this.size);
}

class GmailNeedsPermission implements Exception {}

/// Correos pesados de todas las cuentas (lo que ocupa "Gmail" en la cuota).
class GmailPage extends StatefulWidget {
  const GmailPage({super.key});

  @override
  State<GmailPage> createState() => _GmailPageState();
}

class _GmailPageState extends State<GmailPage> {
  int _minMb = 10;
  bool _scanning = false;
  String _status = '';
  List<Mail>? _mails;
  final Set<String> _needPerm = {};
  final Set<Mail> _sel = {};

  Future<Map<String, dynamic>> _get(Account a, String path, Map<String, String> q) async {
    final res = await http.get(Uri.https('gmail.googleapis.com', path, q),
        headers: {'Authorization': 'Bearer ${await DriveActions.store.tokenFor(a)}'});
    if (res.statusCode == 403 || res.statusCode == 401) throw GmailNeedsPermission();
    if (res.statusCode != 200) throw Exception('Gmail respondió ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _sel.clear();
      _needPerm.clear();
    });
    final out = <Mail>[];
    for (final a in DriveActions.store.accounts) {
      try {
        final ids = <String>[];
        String? page;
        do {
          final j = await _get(a, '/gmail/v1/users/me/messages', {
            'q': 'larger:${_minMb}M',
            'maxResults': '100',
            if (page != null) 'pageToken': page,
          });
          for (final m in (j['messages'] as List? ?? [])) {
            ids.add((m as Map)['id'] as String);
          }
          page = j['nextPageToken'] as String?;
        } while (page != null && ids.length < 300);
        var n = 0;
        for (final id in ids) {
          final m = await _get(a, '/gmail/v1/users/me/messages/$id', {
            'format': 'metadata',
            'metadataHeaders': 'Subject',
            'fields': 'id,sizeEstimate,internalDate,payload/headers',
          });
          String header(String name) {
            for (final h in ((m['payload'] as Map?)?['headers'] as List? ?? [])) {
              if ((h as Map)['name'].toString().toLowerCase() == name) return '${h['value']}';
            }
            return '';
          }

          out.add(Mail(
            a,
            id,
            header('subject').isEmpty ? '(sin asunto)' : header('subject'),
            header('from'),
            DateTime.fromMillisecondsSinceEpoch(int.tryParse('${m['internalDate']}') ?? 0),
            (m['sizeEstimate'] as num?)?.toInt() ?? 0,
          ));
          n++;
          if (mounted && n % 10 == 0) setState(() => _status = '${a.title}: $n de ${ids.length}');
        }
      } on GmailNeedsPermission {
        _needPerm.add(a.email);
      } catch (e) {
        _status = '${a.title}: $e';
      }
    }
    out.sort((x, y) => y.size.compareTo(x.size));
    if (mounted) {
      setState(() {
        _mails = out;
        _scanning = false;
      });
    }
  }

  Future<void> _enable(Account a) async {
    await runAction(context, 'Volvé a la app cuando termines en el navegador', () async {
      final r = await auth.signInNewAccount(scope: Config.scopeWithGmail);
      if (r != null) await DriveActions.store.addFromAuth(r);
    });
  }

  Future<void> _trash() async {
    final list = _sel.toList();
    final bytes = list.fold<int>(0, (s, m) => s + m.size);
    if (!await confirm(
        context,
        'Mover correos a la papelera',
        '${list.length} correos (${formatBytes(bytes)}) van a la papelera de Gmail. '
            'Gmail los borra solo a los 30 días, o podés vaciar su papelera antes para liberar el espacio.',
        'A la papelera')) {
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    var ok = 0;
    for (final m in list) {
      final res = await http.post(
          Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages/${m.id}/trash'),
          headers: {'Authorization': 'Bearer ${await DriveActions.store.tokenFor(m.account)}'});
      if (res.statusCode == 200) {
        ok++;
        _mails?.remove(m);
      }
    }
    messenger.showSnackBar(SnackBar(content: Text('$ok de ${list.length} correos a la papelera')));
    if (mounted) setState(_sel.clear);
  }

  @override
  Widget build(BuildContext context) {
    final mails = _mails;
    final t = Theme.of(context).textTheme;
    String day(DateTime? d) => d == null ? '' : '${d.day}/${d.month}/${d.year}';
    final total = (mails ?? const <Mail>[]).fold<int>(0, (s, m) => s + m.size);
    return Scaffold(
      appBar: AppBar(title: const Text('Gmail pesado'), actions: [
        sidebarButton(context),
        IconButton(onPressed: _scanning ? null : _scan, icon: const Icon(Icons.refresh)),
      ]),
      drawer: sidebarDrawer(context),
      bottomNavigationBar: _sel.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Mandar ${_sel.length} correos a la papelera '
                      '(${formatBytes(_sel.fold<int>(0, (s, m) => s + m.size))})'),
                  onPressed: _trash,
                ),
              ),
            ),
      body: withSidebar(
        context,
        ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Correos de más de'),
              for (final mb in [5, 10, 25])
                ChoiceChip(
                  label: Text('$mb MB'),
                  selected: _minMb == mb,
                  onSelected: (_) => setState(() => _minMb = mb),
                ),
              FilledButton.icon(
                onPressed: _scanning ? null : _scan,
                icon: const Icon(Icons.search),
                label: const Text('Buscar'),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Busca en todas las cuentas los correos más pesados (casi siempre por adjuntos). '
                'Google Fotos no se puede analizar: Google no permite que otras apps lean la biblioteca.'),
          ),
          if (_scanning)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [const LinearProgressIndicator(), const SizedBox(height: 8), Text(_status)]),
            ),
          for (final email in _needPerm)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined),
                title: Text(DriveActions.store.accounts.firstWhere((a) => a.email == email).title),
                subtitle: const Text('Falta el permiso de Gmail en esta cuenta.'),
                trailing: FilledButton(
                  onPressed: () => _enable(DriveActions.store.accounts.firstWhere((a) => a.email == email)),
                  child: const Text('Habilitar'),
                ),
              ),
            ),
          if (mails != null && !_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                Expanded(
                    child: Text('${mails.length} correos · ${formatBytes(total)}', style: t.titleSmall)),
                TextButton(
                  onPressed: () => setState(
                      () => _sel.length == mails.length ? _sel.clear() : _sel.addAll(mails)),
                  child: Text(_sel.length == mails.length ? 'Ninguno' : 'Todos'),
                ),
              ]),
            ),
          for (final m in mails ?? const <Mail>[])
            ListTile(
              leading: Checkbox(
                value: _sel.contains(m),
                onChanged: (v) => setState(() => v == true ? _sel.add(m) : _sel.remove(m)),
              ),
              title: Text(m.subject, overflow: TextOverflow.ellipsis),
              subtitle: Text('${m.account.title} · ${m.from} · ${day(m.date)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Text(formatBytes(m.size)),
              onTap: () => launchUrl(
                  Uri.parse('https://mail.google.com/mail/u/${m.account.email}/#all/${m.id}'),
                  mode: LaunchMode.externalApplication),
            ),
        ]),
      ),
    );
  }
}
