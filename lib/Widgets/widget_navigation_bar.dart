import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/svg.dart';
import 'package:pinaka_pos/Screens/Auth/login_screen.dart';
import 'package:pinaka_pos/Screens/Home/apps_dashboard_screen.dart';
import 'package:pinaka_pos/Screens/Home/pos_home_screen.dart';
import 'package:pinaka_pos/Widgets/scanner_guard.dart';
import 'package:pinaka_pos/Widgets/widget_topbar.dart';
import 'package:provider/provider.dart';
import 'package:flutter_swipe_button/flutter_swipe_button.dart';
import '../Blocs/Orders/refund_orderlist_bloc.dart';
import '../Database/order_panel_db_helper.dart';
import '../Database/user_db_helper.dart';
import '../Helper/Extentions/theme_notifier.dart';

import '../Constants/text.dart';
import '../Blocs/Auth/logout_bloc.dart';
import '../Preferences/pinaka_preferences.dart';
import '../Repositories/Auth/logout_repository.dart';
import '../Repositories/Orders/refund_orderlist_repository.dart';
import '../Repositories/session_valadition_repository.dart';
import '../Screens/Home/Settings/settings_screen.dart';
import '../Screens/Home/shift_open_close_balance.dart';
import '../Screens/Home/total_orders_screen.dart';
import '../Screens/refund_screen.dart';
import '../Utilities/svg_images_utility.dart';

class NavigationBar extends StatefulWidget {
  final int selectedSidebarIndex;
  final Function(int) onSidebarItemSelected;
  final bool isVertical;
  final bool isShiftScreen;
  final Future<bool> Function(int index)? onWillNavigate;
  final Set<int>? callbackOnlyIndices;

  const NavigationBar({
    required this.selectedSidebarIndex,
    required this.onSidebarItemSelected,
    this.isVertical = true,
    this.isShiftScreen = false,
    this.onWillNavigate,
    this.callbackOnlyIndices,
    Key? key,
  }) : super(key: key);

  @override
  State<NavigationBar> createState() => _NavigationBarState();
}

class _NavigationBarState extends State<NavigationBar> {
  late Future<String?> _shiftIdFuture;

  @override
  void initState() {
    super.initState();
    _shiftIdFuture = _getShiftId();
  }

  Future<bool> _canNavigate(int index) async {
    return await widget.onWillNavigate?.call(index) ?? true;
  }

