import 'package:flutter/foundation.dart';
import 'package:flutter_svg/svg.dart';
import 'package:pinaka_pos/Screens/Home/safe_drop_screen.dart';
import 'package:pinaka_pos/Screens/Home/shift_history_dashboard_screen.dart';
import 'package:pinaka_pos/Screens/Home/shift_open_close_balance.dart';
import 'package:provider/provider.dart';
import '../../Constants/text.dart';
import '../../Database/db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Inventory_screen/InventoryScreen.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Widgets/SafeStorageHelper.dart';
import '../../Widgets/widget_topbar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;

class AppsDashboardScreen extends StatefulWidget {
  // Build #1.0.6 - Updated Horizontal & Vertical Scrolling
  final int? lastSelectedIndex; // Make it nullable

  const AppsDashboardScreen({
    super.key,
    this.lastSelectedIndex,
  }); // Optional, no default value

  @override
  State<AppsDashboardScreen> createState() => _AppsDashboardScreenState();
}

class _AppsDashboardScreenState extends State<AppsDashboardScreen>
    with LayoutSelectionMixin {
  final List<String> items = List.generate(18, (index) => 'Bud Light');
  int _selectedSidebarIndex = 3; //Build #1.0.2 : By default fast key should be selected after login
  DateTime now = DateTime.now();
  List<int> quantities = [1, 1, 1, 1];
  bool isLoading = true; // Add a loading state
  final PinakaPreferences _preferences = PinakaPreferences(); // Add this
  // Add variables to track which card is being pressed
  int? _pressedCardIndex;
  bool _isSafeEnabled = false;
  bool _isSafeDropEnabled = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initApps();
  }

  Future<void> _initApps() async {
    if (mounted) {
      setState(() {
        isLoading = true;
      });
    }

    _selectedSidebarIndex = widget.lastSelectedIndex ?? 4;

    // Load values from storage with a reload to ensure sync
    await SafeStorageHelper.reload();
    final safeEnabled = await SafeStorageHelper.getSafeEnable();
    final safeDropEnabled = await SafeStorageHelper.getSafeEnableDrop();

    if (mounted) {
      setState(() {
        _isSafeEnabled = safeEnabled;
        _isSafeDropEnabled = safeDropEnabled;
        isLoading = false;
        _ready = true;
      });
    }
  }

  Future<void> _loadSafeEnable() async {
    final value = await SafeStorageHelper.getSafeEnable();
    if (mounted) {
      setState(() {
        _isSafeEnabled = value;
      });
    }
  }

  Future<void> _loadSafeDropEnable() async {
    final value = await SafeStorageHelper.getSafeEnableDrop();
    if (mounted) {
      setState(() {
        _isSafeDropEnabled = value;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Scaffold(
      body: Column(
        children: [
          // Top Bar
          TopBar(
            screen: Screen.APPS,
            onModeChanged: () async {
              /// Build #1.0.192: Fixed -> Exception -> setState() callback argument returned a Future. (onModeChanged in all screens)
              String newLayout;
              if (sidebarPosition == SidebarPosition.left) {
                newLayout = SharedPreferenceTextConstants.navRightOrderLeft;
              } else if (sidebarPosition == SidebarPosition.right) {
                newLayout = SharedPreferenceTextConstants.navBottomOrderLeft;
              } else {
                newLayout =
                    orderPanelPosition == OrderPanelPosition.left
                        ? SharedPreferenceTextConstants.navBottomOrderRight
                        : SharedPreferenceTextConstants.navLeftOrderRight;
              }

              //Update the notifier which will trigger _onLayoutChanged
              PinakaPreferences.layoutSelectionNotifier.value = newLayout;
              // No need to call saveLayoutSelection here as it's handled in the notifier
              // _preferences.saveLayoutSelection(newLayout);
              //Build #1.0.122: update layout mode change selection to DB
              await UserDbHelper().saveUserSettings({
                AppDBConst.layoutSelection: newLayout,
              }, modeChange: true);
              // update UI
              setState(() {});
            },
          ),
          Divider(
            color: Colors.grey, // Light grey color
            thickness: 0.4, // Very thin line
            height: 1, // Minimal height
          ),

          // SizedBox(
          //   height: 10,
          // ),

          // Main Content
          Expanded(
            child: Row(
              children: [
                // Left Sidebar (Conditional)
                if (sidebarPosition == SidebarPosition.left)
                  custom_widgets.NavigationBar(
                    //Build #1.0.4 : Updated class name LeftSidebar to NavigationBar
                    selectedSidebarIndex: _selectedSidebarIndex,
                    onSidebarItemSelected: (index) {
                      setState(() {
                        _selectedSidebarIndex = index;
                      });
                    },
                    isVertical: true, // Vertical layout for left sidebar
                  ),
                Expanded(
                  child:
                      isLoading
                          ? const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF1E2745),
                            ),
                          )
                          : Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: GridView.count(
                              crossAxisCount: 4,
                              childAspectRatio: 1,
                              children: [
                                _buildCard(
                                  icon:
                                      themeHelper.themeMode == ThemeMode.dark
                                          ? Image.asset(
                                            "assets/cashier_dark.png",
                                          )
                                          : Image.asset(
                                            "assets/cashier_lite.png",
                                          ),
                                  cardIndex: 0,
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder:
                                            (context) =>
                                                ShiftHistoryDashboardScreen(),
                                      ),
                                    );
                                  },
                                ),
                                _buildCard(
                                  icon:
                                  themeHelper.themeMode == ThemeMode.dark
                                      ? Image.asset(
                                    "assets/stock_inventory_dark.png",
                                  )
                                      : Image.asset("assets/img.png"),
                                  cardIndex: 2, // Updated index to 2
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => InventoryScreen(),
                                      ),
                                    );
                                  },
                                ),
                                _buildCard(
                                  icon:
                                      themeHelper.themeMode == ThemeMode.dark
                                          ? Image.asset(
                                            "assets/safedrop_dark.png",
                                          )
                                          : Image.asset(
                                            "assets/safedrop_lite.png",
                                          ),
                                  cardIndex: 1,
                                  onTap:
                                      _isSafeDropEnabled
                                          ? () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder:
                                                    (_) => SafeDropScreen(),
                                              ),
                                            );
                                          }
                                          : () {},
                                ).withOpacity(_isSafeDropEnabled ? 1.0 : 0.0),
                                // _buildCard(
                                //   icon:
                                //       themeHelper.themeMode == ThemeMode.dark
                                //           ? Image.asset(
                                //             "assets/stock_inventory_dark.png",
                                //           )
                                //           : Image.asset("assets/img.png"),
                                //   cardIndex: 2, // Updated index to 2
                                //   onTap: () {
                                //     Navigator.push(
                                //       context,
                                //       MaterialPageRoute(
                                //         builder: (context) => InventoryScreen(),
                                //       ),
                                //     );
                                //   },
                                // ),
                              ],
                            ),
                          ),
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
                    isVertical: true, // Vertical layout for right sidebar
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
              isVertical: false, // Horizontal layout for bottom sidebar
            ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required Widget icon,
    required VoidCallback onTap,
    required int cardIndex,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(width: 330, height: 330, child: icon),
    );
  }
}

extension WidgetOpacity on Widget {
  Widget withOpacity(double opacity) {
    return Opacity(
      opacity: opacity,
      child: IgnorePointer(ignoring: opacity == 0, child: this),
    );
  }
}
