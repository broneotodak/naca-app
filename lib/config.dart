/// NACA App Configuration
class AppConfig {
  // neo-brain Supabase (agent state — direct from Flutter, no backend proxy)
  static const String supabaseUrl = 'https://xsunmervpyrplzarebva.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhzdW5tZXJ2cHlycGx6YXJlYnZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY1NjUwOTEsImV4cCI6MjA5MjE0MTA5MX0.yP7xJ04rGYl1r-PEUn_RNXqf6_O3hyrJfuUoc42gFOE';

  // CCC terminal backend (direct to VPS)
  static const String apiBaseUrl = 'http://178.156.241.204:3100';
  static const String wsUrl = 'ws://178.156.241.204:3100';
  static const String authToken = 'ccc_sk_naca_2026';
}