  Future<String?> _getShiftId() async {
    if (kDebugMode) {
      print("### Getting shiftId from database");
    }
    int? shiftId = await UserDbHelper().getUserShiftId();
    if (kDebugMode) {
      print("### Retrieved shiftId: $shiftId");
    }
    return shiftId.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final logoutBloc = LogoutBloc(LogoutRepository());

    return Container(
      width:
          widget.isVertical ? MediaQuery.of(context).size.width * 0.07 : null,
      height:
          widget.isVertical ? null : MediaQuery.of(context).size.height * 0.125,
      color: theme.scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(5, 10, 5, 10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0B1023),
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
          child: FutureBuilder<String?>(
            future: _shiftIdFuture,
            builder: (context, snapshot) {
              final shiftId = snapshot.data;
              return widget.isVertical
                  ? _buildVerticalLayout(
                      context, shiftId, logoutBloc, snapshot.connectionState)
                  : _buildHorizontalLayout(
                      context, shiftId, logoutBloc, snapshot.connectionState);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalLayout(BuildContext context, String? shiftId,
      LogoutBloc logoutBloc, ConnectionState connectionState) {
    int lastSelectedIndex = 0;
    final themeHelper = Provider.of<ThemeNotifier>(context);

    bool isShiftInvalid = connectionState != ConnectionState.waiting &&
        (shiftId == null || shiftId == "null" || shiftId.isEmpty);

    bool isShiftScreen = widget.isShiftScreen;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (kDebugMode) {
          print(
              "#### _buildVerticalLayout constraints: $constraints, isShiftInvalid: $isShiftInvalid");
        }
        List<Widget> dynamicItems = [
          // SidebarButton(
          //   svgAsset: widget.selectedSidebarIndex == 0
          //       ? SvgUtils.fastKeySelectedIcon
          //       : SvgUtils.fastKeyIcon,
          //   label: TextConstants.fastKeyText,
          //   isSelected: widget.selectedSidebarIndex == 0,
          //   onTap: isShiftInvalid ||
          //           isShiftScreen ||
          //           widget.selectedSidebarIndex == 0
          //       ? () {}
          //       : () async {
          //           if (!await _canNavigate(0)) return;
          //           lastSelectedIndex = 0;
          //           widget.onSidebarItemSelected(0);
          //           if (widget.callbackOnlyIndices?.contains(0) == true) return;
          //
          //           OrderHelper.isOrderPanelLoaded = false;
          //           OrderHelper.notifyOrderPanelToRefresh();
          //           final oh = OrderHelper();
          //           if (oh.activeOrderId != null) {
          //             await oh.saveLastActiveOrderId(oh.activeOrderId!);
          //           }
          //
          //           Navigator.of(context).pushAndRemoveUntil(
          //             PageRouteBuilder(
          //               pageBuilder: (context, animation, secondaryAnimation) =>
          //                   POSHomeScreen(lastSelectedIndex: 0),
          //             ),
          //             (route) => false,
          //           );
          //         },
          //   isVertical: widget.isVertical,
          //   isDisabled: isShiftInvalid || isShiftScreen,
          // ),
          // const SizedBox(height: 10),
          SidebarButton(
            svgAsset: SvgUtils.categoriesIcon,
            label: TextConstants.categoriesText,
            isSelected: widget.selectedSidebarIndex == 0,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 0
                ? () {}
                : () async {
                    if (!await _canNavigate(0)) return;
                    if (kDebugMode) {
                      print("##### Categories button tapped");
                    }
                    lastSelectedIndex = 0;
                    widget.onSidebarItemSelected(0);
                    if (widget.callbackOnlyIndices?.contains(0) == true) return;

                    OrderHelper.isOrderPanelLoaded = false;
                    OrderHelper.notifyOrderPanelToRefresh();
                    final oh = OrderHelper();
                    if (oh.activeOrderId != null) {
                      await oh.saveLastActiveOrderId(oh.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            POSHomeScreen(lastSelectedIndex: 0),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                          return child;
                        },
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: widget.isVertical,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(height: 10),
          SidebarButton(
            svgAsset: SvgUtils.addIcon,
            label: TextConstants.addText,
            isSelected: widget.selectedSidebarIndex == 1,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 1
                ? () {}
                : () async {
                    if (!await _canNavigate(1)) return;
                    if (kDebugMode) {
                      print("##### AddScreen button tapped");
                    }
                    lastSelectedIndex = 1;
                    widget.onSidebarItemSelected(1);
                    if (widget.callbackOnlyIndices?.contains(1) == true) return;
                    OrderHelper.isOrderPanelLoaded = false;
                    OrderHelper.notifyOrderPanelToRefresh();
                    final ohV2 = OrderHelper();
                    if (ohV2.activeOrderId != null) {
                      await ohV2.saveLastActiveOrderId(ohV2.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            POSHomeScreen(lastSelectedIndex: 1),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                          return child;
                        },
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: widget.isVertical,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(height: 10),
          SidebarButton(
            svgAsset: SvgUtils.ordersIcon,
            label: TextConstants.ordersText,
            isSelected: widget.selectedSidebarIndex == 2,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 2
                ? () {}
                : () async {
                    if (!await _canNavigate(2)) return;
                    if (kDebugMode) {
                      print("##### OrdersScreen button tapped");
                    }
                    lastSelectedIndex = 2;
                    widget.onSidebarItemSelected(2);

                    OrderHelper.isOrderPanelLoaded = false;
                    OrderHelper.notifyOrderPanelToRefresh();
                    final oh = OrderHelper();
                    if (oh.activeOrderId != null) {
                      oh.saveLastActiveOrderId(oh.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            TotalOrdersScreen(
                                lastSelectedIndex: lastSelectedIndex),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                          return child;
                        },
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: widget.isVertical,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(height: 10),
          SidebarButton(
            svgAsset: SvgUtils.appsIcon,
            label: TextConstants.appsText,
            isSelected: widget.selectedSidebarIndex == 3,
            onTap: widget.selectedSidebarIndex == 3
                ? () {}
                : () async {
                    if (!await _canNavigate(3)) return;
                    if (kDebugMode) {
                      print("##### AppsScreen button tapped");
                    }
                    lastSelectedIndex = 3;
                    widget.onSidebarItemSelected(3);
                    final oh = OrderHelper();
                    if (oh.activeOrderId != null) {
                      await oh.saveLastActiveOrderId(oh.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            AppsDashboardScreen(
                                lastSelectedIndex: lastSelectedIndex),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                          return child;
                        },
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: widget.isVertical,
          ),
          const SizedBox(height: 10),
          SidebarButton(
            imageAsset: 'assets/refund.png',
            label: "Refund",
            isSelected: widget.selectedSidebarIndex == 4,
            isDisabled: isShiftInvalid || isShiftScreen,
            onTap: (isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 4)
                ? () {}
                : () async {
                    if (!await _canNavigate(4)) return;
                    if (kDebugMode) {
                      print("##### Refund button tapped");
                    }

                    lastSelectedIndex = 4;
                    widget.onSidebarItemSelected(4);
                    final oh = OrderHelper();
                    if (oh.activeOrderId != null) {
                      await oh.saveLastActiveOrderId(oh.activeOrderId!);
                    }

                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BlocProvider(
                          create: (context) => CompletedOrdersBloc(
                            context.read<CompletedOrdersRepository>(),
                          )..add(
                              FetchCompletedOrders(
                                page: 1,
                                perPage: 10,
                              ),
                            ),
                          child: const CompletedOrdersScreen(
                            lastSelectedIndex: 4,
                          ),
                        ),
                      ),
                    );
                  },
            isVertical: widget.isVertical,
          ),
        ];

        Widget fixedItems = Column(
          children: [
            const Divider(color: Colors.black54),
            SidebarButton(
              svgAsset: SvgUtils.settingsIcon,
              label: TextConstants.settingsHeaderText,
              isSelected: widget.selectedSidebarIndex == 5,
              onTap: isShiftInvalid ||
                      isShiftScreen ||
                      widget.selectedSidebarIndex == 5
                  ? () {}
                  : () async {
                      if (!await _canNavigate(5)) return;
                      if (kDebugMode) {
                        print("##### Settings button tapped");
                      }
                      lastSelectedIndex = widget.selectedSidebarIndex;

                      widget.onSidebarItemSelected(5);

                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  SettingsScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                            return child;
                          },
                          transitionDuration: Duration.zero,
                        ),
                      ).then((_) {
                        widget.onSidebarItemSelected(lastSelectedIndex);
                      });
                    },
              isVertical: widget.isVertical,
              isDisabled: isShiftInvalid || isShiftScreen,
            ),
            const SizedBox(height: 10),
            SidebarButton(
              svgAsset: SvgUtils.logoutIcon,
              label: TextConstants.logoutText,
              isSelected: widget.selectedSidebarIndex == 6,
              onTap: isShiftInvalid || isShiftScreen
                  ? () {}
                  : () async {
                      if (!await _canNavigate(6)) return;
                      final previousIndex = widget.selectedSidebarIndex;
                      widget.onSidebarItemSelected(6);
                      if (kDebugMode) {
                        print("nav logout called");
                      }
                      _showLogoutDialog(
                          context, logoutBloc, themeHelper, previousIndex);
                    },
              isVertical: widget.isVertical,
              isDisabled: isShiftInvalid || isShiftScreen,
            ),
            const SizedBox(height: 10),
          ],
        );

        return Padding(
          padding: const EdgeInsets.only(top: 10.0),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(top: 0),
                  children: dynamicItems,
                ),
              ),
              fixedItems,
            ],
          ),
        );
      },
    );
  }

  Widget _buildHorizontalLayout(BuildContext context, String? shiftId,
      LogoutBloc logoutBloc, ConnectionState connectionState) {
    int lastSelectedIndex = 0;
    final themeHelper = Provider.of<ThemeNotifier>(context);

    bool isShiftInvalid = connectionState != ConnectionState.waiting &&
        (shiftId == null || shiftId == "null" || shiftId.isEmpty);

    bool isShiftScreen = widget.isShiftScreen;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (kDebugMode) {
          print(
              "#### _buildHorizontalLayout constraints: $constraints, isShiftInvalid: $isShiftInvalid");
        }

        List<Widget> dynamicItems = [
          // SidebarButton(
          //   svgAsset: widget.selectedSidebarIndex == 0
          //       ? SvgUtils.fastKeySelectedIcon
          //       : SvgUtils.fastKeyIcon,
          //   label: TextConstants.fastKeyText,
          //   isSelected: widget.selectedSidebarIndex == 0,
          //   onTap: isShiftInvalid ||
          //           isShiftScreen ||
          //           widget.selectedSidebarIndex == 0
          //       ? () {}
          //       : () async {
          //           if (!await _canNavigate(0)) return;
          //           lastSelectedIndex = 0;
          //           widget.onSidebarItemSelected(0);
          //           if (widget.callbackOnlyIndices?.contains(0) == true) return;
          //
          //           OrderHelper.isOrderPanelLoaded = false;
          //           OrderHelper.notifyOrderPanelToRefresh();
          //           final ohH0 = OrderHelper();
          //           if (ohH0.activeOrderId != null) {
          //             await ohH0.saveLastActiveOrderId(ohH0.activeOrderId!);
          //           }
          //
          //           Navigator.of(context).pushAndRemoveUntil(
          //             PageRouteBuilder(
          //               pageBuilder: (context, animation, secondaryAnimation) =>
          //                   POSHomeScreen(lastSelectedIndex: 0),
          //               transitionsBuilder:
          //                   (context, animation, secondaryAnimation, child) =>
          //                       child,
          //               transitionDuration: Duration.zero,
          //             ),
          //             (route) => false,
          //           );
          //         },
          //   isVertical: false,
          //   isDisabled: isShiftInvalid || isShiftScreen,
          // ),
          // const SizedBox(width: 10),
          SidebarButton(
            svgAsset: SvgUtils.categoriesIcon,
            label: TextConstants.categoriesText,
            isSelected: widget.selectedSidebarIndex == 0,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 0
                ? () {}
                : () async {
                    if (!await _canNavigate(0)) return;
                    lastSelectedIndex = 0;
                    widget.onSidebarItemSelected(0);
                    if (widget.callbackOnlyIndices?.contains(0) == true) return;

                    OrderHelper.isOrderPanelLoaded = false;
                    OrderHelper.notifyOrderPanelToRefresh();
                    final ohH1 = OrderHelper();
                    if (ohH1.activeOrderId != null) {
                      await ohH1.saveLastActiveOrderId(ohH1.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            POSHomeScreen(lastSelectedIndex: 0),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) =>
                                child,
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: false,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(width: 10),
          SidebarButton(
            svgAsset: SvgUtils.addIcon,
            label: TextConstants.addText,
            isSelected: widget.selectedSidebarIndex == 1,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 1
                ? () {}
                : () async {
                    if (!await _canNavigate(1)) return;
                    lastSelectedIndex = 1;
                    widget.onSidebarItemSelected(1);
                    if (widget.callbackOnlyIndices?.contains(1) == true) return;
                    OrderHelper.isOrderPanelLoaded = false;
                    OrderHelper.notifyOrderPanelToRefresh();
                    final ohH2 = OrderHelper();
                    if (ohH2.activeOrderId != null) {
                      await ohH2.saveLastActiveOrderId(ohH2.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            POSHomeScreen(lastSelectedIndex: 1),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) =>
                                child,
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: false,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(width: 10),
          SidebarButton(
            svgAsset: SvgUtils.ordersIcon,
            label: TextConstants.ordersText,
            isSelected: widget.selectedSidebarIndex == 2,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 2
                ? () {}
                : () async {
                    if (!await _canNavigate(2)) return;
                    lastSelectedIndex = 2;
                    widget.onSidebarItemSelected(2);

                    OrderHelper.isOrderPanelLoaded = false;
                    OrderHelper.notifyOrderPanelToRefresh();
                    final oh = OrderHelper();
                    if (oh.activeOrderId != null) {
                      oh.saveLastActiveOrderId(oh.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            TotalOrdersScreen(
                                lastSelectedIndex: lastSelectedIndex),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) =>
                                child,
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: false,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(width: 10),
          SidebarButton(
            svgAsset: SvgUtils.appsIcon,
            label: TextConstants.appsText,
            isSelected: widget.selectedSidebarIndex == 3,
            onTap: widget.selectedSidebarIndex == 3
                ? () {}
                : () async {
                    if (!await _canNavigate(3)) return;
                    lastSelectedIndex = 3;
                    widget.onSidebarItemSelected(3);
                    final ohH4 = OrderHelper();
                    if (ohH4.activeOrderId != null) {
                      await ohH4.saveLastActiveOrderId(ohH4.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            AppsDashboardScreen(
                                lastSelectedIndex: lastSelectedIndex),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) =>
                                child,
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: false,
          ),
          const SizedBox(width: 10),
          SidebarButton(
            imageAsset: 'assets/refund.png',
            label: "Refund",
            isSelected: widget.selectedSidebarIndex == 4,
            isDisabled: isShiftInvalid || isShiftScreen,
            onTap: (isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 4)
                ? () {}
                : () async {
                    if (!await _canNavigate(4)) return;
                    lastSelectedIndex = 4;
                    widget.onSidebarItemSelected(4);
                    final ohH5 = OrderHelper();
                    if (ohH5.activeOrderId != null) {
                      await ohH5.saveLastActiveOrderId(ohH5.activeOrderId!);
                    }

                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            BlocProvider(
                          create: (context) => CompletedOrdersBloc(
                            context.read<CompletedOrdersRepository>(),
                          )..add(FetchCompletedOrders(page: 1, perPage: 10)),
                          child:
                              const CompletedOrdersScreen(lastSelectedIndex: 4),
                        ),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) =>
                                child,
                        transitionDuration: Duration.zero,
                      ),
                      (route) => false,
                    );
                  },
            isVertical: false,
          ),
        ];

        List<Widget> fixedItems = [
          const VerticalDivider(color: Colors.black54),
          SidebarButton(
            svgAsset: SvgUtils.settingsIcon,
            label: TextConstants.settingsHeaderText,
            isSelected: widget.selectedSidebarIndex == 5,
            onTap: isShiftInvalid ||
                    isShiftScreen ||
                    widget.selectedSidebarIndex == 5
                ? () {}
                : () async {
                    if (!await _canNavigate(5)) return;
                    lastSelectedIndex = widget.selectedSidebarIndex;
                    widget.onSidebarItemSelected(5);

                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            SettingsScreen(),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) =>
                                child,
                        transitionDuration: Duration.zero,
                      ),
                    ).then((_) {
                      widget.onSidebarItemSelected(lastSelectedIndex);
                    });
                  },
            isVertical: false,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(width: 10),
          SidebarButton(
            svgAsset: SvgUtils.logoutIcon,
            label: TextConstants.logoutText,
            isSelected: widget.selectedSidebarIndex == 6,
            onTap: isShiftInvalid || isShiftScreen
                ? () {}
                : () async {
                    if (!await _canNavigate(6)) return;
                    final previousIndex = widget.selectedSidebarIndex;
                    widget.onSidebarItemSelected(6);
                    _showLogoutDialog(
                        context, logoutBloc, themeHelper, previousIndex);
                  },
            isVertical: false,
            isDisabled: isShiftInvalid || isShiftScreen,
          ),
          const SizedBox(width: 10),
        ];

        Widget dynamicRow = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 10,
            children: dynamicItems,
          ),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: dynamicRow),
              Row(
                children: fixedItems,
              ),
            ],
          ),
        );
      },
    );
  }

  /// Handles swipe-to-close-shift: checks for open orders, then navigates to close shift screen or shows warning.
  void _handleSwipeToCloseShift(
    BuildContext context,
    NavigatorState navigator,
    bool isDarkMode,
  ) async {
    final orderHelper = OrderHelper();

    // Build #1.0.281: Check if there are any ACTIVE orders (with items or payments)
    final bool hasActiveOrders = await orderHelper.hasActiveOrders();

    if (hasActiveOrders) {
      if (kDebugMode) {
        print("===== ACTIVE ORDERS FOUND =====");
        print("Total Orders in Hive: ${orderHelper.orders.length}");

        for (var order in orderHelper.orders) {
          print("---------- ORDER ----------");
          print("Order data : ${order.values}");
          print("----------------------------");
        }
        print("===== END ACTIVE ORDERS =====");
      }

      navigator.pop(); // close logout dialog

      // Show Close Shift Warning popup
      showDialog(
        context: navigator.context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
            insetPadding: const EdgeInsets.symmetric(horizontal: 60),
            child: SizedBox(
              width: 500,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 40,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Close Shift Warning",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDarkMode ? Colors.white : Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Please close all open orders before closing shift",
                      style: TextStyle(
                        fontSize: 14,
                        color: isDarkMode ? Colors.white : Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 45,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          ScannerGuard.isCouponPopupOpen = false;
                          Navigator.of(dialogContext).pop();
                        },
                        child: const Text(
                          "OK",
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } else {
      if (kDebugMode) {
        print("No active orders found -> Navigating to Close Shift screen");
      }

      navigator.pop(); // close logout dialog
      ScannerGuard.isCouponPopupOpen = false;

      navigator.push(
        MaterialPageRoute(
          builder: (context) => ShiftOpenCloseBalanceScreen(),
          settings: const RouteSettings(
            arguments: TextConstants.navLogout,
          ),
        ),
      );
    }
  }

  void _showLogoutDialog(BuildContext context, LogoutBloc logoutBloc,
      ThemeNotifier themeHelper, int previousIndex) {
    ScannerGuard.isCouponPopupOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        bool isDarkMode = themeHelper.themeMode == ThemeMode.dark;

        return Dialog(
          backgroundColor:
              Colors.transparent, // transparent to show tilted container
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            alignment:
                Alignment.center, // centers both horizontally & vertically
            children: [
              // 🔹 Tilted outer container
              Transform.rotate(
                angle: 0.04,
                child: Container(
                  width: 380,
                  height: 400,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDarkMode
                          ? const Color(0xFF434242) // dark mode border
                          : Colors.white, // light mode border
                      width: 3,
                    ),
                  ),
                ),
              ),

              // Inner dialog
              SizedBox(
                width: 370,
                height: 400,
                child: Container(
                  decoration: BoxDecoration(
                    color: isDarkMode ? const Color(0xFF434242) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment:
                        MainAxisAlignment.center, // vertical center
                    crossAxisAlignment:
                        CrossAxisAlignment.center, // horizontal center
                    children: [
                      Image.asset(
                        "assets/logout.png",
                        height: 80,
                        width: 80,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "Are you sure?",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDarkMode ? Colors.white : Colors.black,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Choose what would you like to do before leaving",
                        style: TextStyle(
                          fontSize: 14,
                          color: isDarkMode ? Colors.white : Colors.black,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),

                      // 🔹 Swipe Button
                      SizedBox(
                        width: 300,
                        child: SwipeButton(
                          thumb: Container(
                            width: 70,
                            height: 35,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0xFF033495), Color(0xFF3CCBFF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.double_arrow_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(18),
                          activeTrackColor: Colors.transparent,
                          inactiveTrackColor: Colors.transparent,
                          height: 42,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF033495), Color(0xFF3CCBFF)],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              TextConstants.swipeToCloseShift,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),
                          onSwipe: () {
                            // Capture navigator before any async work - context may be invalid after pop
                            final navigator = Navigator.of(context);
                            _handleSwipeToCloseShift(
                                context, navigator, isDarkMode);
                          },
                        ),
                      ),

                      const SizedBox(height: 35),

                      // 🔹 Cancel & Logout buttons
                      Row(
                        children: [
                          SizedBox(
                            width: 160, // 🔹 set your desired width here
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDarkMode
                                    ? const Color(0xFF4C5F7D)
                                    : const Color(0xFFF6F6F6),
                                fixedSize: const Size(double.infinity, 45),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                      6), // ✅ reduced border radius
                                ),
                              ),
                              onPressed: () {
                                ScannerGuard.isCouponPopupOpen = false;
                                Navigator.of(context).pop();
                                widget.onSidebarItemSelected(previousIndex);
                              },
                              child: Text(
                                TextConstants.cancelText,
                                style: TextStyle(
                                  color: isDarkMode
                                      ? ThemeNotifier.textDark
                                      : const Color(0xFF4C5F7D),
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 150, // 🔹 Set desired width here
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFE6464),
                                fixedSize: const Size(double.infinity,
                                    45), // keeps fixed height = 45
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                      6), // ✅ reduced border radius
                                ),
                              ),
                              onPressed: () async {
                                if (kDebugMode)
                                  print(
                                      "Logout confirmed, initiating logout process");
                                TokenValidationService.logoutStarted();
                                // Show loader
                                showDialog(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (_) => const Center(
                                      child: CircularProgressIndicator()),
                                );

                                await logoutBloc.performLogout();

                                // 1️⃣ Logout user from DB
                                await UserDbHelper().logout();

                                // 2️⃣ Clear SharedPreferences
                                await PinakaPreferences.clearUserPreferences();

                                // 3️⃣ Clear TopBar cached user data 🔥 USE PUBLIC METHOD
                                TopBar.clearUserCache();

                                // 4️⃣ Clear any other runtime cache
                                // VendorData.clearAll();

                                if (kDebugMode) {
                                  print("#### User data cleared during logout");
                                }

                                // 5️⃣ Close loader
                                Navigator.of(context).pop();

                                // 6️⃣ Navigate to login screen
                                ScannerGuard.isCouponPopupOpen = false;
                                Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => LoginScreen()),
                                );
                              },
                              child: Text(
                                TextConstants.logoutText,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 16),
                              ),
                            ),
                          )
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SidebarButton extends StatelessWidget {
  final IconData? icon;
  final String? svgAsset;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isVertical;
  final bool isDisabled;
  final String? imageAsset; // PNG / JPG

  const SidebarButton({
    this.icon,
    this.svgAsset,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isVertical = true,
    this.isDisabled = false,
    this.imageAsset,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.0, horizontal: 0.0),
      child: GestureDetector(
        onTap: onTap,
        child: isVertical
            ? _buildVerticalLayout(context)
            : _buildHorizontalLayout(),
      ),
    );
  }

  Widget _buildVerticalLayout(BuildContext context) {
    return Column(
      children: [
        Container(
          width: MediaQuery.of(context).size.width * 0.05,
          padding:
              const EdgeInsets.only(top: 10.0, bottom: 10, left: 2, right: 2),
          decoration: BoxDecoration(
            shape: BoxShape.rectangle,
            color: isSelected ? Color(0xFFFE6464) : Color(0xFF3B4259),
            // latest color
            // color: isSelected ? Colors.red : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 🔹 ICON (SVG / PNG / ICONDATA)
              if (svgAsset != null)
                SvgPicture.asset(
                  svgAsset!,
                  height: 15,
                  colorFilter: ColorFilter.mode(
                    isSelected
                        ? Colors.white
                        : isDisabled
                            ? Colors.grey.shade800
                            : Colors.white70,
                    BlendMode.srcIn,
                  ),
                )
              else if (imageAsset != null)
                Image.asset(
                  imageAsset!,
                  height: 15,
                  color: isSelected
                      ? Colors.white
                      : isDisabled
                          ? Colors.grey.shade800
                          : Colors.white70,
                )
              else
                Icon(
                  icon,
                  color: isSelected
                      ? Colors.white
                      : isDisabled
                          ? Colors.grey.shade800
                          : Colors.white70,
                ),

              const SizedBox(height: 7),

              // 🔹 LABEL
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? Colors.white
                      : isDisabled
                          ? Colors.grey.shade800
                          : Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: isSelected ? 10.0 : 9.0,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        )
      ],
    );
  }

  Widget _buildHorizontalLayout() {
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 14.0),
        decoration: BoxDecoration(
          shape: BoxShape.rectangle,
          color: isSelected ? Color(0xFFFE6464) : const Color(0xFF3B4259),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Row(
          children: [
            if (svgAsset != null)
              SvgPicture.asset(
                svgAsset!,
                colorFilter: ColorFilter.mode(
                  isSelected
                      ? Colors.white
                      : isDisabled
                      ? Colors.grey.shade800
                      : Colors.white70,
                  BlendMode.srcIn,
                ),
                height: 22,
              )
            else if (imageAsset != null)
              Image.asset(
                imageAsset!,
                height: 22,
                color: isSelected
                    ? Colors.white
                    : isDisabled
                    ? Colors.grey.shade800
                    : Colors.white70,
              )
            else
              Icon(
                icon,
                color: isSelected
                    ? Colors.white
                    : isDisabled
                    ? Colors.grey.shade800
                    : Colors.white,
              ),

            SizedBox(width: isSelected ? 6.0 : 4.0),

            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : isDisabled
                    ? Colors.grey.shade800
                    : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: isSelected ? 16.0 : 14.0,
              ),
            ),
          ],
        )
    );
  }
}
