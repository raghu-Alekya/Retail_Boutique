import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../Constants/text.dart';
import '../../Database/db_helper.dart';
import '../../Database/order_panel_db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../../Widgets/widget_order_panel.dart';
import '../../Widgets/widget_topbar.dart';
import 'add_screen.dart';
import 'categories_screen.dart';
import 'fast_key_screen.dart';

/// Single shell for Fast Keys, Categories, and Add tabs.
/// Uses IndexedStack so RightOrderPanel is shared and does not reload when switching tabs.
class POSHomeScreen extends StatefulWidget {
  final int? lastSelectedIndex;

  const POSHomeScreen({super.key, this.lastSelectedIndex});

  @override
  State<POSHomeScreen> createState() => _POSHomeScreenState();
}

class _POSHomeScreenState extends State<POSHomeScreen> with LayoutSelectionMixin {
  int _selectedSidebarIndex = 0;
  int _activeTabIndex = 0; // Build #1.0.283: Separate tab index from selection highlight
  int _refreshCounter = 0;
  final OrderHelper orderHelper = OrderHelper();
  final List<int> quantities = [1, 1, 1, 1];

  @override
  void initState() {
    super.initState();
    _selectedSidebarIndex = widget.lastSelectedIndex ?? 0;

    if (_selectedSidebarIndex == 1) {
      _activeTabIndex = 1;
    } else {
      _activeTabIndex = 0;
    }
  }

  void _refreshOrderList() {
    setState(() => _refreshCounter++);
  }

  Screen _getScreenForIndex(int index) {
    switch (index) {
      case 0:
        return Screen.CATEGORY;
      case 1:
        return Screen.ADD;
      default:
        return Screen.CATEGORY;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopBar(
              screen: _getScreenForIndex(_activeTabIndex),
              onModeChanged: () async {
                String newLayout;
                if (sidebarPosition == SidebarPosition.left) {
                  newLayout = SharedPreferenceTextConstants.navRightOrderLeft;
                } else if (sidebarPosition == SidebarPosition.right) {
                  newLayout = SharedPreferenceTextConstants.navBottomOrderLeft;
                } else {
                  // Navbar at bottom: next click swaps order panel to right (or back to left layout)
                  newLayout = orderPanelPosition == OrderPanelPosition.left
                      ? SharedPreferenceTextConstants.navBottomOrderRight
                      : SharedPreferenceTextConstants.navLeftOrderRight;
                }
                PinakaPreferences.layoutSelectionNotifier.value = newLayout;
                await UserDbHelper().saveUserSettings({AppDBConst.layoutSelection: newLayout}, modeChange: true);
                setState(() {});
              },
              onProductSelected: (product) async {
                try {
                  _refreshOrderList();
                } catch (e, s) {
                  if (kDebugMode) print("Exception in onProductSelected: $e, Stack: $s");
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(TextConstants.errorAddingItem),
                        backgroundColor: Colors.red,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                }
              },
            ),
            const Divider(color: Colors.grey, thickness: 0.4, height: 1),
            Expanded(
              child: Row(
                children: [
                  if (sidebarPosition == SidebarPosition.left)
                    custom_widgets.NavigationBar(
                      selectedSidebarIndex: _selectedSidebarIndex,
                      onSidebarItemSelected: (index) {
                        setState(() {
                          _selectedSidebarIndex = index;
                          if (index == 0) {
                            _activeTabIndex = 0;
                          } else if (index == 1) {
                            _activeTabIndex = 1;
                          }
                        });
                      },
                      isVertical: true,
                      callbackOnlyIndices: const {0, 1},
                    ),
                  if (sidebarPosition == SidebarPosition.right ||
                      (sidebarPosition == SidebarPosition.bottom && orderPanelPosition == OrderPanelPosition.left))
                    RightOrderPanel(
                      key: const ValueKey('order_panel'),
                      quantities: quantities,
                      refreshOrderList: _refreshOrderList,
                      refreshKey: _refreshCounter,
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: _activeTabIndex,
                      children: [
                        // FastKeyScreen(embedInShell: true),
                        CategoriesScreen(embedInShell: true),
                        AddScreen(embedInShell: true),
                      ],
                    ),
                  ),
                  if (sidebarPosition != SidebarPosition.right &&
                      !(sidebarPosition == SidebarPosition.bottom && orderPanelPosition == OrderPanelPosition.left))
                    RightOrderPanel(
                      key: const ValueKey('order_panel'),
                      quantities: quantities,
                      refreshOrderList: _refreshOrderList,
                      refreshKey: _refreshCounter,
                    ),
                  if (sidebarPosition == SidebarPosition.right)
                    custom_widgets.NavigationBar(
                      selectedSidebarIndex: _selectedSidebarIndex,
                      onSidebarItemSelected: (index) {
                        setState(() {
                          _selectedSidebarIndex = index;
                          if (index == 0) {
                            _activeTabIndex = 0;
                          } else if (index == 1) {
                            _activeTabIndex = 1;
                          }
                        });
                      },
                      isVertical: true,
                      callbackOnlyIndices: const {0, 1},
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
                    if (index == 0) {
                      _activeTabIndex = 0;
                    } else if (index == 1) {
                      _activeTabIndex = 1;
                    }
                  });
                },
                isVertical: false,
                callbackOnlyIndices: const {0, 1},
              ),
          ],
        ),
      ),
    );
  }
}
