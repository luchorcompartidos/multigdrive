import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Extensión del instalador que corresponde a este equipo.
String installerExtension() => Platform.isAndroid ? '.apk' : '.exe';

/// Solo aplica a la web.
void reloadPage() {}

/// Guarda un CSV. Android: lo comparte (Drive, mail, etc.). Windows: lo deja en Descargas.
Future<String> saveCsv(String filename, String content) async {
  final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(content)]; // BOM para Excel
  if (Platform.isAndroid) {
    final f = File('${(await getTemporaryDirectory()).path}/$filename');
    await f.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: filename);
    return 'Elegí dónde guardar o compartir $filename';
  }
  final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final f = File('${dir.path}${Platform.pathSeparator}$filename');
  await f.writeAsBytes(bytes, flush: true);
  await launchUrl(Uri.file(dir.path));
  return 'Guardado en ${f.path}';
}
