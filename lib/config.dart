/// Valores que llegan en la compilación (GitHub Actions → --dart-define).
/// Los IDs de cliente no son secretos y quedan acá; el secreto de escritorio es un Secret del repo.
class Config {
  static const webClientId = String.fromEnvironment('WEB_CLIENT_ID',
      defaultValue: '414410842048-ac53pi41embhn1k8e004dnr99m20fqao.apps.googleusercontent.com');
  static const desktopClientId = String.fromEnvironment('DESKTOP_CLIENT_ID',
      defaultValue: '414410842048-2j5f3pa1gb4ajf4v5g6965pjekt2qk5a.apps.googleusercontent.com');
  static const desktopClientSecret = String.fromEnvironment('DESKTOP_CLIENT_SECRET');
  static const webClientSecret = String.fromEnvironment('WEB_CLIENT_SECRET');
  static const webRedirect = 'https://luchorcompartidos.github.io/multigdrive/';
  static const androidScheme = 'com.luchorcompartidos.multigdrive';
  static const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  static const repoUrl = 'https://github.com/luchorcompartidos/multigdrive';

  /// Solo lectura de metadatos (cuota, árbol, tamaños, checksums).
  static const scope = 'https://www.googleapis.com/auth/drive.metadata.readonly';
}
