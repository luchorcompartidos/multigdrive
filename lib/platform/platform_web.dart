import 'dart:js_interop';

import 'package:web/web.dart' as web;

String installerExtension() => '';

void reloadPage() => web.window.location.reload();

/// Descarga el CSV desde el navegador.
Future<String> saveCsv(String filename, String content) async {
  final blob = web.Blob(<JSAny>['\uFEFF$content'.toJS].toJS,
      web.BlobPropertyBag(type: 'text/csv;charset=utf-8'));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.append(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
  return 'Descargado: $filename';
}
