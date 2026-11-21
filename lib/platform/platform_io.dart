import 'dart:io';

/// Extensión del instalador que corresponde a este equipo.
String installerExtension() => Platform.isAndroid ? '.apk' : '.zip';

/// Solo aplica a la web.
void reloadPage() {}
