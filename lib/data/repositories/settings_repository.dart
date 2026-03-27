import 'package:shared_preferences/shared_preferences.dart';

/// Repository for persisting user settings (server addresses, etc.)
class SettingsRepository {
  static const String _savedAddressesKey = 'sgtp_saved_addresses';
  static const String _lastAddressKey = 'sgtp_last_address';
  static const int _maxSavedAddresses = 10;

  /// Get all saved server addresses.
  Future<List<String>> getSavedAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_savedAddressesKey) ?? [];
  }

  /// Add a server address to the saved list.
  /// Deduplicates and keeps only the most recent [_maxSavedAddresses] addresses.
  /// The new address is placed at the front.
  Future<void> saveAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    var addresses = prefs.getStringList(_savedAddressesKey) ?? [];

    // Remove duplicates (case-insensitive)
    addresses.removeWhere(
        (a) => a.toLowerCase() == address.toLowerCase());

    // Add to front
    addresses.insert(0, address);

    // Keep only max entries
    if (addresses.length > _maxSavedAddresses) {
      addresses = addresses.sublist(0, _maxSavedAddresses);
    }

    await prefs.setStringList(_savedAddressesKey, addresses);
    await prefs.setString(_lastAddressKey, address);
  }

  /// Get the most recently used server address.
  Future<String?> getLastAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastAddressKey);
  }
}
