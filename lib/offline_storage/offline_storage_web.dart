/// Web: no se guardan archivos sin conexión.
const bool supported = false;

Future<String> saveStream(String email, String fileName, Stream<List<int>> data) async =>
    throw UnsupportedError('No disponible en la web');

Future<void> deleteFile(String path) async {}

Future<bool> exists(String path) async => false;

Future<void> openFile(String path) async {}
