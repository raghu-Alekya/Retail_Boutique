import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pinaka_pos/Helper/Extentions/text_extensions.dart';
import 'package:pinaka_pos/Screens/Home/shift_history_dashboard_screen.dart';
import 'package:provider/provider.dart';
import '../../Blocs/Auth/shift_bloc.dart';
import '../../Blocs/Auth/vendor_payment_bloc.dart';
import '../../Constants/misc_features.dart';
import '../../Constants/text.dart';
import '../../Database/assets_db_helper.dart';
import '../../Database/db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Helper/api_response.dart';
import '../../Models/Assets/asset_model.dart';
import '../../Models/Auth/shift_summary_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Auth/shift_repository.dart';
import '../../Repositories/Auth/vendor_payment_repository.dart';
import '../../Widgets/widget_add_vendor_payout_dialog.dart';
import '../../Widgets/widget_alert_popup_dialogs.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../../Widgets/widget_topbar.dart';
import '../Auth/login_screen.dart';

class ShiftSummaryDashboardScreen extends StatefulWidget {
  final int? lastSelectedIndex;
  final int? shiftId;

  const ShiftSummaryDashboardScreen({
    super.key,
    this.lastSelectedIndex,
    this.shiftId,
  });

  @override
  State<ShiftSummaryDashboardScreen> createState() => _ShiftSummaryDashboardScreenState();
}

class _ShiftSummaryDashboardScreenState extends State<ShiftSummaryDashboardScreen> with LayoutSelectionMixin {
  int _selectedSidebarIndex = 4;
  late ShiftBloc shiftBloc;
  late VendorPaymentBloc vendorPaymentBloc;
  List<Vendor> _vendors = []; //Build #1.0.74
  List<String> _paymentTypes = [];
  List<String> _purposes = [];
  final PinakaPreferences _preferences = PinakaPreferences(); // Added this

  //state variables for API response and subscription
  APIResponse<ShiftByIdResponse>? apiResponse;
  StreamSubscription? _shiftSubscription; // build 1.0.206 We changed the code to store the shift summary data within the screen's state,
  // which prevents the UI from getting stuck on a loading indicator after you change the display mode.



  @override
  void initState() {
    super.initState();
    _selectedSidebarIndex = widget.lastSelectedIndex ?? 4;
    shiftBloc = ShiftBloc(ShiftRepository());
    vendorPaymentBloc = VendorPaymentBloc(VendorPaymentRepository()); //Build #1.0.74
    if (widget.shiftId != null) {
      // Manually listen to the stream and trigger the fetch
      _shiftSubscription = shiftBloc.shiftByIdStream.listen((response) {
        if (mounted) {
          setState(() {
            apiResponse = response;
          });
        }
      });
      shiftBloc.getShiftById(widget.shiftId!);
      _loadVendorData(); // Load vendor data from AssetDBHelper
      if (kDebugMode) print("ShiftSummaryDashboardScreen: Initialized with shiftId ${widget.shiftId}");
    }
  }

