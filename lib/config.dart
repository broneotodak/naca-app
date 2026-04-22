/// NACA App Configuration
/// Update these values to connect to your VPS backend
class AppConfig {
  // Backend server URL (CCC + NACA endpoints)
  static const String apiBaseUrl = 'http://178.156.241.204:3100';

  // WebSocket URL for terminal streaming
  static const String wsUrl = 'ws://178.156.241.204:3100';

  // Auth token (must match backend AUTH_TOKEN)
  static const String authToken = 'ccc_sk_naca_2026';
}
