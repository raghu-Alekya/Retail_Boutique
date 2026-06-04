import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pinaka_pos/Repositories/Auth/shift_repository.dart';
import 'package:provider/provider.dart';
import '../../Blocs/Auth/shift_bloc.dart';
import '../../Constants/text.dart';
import '../../Database/db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Models/Auth/shift_summary_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Screens/Home/shift_open_close_balance.dart';
import '../../Screens/Home/shift_summary_dashboard_screen.dart';
import '../../Widgets/widget_topbar.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../../Helper/api_response.dart';
import '../Auth/login_screen.dart';

class ShiftHistoryDashboardScreen extends StatefulWidget {
  final int? lastSelectedIndex;
  const ShiftHistoryDashboardScreen({super.key, this.lastSelectedIndex});

  @override
  State<ShiftHistoryDashboardScreen> createState() =>
      _ShiftHistoryDashboardScreenState();
}

class _ShiftHistoryDashboardScreenState
    extends State<ShiftHistoryDashboardScreen> with LayoutSelectionMixin {
  int _selectedSidebarIndex = 3;
  late ShiftBloc shiftBloc; //Build #1.0.74
  final PinakaPreferences _preferences = PinakaPreferences(); // Added this
  List<Shift> _cachedShifts = []; // Store previously loaded shifts
  bool _isDataLoaded =
  false; // // Build #1.0.192: ADDED: Flag to track if data has been loaded at least once
  @override
  void initState() {
    super.initState();
    _selectedSidebarIndex = widget.lastSelectedIndex ?? 3;
    shiftBloc = ShiftBloc(ShiftRepository());
    //API call
    fetchShiftHistory();
  }

  //Build #1.0.74
  Future<void> fetchShiftHistory() async {
    // Fetch shifts for user ID
    final userData = await UserDbHelper().getUserData();
    if (userData != null && userData[AppDBConst.userId] != null) {
      shiftBloc.getShiftsByUser(userData[AppDBConst.userId] as int);
    }
  }

  @override
  void dispose() {
    shiftBloc.dispose(); // Build #1.0.192 : bloc dispose
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      //DEBUG
      print("ShiftHistoryDashboardScreen: Widget build");
    }
    return Scaffold(
      body: Column(
        children: [
          TopBar(
          screen: Screen.ORDERS,
            onModeChanged: () async {
              /// Build #1.0.192: Fixed -> Exception -> setState() callback argument returned a Future. (onModeChanged in all screens)
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
              await UserDbHelper().saveUserSettings(
                  {AppDBConst.layoutSelection: newLayout},
                  modeChange: true);

              // Update UI state
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
                  child: _buildShiftHistoryContent(),
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

  Widget _buildShiftHistoryContent() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: themeHelper.themeMode == ThemeMode.dark
            ? Color(0xFF1F1D2B)
            : Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(6.0),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                margin: EdgeInsets.only(left: 15.0, top: 10.0),
                width: MediaQuery.of(context).size.width * 0.075,
                height: MediaQuery.of(context).size.height * 0.05,
                decoration: BoxDecoration(
                  color: Color(0xFF3B4259),
                  borderRadius: BorderRadius.circular(6.0),
                  border: Border.all(color: Color(0xFF3B4259)),
                ),
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                    size: 20,
                    weight: 10,
                  ),
                  label: Text(
                    'Back',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: 5),
                  ),
                ),
              ),
              // Container(
              //   margin: const EdgeInsets.only(right: 16.0, top: 10),
              //   width: MediaQuery.of(context).size.width * 0.075,
              //   height: MediaQuery.of(context).size.height * 0.05,
              //   decoration: BoxDecoration(
              //     gradient: const LinearGradient(
              //       colors: [
              //         Color(0xFFFF5463),
              //         Color(0xFFFF384A),
              //       ],
              //       begin: Alignment.topLeft, // start at top-left
              //       end: Alignment.topRight, // end at top-right
              //     ),
              //     boxShadow: [
              //       BoxShadow(
              //         color: themeHelper.themeMode == ThemeMode.dark
              //             ? Color(0xFFFF384A).withOpacity(0.60)
              //             : Color(0xFFFF384A).withOpacity(0.50),
              //         blurRadius: 10,
              //         spreadRadius: 1,
              //         offset: Offset(0, 2),
              //       ),
              //     ],
              //     borderRadius: BorderRadius.circular(14),
              //   ),
              //   // child: TextButton.icon(
              //   //   onPressed: () {
              //   //     Navigator.push(
              //   //       context,
              //   //       MaterialPageRoute(
              //   //         builder: (context) => ShiftOpenCloseBalanceScreen(),
              //   //         settings: const RouteSettings(
              //   //             arguments: TextConstants.navShiftHistory),
              //   //       ),
              //   //     );
              //   //   },
              //   //   icon: const Icon(
              //   //     Icons.add,
              //   //     color: Colors.white,
              //   //     size: 22,
              //   //   ),
              //   //   label: const Text(
              //   //     'Update',
              //   //     style: TextStyle(
              //   //       color: Colors.white,
              //   //       fontSize: 14,
              //   //       fontWeight: FontWeight.bold,
              //   //     ),
              //   //   ),
              //   //   style: TextButton.styleFrom(
              //   //     backgroundColor: Colors
              //   //         .transparent, // make button background transparent
              //   //     padding: const EdgeInsets.symmetric(vertical: 5),
              //   //   ),
              //   // ),
              // ),
            ],
          ),
          Expanded(
            child: Container(
              margin: EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: BoxDecoration(
                color: themeHelper.themeMode == ThemeMode.dark
                    ? Color(0xFF1F1D2B)
                    : Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(8.0),
                // boxShadow: [
                //   BoxShadow(
                //     color: Colors.black.withValues(alpha: 0.05),
                //     blurRadius: 4,
                //     spreadRadius: 4,
                //     offset: Offset(0, 0),
                //   ),
                // ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: themeHelper.themeMode == ThemeMode.dark
                          ? Color(0xFF252837)
                          : Color(0xFF838383),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(8.0),
                        topRight: Radius.circular(8.0),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: SizedBox(),
                        ),
                        Expanded(
                            flex: 18,
                            child: Text('Date', style: _headerStyle(context))),
                        Expanded(
                            flex: 18,
                            child:
                            Text('Duration', style: _headerStyle(context))),
                        Expanded(
                            flex: 18,
                            child: Text('Start Time',
                                style: _headerStyle(context))),
                        Expanded(
                            flex: 18,
                            child:
                            Text('End Time', style: _headerStyle(context))),
                        Expanded(
                            flex: 18,
                            child: Text('Sales Amount',
                                style: _headerStyle(context))),
                        Expanded(
                            flex: 18,
                            child: Text('Over/Short',
                                style: _headerStyle(context))),
                        Expanded(flex: 0, child: SizedBox()),
                      ],
                    ),
                  ),
                  Container(
                    margin: EdgeInsets.only(left: 10),
                    height: 1,
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0xFF0A122D)
                        : Color(0xFFF8F8F8),
                  ),
                  Expanded(
                    child: StreamBuilder<APIResponse<ShiftsByUserResponse>>(
                      stream: shiftBloc.shiftsByUserStream,
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          switch (snapshot.data!.status) {
                            case Status.LOADING:
                              return Center(child: CircularProgressIndicator());
                            case Status.COMPLETED:
                              final shifts = snapshot.data!.data!.shifts;
                              if (shifts.isEmpty) {
                                return Center(child: Text('No shifts found'));
                              }
                              return ListView.builder(
                                itemCount: shifts.length,
                                itemBuilder: (context, index) {
                                  final shift = shifts[index];
                                  return InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              ShiftSummaryDashboardScreen(
                                                lastSelectedIndex:
                                                _selectedSidebarIndex,
                                                shiftId: shift.shiftId,
                                              ),
                                        ),
                                      );
                                    },
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 16),
                                      decoration: BoxDecoration(
                                        color: themeHelper.themeMode ==
                                            ThemeMode.dark
                                            ? Color(0xFF030816)
                                            : Color(0xFFF8F8F8),
                                        border: Border(
                                          bottom: BorderSide(
                                            color: themeHelper.themeMode ==
                                                ThemeMode.dark
                                                ? Color(0x70616060)
                                                : Color(0xFFD8D7D7),
                                            width: 1,
                                            style: BorderStyle.solid,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 5,
                                            child: SizedBox(),
                                          ),
                                          Expanded(
                                            flex: 18,
                                            child: Text(
                                              DateTimeHelper.extractDate(
                                                  shift.startTime),
                                              style: _cellStyle(context),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 18,
                                            child: Text(
                                              DateTimeHelper.calculateDuration(
                                                  shift.startTime,
                                                  shift.endTime),
                                              style: _cellStyle(context),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 18,
                                            child: Text(
                                              DateTimeHelper.extractTime(
                                                  shift.startTime),
                                              style: _cellStyle(context),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 18,
                                            child: Text(
                                              shift.endTime.isEmpty
                                                  ? ''
                                                  : DateTimeHelper.extractTime(
                                                  shift.endTime),
                                              style: _cellStyle(context),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 18,
                                            child: Text(
                                              '${TextConstants.currencySymbol}${shift.totalSaleAmount.toStringAsFixed(2)}',
                                              style: _cellStyle(context),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 18,
                                            child: Text(
                                              '${shift.overShort < 0 ? '-' : ''}${TextConstants.currencySymbol}${shift.overShort.abs().toStringAsFixed(2)}',
                                              style: TextStyle(
                                                color: shift.overShort >= 0
                                                    ? Colors.green
                                                    : Colors
                                                    .red, //Fix: all values are showing red , only show negative values as red text
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 0,
                                            child: SizedBox(),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            case Status.ERROR:
                              return Center(
                                  child: Text(TextConstants
                                      .failedToFetchShifts)); // Build #1.0.144
                            default:
                              return SizedBox();
                          }
                        }
                        return Center(child: CircularProgressIndicator());
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build #1.0.192: Fixed -> JIRA - 331 , Shift Summary screen stuck on continuous loading when mode is changed Summary
  Widget _buildShiftListView(List<Shift> shifts, ThemeNotifier themeHelper) {
    return ListView.builder(
      itemCount: shifts.length,
      itemBuilder: (context, index) {
        final shift = shifts[index];
        return InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ShiftSummaryDashboardScreen(
                  lastSelectedIndex: _selectedSidebarIndex,
                  shiftId: shift.shiftId,
                ),
              ),
            );
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.tabsBackground
                  : null,
              border: Border(
                bottom: BorderSide(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? Colors.white38
                      : Colors.grey.shade200,
                  width: 1,
                  style: BorderStyle.solid,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: SizedBox(),
                ),
                Expanded(
                  flex: 18,
                  child: Text(
                    DateTimeHelper.extractDate(shift.startTime),
                    style: _cellStyle(context),
                  ),
                ),
                Expanded(
                  flex: 18,
                  child: Text(
                    DateTimeHelper.calculateDuration(
                        shift.startTime, shift.endTime),
                    style: _cellStyle(context),
                  ),
                ),
                Expanded(
                  flex: 18,
                  child: Text(
                    DateTimeHelper.extractTime(shift.startTime),
                    style: _cellStyle(context),
                  ),
                ),
                Expanded(
                  flex: 18,
                  child: Text(
                    shift.endTime.isEmpty
                        ? ''
                        : DateTimeHelper.extractTime(shift.endTime),
                    style: _cellStyle(context),
                  ),
                ),
                Expanded(
                  flex: 18,
                  child: Text(
                    '${TextConstants.currencySymbol}${shift.totalSaleAmount.toStringAsFixed(2)}',
                    style: _cellStyle(context),
                  ),
                ),
                Expanded(
                  flex: 18,
                  child: Text(
                    '${shift.overShort < 0 ? '-' : ''}${TextConstants.currencySymbol}${shift.overShort.abs().toStringAsFixed(2)}',
                    style: TextStyle(
                      color: shift.overShort >= 0
                          ? Colors.green
                          : Colors
                          .red, //Fix: all values are showing red , only show negative values as red text
                      fontSize: 14,
                    ),
                  ),
                ),
                Expanded(
                  flex: 0,
                  child: SizedBox(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  TextStyle _headerStyle(BuildContext context) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return TextStyle(
      color: themeHelper.themeMode == ThemeMode.dark
          ? ThemeNotifier.textDark
          : Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
    );
  }

  TextStyle _cellStyle(BuildContext context) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return TextStyle(
      color: themeHelper.themeMode == ThemeMode.dark
          ? ThemeNotifier.textDark
          : Colors.black87,
      fontSize: 14,
    );
  }

  void _showDeleteConfirmation(int index) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete Shift'),
          content: Text('Are you sure you want to delete this shift record?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'Delete',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );
  }
}

//Build #1.0.74:  ADDED HELPER
class DateTimeHelper {
  // Calculate duration from start time to current time or end time
  static String calculateDuration(String startTime, String endTime) {
    try {
      final DateFormat dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
      final DateTime start = dateFormat.parse(startTime);
      final DateTime end =
      endTime.isNotEmpty ? dateFormat.parse(endTime) : DateTime.now();
      final Duration duration = end.difference(start);
      final int hours = duration.inHours;
      final int minutes = duration.inMinutes.remainder(60);
      final int seconds = duration.inSeconds.remainder(60);
      if (kDebugMode) {
        print(
            'Calculated duration for start: $startTime, end: $endTime -> $hours:$minutes:$seconds');
      }
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } catch (e) {
      if (kDebugMode) print('Error calculating duration: $e');
      return '00:00:00';
    }
  }

  // Extract date from start time
  static String extractDate(String startTime) {
    try {
      final DateFormat inputFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
      final DateFormat outputFormat = DateFormat('dd/MM/yyyy');
      final DateTime dateTime = inputFormat.parse(startTime);
      final String formattedDate = outputFormat.format(dateTime);
      if (kDebugMode) {
        print('Extracted date from $startTime -> $formattedDate');
      }
      return formattedDate;
    } catch (e) {
      if (kDebugMode) print('Error extracting date: $e');
      return '';
    }
  }

  // Extract time from datetime string
  static String extractTime(String time) {
    try {
      final DateFormat inputFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
      final DateFormat outputFormat = DateFormat('HH:mm:ss');
      final DateTime dateTime = inputFormat.parse(time);
      final String formattedTime = outputFormat.format(dateTime);
      if (kDebugMode) {
        print('Extracted time from $time -> $formattedTime');
      }
      return formattedTime;
    } catch (e) {
      if (kDebugMode) print('Error extracting time: $e');
      return '';
    }
  }
}