import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'history.dart';
import 'unified.dart';

/// Busca (o crea) en la cuenta la carpeta con esa ruta de nombres desde [startId].
Future<String> ensureFolderPath(Account a, AccountIndex idx, String startId, List<String> names) async {
  var current = startId;
  for (final n in names) {
    final found = (idx.children[current] ?? const <DriveItem>[])
        .where((c) => c.isFolder && !c.trashed && c.name == n)
        .firstOrNull;
    if (found != null) {
      current = found.id;
      continue;
    }
    final j = await DriveActions.api(a, 'POST', '/drive/v3/files',
        query: {'fields': fileFields}, body: {'name': n, 'mimeType': folderMime, 'parents': [current]});
    final created = DriveItem.fromApi(j);
    idx.items[created.id] = created;
    idx.rebuild();
    current = created.id;
  }
  return current;
}

/// Sube un archivo (subida reanudable, apta para archivos grandes) y lo agrega al índice.
Future<DriveItem> uploadFile(Account a, String parentId, String name, int size, Stream<List<int>> data) async {
  final token = await DriveActions.store.tokenFor(a);
  final init = await http.post(
    Uri.https('www.googleapis.com', '/upload/drive/v3/files', {'uploadType': 'resumable', 'fields': fileFields}),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Upload-Content-Length': '$size',
    },
    body: jsonEncode({'name': name, 'parents': [parentId]}),
  );
  final location = init.headers['location'];
  if (init.statusCode != 200 || location == null) {
    if (init.statusCode == 403 && init.body.contains('storageQuotaExceeded')) {
      throw Exception('${a.title} no tiene espacio');
    }
    throw Exception('Drive respondió ${init.statusCode} al iniciar la subida');
  }
  final req = http.StreamedRequest('PUT', Uri.parse(location))..contentLength = size;
  data.listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError, cancelOnError: true);
  final res = await http.Response.fromStream(await req.send());
  if (res.statusCode != 200 && res.statusCode != 201) {
    throw Exception('Drive respondió ${res.statusCode} al subir "$name"');
  }
  final it = DriveItem.fromApi(jsonDecode(res.body) as Map<String, dynamic>);
  final idx = DriveActions.indexes.loaded[a.email];
  if (idx != null) idx.items[it.id] = it;
  await History.add('upload', a, it, bytes: it.size);
  return it;
}

/// Elige la cuenta con más lugar libre (entre [accounts]) donde entre [size].
Account? pickAccountFor(Iterable<Account> accounts, int size, Map<String, int> planned) {
  Account? best;
  var bestFree = -1;
  for (final a in accounts) {
    final q = a.quota;
    if (q == null) continue;
    final free = (q.limit == null ? 1000000000000000 : q.limit! - q.usage) - (planned[a.email] ?? 0);
    if (free >= size && free > bestFree) {
      best = a;
      bestFree = free;
    }
  }
  return best;
}

/// Subir archivos a la carpeta fusionada actual (unidad unificada o disco virtual).
Future<void> uploadInto(BuildContext context, List<MergedFolder> path) async {
  final picked = await FilePicker.platform.pickFiles(allowMultiple: true, withReadStream: true);
  if (picked == null || picked.files.isEmpty || !context.mounted) return;
  final root = path.first;
  final names = path.skip(1).map((p) => p.name).toList();
  final planned = <String, int>{};
  await runWithReport(context, 'Subiendo', (progress) async {
    final r = CopyReport()..total = picked.files.length;
    progress(r);
    for (final f in picked.files) {
      try {
        final a = pickAccountFor(root.accounts, f.size, planned);
        if (a == null) throw Exception('No hay lugar para "${f.name}"');
        final spot = root.spots.firstWhere((s) => s.account.email == a.email);
        final parent = await ensureFolderPath(a, spot.index, spot.folderId, names);
        final stream = f.readStream;
        if (stream == null) throw Exception('No se pudo leer "${f.name}"');
        await uploadFile(a, parent, f.name, f.size, stream);
        planned[a.email] = (planned[a.email] ?? 0) + f.size;
      } catch (_) {
        r.failed.add(f.name);
      }
      r.done++;
      progress(r);
    }
    for (final s in root.spots) {
      await DriveActions.notifyChanged(s.account.email);
    }
    for (final a in root.accounts) {
      await DriveActions.store.refreshQuota(a);
    }
    return r;
  }, (r) => '${r.total} archivos subidos');
}
