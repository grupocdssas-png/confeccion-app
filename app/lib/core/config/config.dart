/// Configuración que se inyecta al compilar con --dart-define-from-file=config/dev.json
/// (ver README). Las claves de servidor (service_role, Alegra, WhatsApp) NUNCA van aquí.
class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');
  static const versionApp = '0.1.0-fase1';

  static bool get completa => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get tienePowerSync => powersyncUrl.isNotEmpty;
}
