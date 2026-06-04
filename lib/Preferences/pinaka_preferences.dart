import 'dart:convert';
import 'package:enum_to_string/enum_to_string.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thermal_printer/thermal_printer.dart';
import '../Constants/text.dart';
import '../Utilities/printer_settings.dart';

class PinakaPreferences {
  // Build #1.0.7 , Naveen - added PinakaPreferences code
  static late SharedPreferences _prefs;
  static late ValueNotifier<String>
      layoutSelectionNotifier; //Build #1.0.54: added

  static SharedPreferences get prefs => _prefs;

  static Future<void> prepareSharedPref() async {
    _prefs = await SharedPreferences.getInstance();
    layoutSelectionNotifier = ValueNotifier<String>('');
  }

  static Future<void> saveLoggedInStore({
    required String storeId,
    required String storeName,
    String? storeLogoUrl,
    String? storeBaseUrl,
  }) async {
    await _prefs.setString('storeId', storeId);
    await _prefs.setString('storeName', storeName);
    await _prefs.setString('storeLogoUrl', storeLogoUrl ?? '');
    if (storeBaseUrl != null) {
      await _prefs.setString('storeBaseUrl', storeBaseUrl);
    }
  }

  static Map<String, String?> getLoggedInStore() {
    final storeId = _prefs.getString('storeId');
    final storeName = _prefs.getString('storeName');
    final storeLogoUrl = _prefs.getString('storeLogoUrl');
    final storeBaseUrl = _prefs.getString('storeBaseUrl');
    if (storeId != null && storeName != null) {
      return {
        'storeId': storeId,
        'storeName': storeName,
        'storeLogoUrl': storeLogoUrl,
        'storeBaseUrl': storeBaseUrl,
      };
    }
    return {};
  }

  static Future<void> clearUserPreferences() async {
    // Clear stored store info
    await _prefs.remove('storeId');
    await _prefs.remove('storeName');
    await _prefs.remove('storeLogoUrl');
    await _prefs.remove('storeBaseUrl');

    // Clear layout selection
    layoutSelectionNotifier.value = '';
    await _prefs.remove(SharedPreferenceTextConstants.layoutSelection);

    // Clear selected printer
    await _prefs.remove(SharedPreferenceTextConstants.selectedPrinter);

    // Build #1.0.285: Clear active order state to prevent session cross-talk
    await _prefs.remove('activeOrderId');
    await _prefs.remove('lastActiveOrderId');

    if (kDebugMode) print("#### PinakaPreferences: User preferences cleared");
  }

  /// Build #1.0.122: No need , now we are using DB saving code
  // saveThemeMode
  // Future<void> saveAppThemeMode(ThemeMode mode) async {
  //   _prefs.setString(SharedPreferenceTextConstants.themeModeKey, mode.toString() ?? ThemeMode.light.toString() );
  // }
  //
  // // Get ThemeMode from SharedPreferences
  // Future<String?> getSavedAppThemeMode() async { // Build #1.0.9 : By default dark theme getting selected on launch even after changing from settings
  //   return _prefs.getString(SharedPreferenceTextConstants.themeModeKey);
  // }

  //Build #1.0.54: added in PinakaPreferences class
  // Future<void> saveLayoutSelection(String layout) async {
  //   await _prefs.setString(SharedPreferenceTextConstants.layoutSelection, layout);
  //   // Only update notifier if the value has changed
  //   if (layoutSelectionNotifier.value != layout) {
  //     layoutSelectionNotifier.value = layout;
  //   }
  //   if (kDebugMode) {
  //     print("#### PinakaPreferences: Saved layout: $layout");
  //   }
  // }
  //
  // Future<String?> getSavedLayoutSelection() async {
  //   return _prefs.getString(SharedPreferenceTextConstants.layoutSelection) ??
  //       SharedPreferenceTextConstants.navLeftOrderRight;
  // }

  // saveSelectedPrinter
  Future<void> saveSelectedPrinter(BluetoothPrinter selectedPrinter) async {
    Map<String, dynamic> printer = {
      'deviceName': selectedPrinter.deviceName,
      'productId': selectedPrinter.productId,
      'vendorId': selectedPrinter.vendorId,
      'typePrinter': EnumToString.convertToString(selectedPrinter.typePrinter)
    };

    await _prefs.setString(
        SharedPreferenceTextConstants.selectedPrinter, jsonEncode(printer));
  }

  // Get SelectedPrinter from SharedPreferences
  Future<BluetoothPrinter> getSavedSelectedPrinter() async {
    BluetoothPrinter selectedPrinter = BluetoothPrinter();

    String? printerPref =
        _prefs.getString(SharedPreferenceTextConstants.selectedPrinter);

    if (kDebugMode) {
      print(" >>>>> Preference getSavedSelectedPrinter $printerPref");
    }
    if (printerPref == null) {
      return selectedPrinter;
    }

    Map<String, dynamic> printer =
        jsonDecode(printerPref) as Map<String, dynamic>;

    selectedPrinter.deviceName = printer['deviceName'];
    selectedPrinter.productId = printer['productId'];
    selectedPrinter.vendorId = printer['vendorId'];
    selectedPrinter.typePrinter =
        EnumToString.fromString(PrinterType.values, printer['typePrinter']) ??
            PrinterType.usb;

    if (kDebugMode) {
      print(
          " >>>>> Preference getSavedSelectedPrinter selectedPrinter : ${selectedPrinter.deviceName}, ${selectedPrinter.productId}, ${selectedPrinter.vendorId}, ${selectedPrinter.typePrinter}");
    }
    return selectedPrinter; //
  }
  // ==================== PAYOUT ENABLE ====================

  static const String payoutEnabledKey = "payout_enabled";

  static Future<void> setPayoutEnabled(bool value) async {
    await _prefs.setBool(payoutEnabledKey, value);

    if (kDebugMode) {
      print("#### PinakaPreferences: payout_enabled saved -> $value");
    }
  }

  static Future<bool> getPayoutEnabled() async {
    return _prefs.getBool(payoutEnabledKey) ?? false;
  }
  static Future<void> savePayoutEnabled(bool value) async {
    await _prefs.setBool('payout_enabled', value);
  }
// ===================== 2. PINAKA PREFERENCES =====================

// Add inside PinakaPreferences class

  static Future<void> saveCashbackEnabled(bool value) async {
    await _prefs.setBool('cashback_enabled', value);
  }

  static Future<bool> getCashbackEnabled() async {
    return _prefs.getBool('cashback_enabled') ?? false;
  }
}
