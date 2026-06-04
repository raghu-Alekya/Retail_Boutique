import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:pinaka_pos/Helper/Extentions/text_extensions.dart';
import 'package:pinaka_pos/Screens/Home/safe_open_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../Blocs/Auth/logout_bloc.dart';
import '../../Blocs/Auth/shift_bloc.dart';
import '../../Constants/text.dart';
import '../../Database/assets_db_helper.dart';
import '../../Database/db_helper.dart';
import '../../Database/order_panel_db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Helper/api_response.dart';
import '../../Models/Assets/asset_model.dart';
import '../../Models/Auth/shift_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Auth/logout_repository.dart';
import '../../Repositories/Auth/shift_repository.dart';
import '../../Widgets/SafeStorageHelper.dart';
import '../../Widgets/widget_alert_popup_dialogs.dart';
import '../../Widgets/widget_custom_num_pad.dart';
import '../../Widgets/widget_topbar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../Auth/login_screen.dart';
import 'pos_home_screen.dart';

class ShiftOpenCloseBalanceScreen extends StatefulWidget {
  final int? lastSelectedIndex;
  const ShiftOpenCloseBalanceScreen(
      {super.key, this.lastSelectedIndex});

  @override
  State<ShiftOpenCloseBalanceScreen> createState() => _ShiftOpenCloseBalanceScreenState();
}

class _ShiftOpenCloseBalanceScreenState extends State<ShiftOpenCloseBalanceScreen> with LayoutSelectionMixin {

  bool isLoading = true;

  int _selectedSidebarIndex = 3;

  // Build #1.0.70: Added new variables to store fetched denominations
  List<Denom> _notesDenominations = [];
  List<Denom> _coinsDenominations = [];
  //store values
  String? _shiftId;
  String screenTitle = TextConstants.shiftOpen;
  String? _originScreen;
  final PinakaPreferences _preferences = PinakaPreferences(); // Added this
  late ShiftBloc _shiftBloc;
  double totalAmount = 0.0;
  double cashTubes = 0.0;
  double cashNotesCoin = 0.0;
  // List to store denomination data
  final List<Map<String, dynamic>> denominations = [];
  StreamSubscription? _shiftSubscription;
  bool _isSubmitting = false;
  final logoutBloc = LogoutBloc(LogoutRepository());
  bool _isSafeEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadSafeEnable();
    _shiftBloc = ShiftBloc(ShiftRepository());
    _selectedSidebarIndex = widget.lastSelectedIndex ?? 4; // Build #1.0.7: Restore previous selection
    _checkShiftId();
    WidgetsBinding.instance.addPostFrameCallback((_) {  // Build #1.0.70
      _checkPreviousScreen();
    });
    // Fetch notes and coins denominations from AssetDBHelper
    _fetchDenominations();

    // Simulate a loading delay
    Future.delayed(const Duration(seconds: 3), () {
      if(mounted) { /// add to fix memory leaks
        setState(() {
          isLoading = false; // Set loading to false after 3 seconds
        });
      }
    });

    // Build #1.0.70: Add listeners to update totals when text changes
    _controllers.forEach((denom, controller) {
      controller.addListener(() => _updateTotal(denom, controller));
    });