  //Build #1.0.74
  Future<void> _loadVendorData() async {
    final assetDBHelper = AssetDBHelper.instance;
    try {
      final vendors = await assetDBHelper.getVendorList();
      final paymentTypes = await assetDBHelper.getVendorPaymentTypesList();
      final purposes = await assetDBHelper.getVendorPaymentPurposeList();
      setState(() {
        _vendors = vendors;
        _paymentTypes = paymentTypes;
        _purposes = purposes;
      });
      if (kDebugMode) {
        print("ShiftSummaryDashboardScreen: Loaded ${_vendors.length} vendors, ${_paymentTypes.length} payment types, ${_purposes.length} purposes");
      }
    } catch (e) {
      if (kDebugMode) print("ShiftSummaryDashboardScreen: Error loading vendor data: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load vendor data'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    // Cancel the stream subscription
    _shiftSubscription?.cancel();
    shiftBloc.dispose();
    vendorPaymentBloc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          TopBar(
            screen: Screen.ORDERS,
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
              // _preferences.saveLayoutSelection(newLayout);
              //Build #1.0.122: update layout mode change selection to DB
              await UserDbHelper().saveUserSettings({AppDBConst.layoutSelection: newLayout}, modeChange: true);
              // update UI
              setState(() {});
            },
          ),
          Divider(
            color: Colors.grey,
            thickness: 0.4,
            height: 1,
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
                  ),
                Expanded(
                  child: _buildShiftSummaryContent(),
                ),
                if (sidebarPosition == SidebarPosition.right)
                  custom_widgets.NavigationBar(
                    selectedSidebarIndex: _selectedSidebarIndex,
                    onSidebarItemSelected: (index) {
                      setState(() {
                        _selectedSidebarIndex = index;
                      });
                    },
                    isVertical: true,
                  ),
              ],
            ),
          ),
          if (sidebarPosition == SidebarPosition.bottom)
            custom_widgets.NavigationBar(
              selectedSidebarIndex: _selectedSidebarIndex,
              onSidebarItemSelected: (index) {
                setState(() {
                  _selectedSidebarIndex = index;
                });
              },
              isVertical: false,
            ),
        ],
      ),
    );
  }

  Widget _buildShiftSummaryContent() {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: () {
          // Use the _apiResponse state variable instead of a StreamBuilder
          if (apiResponse == null || apiResponse!.status == Status.LOADING) {
            return const Center(child: CircularProgressIndicator());
          }

          if (apiResponse!.status == Status.ERROR) {
            if (apiResponse!.message!.contains('Unauthorised')) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => LoginScreen()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Unauthorised. Session is expired on this device."),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              });
              return const Center(child: CircularProgressIndicator()); // Show loader while redirecting
            } else {
              return Center(child: Text('Error: ${apiResponse!.message}'));
            }
          }
          if (apiResponse!.status == Status.COMPLETED) {
            final shift = apiResponse!.data!.shift;
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(height: 2),
                            _buildTimeTrackingSection(shift),
                            // _buildSafeDropSection(shift),
                          ],
                        ),
                        SizedBox(width: 10),
                        Column(
                          children: [
                            SizedBox(height: 4),
                            _buildFinancialSummaryCards(shift),
                            // SizedBox(height: 10),
                            // _buildVendorPayoutsSection(shift),
                          ],
                        )
                      ],
                    ),
                    SizedBox(height: 10),
                    _buildVendorPayoutsSection(shift),

                  ],
                ),
              ),
            );
          }



          // StreamBuilder<APIResponse<ShiftByIdResponse>>( //Build #1.0.74
          //   stream: shiftBloc.shiftByIdStream,
          //   builder: (context, snapshot) {
          //     if (kDebugMode) {
          //       print("data is coming --- $snapshot");
          //     }
          //     if (kDebugMode) {
          //       print("data is coming ---- ${snapshot.hasData}");
          //     }
          //     if (snapshot.hasData) {
          //       // if (kDebugMode) {
          //       //   print("data is coming ${snapshot.data}");
          //       // }
          //       switch (snapshot.data!.status) {
          //         case Status.LOADING:
          //           return Center(child: CircularProgressIndicator());
          //         case Status.COMPLETED:
          //           final shift = snapshot.data!.data!.shift;
          //           return SingleChildScrollView(
          //             child: Padding(
          //               padding: EdgeInsets.all(8),
          //               child: Column(
          //                 crossAxisAlignment: CrossAxisAlignment.start,
          //                 children: [
          //                   Row(
          //                     children: [
          //                       Column(
          //                         mainAxisAlignment: MainAxisAlignment.start,
          //                         crossAxisAlignment: CrossAxisAlignment.start,
          //                         children: [
          //                           _buildHeader(),
          //                           _buildTimeTrackingSection(shift),
          //                         ],
          //                       ),
          //                       SizedBox(width: MediaQuery.of(context).size.width * 0.02),
          //                       _buildFinancialSummaryCards(shift),
          //                     ],
          //                   ),
          //                   SizedBox(height: MediaQuery.of(context).size.height * 0.02),
          //                   Row(
          //                     crossAxisAlignment: CrossAxisAlignment.start,
          //                     children: [
          //                       _buildSafeDropSection(shift),
          //                       SizedBox(width: MediaQuery.of(context).size.width * 0.02),
          //                       _buildVendorPayoutsSection(shift),
          //                     ],
          //                   ),
          //                 ],
          //               ),
          //             ),
          //           );
          //         case Status.ERROR:
          //           if (kDebugMode) {
          //             print(" Test --- Unauthorised : response.message ${snapshot.data!.message ?? " "}");
          //           }
          //             if (snapshot.data!.message!.contains('Unauthorised')) {
          //               if (kDebugMode) {
          //                 print("Unauthorised : response.message ${snapshot.data!.message!}");
          //               }
          //               WidgetsBinding.instance.addPostFrameCallback((_) {
          //                 if (mounted) {
          //                   Navigator.pushReplacement(context, MaterialPageRoute(
          //                       builder: (context) => LoginScreen()));
          //
          //                   ScaffoldMessenger.of(context).showSnackBar(
          //                     const SnackBar(
          //                       content: Text("Unauthorised. Session is expired on this device."),
          //                       backgroundColor: Colors.red,
          //                       duration: Duration(seconds: 2),
          //                     ),
          //                   );
          //                 }
          //               });
          //             } else {
          //             return Center(
          //                 child: Text('Error: ${snapshot.data!.message}'));
          //           }
          //         default:
          //           return SizedBox();
          //       }
          //     }
          //     return Center(child: CircularProgressIndicator());
          //   },
          // ),
          // Default fallback
          return const SizedBox.shrink();
        }(),
      ),
    );
  }

  Widget _buildHeader() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return InkWell(
      onTap: () => Navigator.of(context).pop(),
      child: Row(
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              Navigator.pop(context);
            },
            icon: Icon(
                Icons.arrow_back_sharp,
                color: themeHelper.themeMode == ThemeMode.dark
                    ? ThemeNotifier.textDark : Colors.black87,
                size: 20
            ),
          ),
          Text(
            TextConstants.back,
            style: TextStyle(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.textDark : Colors.black87,
              fontSize: MediaQuery.of(context).size.width * 0.01,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeTrackingSection(Shift shift) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Container(
      width: MediaQuery.of(context).size.width * 0.3,
      height: MediaQuery.of(context).size.height * 0.314,
      decoration: BoxDecoration(
        color: themeHelper.themeMode == ThemeMode.dark
            ? Color(0xFF1F1D2B) // outer dark background
            : Color(0xFFF1F0F7), // outer light background
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          topLeft: Radius.circular(8),
          bottomLeft: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],

      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              height: 42,
              width: 100,
              decoration: BoxDecoration(
                color: themeHelper.themeMode == ThemeMode.dark
                    ? Color(0xFF131218)
                    : Color(0xFF3B4259),
                boxShadow: [
                  BoxShadow(
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0x3F3E3E4D).withOpacity(0.6)
                        : Colors.grey.withOpacity(0.2),
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    icon: Icon(Icons.arrow_back_sharp,
                        color: Colors.white, size: 20),
                  ),
                  Text(
                    TextConstants.back,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: MediaQuery.of(context).size.width * 0.01,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 30),
          Container(
            width: MediaQuery.of(context).size.width * 0.280,
            height: MediaQuery.of(context).size.height * 0.145,
            decoration: BoxDecoration(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? Color(0xFF273142)
                  : Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? Colors.black.withOpacity(0.4)
                      : Colors.grey.withOpacity(0.3),
                  blurRadius: 6,
                  spreadRadius: 1,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _buildTimeCard(TextConstants.startTime,
                    DateTimeHelper.extractTime(shift.startTime)),
                SizedBox(width: MediaQuery.of(context).size.width * 0.0065),
                _buildTimeCard(
                    TextConstants.duration,
                    DateTimeHelper.calculateDuration(
                        shift.startTime, shift.endTime)),
                SizedBox(width: MediaQuery.of(context).size.width * 0.0065),
                _buildTimeCard(
                    TextConstants.endTime,
                    shift.endTime.isEmpty
                        ? ''
                        : DateTimeHelper.extractTime(shift.endTime)),
              ],
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildTimeCard(String title, String value) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    // Build #1.0.151: Updated - placeholder for startTime, duration, endTime if value is empty, present showing blank
    final isPlaceholder = value.isEmpty; // Check if value is empty
    final displayText =
    isPlaceholder ? '00:00:00' : value; // Set placeholder if empty
    final textColor = isPlaceholder
        ? Colors.grey // Grey for placeholder
        : themeHelper.themeMode == ThemeMode.dark
        ? ThemeNotifier.textDark
        : Colors.black87; // Regular color for actual value

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          style: TextStyle(
            color: themeHelper.themeMode == ThemeMode.dark
                ? Colors.white70
                : Colors.grey,
            fontSize: MediaQuery.of(context).size.width * 0.01,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: MediaQuery.of(context).size.height * 0.008),
        Container(
          width: MediaQuery.of(context).size.width * 0.080,
          height: MediaQuery.of(context).size.height * 0.065,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: themeHelper.themeMode == ThemeMode.dark
                ? const Color(0xFF1F1D2B) // dark background
                : const Color(0xFFF5F5F5), // light background
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? Color(0xFF1D1B1B)
                  : Color(0xFFE1E1E1),
              width: 1,
            ),
          ),
          child: Text(
            textAlign: TextAlign.center,
            displayText,
            style: TextStyle(
              color: textColor,
              fontSize: MediaQuery.of(context).size.width * 0.011,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFinancialSummaryCards(Shift shift) {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Container(
      height: 204, // increased height for 2 rows
      // height: 234,
      width: sidebarPosition == SidebarPosition.bottom
          ? MediaQuery.of(context).size.width * 0.675
          : MediaQuery.of(context).size.width * 0.608,
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: themeHelper.themeMode == ThemeMode.dark
            ? Color(0xFF1F1D2B)
            : Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),

      // ✅ removed horizontal scroll
      child: Column(
        children: [

          /// FIRST ROW
          Row(
            // mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSummaryCard(
                  TextConstants.openingAmount,
                  '${TextConstants.currencySymbol}${shift.openingBalance.toStringAsFixed(2)}',
                  Color(0xFFD3EAFF),
                  "assets/opening-amount.png",
                  Color(0xFF487FFF)),
              SizedBox(width: MediaQuery.of(context).size.width * 0.008),
              _buildSummaryCard(
                  TextConstants.totalTransactions,
                  '${shift.totalSales}',
                  Color(0xFFF1E2FF),
                  "assets/total_orders.png",
                  Color(0xFF8252E9)),
              SizedBox(width: MediaQuery.of(context).size.width * 0.008),
              _buildSummaryCard(
                  TextConstants.saleAmount,
                  '${TextConstants.currencySymbol}${shift.totalSaleAmount.toStringAsFixed(2)}',
                  Color(0xFFFDE9DB),
                  "assets/sale_amount.png",
                  Color(0xFFFE8B3E)),
              SizedBox(width: MediaQuery.of(context).size.width * 0.008),
              _buildSummaryCard(
                "Till Amount",
                '${shift.tillAmount < 0 ? '-${TextConstants.currencySymbol}${shift.tillAmount.abs().toStringAsFixed(2)}'
                    : '${TextConstants.currencySymbol}${shift.tillAmount.toStringAsFixed(2)}'}',
                Color(0xFFFDF4CD),
                "assets/svg/cash_drawer.svg",
                Color(0xFFEDC531),
              ),
              // SizedBox(width: MediaQuery.of(context).size.width * 0.006),
              // _buildSummaryCard(
              //     TextConstants.closingAmount,
              //     '${TextConstants.currencySymbol}${shift.closingBalance.toStringAsFixed(2)}',
              //     Color(0xFFD2FFF3),
              //     "assets/closing_amount.png",
              //     Color(0xFF0F8B6A)),
            ],
          ),

          SizedBox(height: 6),

          /// SECOND ROW
          Row(
            // mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSummaryCard(
                  TextConstants.closingAmount,
                  '${TextConstants.currencySymbol}${shift.closingBalance.toStringAsFixed(2)}',
                  Color(0xFFD2FFF3),
                  "assets/closing_amount.png",
                  Color(0xFF0F8B6A)),
              SizedBox(width: MediaQuery.of(context).size.width * 0.008),

              _buildSummaryCard(
                  "Card Payment",
                  '${TextConstants.currencySymbol}${shift.cardTotal.toStringAsFixed(2)}',
                  Color(0xFFD5FFD9),
                  "assets/Card_payment.png",
                  Color(0xFF0AAD1B)),
              SizedBox(width: MediaQuery.of(context).size.width * 0.008),
              _buildSummaryCard(
                  "Refund Amount",
                  '${TextConstants.currencySymbol}${shift.refundTotal.toStringAsFixed(2)}',
                  Color(0xFFFFE1E5),
                  "assets/refund.png",
                  Color(0xFFC71F37)),
              // _buildSummaryCard(
              //     "EBT Payment",
              //     '${TextConstants.currencySymbol}${shift.ebtTotal.toStringAsFixed(2)}',
              //     Color(0xFFE4DDD6),
              //     "assets/ebt_payments.svg",
              //     Color(0xFF6F4518)),
              // SizedBox(width: MediaQuery.of(context).size.width * 0.006),
              // _buildSummaryCard(
                  // "Cashback",
                  // '${TextConstants.currencySymbol}${shift.cashbackAmount.toStringAsFixed(2)}',
                  // Color(0xFFFFE5EC),
                  // "assets/cashback_bill.png",
                  // Color(0xFFFB6F92)),
              // SizedBox(width: MediaQuery.of(context).size.width * 0.006),
              // _buildSummaryCard(
              //     "Payout",
              //     '${TextConstants.currencySymbol}${shift.payoutTotal.toStringAsFixed(2)}',
              //     Color(0xFFCEE7F5),
              //     "assets/payout_bill.png",
              //     Color(0xFF2274A5)),
              // SizedBox(width: MediaQuery.of(context).size.width * 0.006),
              // _buildSummaryCard(
              //     "Refund Amount",
              //     '${TextConstants.currencySymbol}${shift.refundTotal.toStringAsFixed(2)}',
              //     Color(0xFFFFE1E5),
              //     "assets/refund.png",
              //     Color(0xFFC71F37)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(
      String title,
      String amount,
      Color color,
      String imagePath,
      Color circleBgColor,
      ) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.125,
      width: sidebarPosition == SidebarPosition.bottom
          ? MediaQuery.of(context).size.width * 0.158
          : MediaQuery.of(context).size.width * 0.141,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [

          /// CURVED LEFT INDICATOR
          Positioned.fill(
            left: -1,
            right: null,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 4,
                decoration: BoxDecoration(
                  color: circleBgColor,
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                ),
              ),
            ),
          ),
          /// MAIN CONTENT
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                /// TOP ROW
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    /// AMOUNT
                    Expanded(
                      child: Text(
                        amount,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFF373535),
                          fontSize: MediaQuery.of(context).size.width * 0.01,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),

                    /// ICON
                    Container(
                      height: 33,
                      width: 33,
                      decoration: BoxDecoration(
                        color: circleBgColor,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: imagePath.endsWith('.svg')
                            ? SvgPicture.asset(
                          imagePath,
                          height: 18,
                          width: 18,
                          color: Colors.white,
                        )
                            : Image.asset(
                          imagePath,
                          height: 18,
                          width: 18,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ],
                ),

                // Spacer(),

                /// TITLE
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xFF000000),
                    fontSize: MediaQuery.of(context).size.width * 0.01,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSafeDropSection(Shift shift) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Container(
      width: MediaQuery.of(context).size.width * 0.3,
      height: MediaQuery.of(context).size.height * 0.595,
      decoration: BoxDecoration(
        color: themeHelper.themeMode == ThemeMode.dark
            ? Color(0xFF1F1D2B)
            : Color(0xFFF1F0F7),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(MediaQuery.of(context).size.width * 0.015),
            decoration: BoxDecoration(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? Color(0xFF1F1D2B)
                  : Color(0xFFF1F0F7),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  TextConstants.safeDrop,
                  style: TextStyle(
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Colors.white
                        : Color(0xFF373535),
                    fontSize: MediaQuery.of(context).size.width * 0.012,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${TextConstants.currencySymbol}${shift.safeDropTotal.toStringAsFixed(2)}', // "safe_drop_total": 0,
                  style: TextStyle(
                    color: Color(0xFF4CAF50),
                    fontSize: MediaQuery.of(context).size.width * 0.012,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // Safe Drop List
          Expanded(
            child: shift.safeDrops.isEmpty
                ? Center(child: Text(TextConstants.safeDropNotFound))
                : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: shift.safeDrops.length,
              itemBuilder: (context, index) {
                final item = shift.safeDrops[index];
                return Container(
                  margin: EdgeInsets.only(
                      bottom: 3,
                      left: 10,
                      right: 10), // space after each item
                  padding: EdgeInsets.symmetric(
                    horizontal: MediaQuery.of(context).size.width * 0.015,
                    vertical: MediaQuery.of(context).size.height * 0.012,
                  ),
                  decoration: BoxDecoration(
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0xFF273142)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    // boxShadow: [
                    //   BoxShadow(
                    //     color: themeHelper.themeMode == ThemeMode.dark
                    //         ? Colors.black.withOpacity(0.6)
                    //         : Colors.grey.withOpacity(0.3),
                    //     blurRadius: 6,
                    //     offset: Offset(0, 3),
                    //   ),
                    // ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${TextConstants.currencySymbol}${item.total.toStringAsFixed(2)}', // safe_drops -> "total": 0,
                            style: TextStyle(
                              color:
                              themeHelper.themeMode == ThemeMode.dark
                                  ? ThemeNotifier.textDark
                                  : Colors.black87,
                              fontSize:
                              MediaQuery.of(context).size.width *
                                  0.011,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(
                              height: MediaQuery.of(context).size.height *
                                  0.004),
                          Text(
                            TextConstants.amount,
                            style: TextStyle(
                              color:
                              themeHelper.themeMode == ThemeMode.dark
                                  ? Colors.white70
                                  : Colors.grey.shade600,
                              fontSize:
                              MediaQuery.of(context).size.width *
                                  0.008,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            DateTimeHelper.extractTime(item.time),
                            style: TextStyle(
                              color:
                              themeHelper.themeMode == ThemeMode.dark
                                  ? ThemeNotifier.textDark
                                  : Colors.black87,
                              fontSize:
                              MediaQuery.of(context).size.width *
                                  0.011,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(
                              height: MediaQuery.of(context).size.height *
                                  0.004),
                          Text(
                            TextConstants.time,
                            style: TextStyle(
                              color:
                              themeHelper.themeMode == ThemeMode.dark
                                  ? Colors.white70
                                  : Colors.grey.shade600,
                              fontSize:
                              MediaQuery.of(context).size.width *
                                  0.008,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildVendorPayoutsSection(Shift shift) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Container(
      width: sidebarPosition == SidebarPosition.bottom
          ? MediaQuery.of(context).size.width * 0.675
          : MediaQuery.of(context).size.width * 0.608,
      height: MediaQuery.of(context).size.height * 0.650,
      decoration: BoxDecoration(
        color: themeHelper.themeMode == ThemeMode.dark
            ? ThemeNotifier.primaryBackground
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        // boxShadow: [
        //   BoxShadow(
        //     color: themeHelper.themeMode == ThemeMode.dark
        //         ? ThemeNotifier.shadow_F7
        //         : Colors.grey.withValues(alpha: 0.05),
        //     blurRadius: 2,
        //     spreadRadius: 2,
        //     offset: Offset(0, 0),
        //   ),
        // ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: EdgeInsets.all(MediaQuery.of(context).size.width * 0.0125),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Text(
                      TextConstants.vendorPayouts,
                      style: TextStyle(
                        color: themeHelper.themeMode == ThemeMode.dark
                            ? ThemeNotifier.textDark
                            : Colors.black,
                        fontSize: MediaQuery.of(context).size.width * 0.015,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(width: MediaQuery.of(context).size.width * 0.02),
                    Text(
                      '${TextConstants.currencySymbol}${shift.totalVendorPayments.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontSize: MediaQuery.of(context).size.width * 0.015,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                // Disable Add button if shift is closed
                InkWell(
                  onTap: shift.shiftStatus == 'closed'
                      ? null
                      : () {
                    if (kDebugMode)
                      print(
                          "ShiftSummaryDashboardScreen: Showing add vendor payout dialog");
                    _showAddVendorPayoutDialog();
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: MediaQuery.of(context).size.width * 0.01,
                      vertical: MediaQuery.of(context).size.height * 0.005,
                    ),
                    // color: Color(0xFFFE6464),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: shift.shiftStatus == 'closed'
                            ? Colors.grey
                            : Color(0xFFFE6464),
                        // themeHelper.themeMode == ThemeMode.dark
                        //         ? ThemeNotifier.borderColor
                        //         : Colors.black54,
                      ),
                      borderRadius: BorderRadius.circular(4),
                      color: shift.shiftStatus == 'closed'
                          ? Colors.grey.shade200
                          : Color(0xFFFE6464),
                      // themeHelper.themeMode == ThemeMode.dark
                      //         ? ThemeNotifier.tabsBackground
                      //         : Colors.white,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add,
                          size: MediaQuery.of(context).size.width * 0.015,
                          color: shift.shiftStatus == 'closed'
                              ? Colors.grey
                              : Color(0xFFFFFFFF),
                          // themeHelper.themeMode == ThemeMode.dark
                          //         ? ThemeNotifier.textDark
                          //         : Colors.black87,
                          weight: 2.0,
                        ),
                        SizedBox(
                            width: MediaQuery.of(context).size.width * 0.010),
                        Text(
                          TextConstants.addText,
                          style: TextStyle(
                            color: shift.shiftStatus == 'closed'
                                ? Colors.grey
                                : Color(0xFFFFFFFF),
                            // themeHelper.themeMode == ThemeMode.dark
                            //         ? ThemeNotifier.textDark
                            //         : Colors.black87,
                            fontSize: MediaQuery.of(context).size.width * 0.01,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: shift.vendorPayouts.isEmpty
                ? Center(child: Text(TextConstants.vendorPayoutNotFound))
                : Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                  child: DataTable(
                    //columnSpacing: MediaQuery.of(context).size.width * 0.055,
                    //horizontalMargin: MediaQuery.of(context).size.width * 0.015,
                    headingRowHeight:
                    MediaQuery.of(context).size.height * 0.065,
                    dataRowHeight:
                    MediaQuery.of(context).size.height * 0.065,

                    headingRowColor: WidgetStateProperty.all(
                      themeHelper.themeMode == ThemeMode.dark
                          ? Color(0xFF273142)
                          : Color(0xFF838383),
                    ),
                    dividerThickness: 0.5,
                    columns: [
                      DataColumn(
                        label: Container(
                          width: MediaQuery.of(context).size.width * 0.14,
                          // decoration: BoxDecoration(
                          //   borderRadius: BorderRadius.circular(19)
                          // ),
                          child: Text(
                            TextConstants.amount,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      DataColumn(
                        label: Container(
                          width: MediaQuery.of(context).size.width * 0.14,
                          child: Text(
                            TextConstants.vendor,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      DataColumn(
                        label: Container(
                          width:
                          MediaQuery.of(context).size.width * 0.20,
                          child: Text(
                            TextConstants.note,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      DataColumn(
                        label: Container(
                          width: MediaQuery.of(context).size.width * 0.12,
                          child: Text(
                            TextConstants.purpose,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      DataColumn(
                        label: Container(
                          width: MediaQuery.of(context).size.width * 0.15,
                          child: Text(
                            'Action',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                    rows:
                    shift.vendorPayouts.asMap().entries.map((entry) {
                      int index = entry.key;
                      VendorPayout item = entry.value;
                      return DataRow(
                        color: themeHelper.themeMode == ThemeMode.dark
                            ? MaterialStateProperty.resolveWith<Color?>(
                              (Set<MaterialState> states) =>
                              Color(0x2527314240),
                        )
                            : MaterialStateProperty.resolveWith<Color?>(
                              (Set<MaterialState> states) =>
                              Color(0xFFECEEFB),
                        ),
                        cells: [
                          DataCell(
                            Container(
                              width: MediaQuery.of(context).size.width *
                                  0.05,
                              child: Text(
                                '${TextConstants.currencySymbol}${item.amount.toStringAsFixed(2)}',
                                style: TextStyle(
                                  color: themeHelper.themeMode ==
                                      ThemeMode.dark
                                      ? Color(0xFFFFFFFF)
                                      : Colors.black87,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ).poppins(),
                            ),
                          ),
                          DataCell(
                            Container(
                              width: MediaQuery.of(context).size.width *
                                  0.05,
                              child: Text(
                                item.vendorName,
                                style: TextStyle(
                                  color: themeHelper.themeMode ==
                                      ThemeMode.dark
                                      ? Color(0xFFFFFFFF)
                                      : Colors.black87,
                                  fontSize: 13,
                                  // fontWeight: FontWeight.w500,
                                ),
                              ).poppins(),
                            ),
                          ),
                          DataCell(
                            Container(
                              width: MediaQuery.of(context).size.width *
                                  0.135,
                              child: Tooltip(
                                message: item.note.isEmpty
                                    ? 'No note'
                                    : item.note,
                                decoration: BoxDecoration(
                                  color: themeHelper.themeMode ==
                                      ThemeMode.dark
                                      ? ThemeNotifier.searchBarBackground
                                      : Colors.grey,
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black
                                          .withValues(alpha: 0.2),
                                      blurRadius: 4,
                                      offset: const Offset(0, 0),
                                    ),
                                  ],
                                ),
                                textStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w400,
                                ),
                                //padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                //margin: const EdgeInsets.all(8),
                                child: Text(
                                  item.note.isEmpty
                                      ? 'No note'
                                      : item.note,
                                  style: TextStyle(
                                    color: themeHelper.themeMode ==
                                        ThemeMode.dark
                                        ? Color(0xFFFFFFFF)
                                        : Colors.black87,
                                    fontSize: 13,
                                    //fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                  softWrap: true,
                                ).poppins(),
                              ),
                            ),
                          ),
                          DataCell(
                            Container(
                              width: MediaQuery.of(context).size.width *
                                  0.05,
                              child: Text(
                                item.serviceType,
                                style: TextStyle(
                                  color: themeHelper.themeMode ==
                                      ThemeMode.dark
                                      ? Color(0xFFFFFFFF)
                                      : Colors.black87,
                                  fontSize: 13,
                                  //fontWeight: FontWeight.w500,
                                ),
                              ).poppins(),
                            ),
                          ),
                          DataCell(
                            Container(
                              width: MediaQuery.of(context).size.width *
                                  0.12,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  InkWell(
                                    onTap: shift.shiftStatus == 'closed'
                                        ? null
                                        : () {
                                      if (kDebugMode)
                                        print(
                                            'ShiftSummaryDashboardScreen: Delete vendor payout at index $index with ID ${item.id}');
                                      _showDeleteConfirmation(
                                          index, item.id);
                                    },
                                    borderRadius:
                                    BorderRadius.circular(4),
                                    child: Container(
                                      height: 30,
                                      width: 30,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.rectangle,
                                        borderRadius:
                                        BorderRadius.circular(8.0),
                                        color: Colors.red.shade50,
                                      ),
                                      child: Icon(
                                        Icons.delete_outline,
                                        color:
                                        shift.shiftStatus == 'closed'
                                            ? Colors.grey
                                            : Colors.red.shade400,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                      width: MediaQuery.of(context)
                                          .size
                                          .width *
                                          0.005),
                                  InkWell(
                                    onTap: shift.shiftStatus == 'closed'
                                        ? null
                                        : () {
                                      if (kDebugMode)
                                        print(
                                            'ShiftSummaryDashboardScreen: Edit vendor payout at index $index with ID ${item.id}');
                                      _showAddVendorPayoutDialog(
                                          payment: item);
                                    },
                                    borderRadius:
                                    BorderRadius.circular(4),
                                    child: Padding(
                                      padding: EdgeInsets.all(
                                          MediaQuery.of(context)
                                              .size
                                              .width *
                                              0.004),
                                      child: Container(
                                        height: 30,
                                        width: 30,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.blue.shade50,
                                        ),
                                        child: Icon(
                                          Icons.edit_outlined,
                                          color: shift.shiftStatus ==
                                              'closed'
                                              ? Colors.grey
                                              : Colors.blue.shade400,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                      width: MediaQuery.of(context)
                                          .size
                                          .width *
                                          0.005),
                                  InkWell(
                                    onTap: () {
                                      if (kDebugMode)
                                        print(
                                            'ShiftSummaryDashboardScreen: Print vendor payout at index $index');
                                    },
                                    borderRadius:
                                    BorderRadius.circular(4),
                                    child: Padding(
                                      padding: EdgeInsets.all(
                                          MediaQuery.of(context)
                                              .size
                                              .width *
                                              0.004),
                                      child: Container(
                                        height: 30,
                                        width: 30,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.grey.shade200,
                                        ),
                                        child: Icon(
                                          Icons.print_outlined,
                                          color: Colors.grey.shade600,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }



  // Widget _buildVendorPayoutsSection(Shift shift) {
  //   final themeHelper = Provider.of<ThemeNotifier>(context);
  //   return Container(
  //     width: MediaQuery.of(context).size.width * 0.595,
  //     height: MediaQuery.of(context).size.height * 0.625,
  //     decoration: BoxDecoration(
  //       color: themeHelper.themeMode == ThemeMode.dark
  //           ? ThemeNotifier.primaryBackground : Colors.white,
  //       borderRadius: BorderRadius.circular(12),
  //       boxShadow: [
  //         BoxShadow(
  //           color: themeHelper.themeMode == ThemeMode.dark
  //               ? ThemeNotifier.shadow_F7 : Colors.grey.withValues(alpha: 0.05),
  //           blurRadius: 2,
  //           spreadRadius: 2,
  //           offset: Offset(0, 0),
  //         ),
  //       ],
  //     ),
  //     child: Column(
  //       crossAxisAlignment: CrossAxisAlignment.start,
  //       children: [
  //         // Header
  //         Container(
  //           padding: EdgeInsets.all(MediaQuery.of(context).size.width * 0.0125),
  //           child: Row(
  //             mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //             children: [
  //               Row(
  //                 mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  //                 children: [
  //                   Text(
  //                     TextConstants.vendorPayouts,
  //                     style: TextStyle(
  //                       color: themeHelper.themeMode == ThemeMode.dark
  //                           ? ThemeNotifier.textDark : Colors.black,
  //                       fontSize: MediaQuery.of(context).size.width * 0.015,
  //                       fontWeight: FontWeight.bold,
  //                     ),
  //                   ),
  //                   SizedBox(width: MediaQuery.of(context).size.width * 0.05),
  //                   Text(
  //                     '${TextConstants.currencySymbol}${shift.totalVendorPayments.toStringAsFixed(2)}',
  //                     style: TextStyle(
  //                       color: Color(0xFF4CAF50),
  //                       fontSize: MediaQuery.of(context).size.width * 0.012,
  //                       fontWeight: FontWeight.bold,
  //                     ),
  //                   ),
  //                 ],
  //               ),
  //               // Disable Add button if shift is closed
  //               InkWell(
  //                 onTap: shift.shiftStatus == 'closed'
  //                     ? null
  //                     : () {
  //                   if (kDebugMode) print("ShiftSummaryDashboardScreen: Showing add vendor payout dialog");
  //                   _showAddVendorPayoutDialog();
  //                 },
  //                 child: Container(
  //                   padding: EdgeInsets.symmetric(
  //                     horizontal: MediaQuery.of(context).size.width * 0.01,
  //                     vertical: MediaQuery.of(context).size.height * 0.005,
  //                   ),
  //                   decoration: BoxDecoration(
  //                     border: Border.all(
  //                       color: shift.shiftStatus == 'closed' ? Colors.grey : themeHelper.themeMode == ThemeMode.dark
  //                           ? ThemeNotifier.borderColor : Colors.black54,
  //                     ),
  //                     borderRadius: BorderRadius.circular(4),
  //                     color: shift.shiftStatus == 'closed' ? Colors.grey.shade200 :themeHelper.themeMode == ThemeMode.dark
  //                         ? ThemeNotifier.tabsBackground : Colors.white,
  //                   ),
  //                   child: Row(
  //                     mainAxisSize: MainAxisSize.min,
  //                     children: [
  //                       Icon(
  //                         Icons.add,
  //                         size: MediaQuery.of(context).size.width * 0.01,
  //                         color: shift.shiftStatus == 'closed' ? Colors.grey : themeHelper.themeMode == ThemeMode.dark
  //                             ? ThemeNotifier.textDark : Colors.black87,
  //                         weight: 2.0,
  //                       ),
  //                       SizedBox(width: MediaQuery.of(context).size.width * 0.003),
  //                       Text(
  //                         TextConstants.addText,
  //                         style: TextStyle(
  //                           color: shift.shiftStatus == 'closed' ? Colors.grey : themeHelper.themeMode == ThemeMode.dark
  //                               ? ThemeNotifier.textDark : Colors.black87,
  //                           fontSize: MediaQuery.of(context).size.width * 0.01,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                     ],
  //                   ),
  //                 ),
  //               ),
  //             ],
  //           ),
  //         ),
  //         Expanded(
  //           child: shift.vendorPayouts.isEmpty
  //               ? Center(child: Text(TextConstants.vendorPayoutNotFound))
  //               : Padding(
  //                 padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
  //                 child: SingleChildScrollView(
  //                               scrollDirection: Axis.vertical,
  //                               child: DataTable(
  //                 //columnSpacing: MediaQuery.of(context).size.width * 0.055,
  //                 //horizontalMargin: MediaQuery.of(context).size.width * 0.015,
  //                 headingRowHeight: MediaQuery.of(context).size.height * 0.085,
  //                 dataRowHeight: MediaQuery.of(context).size.height * 0.085,
  //
  //                 headingRowColor: WidgetStateProperty.all(
  //                   themeHelper.themeMode == ThemeMode.dark
  //                       ? ThemeNotifier.secondaryBackground
  //                       : Colors.white,
  //                 ),
  //                 dividerThickness: 0.5,
  //
  //                 columns: [
  //                   DataColumn(
  //                     label: Container(
  //                       width: MediaQuery.of(context).size.width * 0.05,
  //                       child: Text(
  //                         TextConstants.amount,
  //                         style: TextStyle(
  //                           color: Colors.grey.shade500,
  //                           fontSize: 14,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                     ),
  //                   ),
  //                   DataColumn(
  //                     label: Container(
  //                       width: MediaQuery.of(context).size.width * 0.05,
  //                       child: Text(
  //                         TextConstants.vendor,
  //                         style: TextStyle(
  //                           color: Colors.grey.shade500,
  //                           fontSize: 14,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                     ),
  //                   ),
  //                   DataColumn(
  //                     label: Container(
  //                       width: MediaQuery.of(context).size.width * 0.135,
  //                       child: Text(
  //                         TextConstants.note,
  //                         style: TextStyle(
  //                           color: Colors.grey.shade500,
  //                           fontSize: 14,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                     ),
  //                   ),
  //                   DataColumn(
  //                     label: Container(
  //                       width: MediaQuery.of(context).size.width * 0.05,
  //                       child: Text(
  //                        TextConstants.purpose,
  //                         style: TextStyle(
  //                           color: Colors.grey.shade500,
  //                           fontSize: 14,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                     ),
  //                   ),
  //                   DataColumn(
  //                     label: Container(
  //                       width: MediaQuery.of(context).size.width * 0.12,
  //                       child: Text(
  //                         '',
  //                         style: TextStyle(
  //                           color: Colors.grey.shade500,
  //                           fontSize: 14,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                     ),
  //                   ),
  //                 ],
  //                 rows: shift.vendorPayouts.asMap().entries.map((entry) {
  //                   int index = entry.key;
  //                   VendorPayout item = entry.value;
  //                   return DataRow(
  //                       color: WidgetStateProperty.resolveWith<Color?>(
  //                       (Set<WidgetState> states) => themeHelper.themeMode == ThemeMode.dark
  //                       ? ThemeNotifier.tabsBackground  // Your dark theme color
  //                       : Colors.white
  //                       ),
  //                   cells: [
  //                       DataCell(
  //                         Container(
  //                           width: MediaQuery.of(context).size.width * 0.05,
  //                           child: Text(
  //                             '${TextConstants.currencySymbol}${item.amount.toStringAsFixed(2)}',
  //                             style: TextStyle(
  //                               color:themeHelper.themeMode == ThemeMode.dark
  //                                   ? ThemeNotifier.textDark : Colors.black,
  //                               fontSize: 11,
  //                               //fontWeight: FontWeight.w500,
  //                             ),
  //                           ).poppins(),
  //                         ),
  //                       ),
  //                       DataCell(
  //                         Container(
  //                           width: MediaQuery.of(context).size.width * 0.05,
  //                           child: Text(
  //                             item.vendorName,
  //                             style: TextStyle(
  //                               color: themeHelper.themeMode == ThemeMode.dark
  //                                   ? ThemeNotifier.textDark : Colors.black,
  //                               fontSize: 11,
  //                              // fontWeight: FontWeight.w500,
  //                             ),
  //                           ).poppins(),
  //                         ),
  //                       ),
  //                     DataCell(
  //                       Container(
  //                         width: MediaQuery.of(context).size.width * 0.135,
  //                         child: Tooltip(
  //                           message: item.note.isEmpty ? 'No note' : item.note,
  //                           decoration: BoxDecoration(
  //                             color: themeHelper.themeMode == ThemeMode.dark
  //                                 ? ThemeNotifier.searchBarBackground
  //                                 : Colors.grey,
  //                             borderRadius: BorderRadius.circular(8),
  //                             boxShadow: [
  //                               BoxShadow(
  //                                 color: Colors.black.withValues(alpha: 0.2),
  //                                 blurRadius: 4,
  //                                 offset: const Offset(0, 0),
  //                               ),
  //                             ],
  //                           ),
  //                           textStyle: const TextStyle(
  //                             color: Colors.white,
  //                             fontSize: 12,
  //                             fontFamily: 'Poppins',
  //                             fontWeight: FontWeight.w400,
  //                           ),
  //                           //padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  //                           //margin: const EdgeInsets.all(8),
  //                           child: Text(
  //                             item.note.isEmpty ? 'No note' : item.note,
  //                             style: TextStyle(
  //                               color: themeHelper.themeMode == ThemeMode.dark
  //                                   ? ThemeNotifier.textDark : ThemeNotifier.textLight,
  //                               fontSize: 11,
  //                               //fontWeight: FontWeight.w500,
  //                             ),
  //                             overflow: TextOverflow.ellipsis,
  //                             maxLines: 2,
  //                             softWrap: true,
  //                           ).poppins(),
  //                         ),
  //                       ),
  //                     ),
  //                       DataCell(
  //                         Container(
  //                           width: MediaQuery.of(context).size.width * 0.05,
  //                           child: Text(
  //                             item.serviceType,
  //                             style: TextStyle(
  //                               color: themeHelper.themeMode == ThemeMode.dark
  //                                   ? ThemeNotifier.textDark :  Colors.black,
  //                               fontSize: 11,
  //                               //fontWeight: FontWeight.w500,
  //                             ),
  //                           ).poppins(),
  //                         ),
  //                       ),
  //                       DataCell(
  //                         Container(
  //                           width: MediaQuery.of(context).size.width * 0.12,
  //                           child: Row(
  //                             mainAxisSize: MainAxisSize.min,
  //                             children: [
  //                               InkWell(
  //                                 onTap: shift.shiftStatus == 'closed'
  //                                     ? null
  //                                     : () {
  //                                   if (kDebugMode) print('ShiftSummaryDashboardScreen: Delete vendor payout at index $index with ID ${item.id}');
  //                                   _showDeleteConfirmation(index, item.id);
  //                                 },
  //                                 borderRadius: BorderRadius.circular(4),
  //                                 child: Container(
  //                                   height:30,
  //                                   width:30,
  //                                   decoration: BoxDecoration(
  //                                     shape: BoxShape.rectangle,
  //                                     borderRadius: BorderRadius.circular(8.0),
  //                                     color: Colors.red.shade50,
  //                                   ),
  //                                   child: Icon(
  //                                     Icons.delete_outline,
  //                                     color: shift.shiftStatus == 'closed' ? Colors.grey : Colors.red.shade400,
  //                                     size: 18,
  //                                   ),
  //                                 ),
  //                               ),
  //                               SizedBox(width: MediaQuery.of(context).size.width * 0.005),
  //                               InkWell(
  //                                 onTap: shift.shiftStatus == 'closed'
  //                                     ? null
  //                                     : () {
  //                                   if (kDebugMode) print('ShiftSummaryDashboardScreen: Edit vendor payout at index $index with ID ${item.id}');
  //                                   _showAddVendorPayoutDialog(payment: item);
  //                                 },
  //                                 borderRadius: BorderRadius.circular(4),
  //                                 child: Padding(
  //                                   padding: EdgeInsets.all(MediaQuery.of(context).size.width * 0.004),
  //                                   child: Container(
  //                                     height:30,
  //                                     width:30,
  //                                     decoration: BoxDecoration(
  //                                       shape: BoxShape.circle,
  //                                       color: Colors.blue.shade50,
  //                                     ),
  //                                     child: Icon(
  //                                       Icons.edit_outlined,
  //                                       color: shift.shiftStatus == 'closed' ? Colors.grey : Colors.blue.shade400,
  //                                       size: 18,
  //                                     ),
  //                                   ),
  //                                 ),
  //                               ),
  //                               SizedBox(width: MediaQuery.of(context).size.width * 0.005),
  //                               InkWell(
  //                                 onTap: () {
  //                                   if (kDebugMode) print('ShiftSummaryDashboardScreen: Print vendor payout at index $index');
  //                                 },
  //                                 borderRadius: BorderRadius.circular(4),
  //                                 child: Padding(
  //                                   padding: EdgeInsets.all(MediaQuery.of(context).size.width * 0.004),
  //                                   child: Container(
  //                                     height:30,
  //                                     width:30,
  //                                     decoration: BoxDecoration(
  //                                       shape: BoxShape.circle,
  //                                       color: Colors.grey.shade200,
  //                                     ),
  //                                     child: Icon(
  //                                       Icons.print_outlined,
  //                                       color: Colors.grey.shade600,
  //                                       size: 20,
  //                                     ),
  //                                   ),
  //                                 ),
  //                               ),
  //                             ],
  //                           ),
  //                         ),
  //                       ),
  //                     ],
  //                   );
  //                 }).toList(),
  //                               ),
  //                             ),
  //               ),
  //         ),
  //       ],
  //     ),
  //   );
  // }



  void _showDeleteConfirmation(int index, int paymentId) {
    bool _isDeleting = false; // Track delete button loading state
    CustomDialog.showAreYouSure(
      context,
      confirm: () async {
        if (kDebugMode) print('ShiftSummaryDashboardScreen: Initiating delete for payment ID $paymentId');
        setState(() {
          _isDeleting = true; // Show loader on Yes button
        });
        vendorPaymentBloc.deleteVendorPayment(paymentId);
        await for (var response in vendorPaymentBloc.deleteVendorPaymentStream) {
          if (response.status == Status.COMPLETED) {
            setState(() {
              _isDeleting = false; // Hide loader
            });
            // Navigator.of(context).pop(); // Dismiss confirmation dialog

            shiftBloc.getShiftById(widget.shiftId!);
            if (Misc.showDebugSnackBar) { // Build #1.0.254
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    response.message ?? 'Vendor payout deleted successfully',
                    style: TextStyle(color: Colors.white),
                  ),
                  backgroundColor: Colors.green,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          }
          else if (response.status == Status.ERROR) {
            if (response.message!.contains('Unauthorised')) {
              if (kDebugMode) {
                print("shift summary screen -- Unauthorised : response.message ${response.message!}");
              }
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  Navigator.pushReplacement(context,
                      MaterialPageRoute(builder: (context) => LoginScreen()));
                  if (kDebugMode) {
                    print("message --- ${response.message}");
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          "Unauthorised. Session is expired on this device."),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              });
            }
            else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    response.message ?? 'Failed to delete vendor payout',
                    style: TextStyle(color: Colors.white),
                  ),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          }
          break;
        }
      },
      isDeleting: _isDeleting, // Pass loading state
    );
  }

  void _showAddVendorPayoutDialog({VendorPayout? payment}) {
    showDialog(
      context: context,
      barrierDismissible: false, // 🔒 prevents closing on outside tap
      builder: (BuildContext context) {
        return AddVendorPayoutDialog( //Build #1.0.74: updated code
          shiftId: widget.shiftId!,
          vendors: _vendors,
          paymentTypes: _paymentTypes,
          purposes: _purposes,
          vendorPaymentBloc: vendorPaymentBloc,
          onAdd: (request) async {
            if (kDebugMode) print('ShiftSummaryDashboardScreen: Adding/Editing vendor payout: ${request.toJson()}');
            // Handle create or update
            if (payment != null && request.vendorPaymentId != null) {
              vendorPaymentBloc.updateVendorPayment(request, request.vendorPaymentId!);
              // Listen to update stream
              await for (var response in vendorPaymentBloc.updateVendorPaymentStream) {
                if (response.status == Status.COMPLETED) {

                  shiftBloc.getShiftById(widget.shiftId!); // Refresh shift data
                  if (Misc.showDebugSnackBar) { // Build #1.0.254
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          response.message ?? 'Vendor payout updated successfully',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Colors.green,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                }
                else if (response.status == Status.ERROR) {
                  if (response.message!.contains('Unauthorised')) {
                    if (kDebugMode) {
                      print("Unauthorised : response.message ${response.message!}");
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        Navigator.pushReplacement(
                            context, MaterialPageRoute(
                            builder: (context) => LoginScreen()));

                        if (kDebugMode) {
                          print("message --- ${response.message}");
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                "Unauthorised. Session is expired on this device."),
                            backgroundColor: Colors.red,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    });
                  }
                  else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          response.message ?? 'Failed to update vendor payout',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Colors.red,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                }
                break; // Exit after handling the response
              }
            } else {
              vendorPaymentBloc.createVendorPayment(request);
              // Listen to create stream
              await for (var response in vendorPaymentBloc.createVendorPaymentStream) {
                if (response.status == Status.COMPLETED) {
                  shiftBloc.getShiftById(widget.shiftId!); // Refresh shift data
                  if (Misc.showDebugSnackBar) { // Build #1.0.254
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          response.message ?? 'Vendor payout added successfully',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Colors.green,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } else if (response.status == Status.ERROR) {
                  if (response.message!.contains('Unauthorised')) {
                    if (kDebugMode) {
                      print("Unauthorised : response.message ${response.message!}");
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        Navigator.pushReplacement(
                            context, MaterialPageRoute(
                            builder: (context) => LoginScreen()));

                        if (kDebugMode) {
                          print("message --- ${response.message}");
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                "Unauthorised. Session is expired on this device."),
                            backgroundColor: Colors.red,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    });
                  }
                  else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          response.message ?? 'Failed to add vendor payout',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Colors.red,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                }
                break; // Exit after handling the response
              }
            }
          },
          payment: payment,
        );
      },
    );
  }
}