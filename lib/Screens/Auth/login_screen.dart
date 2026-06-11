import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../Blocs/Assets/asset_bloc.dart';
import '../../Blocs/Auth/login_bloc.dart';
import '../../Blocs/Auth/logout_bloc.dart';
import '../../Constants/misc_features.dart';
import '../../Constants/text.dart';
import '../../Database/assets_db_helper.dart';
import '../../Database/db_helper.dart';
import '../../Database/fast_key_db_helper.dart';
import '../../Database/order_panel_db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/api_response.dart';
import '../../Models/Auth/login_model.dart';
import '../../Models/Auth/logout_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Assets/asset_repository.dart';
import '../../Repositories/Auth/login_repository.dart';
import '../../Repositories/Auth/logout_repository.dart';
import '../../Repositories/Orders/order_repository.dart';
import '../../Repositories/session_valadition_repository.dart';
import '../../Widgets/SafeStorageHelper.dart';
import '../../Widgets/discount_engine_constants.dart';
import '../../Widgets/widget_custom_num_pad.dart';
import '../../Widgets/widget_loading.dart';
import '../../screens/Home/shift_open_close_balance.dart';
import '../Home/pos_home_screen.dart';
import '../../Widgets/widget_error.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final List<String> _password = List.filled(6, "");
  late LoginBloc _bloc;
  late AssetBloc _assetBloc;
  final UserDbHelper _userDbHelper = UserDbHelper();
  bool _hasErrorShown = false; // 👈 // Build #1.0.16 : Track if error is already shown

  @override
  void initState() {
    super.initState();
    _bloc = LoginBloc(LoginRepository());
    _assetBloc = AssetBloc(AssetRepository());
    //  _checkExistingUser(); // Un comment this line if auto login needed
  }

  Future<void> _checkExistingUser() async {
    bool isLoggedIn = await _userDbHelper.isUserLoggedIn();
    if (isLoggedIn && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const POSHomeScreen()),
      );
    }
  }
  bool _discountSyncDone = false;

  void _updatePassword(String value) {
    for (int i = 0; i < _password.length; i++) {
      if (_password[i].isEmpty) {
        setState(() {
          _password[i] = value;
        });
        if (kDebugMode) {
          print("Password updated: $_password");
        }

        // Auto-submit when 6 digits are entered
        // if (i == 5) {
        //   _handleLogin();
        // }
        break;
      }
    }
  }

  void _deletePassword() {
    for (int i = _password.length - 1; i >= 0; i--) {
      if (_password[i].isNotEmpty) {
        setState(() {
          _password[i] = "";
        });
        if (kDebugMode) {
          print("Password deleted: $_password");
        }
        break;
      }
    }
  }

  // Clear all fields with animation by resetting them one by one
  void _clearPassword() {
    setState(() {
      // Clear the fields one by one to trigger the animation on each field
      for (int i = 0; i < _password.length; i++) {
        _password[i] = ""; // Reset each field with animation
      }
    });
    if (kDebugMode) {
      print("Password cleared: $_password");
    }
  }

  bool _validatePin() { // Build #1.0.13
    if (_password.any((digit) => digit.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter 6-digit PIN',
            style: TextStyle(color: Colors.red))),
      );
      return false;
    }
    return true;
  }

  void _handleLogin() async {
    if (!_validatePin()) return;
    _hasErrorShown = false; // Build #1.0.16: Reset error flag before login
    final pin = _password.join();
    _bloc.fetchLoginToken(LoginRequest(pin));

    //Build #1.0.54: added, check if assets are already saved in the database
    //  String? baseUrl = await AssetDBHelper.instance.getAppBaseUrl();
    // if (baseUrl == null) { //Build #1.0.64: updated
    if (kDebugMode) {
      print("#### LoginScreen: No assets found in database, fetching assets");
    }
    //Build 1.0.68: await added for completion of save assets else getting empty data
    // } else {
    //   if (kDebugMode) {
    //     print("#### LoginScreen: Assets already saved in database, skipping fetch");
    //   }
    // }
  }

  // CODE UPDATED!!
  // Build 1.0.202: Original Fix : SCRUM -> 327 - Empty fastkey folders show at first logon to multiple fastkeys loaded on created by the user
  // SCRUM - 348 -> Fast Keys not loading on initial login
  void resetLoadStatus() {
    FastKeyDBHelper.isFastkeyLoaded = false;
    OrderHelper.isOrderPanelLoaded = false;

    if (kDebugMode) {
      print("resetLoadStatus: isFastkeyLoaded -> ${FastKeyDBHelper.isFastkeyLoaded}, isOrderPanelLoaded -> ${OrderHelper.isOrderPanelLoaded}");
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

    return Scaffold(
      body: Row(
        children: [
          // Left Side - Logo Section
          Expanded(
            flex: 1,
            child: Container(
              color: const Color(0xFF1E2745),
              child: Center(
                child: SvgPicture.asset(
                  'assets/svg/app_logo.svg',
                  height: 150,
                ),
              ),
            ),
          ),

          // Right Side - Login Interface
          Expanded(
            flex: 1,
            child: Container(
              color: Color(0xFFE0E0E0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Password Fields
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(6, (index) {
                          double paddingValue = isPortrait ? 8.5 : 12.5;
                          return Padding(
                            padding: EdgeInsets.symmetric(horizontal: paddingValue),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: Container(
                                key: ValueKey<int>(index),
                                width: isPortrait ? 50.0 : 70.0,
                                height: isPortrait ? 50.0 : 70.0,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFFFF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.grey.shade300, width: 1),
                                ),
                                child: Center(
                                  child: _password[index].isEmpty
                                      ? SvgPicture.asset(
                                    'assets/svg/password_placeholder.svg',
                                    width: 15,
                                    height: 15,
                                  )
                                      : SvgPicture.asset(
                                    'assets/svg/password_placeholder.svg',
                                    colorFilter: const ColorFilter.mode(
                                        Colors.black, BlendMode.srcIn),
                                    width: 15,
                                    height: 15,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 32),

                      // Custom NumPad
                      CustomNumPad(
                        numPadType: NumPadType.login,
                        onDigitPressed: _updatePassword,
                        onClearPressed: _clearPassword,
                        onDeletePressed: _deletePassword,
                        actionButtonType: ActionButtonType.delete,
                      ),

                      const SizedBox(height: 32),

                      // Login Button
                      SizedBox(
                        width: MediaQuery.of(context).size.width /
                            (isPortrait ? 7.3 : 7.2),
                        height: MediaQuery.of(context).size.height /
                            (isPortrait ? 20.0 : 10.0),
                        child: ElevatedButton(
                          onPressed: _handleLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E2745), // Background color: #1E2745
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          // In LoginScreen.dart - update the ElevatedButton's child widget
                          child: StreamBuilder<APIResponse<LoginResponse>>(
                            stream: _bloc.loginStream,
                            builder: (context, snapshot) {
                              if (snapshot.hasData) {
                                switch (snapshot.data?.status) {
                                  case Status.LOADING:
                                    return Center(
                                      child: Loading(
                                        loadingMessage: snapshot.data?.message,
                                      ),
                                    );

                                  case Status.COMPLETED:
                                    if (snapshot.data?.data?.token != null) {
                                      WidgetsBinding.instance.addPostFrameCallback((_) async {
                                        final loginResponse = snapshot.data!.data!;

                                        bool isCashbackEnabled =
                                            loginResponse.cashbackEnable ?? false;

                                        await PinakaPreferences.saveCashbackEnabled(
                                            isCashbackEnabled);
                                        bool isPayoutEnabled =
                                            loginResponse.payoutEnable ?? false;

                                        await PinakaPreferences.savePayoutEnabled(isPayoutEnabled);
                                        final pin = _password.join();
                                        final token = loginResponse.token ?? "";
                                        TokenValidationService.stopValidation();
                                        TokenValidationService.startValidation(
                                          token: token,
                                          pin: pin,
                                        );

                                        await SafeStorageHelper.saveSafeEnableDrop(
                                          loginResponse.safeEnableDrop == "1",
                                        );
                                        if (!_discountSyncDone) {
                                          _discountSyncDone = true;
                                          try {
                                            final repo = OrderRepository();
                                            await syncDiscountRulesFromApi(AppDB.isar, repo);
                                            debugPrint("✅ Discount rules synced after login");
                                          } catch (e) {
                                            debugPrint("❌ Discount rule sync failed: $e");
                                          }
                                        }

// ✅ DEBUG
                                        if (kDebugMode) {
                                          print("🔐 safe_enable = ${loginResponse.safeEnable}");
                                          print("💾 safe_enable stored = ${loginResponse.safeEnable == "1"}");
                                          print("🔽 safe_enable_drop = ${loginResponse.safeEnableDrop}");
                                        }

                                        // Build #1.0.163: Call image assets API in background without waiting for it
                                        unawaited(_assetBloc.fetchImageAssets()); // This will run in background
                                        // Build #1.0.69 : Call Fetch Assets Api after login api call success!
                                        await _assetBloc.fetchAssets(); // Fetch and save assets
                                        /// Fix -> SCRUM - 327, 348
                                        resetLoadStatus();
                                        // Build #1.0.70 - check shift started or not based on shift id
                                        int? shiftId = await UserDbHelper().getUserShiftId(); // Build #1.0.149 : using from db
                                        if (shiftId != null && snapshot.data?.data?.shiftId != null) { // Build #1.0.154: Updated -> shift_id checking null or not in login response
                                          Navigator.pushReplacement(
                                              context,
                                              MaterialPageRoute(builder: (context) => const POSHomeScreen()));
                                        }else{
                                          Navigator.pushReplacement(
                                            context,
                                            MaterialPageRoute(builder: (context) => const ShiftOpenCloseBalanceScreen(),
                                              settings: RouteSettings(arguments: TextConstants.loginScreen),
                                            ),
                                          );
                                        }
                                      });
                                      return Center(
                                        child: Loading(
                                          loadingMessage: TextConstants.loading,
                                        ),
                                      );
                                    } else {
                                      if (kDebugMode) {
                                        print("Error in login bloc in completed and token is null");
                                      }
                                      return Center(
                                        child: Text(
                                          snapshot.data?.data?.message ?? "",
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16,
                                            color: Colors.red,
                                          ),
                                        ),
                                      );
                                    }

                                  case Status.ERROR:
                                    if (kDebugMode) {
                                      print("Error in login bloc.");
                                    }
                                    var errorMsg = snapshot.data?.message ?? "Login failed. Please try again.";
                                    if(errorMsg.contains('logout')){

                                    }
                                    if (!_hasErrorShown) { // 👈 Ensure error is shown only once
                                      _hasErrorShown = true;
                                      var isLoading = false;
                                      var logoutBloc = LogoutBloc(LogoutRepository());
                                      WidgetsBinding.instance.addPostFrameCallback((_) { // Build #1.0.16
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content:

                                            Row(
                                              children: [
                                                Text(
                                                  snapshot.data?.message ?? TextConstants.failedToLogin, // Build #1.0.166
                                                  style: const TextStyle(color: Colors.red),
                                                ),
                                                Spacer(),
                                                // !isLoading ? SizedBox(): StreamBuilder<APIResponse<LogoutResponse>>(
                                                //     stream: logoutBloc.logoutStream,
                                                //     builder: (context, snapshot) {
                                                //   if (!snapshot.hasData || snapshot.data!.status == Status.LOADING) { // Build #1.0.148: updated condition , no need two if's
                                                //     return const Center(child: CircularProgressIndicator());
                                                //   }
                                                //   var response = snapshot.data!;
                                                //   if (snapshot.data!.status == Status.COMPLETED) {
                                                //
                                                //     if (kDebugMode) {
                                                //       print("Logout successful, navigating to LoginScreen");
                                                //     }
                                                //     ScaffoldMessenger.of(context).showSnackBar(
                                                //       SnackBar(
                                                //         content: Text(response?.message ?? TextConstants.successfullyLogout),
                                                //         backgroundColor: Colors.green,
                                                //         duration: const Duration(seconds: 2),
                                                //       ),
                                                //     );
                                                //     // Update loading state and navigate
                                                //     // isLoading = false;
                                                //     //Navigator.of(context).pop(); // Close loader dialog
                                                //     Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => LoginScreen()));
                                                //   } else if (response.status == Status.ERROR) {
                                                //       if (kDebugMode) {
                                                //         print("Logout failed: ${response.message}");
                                                //       }
                                                //       ScaffoldMessenger.of(context).showSnackBar(
                                                //         SnackBar(
                                                //           content: Text(response.message ?? TextConstants.failedToLogout),
                                                //           backgroundColor: Colors.red,
                                                //           duration: const Duration(seconds: 2),
                                                //         ),
                                                //       );
                                                //       isLoading  = false;
                                                //       // Update loading state
                                                //       // isLoading = false;
                                                //       // Navigator.of(context).pop(); // Close loader dialog
                                                //     }
                                                //   return const Center(child: CircularProgressIndicator());
                                                // }),
                                                // isLoading ? SizedBox():
                                                TextButton(
                                                  onPressed: () {
                                                    // // isLoading = true;
                                                    // logoutBloc.logoutStream.listen((response) {
                                                    //   if (response.status == Status.COMPLETED) {
                                                    //     if (kDebugMode) {
                                                    //       print("Logout successful, navigating to LoginScreen");
                                                    //     }
                                                    //     ScaffoldMessenger.of(context).showSnackBar(
                                                    //       SnackBar(
                                                    //         content: Text(response.message ?? TextConstants.successfullyLogout),
                                                    //         backgroundColor: Colors.green,
                                                    //         duration: const Duration(seconds: 2),
                                                    //       ),
                                                    //     );
                                                    //     // Update loading state and navigate
                                                    //     // isLoading = false;
                                                    //     //Navigator.of(context).pop(); // Close loader dialog
                                                    //     Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => LoginScreen()),);
                                                    //   } else if (response.status == Status.ERROR) {
                                                    //     if (kDebugMode) {
                                                    //       print("Logout failed: ${response.message}");
                                                    //     }
                                                    //     ScaffoldMessenger.of(context).showSnackBar(
                                                    //       SnackBar(
                                                    //         content: Text(response.message ?? TextConstants.failedToLogout),
                                                    //         backgroundColor: Colors.red,
                                                    //         duration: const Duration(seconds: 2),
                                                    //       ),
                                                    //     );
                                                    //     // Update loading state
                                                    //     // isLoading = false;
                                                    //    // Navigator.of(context).pop(); // Close loader dialog
                                                    //   }
                                                    // });
                                                    //
                                                    // // Trigger logout API call
                                                    // logoutBloc.performLogout();


                                                    // Build #1.0.163: call Logout API after close shift
                                                    showDialog(
                                                      context: context,
                                                      barrierDismissible: false,
                                                      builder: (BuildContext context) {
                                                        bool isLoading = true; // Initial loading state
                                                        logoutBloc.logoutStream.listen((response) {
                                                          if (response.status == Status.COMPLETED) {
                                                            if (kDebugMode) {
                                                              print("#### COMPLETED performLogoutByEmpPin : Logout successful using pin");
                                                            }
                                                            // if (Misc.showDebugSnackBar) { // Build #1.0.254
                                                            ScaffoldMessenger.of(context).showSnackBar(
                                                              SnackBar(
                                                                content: Text(response.message ?? TextConstants.successfullyLogout),
                                                                backgroundColor: Colors.green,
                                                                duration: const Duration(seconds: 1),
                                                              ),
                                                            );
                                                            // }
                                                            // Update loading state and navigate
                                                            isLoading = false;
                                                            Navigator.of(context).pop(); // Close loader dialog
                                                            // Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => LoginScreen()),
                                                            // );
                                                          } else if (response.status == Status.ERROR) {
                                                            if (kDebugMode) {
                                                              print("Logout failed: ${response.message}");
                                                            }
                                                            ScaffoldMessenger.of(context).showSnackBar(
                                                              SnackBar(
                                                                content: Text(response.message ?? TextConstants.failedToLogout),
                                                                backgroundColor: Colors.red,
                                                                duration: const Duration(seconds: 1),
                                                              ),
                                                            );
                                                            // Update loading state
                                                            isLoading = false;
                                                            Navigator.of(context).pop(); // Close loader dialog
                                                          }
                                                        });

                                                        // Build #1.0.166: Trigger logout API call with _password PIN
                                                        final pin = _password.join();
                                                        TokenValidationService.stopValidation();
                                                        logoutBloc.performLogoutByEmpPin(int.tryParse(pin));

                                                        // Show circular loader
                                                        return StatefulBuilder(
                                                          builder: (context, setState) {
                                                            return Center(
                                                              child: CircularProgressIndicator(),
                                                            );
                                                          },
                                                        );
                                                      },
                                                    );

                                                  },
                                                  child: Text(
                                                    TextConstants.logoutText, // Build #1.0.166
                                                    style: const TextStyle(color: Colors.red),
                                                  ),),

                                              ],
                                            ),
                                            backgroundColor: Colors.black, // ✅ Black background
                                            //duration: const Duration(seconds: 3),
                                            showCloseIcon: true,

                                          ),
                                        );
                                      });
                                    }
                                // return Center(
                                //   child: Text(
                                //     snapshot.data?.message ?? "Something went wrong",
                                //     textAlign: TextAlign.center,
                                //     style: const TextStyle(
                                //       fontWeight: FontWeight.w600,
                                //       fontSize: 16,
                                //       color: Colors.red,
                                //     ),
                                //   ),
                                // );
                                  default:
                                    break;
                                }
                              }
                              return const Center(
                                child: Text(
                                  TextConstants.loginBtnText,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}