    // Add listeners to update totals when text changes - Coins
    _coinControllers.forEach((denom, controller) {
      controller.addListener(() => _updateCoinTotal(denom, controller));
    });
  }

  Future<void> _loadSafeEnable() async {
    _isSafeEnabled = await SafeStorageHelper.getSafeEnable();
    if (mounted) setState(() {});
  }

  // Build #1.0.70: New method to reset state
  void _resetState() {
    if (kDebugMode) {
      print("Resetting ShiftOpenCloseBalanceScreen state");
    }
    _clearCounts();
    _controllers.forEach((key, controller) => controller.clear());
    _coinControllers.forEach((key, controller) => controller.clear());
    setState(() {
      _noteTotals.updateAll((key, value) => 0.0);
      _coinTotals.updateAll((key, value) => 0.0);
      _grandTotal = 0.0;
    });
  }

  Future<void> _checkShiftId() async {  // Build #1.0.70

    /// ADDED TESTING PURPOSE -> REMOVE
    // final prefs = await SharedPreferences.getInstance();
    // await prefs.remove(TextConstants.shiftId);

    int? shiftId = await UserDbHelper().getUserShiftId(); // Build #1.0.149 : using from db
    if (shiftId != null) {
      _shiftId = shiftId.toString();
    }
    if (kDebugMode) {
      print("#### _checkShiftId: $_shiftId");
    }
  }

  // Build #1.0.70: Added _checkPreviousScreen method
  void _checkPreviousScreen() {
    final previousScreen = ModalRoute.of(context)?.settings.arguments as String?;
    _originScreen = previousScreen;
    if (previousScreen == TextConstants.navLogout) {
      setState(() {
        screenTitle = TextConstants.shiftClose;
      });
    } else if (previousScreen == TextConstants.navShiftHistory) { //Build #1.0.74
      setState(() {
        screenTitle = TextConstants.shiftBal;
      });
    }
  }

  // Build #1.0.70: Method to fetch denominations from AssetDBHelper
  Future<void> _fetchDenominations() async {
    if (kDebugMode) {
      print("Fetching denominations from AssetDBHelper...");
    }
    _notesDenominations = await AssetDBHelper.instance.getNotesDenomList();
    _coinsDenominations = await AssetDBHelper.instance.getCoinDenomList();

    if (kDebugMode) {
      print("Fetched Notes Denominations: $_notesDenominations");
      print("Fetched Coins Denominations: $_coinsDenominations");
    }

    // Add dummy denominations for testing (12 more to reach 20 total)
    // _notesDenominations.addAll([
    //   Denom(denom: "500", image: 'assets/svg/500_note.svg'),
    //   Denom(denom: "200", image: 'assets/svg/200_note.svg'),
    //   Denom(denom: "1000", image: 'assets/svg/1000_note.svg'),
    //   Denom(denom: "2000", image: 'assets/svg/2000_note.svg'),
    //   Denom(denom: "5000", image: 'assets/svg/5000_note.svg'),
    //   Denom(denom: "10000", image: 'assets/svg/10000_note.svg'),
    //   Denom(denom: "0.01", image: 'assets/svg/1_cent.svg'),
    //   Denom(denom: "0.02", image: 'assets/svg/2_cent.svg'),
    //   Denom(denom: "0.20", image: 'assets/svg/20_cent.svg'),
    //   Denom(denom: "1.00", image: 'assets/svg/1_dollar_coin.svg'),
    //   Denom(denom: "2.00", image: 'assets/svg/2_dollar_coin.svg'),
    //   Denom(denom: "5.00", image: 'assets/svg/5_dollar_coin.svg'),
    // ]);
    setState(() {
      // Initialize controllers and totals dynamically based on fetched denominations
      _notesDenominations.forEach((denom) {
        if (kDebugMode) {
          print("###### _notesDenominations image: ${denom.image}");
        }
        _coinDenominations[denom.denom.toString()] = double.parse(denom.denom);
        _noteTotals[denom.denom.toString()] = 0.0;
        _controllers[denom.denom.toString()] = TextEditingController();
        _controllers[denom.denom.toString()]!.addListener(() => _updateTotal(denom.denom.toString(), _controllers[denom.denom.toString()]!));
      });

      _coinsDenominations.forEach((denom) {
        if (kDebugMode) {
          print("###### _coinsDenominations image: ${denom.image}");
        }
        _coinDenominations[denom.denom.toString()] = double.parse(denom.denom);
        _coinTotals[denom.denom.toString()] = 0.0;
        _coinControllers[denom.denom.toString()] = TextEditingController();
        _coinControllers[denom.denom.toString()]!.addListener(() => _updateCoinTotal(denom.denom.toString(), _coinControllers[denom.denom.toString()]!));
      });
    });
  }

  final TextEditingController _note100Controller = TextEditingController();
  final TextEditingController _note50Controller = TextEditingController();
  final TextEditingController _note20Controller = TextEditingController();
  final TextEditingController _note10Controller = TextEditingController();
  final TextEditingController _note5Controller = TextEditingController();
  final TextEditingController _note2Controller = TextEditingController();
  final TextEditingController _note1Controller = TextEditingController();

  // Coin Controllers
  final TextEditingController _coin50Controller = TextEditingController();
  final TextEditingController _coin25Controller = TextEditingController();
  final TextEditingController _coin10Controller = TextEditingController();
  final TextEditingController _coin5Controller = TextEditingController();

  // Build #1.0.70: Added maps to manage controllers dynamically
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, TextEditingController> _coinControllers = {};

  // Maps to hold note values and their corresponding totals
  final Map<String, double> _noteDenominations = {
    '100': 100.0,
    '50': 50.0,
    '20': 20.0,
    '10': 10.0,
    '5': 5.0,
    '2': 2.0,
    '1': 1.0,
  };

  final Map<String, double> _noteTotals = {
    '100': 0.0,
    '50': 0.0,
    '20': 0.0,
    '10': 0.0,
    '5': 0.0,
    '2': 0.0,
    '1': 0.0,
  };

  // Maps to hold coin values and their corresponding totals
  final Map<String, double> _coinDenominations = {
    '0.50': 0.50,
    '0.25': 0.25,
    '0.10': 0.10,
    '0.05': 0.05,
  };

  final Map<String, double> _coinTotals = {
    '0.50': 0.0,
    '0.25': 0.0,
    '0.10': 0.0,
    '0.05': 0.0,
  };

  double _grandTotal = 0.0;

  void _updateTotal(String denomination, TextEditingController controller) {
    setState(() {
      final int count = int.tryParse(controller.text) ?? 0;
      final double value = double.tryParse(denomination) ?? 0.0;

      _noteTotals[denomination] = count * value;
      _calculateGrandTotal();
    });
  }

  void _updateCoinTotal(String denomination, TextEditingController controller) {
    setState(() {
      final int count = int.tryParse(controller.text) ?? 0;
      final double value = double.tryParse(denomination) ?? 0.0;

      _coinTotals[denomination] = count * value;
      _calculateGrandTotal();
    });
  }


  ShiftRequest _buildShiftRequest({int? shiftId, String? status}) {
    List<Denomination> drawerDenoms = [];

    _notesDenominations.forEach((denom) {
      int count = int.tryParse(_controllers[denom.denom.toString()]?.text ?? '0') ?? 0;
      drawerDenoms.add(Denomination(denomination: num.tryParse(denom.denom.toString()) ?? 0, denomCount: count));
    });
    _coinsDenominations.forEach((denom) {
      int count = int.tryParse(_coinControllers[denom.denom.toString()]?.text ?? '0') ?? 0;
      drawerDenoms.add(Denomination(denomination: num.tryParse(denom.denom.toString()) ?? 0, denomCount: count));
    });

    List<TubeDenomination> tubeDenoms = [];
    denominations.forEach((denom) {
      tubeDenoms.add(TubeDenomination(
        denomination: denom['denomValue'],
        tubeCount: denom['tubeCount'],
        cellCount: denom['tubeCount'],
        total: denom['amount'],
      ));
    });

    return ShiftRequest(
      shiftId: shiftId,
      status: status,
      drawerDenominations: drawerDenoms,
      drawerTotalAmount: cashNotesCoin,
      tubeDenominations: tubeDenoms,
      tubeTotalAmount: cashTubes,
      totalAmount: totalAmount,
    );
  }

  Future<void> _handleShiftSubmit({bool navigateNext = false}) async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    try {
      int? shiftId = await UserDbHelper().getUserShiftId();
      String? previousScreen = _originScreen;

      String status = TextConstants.open;
      String? closeShiftStatus;

      if (shiftId != null) {
        if (previousScreen == TextConstants.navLogout) {
          status = TextConstants.update;
          closeShiftStatus = TextConstants.closed;
        } else if (previousScreen == TextConstants.navShiftHistory) {
          status = TextConstants.update;
        }
      }

      await _shiftSubscription?.cancel();

      final request = _buildShiftRequest(
        shiftId: shiftId,
        status: status,
      );

      _shiftBloc.manageShift(request);

      bool dialogShown = false;

      _shiftSubscription = _shiftBloc.shiftStream.listen((response) async {
        if (!mounted || dialogShown) return;

        if (response.status == Status.COMPLETED) {
          dialogShown = true;
          setState(() => _isSubmitting = false);

          // ---------------- OPEN / UPDATE ----------------
          if (closeShiftStatus == null) {
            bool? result;

            if (status == TextConstants.open) {
              await UserDbHelper()
                  .updateUserShiftId(response.data!.shiftId);

              result = await CustomDialog.showStartShiftVerification(
                context,
                totalAmount: totalAmount,
                overShort: response.data!.overShort.toDouble(),
              );
            } else {
              result = await CustomDialog.showUpdateShiftVerification(
                context,
                totalAmount: totalAmount,
                overShort: response.data!.overShort.toDouble(),
              );
            }

            if (result == true && mounted) {
              _resetState();
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => POSHomeScreen()),
                    (_) => false,
              );
            }
            return;
          }

          // ---------------- CLOSE SHIFT ----------------
          bool? confirmClose =
          await CustomDialog.showCloseShiftVerification(
            context,
            totalAmount: totalAmount,
            overShort: response.data!.overShort.toDouble(),
          );

          if (confirmClose != true) return;

          // Show loader dialog
          CustomDialog.showCloseShiftVerification(
            context,
            totalAmount: totalAmount,
            overShort: response.data!.overShort.toDouble(),
            isLoading: true,
          );

          await _shiftSubscription?.cancel();

          final closeRequest = _buildShiftRequest(
            shiftId: shiftId,
            status: TextConstants.closed,
          );
          _calculateGrandTotal();


          _shiftBloc.manageShift(closeRequest);

          _shiftSubscription = _shiftBloc.shiftStream.listen((closeResponse) async {
            if (closeResponse.status == Status.COMPLETED) {
              // if (mounted) Navigator.of(context).pop(); // close loader
              await UserDbHelper().updateUserShiftId(null);

              logoutBloc.performLogout();


              StreamSubscription? logoutSub;
              logoutSub = logoutBloc.logoutStream.listen((logoutResponse) {
                if (logoutResponse.status == Status.COMPLETED && mounted) {
                  logoutSub?.cancel();
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => LoginScreen()),
                  );
                }
              });
            }
          });
        }

        if (response.status == Status.ERROR) {
          setState(() => _isSubmitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(TextConstants.failedToUpdateShift),
              backgroundColor: Colors.red,
            ),
          );
        }
      });
    } catch (e) {
      setState(() => _isSubmitting = false);
      if (kDebugMode) print("Submit error: $e");
    }
  }


  void _calculateGrandTotal() {
    final double noteTotal =
    _noteTotals.values.fold(0.0, (a, b) => a + b);

    final double coinTotal =
    _coinTotals.values.fold(0.0, (a, b) => a + b);

    cashNotesCoin = noteTotal + coinTotal;
    totalAmount = cashNotesCoin + cashTubes;
    _grandTotal = cashNotesCoin;

    if (kDebugMode) {
      print("🧮 Notes: $noteTotal");
      print("🧮 Coins: $coinTotal");
      print("🧮 Drawer: $cashNotesCoin");
      print("🧮 Tubes: $cashTubes");
      print("🧮 TOTAL: $totalAmount");
    }
  }


  void _clearCounts() {
    _controllers.forEach((key, controller) => controller.clear());
    _coinControllers.forEach((key, controller) => controller.clear());

    setState(() {
      _noteTotals.updateAll((key, value) => 0.0);
      _coinTotals.updateAll((key, value) => 0.0);
      _grandTotal = 0.0;
    });
    if (kDebugMode) {
      print("Cleared all counts and totals.");
    }
  }

  TextEditingController _getControllerForDenomination(String denomination) {
    return _controllers[denomination] ?? TextEditingController();
  }

  TextEditingController _getControllerForCoinDenomination(String denomination) {
    return _coinControllers[denomination] ?? TextEditingController();
  }


  @override
  void dispose() {
    _shiftSubscription?.cancel(); // ✅ ADD THIS
    _shiftBloc.dispose();
    _note100Controller.dispose();
    _note50Controller.dispose();
    _note20Controller.dispose();
    _note10Controller.dispose();
    _note5Controller.dispose();
    _note2Controller.dispose();
    _note1Controller.dispose();
    _coin5Controller.dispose();
    _coin50Controller.dispose();
    _coin25Controller.dispose();
    _coin10Controller.dispose();
    _controllers.forEach((key, controller) => controller.dispose());
    _coinControllers.forEach((key, controller) => controller.dispose());
    super.dispose();
  }

  // Build #1.0.70: Load API and assets images func
  Widget _loadSvg(String path, double height, double width) {
    if (path.startsWith('http')) {
      return SvgPicture.network(
        path,
        height: height,
        width: width,
        placeholderBuilder: (context) => SvgPicture.asset(
          'assets/svg/1.svg', // Your fallback asset
          height: height,
          width: width,
        ),
      );
    } else {
      return SvgPicture.asset(
        path,
        height: height,
        width: width,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final previousScreen = ModalRoute.of(context)?.settings.arguments as String?; //Build #1.0.74
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopBar(
              screen: Screen.SHIFT,
              onModeChanged: () async{ /// Build #1.0.192: Fixed -> Exception -> setState() callback argument returned a Future. (onModeChanged in all screens)
                String newLayout;
                if (sidebarPosition == SidebarPosition.left) {
                  newLayout = SharedPreferenceTextConstants.navRightOrderLeft;
                } else if (sidebarPosition == SidebarPosition.right) {
                  newLayout = SharedPreferenceTextConstants.navBottomOrderLeft;
                } else {
                  newLayout = orderPanelPosition == OrderPanelPosition.left
                      ? SharedPreferenceTextConstants.navBottomOrderRight
                      : SharedPreferenceTextConstants.navLeftOrderRight;
                }

                // Update the notifier which will trigger _onLayoutChanged
                PinakaPreferences.layoutSelectionNotifier.value = newLayout;
                // No need to call saveLayoutSelection here as it's handled in the notifier
                //  _preferences.saveLayoutSelection(newLayout);
                //Build #1.0.122: update layout mode change selection to DB
                await UserDbHelper().saveUserSettings({AppDBConst.layoutSelection: newLayout}, modeChange: true);
                // update UI
                setState(() {});
              },
            ),
            Divider(
              color: Colors.grey, // Light grey color
              thickness: 0.4, // Very thin line
              height: 1, // Minimal height
            ),
            Expanded(
              child: Row(
                children: [
                  if (sidebarPosition == SidebarPosition.left)
                    custom_widgets.NavigationBar(
                      selectedSidebarIndex: _selectedSidebarIndex,
                      onSidebarItemSelected: (index) {
                        setState(() {
                          _selectedSidebarIndex = index;
                        });
                      },
                      isVertical: true,
                      isShiftScreen: true, // 🔥 THIS FIXES HEIGHT JUMP
                    ),


                  Expanded(
                      child: Padding(
                          padding: EdgeInsets.fromLTRB(8, 12, 12, 12),
                          child: Container(
                            height: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              color: themeHelper.themeMode == ThemeMode.dark
                                  ? ThemeNotifier.primaryBackground : Colors.white,
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16,right: 16,left: 16),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              screenTitle,
                                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                            ),
                                            // const SizedBox(height: 4),
                                            const Text(
                                              TextConstants.shiftSubTitle,
                                              style: TextStyle(fontSize: 12, color: Colors.grey),
                                            ),
                                          ],
                                        ),
                                        // Bottom buttons - Removed "Back" button
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.end,
                                          children: [
                                            SizedBox(  // Build #1.0.70: updated code
                                              height: MediaQuery.of(context).size.height * 0.06,
                                              width: MediaQuery.of(context).size.width * 0.1,
                                              child: OutlinedButton(
                                                onPressed: ((_shiftId == null || _shiftId!.isEmpty) && (previousScreen != TextConstants.navCashier)) ? null : () {

                                                  // Build #1.0.221 : Fixed Issue
                                                  // enable back button for close and update time and show "are you sure ? " dialog then exit to fast key screen
                                                  CustomDialog.showAreYouSure(
                                                    context,
                                                    confirm: () {
                                                      if (kDebugMode) {
                                                        print("##### DEBUG Back Button confirm Tapped");
                                                      }
                                                      //  Navigator.pop(context); // Close the dialog
                                                      // Use a slight delay to ensure dialog is fully closed before navigating
                                                      Future.delayed(Duration(milliseconds: 100), () {
                                                        Navigator.push(
                                                          context,
                                                          MaterialPageRoute(builder: (context) => POSHomeScreen(lastSelectedIndex: 0)),
                                                        );
                                                      });
                                                    },
                                                    description: TextConstants.areYouSureExitShiftDescription,
                                                    confirmText: TextConstants.yesExit,
                                                    cancelText: TextConstants.noStay,
                                                  );
                                                },
                                                style: OutlinedButton.styleFrom(
                                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                                  side: BorderSide(
                                                    color: ((_shiftId == null || _shiftId!.isEmpty) && (previousScreen != TextConstants.navCashier))
                                                        ? Colors.grey.shade400 // Greyed-out border when disabled
                                                        : Colors.grey.shade300, // Active border
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  foregroundColor: ((_shiftId == null || _shiftId!.isEmpty) && (previousScreen != TextConstants.navCashier))
                                                      ? Colors.grey.shade400  // Greyed-out text when disabled
                                                      : Colors.blueGrey, // Active text color
                                                  backgroundColor: ((_shiftId == null || _shiftId!.isEmpty) && (previousScreen != TextConstants.navCashier))
                                                      ? Colors.grey.shade100 // Subtle background when disabled
                                                      : Colors.transparent, // No background when active
                                                ),
                                                child: Text(
                                                  TextConstants.backText,
                                                  style: TextStyle(
                                                    color: (_shiftId == null || _shiftId!.isEmpty)
                                                        ? Colors.grey.shade400 // Greyed-out text
                                                        :  themeHelper.themeMode == ThemeMode.dark
                                                        ? ThemeNotifier.textDark : Colors.blueGrey, // Active text
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 20),
                                            SizedBox(
                                              height: MediaQuery.of(context).size.height * 0.06,
                                              width: MediaQuery.of(context).size.width * 0.1,
                                              child: ElevatedButton(  // Build #1.0.70
                                                // onPressed: () {
                                                //   // Add this line to close the keypad
                                                //   FocusScope.of(context).unfocus();
                                                //   // Next button action - Pass the grand total to SafeOpenScreen
                                                //   Navigator.push(
                                                //     context,
                                                //     SlideRightRoute(
                                                //       page: SafeOpenScreen(
                                                //         cashNotesCoins: _grandTotal,
                                                //         previousScreen: _originScreen ?? TextConstants.navShiftHistory, //Build #1.0.74
                                                //       ),
                                                //       arguments: TextConstants.navShiftHistory, // Build #1.0.226: Fixed Issue -> Menu items are not disabled in shift closing/update time in second screen
                                                //     ),
                                                //   ).then((_) {
                                                //     // Reset state when returning
                                                //     // _resetState();
                                                //   });
                                                // },

                                                // onPressed: () async {
                                                //   FocusScope.of(context).unfocus();
                                                //
                                                //   await _handleShiftSubmit(navigateNext: true);
                                                // },

                                                onPressed: () async {
                                                  FocusScope.of(context).unfocus();

                                                  if (_isSafeEnabled) {
                                                    // ✅ SAFE ENABLE = 1 → go to SafeOpenScreen
                                                    Navigator.push(
                                                      context,
                                                      SlideRightRoute(
                                                        page: SafeOpenScreen(
                                                          cashNotesCoins: _grandTotal,
                                                          previousScreen:
                                                          _originScreen ?? TextConstants.navShiftHistory,
                                                        ),
                                                        arguments: TextConstants.navShiftHistory,
                                                      ),
                                                    );
                                                  } else {
                                                    // ❌ SAFE NOT ENABLED → normal flow
                                                    await _handleShiftSubmit(navigateNext: true);
                                                  }
                                                },

                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Color(0xFFFF6B6B),
                                                  foregroundColor: Colors.white,
                                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                ),
                                                child: const Text('Submit',
                                                    style: TextStyle(
                                                        fontSize: 16)),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        margin: EdgeInsets.only(left: 16, right: 8),
                                        padding: EdgeInsets.all(8),
                                        width: MediaQuery.of(context).size.width * 0.425,
                                        height: sidebarPosition == SidebarPosition.bottom
                                            ? MediaQuery.of(context).size.height * 0.625  // Reduced height for bottom nav
                                            :MediaQuery.of(context).size.height * 0.7,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(5),
                                          color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.secondaryBackground :  Colors.grey.shade100,
                                          boxShadow:[
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.1),
                                              blurRadius: 2,
                                              spreadRadius: 2,
                                              offset: const Offset(0, 0),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.center,
                                          children: [
                                            const Text(
                                              TextConstants.notes,
                                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                            ).poppins(),
                                            const SizedBox(height: 5),

                                            // Table headers
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Expanded(
                                                  flex: 2,
                                                  child: Text(
                                                    TextConstants.type,
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.w500,
                                                      color: themeHelper.themeMode == ThemeMode.dark
                                                          ? ThemeNotifier.textDark : Colors.grey[700],
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 3,
                                                  child: Text(
                                                    TextConstants.noOfNotes,
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.w500,
                                                      color:  themeHelper.themeMode == ThemeMode.dark
                                                          ? ThemeNotifier.textDark : Colors.grey[700],
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 3,
                                                  child: Text(
                                                    TextConstants.totalAmountText,
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.w500,
                                                      color: themeHelper.themeMode == ThemeMode.dark
                                                          ? ThemeNotifier.textDark : Colors.grey[700],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            Divider(
                                              color: Colors.grey.shade300,
                                            ),

                                            // Note rows - Use fetched denominations
                                            Expanded(
                                              child: ListView.builder(
                                                // scrollDirection: Axis.vertical,
                                                // physics: AlwaysScrollableScrollPhysics(),
                                                // children: _notesDenominations.map((denom) {
                                                //   String denomination = denom.denom.toString();
                                                itemCount: _notesDenominations.length,
                                                physics: const AlwaysScrollableScrollPhysics(),
                                                padding: EdgeInsets.zero, // Remove default padding
                                                itemBuilder: (context, index) {
                                                  final denom = _notesDenominations[index];
                                                  String denomination = denom.denom.toString();
                                                  return Padding(
                                                    padding: const EdgeInsets.symmetric(vertical: 7.0, horizontal: 7.0),
                                                    child: Row(
                                                      children: [
                                                        _loadSvg(
                                                          denom.image ?? 'assets/svg/1.svg',
                                                          24,
                                                          24,
                                                        ),
                                                        Padding(
                                                          padding: EdgeInsets.symmetric(horizontal: 12.0),
                                                          child: Text(
                                                            '×',
                                                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.normal, color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.textDark : Colors.grey),
                                                          ),
                                                        ),
                                                        Container(
                                                          height: MediaQuery.of(context).size.height * 0.06,
                                                          width: MediaQuery.of(context).size.width * 0.15,
                                                          decoration: BoxDecoration(
                                                              shape: BoxShape.rectangle,
                                                              border: Border.all(color:  themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.borderColor : Colors.grey.shade300),
                                                              borderRadius: BorderRadius.circular(5),
                                                              color:  themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.paymentEntryContainerColor :Colors.white
                                                          ),
                                                          child: TextField(
                                                            controller: _getControllerForDenomination(denomination),
                                                            keyboardType: TextInputType.number,
                                                            textInputAction: TextInputAction.next,
                                                            inputFormatters: [
                                                              FilteringTextInputFormatter.digitsOnly,
                                                            ],
                                                            onSubmitted: (value){
                                                              FocusScope.of(context).nextFocus();
                                                            },
                                                            decoration: InputDecoration(
                                                              hintText: '0',
                                                              hintStyle: TextStyle(color: themeHelper.themeMode == ThemeMode.dark
                                                                  ? ThemeNotifier.textDark : Colors.grey),
                                                              border: InputBorder.none,
                                                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9.0),
                                                            ),
                                                          ),
                                                        ),
                                                        Padding(
                                                          padding: EdgeInsets.symmetric(horizontal: 12.0),
                                                          child: Text(
                                                            '=',
                                                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color:  themeHelper.themeMode == ThemeMode.dark
                                                                ? ThemeNotifier.textDark : Colors.grey),
                                                          ),
                                                        ),
                                                        Container(
                                                          height: MediaQuery.of(context).size.height * 0.06,
                                                          width: MediaQuery.of(context).size.width * 0.15,
                                                          alignment: Alignment.centerRight,
                                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                                          decoration: BoxDecoration(
                                                            border: Border.all(color:  themeHelper.themeMode == ThemeMode.dark
                                                                ? ThemeNotifier.borderColor : Colors.grey.shade400),
                                                            borderRadius: BorderRadius.circular(4),
                                                            color:  themeHelper.themeMode == ThemeMode.dark
                                                                ? ThemeNotifier.orderPanelTabBackground :Colors.grey.shade300,
                                                          ),
                                                          child: Text(
                                                            '${TextConstants.currencySymbol}${_noteTotals[denomination]!.toStringAsFixed(2)}',
                                                            style: TextStyle(
                                                              fontSize: 16,
                                                              color:  themeHelper.themeMode == ThemeMode.dark
                                                                  ? ThemeNotifier.textDark : Colors.grey,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Coins Container and Total Section
                                      Column(
                                        mainAxisAlignment: MainAxisAlignment.start,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          // Coins Container
                                          Container(
                                            margin: EdgeInsets.only(left: 16, right: 8),
                                            padding: EdgeInsets.all(8),
                                            width: MediaQuery.of(context).size.width * 0.425,
                                            height: sidebarPosition == SidebarPosition.bottom
                                                ? MediaQuery.of(context).size.height * 0.45  // Reduced height for bottom nav
                                                :MediaQuery.of(context).size.height * 0.45,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(5),
                                              color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.secondaryBackground : Colors.grey.shade100,
                                              boxShadow:[
                                                BoxShadow(
                                                  color: Colors.black.withValues(alpha: 0.1),
                                                  blurRadius: 2,
                                                  spreadRadius: 2,
                                                  offset: const Offset(0, 0),
                                                ),
                                              ],
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.center,
                                              children: [
                                                const Text(
                                                  TextConstants.coins,
                                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                                ).poppins(),
                                                const SizedBox(height: 5),

                                                // Table headers
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  crossAxisAlignment: CrossAxisAlignment.center,
                                                  children: [
                                                    Expanded(
                                                      flex:2,
                                                      child: Text(
                                                        TextConstants.type,
                                                        style: TextStyle(
                                                          fontWeight: FontWeight.w500,
                                                          color: themeHelper.themeMode == ThemeMode.dark
                                                              ? ThemeNotifier.textDark : Colors.grey[700],
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      flex: 3,
                                                      child: Text(
                                                        TextConstants.noOfCoins,
                                                        style: TextStyle(
                                                          fontWeight: FontWeight.w500,
                                                          color: themeHelper.themeMode == ThemeMode.dark
                                                              ? ThemeNotifier.textDark : Colors.grey[700],
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      flex: 3,
                                                      child: Text(
                                                        TextConstants.totalAmountText,
                                                        style: TextStyle(
                                                          fontWeight: FontWeight.w500,
                                                          color: themeHelper.themeMode == ThemeMode.dark
                                                              ? ThemeNotifier.textDark : Colors.grey[700],
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                Divider(
                                                  color: Colors.grey.shade300,
                                                ),

                                                // Coin rows - Use fetched denominations
                                                Expanded(
                                                  child: ListView.builder(
                                                    itemCount: _coinsDenominations.length,
                                                    physics: const AlwaysScrollableScrollPhysics(),
                                                    padding: EdgeInsets.zero, // Remove default padding
                                                    itemBuilder: (context, index) {
                                                      final denom = _coinsDenominations[index];
                                                      String denomination = denom.denom.toString();

                                                      // scrollDirection: Axis.vertical,
                                                      // physics: AlwaysScrollableScrollPhysics(),
                                                      // children: _coinsDenominations.map((denom) {
                                                      //   String denomination = denom.denom.toString();
                                                      return Padding(
                                                        padding: const EdgeInsets.symmetric(vertical: 7.0, horizontal: 7.0),
                                                        child: Row(
                                                          children: [
                                                            _loadSvg(
                                                              denom.image ?? 'assets/svg/50_cents.svg',
                                                              24,
                                                              24,
                                                            ),
                                                            Padding(
                                                              padding: const EdgeInsets.symmetric(horizontal: 12.0),
                                                              child: Text(
                                                                '×',
                                                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.normal, color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.textDark : Colors.grey),
                                                              ),
                                                            ),
                                                            Container(
                                                              height: MediaQuery.of(context).size.height * 0.06,
                                                              width: MediaQuery.of(context).size.width * 0.15,
                                                              decoration: BoxDecoration(
                                                                  shape: BoxShape.rectangle,
                                                                  border: Border.all(color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.borderColor : Colors.grey.shade300),
                                                                  borderRadius: BorderRadius.circular(5),
                                                                  color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.paymentEntryContainerColor : Colors.white
                                                              ),
                                                              child: TextField(
                                                                controller: _getControllerForCoinDenomination(denomination),
                                                                keyboardType: TextInputType.number,
                                                                textInputAction: TextInputAction.next, // This adds the "Enter" button
                                                                inputFormatters: [
                                                                  FilteringTextInputFormatter.digitsOnly,
                                                                ],
                                                                onSubmitted: (value) {
                                                                  FocusScope.of(context).nextFocus();
                                                                },
                                                                decoration: InputDecoration(
                                                                  hintText: '0',
                                                                  hintStyle: TextStyle(color: themeHelper.themeMode == ThemeMode.dark
                                                                      ? ThemeNotifier.textDark : Colors.grey),
                                                                  border: InputBorder.none,
                                                                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9.0),
                                                                ),
                                                              ),
                                                            ),
                                                            Padding(
                                                              padding: const EdgeInsets.symmetric(horizontal: 12.0),
                                                              child: Text(
                                                                '=',
                                                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.textDark : Colors.grey),
                                                              ),
                                                            ),
                                                            Container(
                                                              height: MediaQuery.of(context).size.height * 0.06,
                                                              width: MediaQuery.of(context).size.width * 0.15,
                                                              alignment: Alignment.centerRight,
                                                              padding: const EdgeInsets.symmetric(horizontal: 8),
                                                              decoration: BoxDecoration(
                                                                border: Border.all(color: themeHelper.themeMode == ThemeMode.dark
                                                                    ? ThemeNotifier.borderColor : Colors.grey.shade400),
                                                                borderRadius: BorderRadius.circular(4),
                                                                color: themeHelper.themeMode == ThemeMode.dark
                                                                    ? ThemeNotifier.orderPanelTabBackground : Colors.grey.shade300,
                                                              ),
                                                              child: Text(
                                                                '${TextConstants.currencySymbol}${_coinTotals[denomination]!.toStringAsFixed(2)}',
                                                                style: TextStyle(
                                                                  fontSize: 16,
                                                                  color: themeHelper.themeMode == ThemeMode.dark
                                                                      ? ThemeNotifier.textDark : Colors.grey,
                                                                  fontWeight: FontWeight.bold,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          SizedBox(
                                            height: 10,
                                          ),
                                          TextButton(
                                            onPressed: _clearCounts,
                                            style: TextButton.styleFrom(
                                              foregroundColor: Colors.red,
                                              side: const BorderSide(color: Colors.grey),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                            ),
                                            child: const Text('CLEAR COUNTS'),
                                          ),
                                          SizedBox(
                                            height: 5,
                                          ),
                                          Row(
                                            children: [
                                              const Text(
                                                TextConstants.totalAmount,
                                                style: TextStyle(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              Container(
                                                height: MediaQuery.of(context).size.height * 0.06,
                                                width: MediaQuery.of(context).size.width * 0.25,
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                                decoration: BoxDecoration(
                                                  border: Border.all(color: Colors.grey.shade300),
                                                  borderRadius: BorderRadius.circular(5),
                                                ),
                                                alignment: Alignment.centerRight,
                                                child: Text(
                                                  '${TextConstants.currencySymbol}${_grandTotal.toStringAsFixed(2)}',
                                                  style: TextStyle(
                                                      fontSize: 18,
                                                      fontWeight: FontWeight.bold,
                                                      color: themeHelper.themeMode == ThemeMode.dark
                                                          ? ThemeNotifier.textDark : Colors.grey
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          )
                      )
                  ),

                  // Right Sidebar (Conditional)
                  if (sidebarPosition == SidebarPosition.right)
                    custom_widgets.NavigationBar(
                      //Build #1.0.4 : Updated class name LeftSidebar to NavigationBar
                      selectedSidebarIndex: _selectedSidebarIndex,
                      onSidebarItemSelected: (index) {
                        setState(() {
                          _selectedSidebarIndex = index;
                        });
                      },
                      isVertical: true,
                      isShiftScreen: true,// Vertical layout for right sidebar
                    ),
                ],
              ),
            ),
            // Bottom Sidebar (Conditional)
            if (sidebarPosition == SidebarPosition.bottom)
              custom_widgets.NavigationBar(
                //Build #1.0.4 : Updated class name LeftSidebar to NavigationBar
                selectedSidebarIndex: _selectedSidebarIndex,
                onSidebarItemSelected: (index) {
                  setState(() {
                    _selectedSidebarIndex = index;
                  });
                },
                isVertical: false,
                isShiftScreen: true,// Horizontal layout for bottom sidebar
              ),
          ],
        ),
      ),
    );
  }
}

class SlideRightRoute extends PageRouteBuilder {
  final Widget page;
  final String arguments; // Build #1.0.226: Added this parameter
  SlideRightRoute({required this.page, this.arguments = ''})
      : super(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: const Duration(milliseconds: 1000), // Control the speed
    reverseTransitionDuration: const Duration(milliseconds: 1000),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      const begin = Offset(1.0, 0.0); // Start position (from the right)
      const end = Offset.zero; // End position (center)
      const curve = Curves.easeInOut;

      var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
      var offsetAnimation = animation.drive(tween);

      return SlideTransition(
        position: offsetAnimation,
        child: child,
      );
    },
    settings: RouteSettings(arguments: arguments), // Build #1.0.226: Fixed Issue -> Menu items are not disabled in shift closing/update time in second screen
  );
}
