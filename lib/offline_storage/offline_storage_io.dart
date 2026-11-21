import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Android y Windows: los archivos quedan en la carpeta de la app.
const bool supported = true;

String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

Future<String> saveStream(String email, String fileName, Stream<List<int>> data) async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}offline'
      '${Platform.pathSeparator}${_safe(email)}');
  if (!await dir.exists()) await dir.create(recursive: true);
  final f = File('${dir.path}${Platform.pathSeparator}${_safe(fileName)}');
  final tmp = File('${f.path}.part');
  final sink = tmp.openWrite();
  try {
    await sink.addStream(data);
  } finally {
    await sink.close();
  }
  if (await f.exists()) await f.delete();
  await tmp.rename(f.path);
  return f.path;
}

Future<void> deleteFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

Future<bool> exists(String path) => File(path).exists();

Future<void> openFile(String path) async {
  final r = await OpenFilex.open(path);
  if (r.type != ResultType.done) throw Exception('No se pudo abrir: ${r.message}');
}
