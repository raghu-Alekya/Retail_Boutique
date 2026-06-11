import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../Helper/url_helper.dart';
import '../Screens/Auth/login_screen.dart';
import '../Widgets/naviagtion_services.dart';
import '../Widgets/session_ended_dialog.dart';
// import '../Widgets/navigation_service.dart';
// import '../Widgets/session_logout_popup.dart';

class TokenValidationService {
  static Timer? _timer;
  static bool _sessionEnding = false;

  static void logoutStarted() {
    _sessionEnding = true;
    stopValidation();
  }

  static void loginStarted() {
    _sessionEnding = false;
  }
  /// Start checking token every 30 seconds
  static void startValidation({
    required String token,
    required String pin,
  }) {

    print("START TOKEN VALIDATION");

    stopValidation();

    _timer = Timer.periodic(
      const Duration(seconds: 30),
          (_) async {

        print("CALLING VALIDATE TOKEN API");

        await validateToken(
          token: token,
          pin: pin,
        );
      },
    );
  }

  static void stopValidation() {

    print("STOP TOKEN VALIDATION");

    _timer?.cancel();
  }

  static Future<void> validateToken({
    required String token,
    required String pin,
  }) async {

    try {

      print("VALIDATING TOKEN...");
      print("TOKEN: $token");
      print("PIN: $pin");

      final response = await http.post(
        Uri.parse(
          '${UrlHelper.baseUrl}${UrlHelper.pinakaPosV1}token/validate-token-pin',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          "emp_login_pin": pin,
        }),
      );

      print("STATUS CODE: ${response.statusCode}");
      print("RESPONSE BODY: ${response.body}");

      final data = jsonDecode(response.body);

      /// TOKEN INVALID
      if (response.statusCode == 403 &&
          data['code'] == 'jwt_auth_obsolete_token') {

        print("TOKEN INVALIDATED");
        print("SHOWING SESSION ENDED POPUP");

        stopValidation();

        /// SHOW POPUP GLOBALLY
        SessionEndedDialog.show(
          navigatorKey.currentContext!,
          onTapHere: () {

            print("REDIRECTING TO LOGIN");

            /// CLEAR STORAGE HERE

            navigatorKey.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => const LoginScreen(),
              ),
                  (route) => false,
            );
          },
        );
      } else {

        print("TOKEN STILL VALID");

      }

    } catch (e) {

      print("TOKEN VALIDATION ERROR: $e");

    }
  }
}