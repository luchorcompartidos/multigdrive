/// Valores que llegan en la compilación (GitHub Actions → --dart-define).
/// Los IDs de cliente no son secretos y quedan acá; el secreto de escritorio es un Secret del repo.
class Config {
  static const webClientId = String.fromEnvironment('WEB_CLIENT_ID',
      defaultValue: '414410842048-9039a81gkn8lgq83j851ka6qq5kqqvaa.apps.googleusercontent.com');
  static const desktopClientId = String.fromEnvironment('DESKTOP_CLIENT_ID',
      defaultValue: '414410842048-2j5f3pa1gb4ajf4v5g6965pjekt2qk5a.apps.googleusercontent.com');
  static const desktopClientSecret = String.fromEnvironment('DESKTOP_CLIENT_SECRET');
  static const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  static const repoUrl = 'https://github.com/luchorcompartidos/multigdrive';

  /// Solo lectura de metadatos (cuota, árbol, tamaños, checksums).
  static const scope = 'https://www.googleapis.com/auth/drive.metadata.readonly';
}
