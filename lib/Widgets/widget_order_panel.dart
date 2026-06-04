import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io';
import 'package:buttons_tabbar/buttons_tabbar.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dotted_line/dotted_line.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_barcode_listener/flutter_barcode_listener.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_svg/svg.dart';
import 'package:focus_detector/focus_detector.dart';
import 'package:http/http.dart' as http;
import 'package:pinaka_pos/Database/storage/storage_provider.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:pinaka_pos/Database/discount_rule_isar.dart';
import 'package:pinaka_pos/Database/isar_cache_entry.dart';
import 'package:pinaka_pos/Models/Search/product_by_sku_model.dart' as SKU;
import 'package:pinaka_pos/Models/Search/product_search_model.dart';
import 'package:pinaka_pos/Models/Search/product_variation_model.dart';
import 'package:pinaka_pos/Providers/Auth/product_variation_provider.dart';
import 'package:pinaka_pos/Repositories/Search/product_search_repository.dart';
import 'package:pinaka_pos/Screens/Home/order_summary_screen.dart';
import 'package:pinaka_pos/Widgets/scanner_guard.dart';
import 'package:pinaka_pos/Widgets/weighing_scale_widget.dart';
import 'package:pinaka_pos/Widgets/widget_age_verification_popup_dialog.dart';
import 'package:pinaka_pos/Widgets/widget_alert_popup_dialogs.dart';
import 'package:pinaka_pos/Widgets/widget_custom_num_pad.dart';
import 'package:pinaka_pos/Widgets/widget_edit_product_items.dart';
import 'package:pinaka_pos/Widgets/widget_nested_grid_layout.dart';
import 'package:pinaka_pos/Widgets/widget_tabs.dart';
import 'package:pinaka_pos/Widgets/widget_topbar.dart';
import 'package:pinaka_pos/Widgets/widget_variants_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../Blocs/Orders/order_bloc.dart';
import '../Blocs/Search/product_search_bloc.dart';
import '../Constants/layout_values.dart';
import '../Constants/misc_features.dart';
import '../Constants/text.dart';
import '../Database/assets_db_helper.dart';
import '../Database/db_helper.dart';
import '../Database/isar_service.dart';
import '../Database/order_panel_db_helper.dart';
import '../Database/user_db_helper.dart';
import '../Helper/native_usb_scan_bridge.dart';
import '../Helper/Extentions/money_rounding_helper.dart';
import '../Helper/Extentions/theme_notifier.dart';
import '../Helper/api_response.dart';
import '../Helper/customerdisplayhelper.dart';
import '../Helper/url_helper.dart';
import '../Models/Assets/asset_model.dart';
import '../Preferences/pinaka_preferences.dart';
import '../Repositories/Category/category_repository.dart';
import '../Screens/Auth/login_screen.dart';
import '../Screens/Home/isar_payments/local_payments_db_helper.dart';
import '../Utilities/global_utility.dart';
import '../Models/Orders/orders_model.dart';
import '../Providers/Age/age_verification_provider.dart';
import '../Repositories/Auth/store_validation_repository.dart';
import '../Repositories/Orders/order_repository.dart';
import '../Screens/Home/add_screen.dart';
import '../Screens/Home/edit_product_screen.dart';
import '../Utilities/svg_images_utility.dart';
import '../services/CustomerDisplayService.dart';
import '../services/customer_services.dart';
import 'ManualPriceDialog.dart';
import 'OrderPopupHelper.dart';
import 'discount_engine_constants.dart';
import 'widget_logs_toast.dart';

class ScannerMutex {
  static bool noOrderBusy = false;
}

String logString = "";
bool isOrderInForeground = true;

///Add visibility code to check if order panel is visible or not
class RightOrderPanel extends StatefulWidget {
  final String? formattedDate;
  final String? formattedTime;
  final List<int> quantities;
  final VoidCallback? refreshOrderList;
  final int
      refreshKey; //Build #1.0.170: Added: Key to trigger refresh only when explicitly needed

  const RightOrderPanel({
    this.formattedDate,
    this.formattedTime,
    required this.quantities,
    this.refreshOrderList,
    this.refreshKey =
        0, //Build #1.0.170: Default to 0, increment externally to trigger refresh
    Key? key,
  }) : super(key: key);

  @override
  _RightOrderPanelState createState() => _RightOrderPanelState();
}

class _RightOrderPanelState extends State<RightOrderPanel>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const MethodChannel customerDisplayChannel =
      MethodChannel('com.alekta.pinakapos/sunmi_display');

  Future<void> _agentDebugLog({
    required String hypothesisId,
    required String location,
    required String message,
    required Map<String, dynamic> data,
    String runId = "run1",
  }) async {
    try {
      final payload = <String, dynamic>{
        "sessionId": "f67d41",
        "runId": runId,
        "hypothesisId": hypothesisId,
        "location": location,
        "message": message,
        "data": data,
        "timestamp": DateTime.now().millisecondsSinceEpoch,
      };
      await File("debug-f67d41.log").writeAsString(
        "${jsonEncode(payload)}\n",
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> enablePhoneInput() async {
    try {
      await customerDisplayChannel.invokeMethod('enablePhoneInput');
    } catch (e) {
      print("Enable phone input error: $e");
    }
  }

  List<Map<String, Object>> tabs = []; // List of order tabs
  TabController? _tabController; // Controller for tab switching
  final ScrollController _scrollController =
      ScrollController(); // Scroll controller for tab scrolling
  List<Map<String, dynamic>> orderItems =
      []; // List of items in the selected order
  final OrderHelper orderHelper =
      OrderHelper(); // Helper instance to manage orders
  bool _isLoading = false;
  static bool _isCustomItemLoading = false;
  bool _isPayBtnLoading = false;
  late OrderBloc orderBloc;
  StreamSubscription? _updateOrderSubscription;
  StreamSubscription? _fetchOrdersSubscription;
  final ProductBloc productBloc = ProductBloc(
      ProductRepository()); // Build #1.0.44 : Added for barcode scanning
  StreamSubscription?
      _productBySkuSubscription; // Build #1.0.44 : Added for product stream
  StreamSubscription? _removePayoutOrDiscountSubscription;
  StreamSubscription? _removeMerchantDiscountSubscription; // Build #1.0.274
  StreamSubscription? _removeCouponSubscription;
  bool _showFullSummary = false;
  late ScaffoldMessengerState _scaffoldMessenger;
  bool _isFetchingInitialData =
      false; // Build #1.0.128: Added this flag to track if we're in the middle of initial fetch
  int _listVersion = 0; // Build 1.0.214: Added this version counter
  double cashbackFee = 0.0;
  bool _scanLocked = false;
  bool _ageVerificationActive = false;
  bool _isWeightDialogOpen = false;
  String? _lastScannedBarcode;
  DateTime? _lastScanTime;
  int _fetchOrderItemsRequestId = 0;

  Map<String, dynamic>? resolvedProductMap;
  VoidCallback? _orderPanelRefreshListener;
  bool _isNewTabDisabled = false;
  bool _isSwitchingOrder = false;

  /// True only after restore + fetch complete; prevents showing stale order items when switching from Orders/Apps.
  bool _initialRestoreDone = false;

  int _currentOrderVersion = 0;

  VoidCallback? _modeChangeListener;

  void _toggleSummary() {
    setState(() {
      _showFullSummary = !_showFullSummary;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  int? _normalizeOrderId(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  /// True when [activeId] matches a tab (handles int/String mismatches).
  bool _tabsContainActiveOrder(int? activeId) {
    if (activeId == null) return false;
    for (final t in tabs) {
      final id = _normalizeOrderId(t['orderId']);
      if (id != null && id == activeId) return true;
    }
    return false;
  }

  String normalizeSku(String sku) {
    return sku.trim().toLowerCase().replaceAll(" ", "");
  }

  late final CategoryRepository _categoryRepository;

  void _onNativeUsbBarcode(String barcode) =>
      unawaited(_handleOrderPanelBarcode(barcode));

  // At top of _RightOrderPanelState
  Future<void> _clearAllOrderData() async {
    if (!mounted) return;

    setState(() {
      orderItems = [];
      tabs = [];
      _listVersion++;
      _currentOrderVersion++;
      _isSwitchingOrder = true;
      _initialRestoreDone = false;
    });

    await orderHelper.clearPersistedCartSelection(); // your existing helper
    await orderHelper.setActiveOrder(null);

    // Clear Hive cache for this order
    final box = StorageProvider.offlineOrders;
    if (orderHelper.activeOrderId != null) {
      await box.delete(orderHelper.activeOrderId.toString());
    }

    OrderHelper.isOrderPanelLoaded = false;

    if (mounted) {
      setState(() => _isSwitchingOrder = false);
    }
  }

  @override
  void initState() {
    super.initState();
    NativeUsbScanBridge.registerHandler(_onNativeUsbBarcode);
    _categoryRepository = CategoryRepository();
    WidgetsBinding.instance.addObserver(this);
    orderBloc = OrderBloc(OrderRepository());
    // Force full refresh when panel mounts (e.g. navigating from Orders tab) so we show
    // the active processing order, not the order viewed in Orders tab
    OrderHelper.isOrderPanelLoaded = false;
// AFTER — keep OLD data visible until new data is ready
    _modeChangeListener = () {
      if (!mounted) return;
      // Mark switching so build() doesn't derive from stale cache,
      // but DO NOT clear orderItems/tabs yet — that causes the flicker.
      setState(() {
        _isSwitchingOrder = true;
        _initialRestoreDone = false;
        _isLoading = true;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        OrderHelper.isOrderPanelLoaded = false;
        await fetchOrdersData(); // sets _isSwitchingOrder = false when done
      });
    };
    TopBar.modeChangedNotifier.addListener(_modeChangeListener!);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await orderHelper.restoreActiveOrderId();
      await fetchOrdersData();
      if (mounted) {
        setState(() => _initialRestoreDone =
            true); // Safe to derive from orderHelper in build
      }
    });
    _orderPanelRefreshListener = () {
      if (mounted) {
        OrderHelper.isOrderPanelLoaded = false;
        fetchOrdersData();
      }
    };
    OrderHelper.orderPanelRefreshNotifier
        .addListener(_orderPanelRefreshListener!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      OrderHelper.isOrderPanelLoaded = false;
      fetchOrdersData();
    }
  }

  double getCurrentMerchantDiscount(Map<String, dynamic> order,
      {double? grossTotal, double? orderDiscount, double? orderTax}) {
    // If any required key is missing, return 0 immediately
    if (!order.containsKey('merchantDiscountType') &&
        !order.containsKey('merchantDiscountFixed') &&
        !order.containsKey('merchantDiscountPercentage')) {
      return 0.0;
    }

    double currentGross = grossTotal ?? 0.0;
    if (grossTotal == null) {
      final products = (order['products'] as List?) ?? [];
      for (var p in products) {
        final price = double.tryParse(p['price']?.toString() ?? '0') ?? 0.0;
        final qty = int.tryParse(p['quantity']?.toString() ?? '1') ?? 1;
        currentGross += price * qty;
      }
    }

    final type = order['merchantDiscountType']?.toString() ?? 'fixed';
    final perc = double.tryParse(
            order['merchantDiscountPercentage']?.toString() ?? '0') ??
        0.0;
    final fixed =
        double.tryParse(order['merchantDiscountFixed']?.toString() ?? '0') ??
            0.0;

    double result = 0.0;
    if (type == 'percentage' && perc > 0) {
      double discVal =
          orderDiscount ?? (order['orderDiscount'] as num?)?.toDouble() ?? 0.0;
      double base = currentGross - discVal;
      result = (base * perc) / 100.0;
    } else {
      result = fixed;
    }

    //  Ignore floating point noise
    return result < 0.000001 ? 0.0 : result;
  }

  // Build #1.0.104: created this function for initial call & while back to this screen
  Future<void> fetchOrdersData() async {
    if (kDebugMode) {
      print("##### fetchOrdersData called (OFFLINE MODE)");
      print(
          "##### fetchOrdersData -> isOrderPanelLoaded : ${OrderHelper.isOrderPanelLoaded}");
    }
    if (OrderHelper.isOrderPanelLoaded) {
      setState(() => _isFetchingInitialData = false);
      // Use loadData (Hive) for consistency with offline mode - avoids full reload when data already available
      await orderHelper.loadData();
      if (mounted) await _getOrderTabs();
      return;
    }
    // ✅ Indicate that we are fetching
    setState(() {
      _isFetchingInitialData = true;
      _isLoading = true;
    });

    try {
      // 🔹 Load offline data directly through OrderHelper
      final helper = OrderHelper();
      await helper.loadData(); // Already loads Hive offline orders

      if (kDebugMode) {
        print("📦 Offline orders loaded: ${helper.orders.length}");
      }

      // ✅ Mark panel loaded and render
      OrderHelper.isOrderPanelLoaded = true;
      if (mounted) await _getOrderTabs(); // Use offline OrderHelper.orders
    } catch (e, s) {
      if (kDebugMode) {
        print("❌ Error loading offline orders in fetchOrdersData: $e");
        print("Stack trace: $s");
      }
    } finally {
      setState(() {
        _isFetchingInitialData = false;
        _isLoading = false;
        _isSwitchingOrder = false; // ← ADD THIS LINE
      });
    }
  }

  @override
  void didUpdateWidget(RightOrderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshKey != widget.refreshKey) {
      if (mounted) {
        setState(() {
          orderItems = [];
          _initialRestoreDone = false;
          _currentOrderVersion++;
          _listVersion++;
        });
      }
      // ── existing code below, unchanged ──────────────────────────────
      if (kDebugMode) print("🔄 Refresh key changed — forcing data reload");
      OrderHelper.isOrderPanelLoaded = false;
      fetchOrdersData();
    }
    if (widget.refreshKey != oldWidget.refreshKey &&
        mounted &&
        !_isFetchingInitialData) {
      setState(() => _isLoading = true);
      if (kDebugMode) {
        print("##### _isFetchingInitialData : $_isFetchingInitialData");
      }
      _getOrderTabs();
    }

    if (kDebugMode) {
      print("##### OrderPanel didUpdateWidget");
    }
  }

  // Build #1.0.10: Fetches the list of order tabs from OrderHelper
  Future<void> _getOrderTabs() async {
    if (kDebugMode) {
      print("##### DEBUG: _getOrderTabs - Loading order tabs");
    }

    await orderHelper.loadData();

    if (!mounted) return;

    // --------------------------------------------------
    // 1️⃣ ASYNC WORK (NO setState here)
    // --------------------------------------------------
    final List<Map<String, dynamic>> visibleOrders = [];

    // Build #1.0.287: Take a snapshot of orders to avoid race conditions during async loop
    final List<Map<String, dynamic>> ordersSnapshot =
        List<Map<String, dynamic>>.from(orderHelper.orders);

    for (final order in ordersSnapshot) {
      final int? orderId = _normalizeOrderId(
        order[AppDBConst.orderServerId] ?? order['order_id'] ?? order['id'],
      );
      if (orderId == null) continue;

      final payments = await LocalPaymentDBHelper.instance
          .getPaymentsByOrderId(orderId, userId: orderHelper.activeUserId);

      final bool hasAnyPayment = payments.isNotEmpty;

      if (kDebugMode) {
        print(
          "🧾 Order $orderId → payments=${payments.length}, hide=$hasAnyPayment",
        );
      }

      // ❌ Hide order once payment starts
      if (hasAnyPayment) continue;

      visibleOrders.add(order);
    }

    // --------------------------------------------------
    // 2️⃣ UI UPDATE (SYNC ONLY)
    // --------------------------------------------------
    if (!mounted) return;

    setState(() {
      tabs = visibleOrders
          .asMap()
          .entries
          .map((entry) {
            final o = entry.value;
            final normalizedId = _normalizeOrderId(
              o[AppDBConst.orderServerId] ??
                  o['order_id'] ??
                  o[AppDBConst.orderId] ??
                  o['id'],
            );
            if (normalizedId == null) {
              return <String, Object>{
                "title": "",
                "subtitle": "Tab ${entry.key + 1}",
                "orderId": 0,
              };
            }
            return {
              "title": "$normalizedId",
              "subtitle": "Tab ${entry.key + 1}",
              "orderId": normalizedId,
            };
          })
          .where((t) => (t["orderId"] as int) > 0)
          .toList();

      if (kDebugMode) {
        print("##### DEBUG: Loaded ${tabs.length} tabs: $tabs");
      }
    });

    // --------------------------------------------------
    // 3️⃣ ACTIVE TAB SAFETY
    // --------------------------------------------------
    // if (tabs.isNotEmpty) {
    //   final visibleIds = tabs.map((t) => t['orderId'] as int).toList();
    //
    //   // if (orderHelper.activeOrderId == null && visibleIds.isNotEmpty) {
    //   //   await orderHelper.setActiveOrder(visibleIds.last); // 👈 keep newest
    //   //   await orderHelper.saveLastActiveOrderId(visibleIds.last);
    //   // }
    //
    // }

    // --------------------------------------------------
    // 4️⃣ CONTROLLER + ITEMS
    // --------------------------------------------------
    if (!mounted) return;

    final visibleOrderIds = tabs
        .map((t) => _normalizeOrderId(t['orderId']))
        .whereType<int>()
        .toList();

    final int? activeId = orderHelper.activeOrderId;

// 🔥 HANDLE ALL INVALID ACTIVE ORDER CASES
    if (activeId != null && !visibleOrderIds.contains(activeId)) {
      if (kDebugMode) {
        print("🟥 Active order $activeId is no longer visible → resetting");
      }

      if (visibleOrderIds.isNotEmpty) {
        //  Switch to newest visible order
        final newActiveId = visibleOrderIds.last;

        await orderHelper.setActiveOrder(newActiveId);
        await orderHelper.saveLastActiveOrderId(newActiveId);

        //  ONLY update display if active order exists
        if (newActiveId != 0) {
          print("Showing new active order on display → $newActiveId");
          await CustomerDisplayHelper.updateCustomerDisplay(newActiveId);
        }
      } else {
        // ❌ NO orders left → FULL RESET
        await orderHelper.setActiveOrder(null);

        if (mounted) {
          setState(() {
            orderItems.clear();
          });
        }

        print("✅ No active orders → showing welcome screen");

        // ✅ ALWAYS fallback to welcome when no orders
        await CustomerDisplayService.showWelcome();
      }
    }

    _initializeTabController();
    await fetchOrderItems();

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  void _fetchOrders() {
    //Build #1.0.40: fetch orders items from API sync & updating to UI
    // updated above
    // setState(() => _isLoading = true); // Build #1.0.104: Show loader
    _fetchOrdersSubscription?.cancel(); //Build #1.0.170
    _fetchOrdersSubscription =
        orderBloc.fetchOrdersStream.listen((response) async {
      if (!mounted) return;

      if (response.status == Status.COMPLETED) {
        if (kDebugMode) {
          print(
              "##### DEBUG: Fetched orders successfully 33333, total orders: ${orderHelper.orders.length}");
        }
        setState(() => _isFetchingInitialData =
            false); // Build #1.0.128: Initial fetch complete
        await _getOrderTabs(); // Build  #1.0.177: add await to loadTabs to fix delay in loading
        OrderHelper.isOrderPanelLoaded = true;
        //_fetchOrdersSubscription?.cancel();
      } else if (response.status == Status.ERROR) {
        if (response.message!.contains('Unauthorised')) {
          if (kDebugMode) {
            print(
                "categories screen 1  ---- Unauthorised : ${response.message!}");
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.pushReplacement(context,
                  MaterialPageRoute(builder: (context) => LoginScreen()));

              if (kDebugMode) {
                print("message 1 --- ${response.message}");
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text("Unauthorised. Session is expired on this device."),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          });
        } else {
          if (kDebugMode) {
            print("##### ERROR: Fetch orders failed - ${response.message}");
          }
          setState(() {
            _isLoading = false;
            _isFetchingInitialData = false; // Build #1.0.128
          }); // Build #1.0.104: Hide loader
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response.message ?? "Failed to fetch orders"),
              backgroundColor: Colors.red, // ✅ Added red background for error
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    });

    orderBloc.fetchOrders();
  }

  // Build #1.0.10: Fetches order items for the active order
  Future<void> fetchOrderItems() async {
    final int requestId = ++_fetchOrderItemsRequestId;

    final activeId = orderHelper.activeOrderId;

    // FIX: Immediately clear orderItems when there is no active order
    if (orderHelper.activeOrderId == null) {
      if (mounted) {
        setState(() {
          orderItems = [];
          _listVersion++;
          _currentOrderVersion++;
        });
      }
      return;
    }

    // #region agent log
    unawaited(_agentDebugLog(
      hypothesisId: "H3",
      location: "widget_order_panel.dart:fetchOrderItems:start",
      message: "fetchOrderItems entry",
      data: {
        "activeOrderId": activeId,
        "tabCount": tabs.length,
        "hasActiveTab":
            activeId != null && tabs.any((t) => t['orderId'] == activeId),
      },
    ));
    // #endregion

    // Tabs can lag behind activeOrderId (e.g. while _getOrderTabs runs, or offline-only).
    // Never clear the cart just because the tab bar has not caught up yet.
    if (!_tabsContainActiveOrder(activeId)) {
      if (kDebugMode) {
        print(
          "⚠️ fetchOrderItems — active order not in tab bar; still loading by id: $activeId",
        );
      }
    }

    if (kDebugMode) {
      print("##### DEBUG: fetchOrderItems 112233");
    }
    if (orderHelper.activeOrderId != null) {
      if (kDebugMode) {
        print(
            "##### DEBUG: order panel fetchOrderItems - Fetching items for activeOrderId: ${orderHelper.activeOrderId}");
      }
      try {
        final int oid = orderHelper.activeOrderId!;
        // 1️⃣ Prefer offline storage; 2️⃣ SQLite — run both reads in parallel when offline may be empty.
        final Future<List<Map<String, dynamic>>> offlineFuture =
            orderHelper.getOrderItemsFromOffline(oid);
        final Future<List<Map<String, dynamic>>> ordersFuture =
            orderHelper.getOrderById(oid);
        final offlineItems = await offlineFuture;
        if (requestId != _fetchOrderItemsRequestId) return;
        // #region agent log
        unawaited(_agentDebugLog(
          hypothesisId: "H3",
          location: "widget_order_panel.dart:fetchOrderItems:offlineRead",
          message: "offline items read",
          data: {
            "activeOrderId": orderHelper.activeOrderId,
            "offlineItemCount": offlineItems.length,
            "firstItemKeys": offlineItems.isNotEmpty
                ? offlineItems.first.keys.take(8).toList()
                : <String>[],
          },
        ));
        // #endregion

        // FIX: Verify that active order hasn't changed while fetching
        if (orderHelper.activeOrderId != oid) {
          if (kDebugMode)
            print("⚠️ Active order changed during fetch, discarding results");
          return;
        }

        if (offlineItems.isNotEmpty) {
          // ── Re-seed tax fields for custom items so buildCurrentOrder
          // displays correct tax without needing to re-derive from Hive ──
          final offlineBox = StorageProvider.offlineOrders;
          final rawOrder = await offlineBox.get(oid.toString());
          if (rawOrder != null) {
            final orderMap = Map<String, dynamic>.from(rawOrder);
            final storedProducts = (orderMap['products'] as List? ?? [])
                .map((e) => Map<String, dynamic>.from(e))
                .toList();

            for (int i = 0; i < offlineItems.length; i++) {
              final displayItem = Map<String, dynamic>.from(offlineItems[i]);
              final itemType =
                  (displayItem['item_type'] ?? '').toString().toLowerCase();
              if (itemType.contains('custom')) {
                // Find matching product in Hive to get tax fields
                final itemName =
                    (displayItem['item_name'] ?? '').toString().toLowerCase();
                final itemPrice = double.tryParse(
                        displayItem['item_price']?.toString() ?? '0') ??
                    0.0;
                final match = storedProducts.firstWhere((p) {
                  final pName = (p['name'] ?? '').toString().toLowerCase();
                  final pPrice =
                      double.tryParse(p['price']?.toString() ?? '0') ?? 0.0;
                  return pName == itemName && (pPrice - itemPrice).abs() < 0.01;
                }, orElse: () => {});

                if (match.isNotEmpty) {
                  final taxRate = double.tryParse(
                          match['tax_rate']?.toString() ??
                              match['tax_percent']?.toString() ??
                              '0') ??
                      0.0;
                  final qty = int.tryParse(
                          displayItem['items_count']?.toString() ?? '1') ??
                      1;
                  final itemTax = taxRate > 0
                      ? roundTaxHalfUp(((itemPrice * taxRate) / 100) * qty)
                      : 0.0;
                  displayItem['tax_rate'] = taxRate;
                  displayItem['tax_class'] = match['tax_class'] ??
                      match['selected_category_tax_slug'] ??
                      '';
                  displayItem['item_tax'] = itemTax;
                  offlineItems[i] = displayItem;
                }
              }
            }
          }

          await orderHelper.loadData();
          if (requestId != _fetchOrderItemsRequestId) return;
          if (orderHelper.activeOrderId != oid) return;

          if (mounted) {
            setState(() {
              if (requestId != _fetchOrderItemsRequestId) return;
              orderItems = List<Map<String, dynamic>>.from(offlineItems);
              _listVersion++;
              _currentOrderVersion++;
            });
          }
          return;
        }
        // 2️⃣ Fallback to SQLite (synced/API orders)
        var orders = await ordersFuture;
        if (requestId != _fetchOrderItemsRequestId) return;
        // FIX: Double-check active order ID again after await
        if (orderHelper.activeOrderId != oid) return;

        if (orders.isEmpty) {
          if (kDebugMode) {
            print(
                "##### DEBUG: fetchOrderItems - No order found for activeOrderId: ${orderHelper.activeOrderId}, clearing items");
          }
          await orderHelper.clearPersistedCartSelection();
          if (mounted) {
            setState(() {
              orderItems = []; // Clear items if no order exists
            });
          }
          await _getOrderTabs(); // Refresh tabs to reflect no active order
          return;
        }

        var order = orders.first;
        if (kDebugMode) {
          print("##### DEBUG: fetchOrderItems - Retrieved ${order.length}");
          print(
              "##### DEBUG: fetchOrderItems - Retrieved order: ${order[AppDBConst.orderServerId]}");
          print(
              "##### DEBUG: fetchOrderItems - Retrieved items: ${order[AppDBConst.itemProductId]}");
        }
        List<Map<String, dynamic>> items =
            await orderHelper.getOrderItems(order[AppDBConst.orderServerId]);
        if (requestId != _fetchOrderItemsRequestId) return;
        if (orderHelper.activeOrderId != oid) return;

        if (kDebugMode) {
          print(
              "##### DEBUG: fetchOrderItems - Retrieved ${items.length} items: $items");
        }

        if (mounted) {
          setState(() {
            if (requestId != _fetchOrderItemsRequestId) return;
            orderItems =
                List<Map<String, dynamic>>.from(items); // Create mutable copy
            _listVersion++; // Build 1.0.214: Increment version when items change
          });
        }
      } catch (e, s) {
        if (kDebugMode) {
          print("##### ERROR: fetchOrderItems failed - $e, Stack: $s");
        }
        if (mounted) {
          setState(() {
            orderItems = []; // Clear items on error
          });
        }
      }
    } else {
      if (kDebugMode) {
        print("##### DEBUG: fetchOrderItems - No active order, clearing items");
      }
      setState(() => _isLoading = false); // Build #1.0.104: Hide loader
      if (mounted) {
        setState(() {
          orderItems = []; // Clear items if no active order
          _listVersion++; // Build 1.0.214: Increment version when items change
        });
      }
    }
  }

  dynamic _convertToJsonSafe(dynamic value) {
    if (value == null) return null;

    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _convertToJsonSafe(v)));
    } else if (value is List) {
      return value.map(_convertToJsonSafe).toList();
    } else if (value is Enum) {
      return value.name;
    } else if (value is Object) {
      try {
        final json = (value as dynamic).toJson?.call();
        if (json is Map) return _convertToJsonSafe(json);
      } catch (_) {}
    }
    return value; // primitives
  }

  Future<void> _initializeTabController() async {
    if (kDebugMode) print("##### _initializeTabController");
    if (!mounted) return;

    if (tabs.isEmpty) {
      orderHelper.activeOrderId = null;
      if (mounted) setState(() => orderItems = []);
      final storeInfo = PinakaPreferences.getLoggedInStore();
      if (storeInfo.isNotEmpty) {
        await CustomerDisplayHelper.updateWelcomeWithStore(
          storeInfo['storeId']!,
          storeInfo['storeName']!,
          storeLogoUrl: storeInfo['storeLogoUrl'],
          storeBaseUrl: storeInfo['storeBaseUrl'],
        );
      } else {
        await CustomerDisplayService.showWelcome();
      }
      return;
    }

    // 1️⃣ Calculate Default Index BEFORE creating controller
    int defaultIndex = 0;
    if (orderHelper.activeOrderId != null) {
      final idx = tabs.indexWhere(
        (t) => _normalizeOrderId(t["orderId"]) == orderHelper.activeOrderId,
      );
      if (idx != -1) {
        defaultIndex = idx;
      } else {
        defaultIndex = 0;
        final fallbackOrderId = _normalizeOrderId(tabs[0]["orderId"]) ?? 0;
        if (fallbackOrderId != 0) {
          await orderHelper.setActiveOrder(fallbackOrderId);
          await orderHelper.saveLastActiveOrderId(fallbackOrderId);
        }
      }
    }

    // 2️⃣ Initialize TabController
    _tabController?.dispose();
    _tabController = TabController(
      length: tabs.length,
      vsync: this,
      initialIndex: defaultIndex,
    );

    // 3️⃣ Tab listener – now clears orderItems immediately for responsive UI
    _tabController!.addListener(() async {
      if (!_tabController!.indexIsChanging &&
          mounted &&
          _tabController!.index < tabs.length) {
        final selectedIndex = _tabController!.index;
        final selectedOrderId =
            _normalizeOrderId(tabs[selectedIndex]["orderId"]);
        if (selectedOrderId == null) return;

        // If already on the same order, do nothing
        if (selectedOrderId == orderHelper.activeOrderId) return;

        // Increment request ID to ignore stale responses
        final int requestId = ++_fetchOrderItemsRequestId;

        // Clear UI immediately – totals will become zero until fetch completes
        setState(() {
          _isSwitchingOrder = true;
          _currentOrderVersion++;
          orderItems = []; // ← clears old items → totals become zero
          _listVersion++;
        });

        await orderHelper.setActiveOrder(selectedOrderId);
        await orderHelper.saveLastActiveOrderId(selectedOrderId);

        // Only fetch if this request is still the latest
        if (requestId == _fetchOrderItemsRequestId && mounted) {
          await fetchOrderItems(); // this will repopulate orderItems
        }

        if (mounted) {
          setState(() => _isSwitchingOrder = false);
          unawaited(
              CustomerDisplayHelper.updateCustomerDisplay(selectedOrderId));
        }
      }
    });

    // 4️⃣ Final UI sync
    if (mounted) {
      final activeTabOrderId =
          _normalizeOrderId(tabs[defaultIndex]["orderId"]) ?? 0;
      if (activeTabOrderId != 0) {
        CustomerDisplayHelper.updateCustomerDisplay(activeTabOrderId);
      }
      setState(() {});
    }
  }

  Future<void> addNewTab() async {
    Future<void> addNewTab() async {
      if (_isNewTabDisabled) return;

      setState(() {
        _isNewTabDisabled = true;
      });

      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() => _isNewTabDisabled = false);
        }
      });

      if (kDebugMode) {
        print("##### DEBUG: addNewTab - Creating new order");
      }

      showLogs = true;
      logString += "##### DEBUG: addNewTab - Creating new order \n ";

      setState(() => _isLoading = true);

      _updateOrderSubscription?.cancel();
      _updateOrderSubscription =
          orderBloc.createOrderStream.listen((response) async {
        if (!mounted) return;

        if (response.status == Status.COMPLETED) {
          setState(() => _isLoading = false);

          final orderId = response.data!.id;

          if (kDebugMode) {
            print("##### Order created: $orderId");
          }

          // ✅ Save order locally
          await orderHelper.createOrder(serverOrderId: orderId);

          // ✅ Set active order
          await orderHelper.setActiveOrder(orderId);
          await orderHelper.saveLastActiveOrderId(orderId);

          // 🔥🔥🔥 ADD THIS BLOCK (IMPORTANT)
          await CustomerDisplayService.showCustomerData(
            orderId: orderId,
            items: [],
            grossTotal: 0.0,
            discount: 0.0,
            merchantDiscount: 0.0,
            netTotal: 0.0,
            tax: 0.0,
            netPayable: 0.0,
            orderDate: "",
            orderTime: "",
            cashbackFee: 0.0,
            loyaltyContact: "",
            summaryEnabled: false,
            discountType: "NONE",
            discountValue: 0.0,
          );
          // 🔥🔥🔥 END FIX

          // ✅ Add tab
          setState(() {
            tabs.add({
              "title": "$orderId",
              "subtitle": "Tab ${tabs.length + 1}",
              "orderId": orderId as Object,
            });
          });

          _initializeTabController();
          _tabController?.index = tabs.length - 1;
          _scrollToSelectedTab();

          await fetchOrderItems();

          // Optional: keep this (will refresh if data comes later)
          await CustomerDisplayHelper.updateCustomerDisplay(orderId);

          if (Misc.showDebugSnackBar) {
            _scaffoldMessenger.showSnackBar(
              const SnackBar(
                content: Text("Order created successfully"),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } else if (response.status == Status.ERROR) {
          setState(() => _isLoading = false);

          _scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(response.message ?? "Failed to create order"),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      });

      logString += await orderBloc.createOrder();
      setState(() {});
    }

    if (_isNewTabDisabled) return; // 🔒 hard guard

    setState(() {
      _isNewTabDisabled = true;
    });

    // 🔓 auto-unlock after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _isNewTabDisabled = false);
      }
    });
    // Create new order if none exists
    if (kDebugMode) {
      print("##### DEBUG: addNewTab - Creating new order");
    }
    showLogs = true;
    logString += "##### DEBUG: addNewTab - Creating new order \n ";

    /// Build #1.0.128: No need here , now we are handling from Order repository class
    // final prefs = await SharedPreferences.getInstance();
    // final shiftId = prefs.getString(TextConstants.shiftId);
    //
    // //Build #1.0.78: Validation required : if shift id is empty show toast or alert user to start the shift first
    // if (shiftId == null || shiftId.isEmpty) {
    //   if (kDebugMode) print("####### _createOrder() : shiftId -> $shiftId");
    //   ScaffoldMessenger.of(context).showSnackBar(
    //     SnackBar(
    //       content: Text("Please start your shift before creating an order."),
    //       backgroundColor: Colors.green,
    //       duration: const Duration(seconds: 2),
    //     ),
    //   );
    // }
    setState(() => _isLoading = true); // Show loader
    // String deviceId = await getDeviceId();
    // OrderMetaData device = OrderMetaData(key: OrderMetaData.posDeviceId, value: deviceId);
    // OrderMetaData placedBy = OrderMetaData(key: OrderMetaData.posPlacedBy, value: '${orderHelper.activeUserId ?? 1}');
    // OrderMetaData shiftIdValue = OrderMetaData(key: OrderMetaData.shiftId, value: shiftId!);
    // List<OrderMetaData> metaData = [device, placedBy, shiftIdValue];

    _updateOrderSubscription?.cancel();
    _updateOrderSubscription =
        orderBloc.createOrderStream.listen((response) async {
      if (!mounted) return;

      if (response.status == Status.COMPLETED) {
        setState(() => _isLoading = false); // Hide loader
        if (kDebugMode) {
          print(
              "##### DEBUG: addNewTab - Order created successfully, serverOrderId: ${response.data!.id}");
        }
        // Persist to SQLite so order panel shows this order
        await orderHelper.createOrder(serverOrderId: response.data!.id);
        setState(() {
          tabs.add({
            "title": "${response.data!.id}",
            "subtitle": "Tab ${tabs.length + 1}",
            "orderId": response.data!.id as Object,
          });
        });

        _initializeTabController();
        _tabController?.index = tabs.length - 1;
        _scrollToSelectedTab();
        await fetchOrderItems();

        if (Misc.showDebugSnackBar) {
          // Build #1.0.254
          _scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text("Order created successfully"),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (response.status == Status.ERROR) {
        if (response.message!.contains('Unauthorised')) {
          if (kDebugMode) {
            print(
                "categories screen 2  ---- Unauthorised : ${response.message!}");
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.pushReplacement(context,
                  MaterialPageRoute(builder: (context) => LoginScreen()));

              if (kDebugMode) {
                print("message 2 --- ${response.message}");
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text("Unauthorised. Session is expired on this device."),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          });
        } else {
          setState(() => _isLoading = false); //Build #1.0.99: Hide loader
          if (kDebugMode) {
            print(
                "##### ERROR: addNewTab - Failed to create order: ${response.message}");
          }
          _scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(response.message ?? "Failed to create order"),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    });

    logString += await orderBloc.createOrder(); // Build #1.0.128
    setState(() {});
  }

  // =============================================================
// GLOBAL HELPER — FIXES ALL MAP<dynamic, dynamic> ERRORS
// =============================================================
  dynamic deepCast(dynamic source) {
    if (source is Map) {
      return source.map(
        (key, value) => MapEntry(key.toString(), deepCast(value)),
      );
    }

    if (source is List) {
      return source.map((e) => deepCast(e)).toList();
    }

    return source;
  }

  // Scrolls to the last tab to ensure visibility
  void _scrollToSelectedTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  // Build #1.0.10: Removes a tab (order) from the UI and database
  //Build #1.0.78:Explanation:
  // Removed orderHelper.deleteOrder from the API success block, as it’s now handled in OrderBloc.changeOrderStatus.
  // Kept local deletion for non-API orders (serverOrderId == null).
  // Ensured loader is shown (_isLoading = true) and hidden appropriately.
  // Added alert dialog for error handling with retry option.

  // Build #1.0.10: Deletes an item from the active order
  //Build #1.0.78: Explanation!
  // Removed database operations (orderHelper.deleteItem) as they’re now in OrderBloc.
  // Added dbOrderId and dbItemId to deleteOrderItem, removeFeeLines, and removeCoupon calls.
  // Used sku in OrderLineItem for custom items and products.
  // Ensured loader is shown during API calls.
  // Kept local deletion for non-API orders.
  bool _isDialogOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaffoldMessenger = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    NativeUsbScanBridge.unregisterHandler(_onNativeUsbBarcode);
    WidgetsBinding.instance.removeObserver(this);
    _updateOrderSubscription?.cancel(); // Cancel the subscription
    //orderBloc.dispose(); // Dispose the bloc if needed
    _fetchOrdersSubscription?.cancel();
    _removeMerchantDiscountSubscription?.cancel();
    orderBloc.dispose();
    productBloc.dispose();
    _tabController?.dispose();
    _scrollController.dispose(); // Dispose ScrollController
    _productBySkuSubscription
        ?.cancel(); // Build #1.0.44 : Added Cancel product subscription
    // productBloc.dispose(); // Added: Dispose ProductBloc
    super.dispose();
    if (_modeChangeListener != null) {
      TopBar.modeChangedNotifier.removeListener(_modeChangeListener!);
    }

    if (_orderPanelRefreshListener != null) {
      OrderHelper.orderPanelRefreshNotifier
          .removeListener(_orderPanelRefreshListener!);
    }
  }

  Future<String> getDeviceId() async {
    // Build #1.0.44 : Get Device Id
    final storeValidationRepository = StoreValidationRepository();
    try {
      final deviceDetails = await GlobalUtility
          .getDeviceDetails(); //Build #1.0.126: updated to GlobalUtility
      return deviceDetails['device_id'] ?? 'unknown';
    } catch (e) {
      if (kDebugMode) {
        print('Error fetching device ID: $e');
      }
      return 'unknown';
    }
  }

  /// Extract DOB from barcode: expects "DBBMMDDYYYY"
  DateTime? parseDOBFromBarcode(String barcodeData) {
    try {
      if (kDebugMode) {
        print("Order Panel parseDOBFromBarcode: $barcodeData");
      }
      final dobMatch = RegExp(r'DBB(\d{8})').firstMatch(barcodeData);
      if (dobMatch != null) {
        final dobStr = dobMatch.group(1)!;
        final month = int.parse(dobStr.substring(0, 2));
        final day = int.parse(dobStr.substring(2, 4));
        final year = int.parse(dobStr.substring(4, 8));
        if (kDebugMode) {
          print("Order Panel parseDOBFromBarcode: $month/$day/$year");
        }
        return DateTime(year, month, day);
      }
    } catch (e) {
      if (kDebugMode) print("Error parsing DOB: $e");
    }
    return null;
  }

  Future<void> _openCustomItemDialog(
      BuildContext context, String barcode) async {
    if (_isCustomItemLoading) return;
    _isCustomItemLoading = true;

    await CustomDialog.showCustomItemNotAdded(
      context,
      onRetry: () {
        Navigator.of(context).pop();
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (context) => AddScreen(
              barcode: barcode,
              selectedTabIndex: 2, // Custom Item tab
            ),
          ),
          (route) => false,
        );
      },
    ).then((_) {
      _isCustomItemLoading = false;
      if (kDebugMode) {
        print("🧩 Custom Item dialog closed for SKU: $barcode");
      }
    });
  }

//Build #1.0.268: 1. add below function in  BarcodeKeyboardListenerState lib
  // void callback(String barcode){
  //   _onBarcodeScannedCallback.call(barcode);
  // }
  // final GlobalKey<BarcodeKeyboardListenerState> _scannerKey = GlobalKey();//Build #1.0.268: 2. create global key

  Future<void> _handleOrderPanelBarcode(String barcode) async {
    if (ScannerMutex.noOrderBusy) {
      print("🚫 BLOCKED BY ScannerMutex.noOrderBusy");
      return;
    }

    if (ScannerGuard.isCouponPopupOpen) {
      if (kDebugMode) {
        print("🚫 Scanner blocked (OrderSummary / Popup / Payment)");
      }
      return;
    }

    //  ⛔ HARD BLOCK — prevents duplicate scans
    if (_scanLocked) return;

    // 🛡️ SOFTWARE DEBOUNCE BLOCK — Prevents duplicate physical scanner bursts
    final now = DateTime.now();
    final sanitizedBarcode = OrderHelper.normalizeSku(barcode);
    if (sanitizedBarcode == _lastScannedBarcode && _lastScanTime != null) {
      if (now.difference(_lastScanTime!).inMilliseconds < 1500) {
        if (kDebugMode)
          print("🚫 Ignored debounced duplicate scan for $sanitizedBarcode");
        return;
      }
    }
    _lastScannedBarcode = sanitizedBarcode;
    _lastScanTime = now;

    final trimmedBarcode = barcode;

    // ⛔ Ignore junk frames
    if (trimmedBarcode.length < 6) return;
    _scanLocked = true;
    try {
      final trimmedBarcode = barcode;
      if (kDebugMode) print("🔹 Scanned → $trimmedBarcode");

      final upper = trimmedBarcode.toUpperCase();

      final bool isDriverLicense = upper.contains("ANSI") ||
          upper.contains("DBB") ||
          upper.contains("DAQ") ||
          upper.contains("DL");

      if (isDriverLicense) {
        if (kDebugMode) {
          print("🪪 Driver License detected → stopping product flow");
          print("🪪 DRIVER LICENSE RAW BARCODE ↓↓↓");
          print(trimmedBarcode); // ✅ FULL PDF417 DATA
          print("🪪 DRIVER LICENSE RAW BARCODE ↑↑↑");
        }
        _ageVerificationActive = true;
        _scanLocked = true;

        // ⏳ Absorb trailing scanner frames
        await Future.delayed(const Duration(milliseconds: 1200));

        _ageVerificationActive = false;
        _scanLocked = false;

        // 🔥 VERY IMPORTANT — STOP HERE
        return;
      }

      if (!isOrderInForeground ||
          trimmedBarcode.isEmpty ||
          _isLoading ||
          _isCustomItemLoading) return;

      _isLoading = true;
      if (mounted) setState(() {});
      final orderHelper = OrderHelper();
      final ensuredOrderId = await orderHelper.ensureOrderExists();

      if (ensuredOrderId == null) {
        print("❌ Scanner: Failed to create or restore order");
        _isLoading = false;
        if (mounted) setState(() {});
        await _openCustomItemDialog(context, trimmedBarcode);
        return;
      }

      final activeOrderId = ensuredOrderId;
      final productBox = StorageProvider.productCache;
      final normalizedBarcode = OrderHelper.normalizeSku(trimmedBarcode);
      final cacheKey = "sku_$normalizedBarcode";

      SKU.ProductBySkuResponse? product;
      bool foundOffline = false;
      // unused local normalizedSku was removed

// The synchronous backend validation that bypassed cache was removed to restore instantaneous scanning speeds.

//             // 🔥 FAST DELETION VALIDATION
//             final isar = await IsarService.instance;
//
//             final cachedEntries = await isar.isarCacheEntrys
//                 .where()
//                 .filter()
//                 .keyStartsWith("products_")
//                 .findAll();
//
//             bool existsInCache = false;
//
//             for (final entry in cachedEntries) {
//               final List<dynamic> products = json.decode(entry.json);
//
//               for (final p in products) {
//                 final sku = (p["sku"] ?? "").toString().toLowerCase();
//
//                 if (sku == normalizedBarcode.toLowerCase()) {
//                   existsInCache = true;
//                   break;
//                 }
//               }
//
//               if (existsInCache) break;
//             }
//
// // 🔥 IF NOT FOUND → OPEN CUSTOM ITEM POPUP
//             if (!existsInCache) {
//               print("🔄 Product removed from backend → opening Custom Item popup");
//
//               _isLoading = false;
//               if (mounted) setState(() {});
//
//               await _openCustomItemDialog(context, trimmedBarcode);
//               return;
//             }
      // ---------------------------------------------------------------------------
      // 1️⃣ MEMORY CACHE
      // ---------------------------------------------------------------------------
// 1️⃣ MEMORY CACHE
// ---------------------------------------------------------------------------
      try {
        final memoryData = OrderHelper.getFromCache(trimmedBarcode);

        if (memoryData != null) {
          if (kDebugMode) {
            print("💾 MEMORY CACHE HIT");
            print("💾 memoryData (raw) → $memoryData");
            try {
              print("💾 memoryData (json) → ${jsonEncode(memoryData)}");
            } catch (_) {
              print("💾 memoryData NOT JSON serializable");
            }
          }

          Map<String, dynamic> productMap;

          // Case A → stored as {products:[{...}]}
          if (memoryData is Map &&
              memoryData["products"] is List &&
              memoryData["products"].isNotEmpty) {
            productMap = Map<String, dynamic>.from(memoryData["products"][0]);

            // 🔐 Restore meta_data safely
            if (productMap["meta_data"] is List) {
              productMap["meta_data"] =
                  List<Map<String, dynamic>>.from(productMap["meta_data"]);
            }

            // 🔐 Restore tags safely
            if (productMap["tags"] is List) {
              productMap["tags"] =
                  List<Map<String, dynamic>>.from(productMap["tags"]);
            }
          }

          // Case B → stored as flat map
          else {
            productMap = Map<String, dynamic>.from(memoryData);
          }
          // 🔥 FIX FOR CUSTOM ITEM RE-SCAN 🔥
          if (productMap.containsKey('product') &&
              productMap['product'] is Map<String, dynamic>) {
            productMap = Map<String, dynamic>.from(productMap['product']);
          }

// ✅ STORE FINAL MAP FOR LATER USE
          resolvedProductMap = productMap;

          if (kDebugMode) {
            print("💾 Extracted productMap from memory → $productMap");
            try {
              print("💾 productMap JSON → ${jsonEncode(productMap)}");
            } catch (_) {
              print("💾 productMap not JSON encodable");
            }
            // ⭐⭐⭐ ADD THESE THREE ⭐⭐⭐
            print("🖼 MEMORY productMap['images'] → ${productMap['images']}");

            if (productMap['images'] is List &&
                productMap['images'].isNotEmpty) {
              print("🖼 MEMORY image src → ${productMap['images'][0]['src']}");
            } else {
              print("🖼 MEMORY image src → NONE");
            }
          }

          product = SKU.ProductBySkuResponse.fromJson(productMap);
          foundOffline = true;

          if (kDebugMode) {
            print(
                "🧠 MEMORY → PRODUCT → name=${product?.name}, price=${product?.price}, sku=${product?.sku}");
          }
        }
      } catch (e, s) {
        print("❌ MEMORY CACHE ERROR → $e");
        print("📌 STACKTRACE → $s");
      }

// ---------------------------------------------------------------------------
// 2️⃣ PRODUCT CACHE (Custom Items + Normal SKU)
// ---------------------------------------------------------------------------
      try {
        if (product == null) {
          final cached = await productBox.get(cacheKey); // <-- await here

          if (cached != null) {
            if (kDebugMode) {
              print("💽 HIVE productCache[$cacheKey] RAW → $cached");
              try {
                print("💽 HIVE JSON → ${jsonEncode(cached)}");
              } catch (_) {
                print("💽 HIVE map not JSON encodable");
              }
            }

            List<dynamic> items = [];

            if (cached is Map && cached["products"] is List) {
              items = List<dynamic>.from(cached["products"]); // safe copy
            }

            if (items.isNotEmpty) {
              final productMap = Map<String, dynamic>.from(items[0]);

              if (kDebugMode) {
                print("💽 Extracted productMap from Hive → $productMap");
                try {
                  print("💽 productMap JSON → ${jsonEncode(productMap)}");
                } catch (_) {
                  print("💽 productMap not JSON encodable");
                }
              }

              product = SKU.ProductBySkuResponse.fromJson(productMap);
              resolvedProductMap = productMap;
              foundOffline = true;

              if (kDebugMode) {
                print(
                    "🟢 productCache → PRODUCT → name=${product?.name}, price=${product?.price}");
              }
            }
          }
        }
      } catch (e, s) {
        print("❌ PRODUCT CACHE ERROR → $e");
        print("📌 STACKTRACE → $s");
      }
      // Removed redundant auto-increment logic.
      // All scans now proceed to product resolution below.

      // ---------------------------------------------------------------------------
      // 4️⃣ FULL LIST CACHE
      // ---------------------------------------------------------------------------
      try {
        if (product == null) {
          final allData = productBox.get("all_products_list");

          if (allData is List) {
            for (var item in await allData) {
              final p = SKU.ProductBySkuResponse.fromJson({
                "products": [deepCast(item)]
              });
              if ((p.sku ?? "").toLowerCase() == trimmedBarcode.toLowerCase()) {
                product = p;
                foundOffline = true;
                break;
              }
            }
          }
        }
      } catch (e) {
        if (kDebugMode) print("⚠ full list error: $e");
      }

      // ---------------------------------------------------------------------------
      // 5️⃣ ONLINE API FETCH
      // ---------------------------------------------------------------------------
      if (product == null) {
        try {
          final products =
              await ProductRepository().fetchProductBySku(trimmedBarcode);

          if (products.isNotEmpty) {
            product = products.first;

            await productBox.put(cacheKey, {
              "products": products.map((p) {
                final map = p.toJson();

                // 🔥 FIX: Persist tags
                map["tags"] = p.tags
                    ?.map((t) => {
                          "id": t.id,
                          "name": t.name,
                          "slug": t.slug,
                        })
                    .toList();

                // 🔥 Also persist meta_data if present
                map["meta_data"] = p.metaData
                    ?.map((m) => {
                          "key": m.key,
                          "value": m.value,
                        })
                    .toList();

                return map;
              }).toList(),
            });

            if (kDebugMode) print("🌐 Online fetch → ${product?.name}");
          }
        } catch (e) {
          print("📴 API error: $e");
        }
      }

      // ---------------------------------------------------------------------------
      // 6️⃣ STILL NULL → CUSTOM ITEM POPUP
      // ---------------------------------------------------------------------------
      // 6️⃣ STILL NULL → CUSTOM ITEM POPUP
      if (product == null) {
        // ❌ Block only if scanner or age flow is active
        if (_ageVerificationActive || isDriverLicense) {
          if (kDebugMode) {
            print("🚫 Custom Item popup BLOCKED (DL / Age / Locked)");
          }

          _isLoading = false;
          if (mounted) setState(() {});
          return;
        }

        // ✅ Stop loader BEFORE opening popup
        _isLoading = false;
        if (mounted) setState(() {});

        // ✅ PASS BARCODE HERE
        await _openCustomItemDialog(context, trimmedBarcode);

        return;
      }

      // ---------------------------------------------------------------------------
      // 7️⃣ EXTRACT PRODUCT DATA
      // ---------------------------------------------------------------------------
      final bool isCustomItem =
          product.id == null || product.id == 0 || product.type == 'custom';

      final productId = product.id ?? 0;

      final productName = isCustomItem
          ? (resolvedProductMap?['name'] ?? 'Custom Item').toString()
          : (product.name ?? 'Unnamed Product');

      final productSku = isCustomItem
          ? (resolvedProductMap?['sku'] ?? trimmedBarcode).toString()
          : (product.sku ?? trimmedBarcode);

      final productPrice = isCustomItem
          ? double.tryParse(
                resolvedProductMap?['price']?.toString() ?? '0',
              ) ??
              0.0
          : double.tryParse(product.price?.toString() ?? '0') ?? 0.0;

      final int? selectedVariationId =
          (product.variations != null && product.variations!.isNotEmpty)
              ? null // variant not selected yet
              : null;

      final taxStatus = isCustomItem
          ? (resolvedProductMap?['tax_status'] ?? '').toString()
          : (product.taxStatus ?? '');
      final taxClass = isCustomItem
          ? (resolvedProductMap?['tax_class'] ?? '').toString()
          : (product.taxClass ?? '');
      final taxRate = isCustomItem
          ? double.tryParse(
                  resolvedProductMap?['tax_rate']?.toString() ?? '0') ??
              0.0
          : 0.0;

// 🖼 Image
      String image = "";
      if ((product.images ?? []).isNotEmpty) {
        image = product.images!.first.src ?? "";
      }

// 🧠 Metadata & Tags
      final metaData = product.metaData ?? [];
      final tags = product.tags ?? [];

      if (kDebugMode) {
        debugPrint("──────── PRODUCT DEBUG ────────");
        debugPrint("ID        : $productId");
        debugPrint("Name      : $productName");
        debugPrint("SKU       : $productSku");
        debugPrint("Price     : $productPrice");
        debugPrint("Image     : $image");

        // 🧠 META DATA
        if (metaData.isNotEmpty) {
          debugPrint("📦 META DATA:");
          for (final m in metaData) {
            debugPrint("  • ${m.key} = ${m.value}");
          }
        } else {
          debugPrint("📦 META DATA: none");
        }

        // 🏷 TAGS
        if (tags.isNotEmpty) {
          debugPrint("🏷 TAGS:");
          for (final tag in tags) {
            debugPrint("  • ${tag.name ?? tag.slug ?? tag.id}");
          }
        } else {
          debugPrint("🏷 TAGS: none");
        }

        debugPrint("──────────────────────────────");
      }
      // SKIP POPUP IF PRODUCT ALREADY EXISTS IN ORDERPANEL
// ------------------------------------------------------------
      final bool exists = await OrderHelper.existsInOrderBySku(
        activeOrderId,
        productSku,
      );
      // ------------------------------------------------------------
// 🔥 FINAL BACKEND EXISTENCE CHECK
// ------------------------------------------------------------
      bool existsInBackend = false;

      try {
        final apiProducts = await ProductRepository()
            .fetchProductBySku(normalizedBarcode, forceRefresh: true);

        existsInBackend = apiProducts.isNotEmpty;

        if (kDebugMode) {
          print("🌐 Backend fresh validation → $existsInBackend");
        }
      } catch (e) {
        print("⚠ Backend validation failed: $e");
      }
// 🚨 If backend says product does NOT exist
      if (!existsInBackend && !isCustomItem) {
        print("⛔ Backend confirms product deleted → cleaning ALL local cache");

        // 🧠 MEMORY
        OrderHelper.removeFromCache(normalizedBarcode);

        // 💽 SKU CACHE
        await StorageProvider.productCache.delete("sku_$normalizedBarcode");

        // 🗑 REMOVE FROM FULL LIST CACHE (SAFE VERSION)
        final allProducts =
            await StorageProvider.productCache.get("all_products_list");

        if (allProducts is List) {
          final updated = allProducts.where((item) {
            try {
              // Case 1: Flat product map
              if (item is Map && item["sku"] != null) {
                final sku = item["sku"].toString().toLowerCase();
                return sku != normalizedBarcode.toLowerCase();
              }

              // Case 2: Wrapped inside {products:[...]}
              if (item is Map &&
                  item["products"] is List &&
                  item["products"].isNotEmpty) {
                final first = item["products"][0];
                final sku = (first["sku"] ?? "").toString().toLowerCase();
                return sku != normalizedBarcode.toLowerCase();
              }

              return true;
            } catch (_) {
              return true;
            }
          }).toList();

          await StorageProvider.productCache.put("all_products_list", updated);
        }

        print("🧹 Local cache fully cleaned for SKU: $normalizedBarcode");

        _isLoading = false;
        if (mounted) setState(() {});

        await _openCustomItemDialog(context, trimmedBarcode);
        return;
      }

      // ---------------------------------------------------------------------------
// ⭐ FINAL EBT ELIGIBILITY CHECK (NOW PRODUCT IS LOADED) ✅
// ---------------------------------------------------------------------------
      bool isEbtEligible = false;

      try {
        final tags = product?.tags ?? [];

        isEbtEligible = tags.any((t) {
          final name = (t.name ?? "").toLowerCase();
          final slug = (t.slug ?? "").toLowerCase();

          return name == "ebt" ||
              name == "ebt eligible" ||
              slug == "ebt" ||
              slug == "ebt-eligible";
        });

        print("💳 FINAL EBT Eligible? → $isEbtEligible (via product.tags)");
      } catch (e) {
        print("⚠ EBT eligibility error → $e");
      }

      // Detect variant intent early so barcode flow does not auto-increment
      // and return before reaching the variants popup/API logic.
      final bool hasVariantTag = (product.tags ?? []).any((t) {
        final name = (t.name ?? "").toLowerCase();
        final slug = (t.slug ?? "").toLowerCase();
        return name.contains("variant") || slug.contains("variant");
      });
      final dynamic hasVariantsRaw = resolvedProductMap?["has_variants"];
      final bool hasVariantMetaFlag = hasVariantsRaw == true ||
          hasVariantsRaw?.toString().toLowerCase() == "true" ||
          hasVariantsRaw?.toString() == "1";
      final bool shouldOpenVariantFlow =
          (product.variations ?? []).isNotEmpty ||
              hasVariantTag ||
              hasVariantMetaFlag;
      final bool hasProduceTag = (product.tags ?? []).any((t) {
        final name = (t.name ?? "").toString().toLowerCase().trim();
        final slug = (t.slug ?? "").toString().toLowerCase().trim();
        return name.contains("produce") || slug.contains("produce");
      });

      // 🔥 ONLY AUTO-INCREMENT NON-VARIANT PRODUCTS
      if (exists &&
          (product.variations ?? []).isEmpty &&
          !shouldOpenVariantFlow &&
          !hasProduceTag) {
        print("🔁 NON-VARIANT → Auto increment");

        await orderHelper.addItemToOrder(
          productId,
          productName,
          image,
          productPrice,
          1,
          productSku,
          activeOrderId,
          type: isCustomItem ? 'custom' : ItemType.product.value,
          productId: productId,
          isEbtEligible: isEbtEligible,
          variationId: 0,
          taxStatus: taxStatus,
          taxClass: taxClass,
          taxRate: taxRate,
        );

        await fetchOrderItems();
        await CustomerDisplayHelper.updateCustomerDisplay(activeOrderId);

        _isLoading = false;
        if (mounted) setState(() {});
        return; // 🚫 STOP HERE — POPUP NEVER OPENS
      }

      // VARIABLE PRICE PRODUCT CHECK
// ------------------------------------------------------------
      final hasVariablePriceTag = (product.tags ?? []).any((tag) {
        final name = (tag.name ?? "").toLowerCase();
        final slug = (tag.slug ?? "").toLowerCase();
        return name.contains("variable product") ||
            slug.contains("variable-product");
      });

      print("🧪 hasVariablePriceTag = $hasVariablePriceTag");
      print("⏳ _isLoading before popup = $_isLoading");

// ------------------------------------------------------------
// ⭐ SHOW VARIABLE PRICE POPUP (ONLY FIRST TIME)
// ------------------------------------------------------------
      if (hasVariablePriceTag) {
        print("💡 Triggering ManualPriceDialog for variable product");

        try {
          final double? enteredPrice = await ManualPriceDialog.show(
            context,
            productName: productName,
            productImage: image,
            minPrice: productPrice,
          );

          print("💬 ManualPriceDialog returned → $enteredPrice");

          if (enteredPrice == null) {
            print("❌ User cancelled ManualPriceDialog");
            return;
          }

          print("✅ Adding variable product to order with price $enteredPrice");

          await orderHelper.addItemToOrder(
            productId,
            productName,
            image,
            enteredPrice,
            1,
            productSku,
            activeOrderId,
            type: isCustomItem ? 'custom' : ItemType.product.value,
            productId: productId,
            variationId: 0,
            isEbtEligible: isEbtEligible,
            taxStatus: taxStatus,
            taxClass: taxClass,
            taxRate: taxRate,
          );

          print("🛒 Product added to order");

          // / ⭐ FIX: MARK VARIABLE PRICE AS ALREADY ADDED
// ------------------------------------------------------------
          // ⭐ FIX: MARK VARIABLE PRICE AS ALREADY ADDED
          final box = StorageProvider.offlineOrders;
          final orderKey = activeOrderId.toString();
          final hiveOrder = Map<String, dynamic>.from(
            await box.get(orderKey),
          );

// Mark that popup has been shown once
          hiveOrder["variable_price_added_$productId"] = true;

// VERY IMPORTANT: Store the actual manual price user entered
          hiveOrder["selected_price_$productId"] = enteredPrice;

          await box.put(orderKey, hiveOrder);

          print(
              "💾 FIX APPLIED → Variable price flags saved for scanned product");
          print("  → variable_price_added_$productId = true");
          print("  → selected_price_$productId = $enteredPrice");

          await fetchOrderItems();
          await CustomerDisplayHelper.updateCustomerDisplay(activeOrderId);

          print("📊 Customer display updated");
        } finally {
          _isLoading = false;
          if (mounted) setState(() {});
          print("⏳ _isLoading after popup = $_isLoading");
        }

        return; // STOP FURTHER EXECUTION
      }

// ------------------------------------------------------------
// ⭐ NORMAL PRODUCT FLOW
// ------------------------------------------------------------
      print("➡ Not a variable product, continuing normal flow");

      // ======================================================
// ⭐ AGE RESTRICTION CHECK — FINAL STABLE VERSION
// ======================================================

      if (kDebugMode) {
        print("\n---------------- AGE CHECK START ----------------");
        print("Product Scanned: ID=${product.id}, Name=${product.name}");
      }

      //PRODUCE (WEIGHED ITEMS) HANDLING
      if (hasProduceTag) {
        if (_isWeightDialogOpen) {
          print("🚫 Weight dialog already open, ignoring duplicate scan");
          return;
        }
        print(
            "🏷 Produce tag detected on product → Showing AutoWeightPriceDialog");

        // Stop loader before showing dialog
        _isLoading = false;
        if (mounted) setState(() {});

        _isWeightDialogOpen = true;
        final result = await showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AutoWeightPriceDialog(
            productName: productName,
            unitPrice: productPrice,
          ),
        ).whenComplete(() {
          _isWeightDialogOpen = false;
        });

        if (result == null) {
          print("Auto weight cancelled by user");
          return;
        }

        final double finalPrice = result["finalPrice"] as double;
        final double weight = result["weight"] as double;

        print(
            "Weight: ${weight}kg, Final Price: ₹${finalPrice.toStringAsFixed(2)}");

        await orderHelper.addItemToOrder(
          null, // or productId if you want to keep reference
          productName,
          image,
          finalPrice,
          1, // quantity = 1 (weight-based item)
          productSku,
          activeOrderId,
          type: 'weighted',
          weightQty: weight,
          productId: productId,
          variationId: -1,
          salesPrice: finalPrice,
          regularPrice: productPrice,
          unitPrice: productPrice,
          isEbtEligible: isEbtEligible,
          // Optional: store weight in meta_data
          // metaData: [
          //   {"key": "weight",   "value": weight.toString()},
          //   {"key": "unit",     "value": "kg"},
          //   {"key": "_weighed", "value": "true"},
          // ],
          onItemAdded: () async {
            print("Weighted produce item added successfully!");
          },
        );

        await fetchOrderItems();
        await CustomerDisplayHelper.updateCustomerDisplay(activeOrderId);

        return; // critical: prevent normal quantity=1 addition below
      }
//

// ------------------------------------------------------
// 1️⃣ INIT
// ------------------------------------------------------
      bool isRestricted = false;
      int minimumAge = 0;

// ------------------------------------------------------
// 2️⃣ CHECK PRODUCT METADATA
// ------------------------------------------------------
      for (final meta in (product.metaData ?? [])) {
        final key = (meta.key ?? "").toLowerCase().trim();
        final rawValue = (meta.value ?? "").toString().toLowerCase().trim();

        // Only process relevant keys
        if (!(key.contains("age") || key.contains("age_restricted"))) continue;

        // Case 1: Boolean restriction (true / yes / 1)
        if (rawValue == "true" || rawValue == "yes" || rawValue == "1") {
          isRestricted = true;
          continue;
        }

        // Case 2: Extract numeric age (18, 21, etc.)
        final match = RegExp(r'\d+').firstMatch(rawValue);
        if (match != null) {
          final parsedAge = int.tryParse(match.group(0)!);
          if (parsedAge != null && parsedAge > minimumAge) {
            minimumAge = parsedAge;
            isRestricted = true;
          }
        }
      }

// ------------------------------------------------------
// 3️⃣ CHECK PRODUCT TAGS (Backup Validation)
// ------------------------------------------------------
      for (final tag in (product.tags ?? [])) {
        final name = (tag.name ?? "").toLowerCase();
        final slug = (tag.slug ?? "").toLowerCase();

        if (name.contains("alcohol") || slug.contains("alcohol")) {
          isRestricted = true;
        }

        final hasAge = name.contains("18+") ||
            name.contains("21+") ||
            name.contains("age") ||
            slug.contains("18+") ||
            slug.contains("21+") ||
            slug.contains("age");

        if (hasAge) {
          final match = RegExp(r'\d+').firstMatch(name + slug);
          if (match != null) {
            final parsedAge = int.tryParse(match.group(0)!);
            if (parsedAge != null && parsedAge > minimumAge) {
              minimumAge = parsedAge;
              isRestricted = true;
            }
          }
        }
      }

// ------------------------------------------------------
// 4️⃣ LOAD ORDER DATA (Hive)
// ------------------------------------------------------
      final hiveBox = StorageProvider.offlineOrders;
      final orderKey = orderHelper.activeOrderId.toString();

      // Ensure order exists
      if (!await hiveBox.containsKey(orderKey)) {
        await hiveBox.put(orderKey, {
          "age_verified": false,
        });
      }

      final Map<String, dynamic> hiveOrder =
          Map<String, dynamic>.from(await hiveBox.get(orderKey));

// ------------------------------------------------------
// 5️⃣ CHECK IF ALREADY VERIFIED
// ------------------------------------------------------
      final bool alreadyVerified = hiveOrder["age_verified"] == true ||
          hiveOrder["age_verified"] == 1 ||
          hiveOrder["age_verified"]?.toString().toLowerCase() == "true";

      if (kDebugMode) {
        print("Age restricted: $isRestricted");
        print("Minimum age   : $minimumAge");
        print("Already verified: $alreadyVerified");
      }

// ------------------------------------------------------
// 6️⃣ SHOW AGE VERIFICATION (ONCE)
// ------------------------------------------------------
      if (isRestricted && !alreadyVerified) {
        // 🔴 STOP LOADING BEFORE OPENING AGE VERIFICATION
        _isLoading = false;
        if (mounted) setState(() {});

        final verified = await AgeVerificationProvider()
            .ageRestrictedProduct(context, product);

        // ❌ User cancelled or failed verification
        if (!verified) {
          return;
        }

        // ✅ Mark as verified for this order
        hiveOrder["age_verified"] = true;
        await hiveBox.put(orderKey, hiveOrder);
      }

      if (kDebugMode) {
        print("---------------- AGE CHECK END ----------------\n");
      }

      // ---------------------------------------------------------------------------
      // 8️⃣ VARIATIONS FLOW
      // =====================================================================
      if (shouldOpenVariantFlow) {
        List<Map<String, dynamic>> variants = [];

        // 1️⃣ Try existing bloc stream flow first.
        try {
          productBloc.fetchProductVariations(product.id);
          final response = await productBloc.variationStream
              .firstWhere((r) => r.status == Status.COMPLETED)
              .timeout(const Duration(milliseconds: 1200));

          variants = (response.data ?? [])
              .map((v) => {
                    "id": v.id,
                    "name": v.name,
                    "price": v.price,
                    "image": v.image?.src,
                    "sku": v.sku,
                  })
              .toList();
        } catch (_) {
          // Fall through to direct API fetch below.
        }

        // 2️⃣ Fallback: direct Woo variation API by product id.
        if (variants.isEmpty && product.id > 0) {
          try {
            final userData = await UserDbHelper().getUserData();
            final String token = userData?[AppDBConst.userToken] ?? "";
            final uri = Uri.parse(
                '${UrlHelper.baseUrl}${UrlHelper.wooCommerceV3}products/${product.id}/variations');
            final headers = <String, String>{
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            };
            final resp = await http.get(uri, headers: headers);
            if (resp.statusCode == 200) {
              final decoded = jsonDecode(resp.body);
              if (decoded is List) {
                variants = decoded
                    .whereType<Map>()
                    .map<Map<String, dynamic>>((v) {
                      final map = v
                          .map((key, value) => MapEntry(key.toString(), value));
                      final attrs = map["attributes"];
                      final String fallbackName = attrs is List
                          ? attrs
                              .whereType<Map>()
                              .map((a) => (a["option"] ?? "").toString())
                              .where((x) => x.isNotEmpty)
                              .join(" - ")
                          : "";
                      return {
                        "id": map["id"],
                        "name": (map["name"] ?? "").toString().isNotEmpty
                            ? map["name"]
                            : (fallbackName.isNotEmpty
                                ? fallbackName
                                : "Variant"),
                        "price": (map["price"] ?? map["regular_price"] ?? "0")
                            .toString(),
                        "image":
                            (map["image"] is Map && map["image"]["src"] != null)
                                ? map["image"]["src"]
                                : (map["image"] is String ? map["image"] : ""),
                        "sku": map["sku"] ?? "",
                      };
                    })
                    .where((v) => v["id"] != null)
                    .toList();
              }
            }
          } catch (e) {
            if (kDebugMode) {
              print("⚠️ Variation fallback API failed: $e");
            }
          }
        }

        if (variants.isEmpty) {
          _isLoading = false;
          if (mounted) setState(() {});
          return;
        }

        // 3️⃣ SHOW VARIANT POPUP (ALWAYS)
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => VariantsDialog(
            title: product?.name ?? "",
            variations: variants,
            onAddVariant: (selected, qty) async {
              await orderHelper.addItemToOrder(
                selected["id"],
                selected["name"],
                selected["image"],
                double.tryParse(selected["price"].toString()) ?? 0,
                qty,
                selected["sku"],
                activeOrderId,
                type: 'variant',
                productId: product?.id,
                variationId: selected["id"],
                isEbtEligible: isEbtEligible,
              );
              await fetchOrderItems();
              await CustomerDisplayHelper.updateCustomerDisplay(activeOrderId);

              Navigator.of(_).pop();
            },
          ),
        );

        // 🔥 THIS LINE IS CRITICAL
        // ⛔ STOP EVERYTHING ELSE
        _isLoading = false;
        if (mounted) setState(() {});
        return;
      }

      // ---------------------------------------------------------------------------
      // 9️⃣ ADD ITEM TO ORDER
      // ---------------------------------------------------------------------------
      await orderHelper.addItemToOrder(
        productId,
        productName,
        image,
        productPrice,
        1,
        productSku,
        activeOrderId,
        type: isCustomItem ? 'custom' : ItemType.product.value,
        productId: productId,
        variationId: 0,
        isEbtEligible: isEbtEligible,
        taxStatus: taxStatus,
        taxClass: taxClass,
        taxRate: taxRate,
      );

      await fetchOrderItems();
      await CustomerDisplayHelper.updateCustomerDisplay(activeOrderId);

      _isLoading = false;
      if (mounted) setState(() {});
    } catch (e, s) {
      print("❌ Scan failed: $e\n$s");
    } finally {
      _scanLocked = false;
      // Only reset loading flags
      if (_isLoading) {
        _isLoading = false;
        if (mounted) setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return FocusDetector(
      onFocusLost: () {
        // Build #1.0.219 -> FIXED ISSUE [SCRUM - 366] : Swipe-to-Delete UI State Not Resetting
        // When this widget regains focus, reset slidable states
        if (!mounted) return;
        setState(() {
          _listVersion++;
        });
      },
      child: BarcodeKeyboardListener(
        // Build #1.0.44 : Added - Wrap with BarcodeKeyboardListener for barcode scanning
        // key:  _scannerKey,//Build #1.0.268: 3. Add key for scanner event
        bufferDuration: const Duration(milliseconds: 700),
        //Build #1.0.78: Removed orderHelper.addItemToOrder from the API success block, as it’s now in OrderBloc.updateOrderProducts.
        // Kept local addItemToOrder for non-API orders.
        // Ensured loader is shown during API calls and hidden afterward.
        useKeyDownEvent: Platform.isWindows,
        caseSensitive: true,
        onBarcodeScanned: (barcode) =>
            unawaited(_handleOrderPanelBarcode(barcode)),

        child: Stack(
          children: [
            // 🔹 Main Order Panel (Card + Tabs)
            Container(
              width: MediaQuery.of(context).size.width * 0.31,
              padding: const EdgeInsets.fromLTRB(2, 0, 10, 10),
              child: Card(
                elevation: 4,
                margin: const EdgeInsets.only(top: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    children: [
                      // 🔹 Tabs header
                      Container(
                        color: themeHelper.themeMode == ThemeMode.dark
                            ? ThemeNotifier.primaryBackground
                            : null,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // 🔹 Tabs row
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                controller: _scrollController,
                                child: Row(
                                  children: _tabController == null
                                      ? []
                                      : List.generate(tabs.length, (index) {
                                          final tabOrderId = _normalizeOrderId(
                                              tabs[index]["orderId"]);
                                          final isSelected =
                                              tabOrderId != null &&
                                                  tabOrderId ==
                                                      orderHelper.activeOrderId;

                                          return Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4, vertical: 4),
                                            child: GestureDetector(
                                              onTap: () {
                                                if (_tabController == null)
                                                  return;

                                                if (_tabController!.index !=
                                                    index) {
                                                  _tabController!
                                                      .animateTo(index);
                                                }
                                              },
                                              child: Container(
                                                height: 50,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 12),
                                                decoration: BoxDecoration(
                                                  color: isSelected
                                                      ? const Color(0xFFFCDFDC)
                                                      : (themeHelper
                                                                  .themeMode ==
                                                              ThemeMode.dark
                                                          ? const Color(
                                                              0xFF31354A)
                                                          : const Color(
                                                              0xFFEFEEEE)),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Text(
                                                      (tabs[index]["title"] ??
                                                              "")
                                                          .toString(),
                                                      style: TextStyle(
                                                        color: isSelected
                                                            ? const Color(
                                                                0xFFFE6464)
                                                            : const Color(
                                                                0xFF999393),
                                                        fontWeight: isSelected
                                                            ? FontWeight.bold
                                                            : FontWeight.w500,
                                                        fontSize: isSelected
                                                            ? 15
                                                            : 14,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 9),
                                                    if (isSelected)
                                                      GestureDetector(
                                                        onTap: () {
                                                          CustomDialog
                                                              .showAreYouSure(
                                                            context,
                                                            confirm: () {
                                                              removeTab(index);
                                                            },
                                                          );
                                                        },
                                                        child: Image.asset(
                                                          "assets/deletecircle.png",
                                                          width: 20,
                                                          height: 20,
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        }),
                                ),
                              ),
                            ),

                            // 🔹 New tab button
                            ElevatedButton(
                              onPressed: _isNewTabDisabled ? null : addNewTab,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                elevation: 0,
                                padding: const EdgeInsets.only(right: 4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: Container(
                                width: 85,
                                height: 50,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _isNewTabDisabled
                                      ? const Color(
                                          0xFFE0E0E0) // 🔘 grey background
                                      : (themeHelper.themeMode == ThemeMode.dark
                                          ? const Color(0xFF000000)
                                          : const Color(0xFFFFFFFF)),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: _isNewTabDisabled
                                        ? const Color(
                                            0xFFBDBDBD) // 🔘 grey border
                                        : const Color(0xFFFE6464),
                                    width: 1.0,
                                  ),
                                  boxShadow: _isNewTabDisabled
                                      ? [] // 🔕 no shadow when disabled
                                      : [
                                          BoxShadow(
                                            color: themeHelper.themeMode ==
                                                    ThemeMode.dark
                                                ? const Color(0xFF525252)
                                                : const Color(0xFFB2AFAF),
                                            blurRadius: 4,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _isNewTabDisabled
                                              ? const Color(
                                                  0xFF9E9E9E) // 🔘 grey icon border
                                              : const Color(0xFFFE6464),
                                          width: 2,
                                        ),
                                      ),
                                      child: Icon(
                                        Icons.add,
                                        size: 16,
                                        color: _isNewTabDisabled
                                            ? const Color(
                                                0xFF9E9E9E) // 🔘 grey icon
                                            : const Color(0xFFFE6464),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      "New",
                                      style: TextStyle(
                                        color: _isNewTabDisabled
                                            ? const Color(
                                                0xFF9E9E9E) // 🔘 grey text
                                            : const Color(0xFFFE6464),
                                        fontSize: 16,
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

                      // 🔹 Content area
                      Expanded(child: buildCurrentOrder()),
                    ],
                  ),
                ),
              ),
            ),

            // 🔹 Empty Order Panel Overlay (when tabs list is empty)
            if (tabs.isEmpty &&
                orderHelper.activeOrderId == null &&
                !_isSwitchingOrder &&
                !_isLoading &&
                !_isFetchingInitialData)
              Positioned.fill(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset(
                        'assets/scannerandsearch.png',
                        width: 100,
                        height: 100,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'No items in the Order panel',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? Colors.white
                              : const Color(0xFF373535),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Order panel is empty. Add items by scanning,\nsearching, or selecting from the list.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? Colors.grey[400]
                              : Colors.grey.shade500,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  //Build #1.0.268: 5. (optional) to show logs on screen
  bool showLogs = false;
  Widget _showLogString() {
    return Container(
      width: MediaQuery.of(context).size.width * 0.30,
      color: const Color(0x7A000000),
      child: Stack(children: [
        Text(
          logString,
          style: TextStyle(color: Colors.white70),
        ),
        Positioned(
            top: 2,
            right: 2,
            child: CloseButton(
              onPressed: () {
                showLogs = false;
                logString = "";
                setState(() {});
              },
            )),
      ]),
    );
  }

//   Future<bool> _ageRestrictedProduct(SKU.ProductBySkuResponse product) async {
//     ///@
// //
// // ANSI 636026100102DL00410277ZA03180012DLDAQD05848559 DCSBELE SHRAVAN DDEN DACKUMAR DDFNvDADNONEaDDGNrDCAD DCBNONEtDCDNONEaDBD02052025gDBB07181978gDBA09032030 DBC1=DAU070 in DAYBROpDAG233 W FELLARS DRrDAIPHOENIXoDAJAZdDAK850237501  uDCF003402EB0B124005cDCGUSAtDCK48102972534.DDAFtDDB02282023aDDD1gDAZBLKsDAW196?DDK1
// //     ZAZAAN.ZACN
//
//     var isVerified = false;
//     var tagg = product.tags?.firstWhere((element) => element.name == "Age Restricted", orElse: () => SKU.Tags());
//     var hasAgeRestriction = tagg?.name?.contains("Age Restricted");
//
//     if (kDebugMode) {
//       print("Order Panel _ageRestrictedProduct hasAgeRestriction = $hasAgeRestriction");
//     }
//
//     if (hasAgeRestriction ?? false) {
//       var tag = product.tags?.firstWhere((element) => element.name == "Age Restricted", orElse: () => SKU.Tags());
//       if (kDebugMode) {
//         print("Order Panel _ageRestrictedProduct hasAgeRestriction tag = ${tag?.id}, ${tag?.name}, ${tag?.slug}");
//       }
//       if (tag?.slug == "") {
//         return isVerified;
//       }
//       await AgeVerificationHelper.showAgeVerification(
//         context: context,
//         // productName: product.name,
//         minimumAge: int.parse(tag?.slug ?? "0"),
//         onManualVerify: () {
//           // Add product to cart - manually verified
//           // _addToCart(product);
//           isVerified = true;
//         },
//         onAgeVerified: () {
//           // Add product to cart - age verified
//           // _addToCart(product);
//           isVerified = true;
//         },
//         onCancel: () {
//           // User cancelled - don't add to cart
//           isVerified = false;
//           Navigator.pop(context);
//         },
//       );
//     } else {
//       // No age restriction - add directly
//       // _addToCart(product);
//       isVerified = true;
//     }
//     return isVerified;
//   }

  //Build #1.0.67: Handler methods for response and error

  Future<void> _handleResponse(
    APIResponse response,
    Map<String, dynamic> orderItem, {
    bool isPayout = false,
    bool isCoupon = false,
    bool isCustomItem = false,
    VoidCallback? retryCallback, // Call back
  }) async {
    if (!mounted) return;
    if (response.status == Status.COMPLETED) {
      //Build #1.0.170: Updated - No need to make _isLoading is false here , we are doing after refresh!
      // setState(() => _isLoading = false); //Build #1.0.92
      if (Misc.showDebugSnackBar) {
        // Build #1.0.254
        _scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(
                "${isPayout ? 'Payout' : isCoupon ? 'Coupon' : isCustomItem ? 'Custom Item' : 'Item'} removed successfully"),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      await orderHelper.deleteItem(orderItem[AppDBConst.itemServerId]);
      await fetchOrderItems();
      widget.refreshOrderList?.call();
    } else if (response.status == Status.ERROR) {
      if (response.message!.contains('Unauthorised')) {
        if (kDebugMode) {
          print("categories screen 5 ---- Unauthorised : ${response.message!}");
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.pushReplacement(context,
                MaterialPageRoute(builder: (context) => LoginScreen()));

            if (kDebugMode) {
              print("message 5 --- ${response.message}");
            }
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content:
                    Text("Unauthorised. Session is expired on this device."),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 2),
              ),
            );
          }
        });
      } else {
        setState(() => _isLoading = false); //Build #1.0.99 : hide loader
        _scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(
                "Failed to remove ${isPayout ? 'payout' : isCoupon ? 'coupon' : isCustomItem ? 'custom item' : 'item'}"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
        if (isPayout) {
          await CustomDialog.showDiscountNotApplied(
            context,
            errorMessageTitle: TextConstants.removePayoutFailed,
            errorMessageDes:
                response.message ?? TextConstants.discountNotAppliedDescription,
            onRetry: retryCallback, // Pass retry callback
          );
        } else if (isCoupon) {
          await CustomDialog.showCouponNotApplied(
            context,
            errorMessageTitle: TextConstants.removeCouponFailed,
            errorMessageDes:
                response.message ?? TextConstants.couponNotAppliedDescription,
            onRetry: retryCallback, // Pass retry callback
          );
        } else if (isCustomItem) {
          await CustomDialog.showCustomItemNotAdded(
            context,
            errorMessageTitle: TextConstants.removeCustomItemFailed,
            errorMessageDes: response.message ??
                TextConstants.customItemCouldNotBeAddedDescription,
            onRetry: retryCallback,
          );
        }
      }
    }
  }

  //Build #1.0.67
  void _handleError(String message,
      {bool isPayout = false,
      bool isCoupon = false,
      bool isCustomItem = false}) async {
    if (!mounted) return; // Check if widget is still mounted
    setState(() => _isLoading = false);
    _scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 2),
      ),
    );
    //Build #1.0.99: Dismiss any open dialog
    Navigator.of(context, rootNavigator: true).pop();
  }

  //Build #1.0.67
  Future<void> _handleLocalDelete(
      Map<String, dynamic> orderItem, BuildContext context) async {
    if (!mounted) return; // Check if widget is still mounted
    setState(() => _isLoading = false);
    await orderHelper
        .deleteItem(orderItem[AppDBConst.itemServerId]); //Build #1.0.92
    await fetchOrderItems();
    widget.refreshOrderList?.call();
    _scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(TextConstants.itemRemoved),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> removeTab(int index) async {
    if (tabs.isEmpty) {
      print("❌ removeTab called but tabs is empty");
      return;
    }

    final int orderId = tabs[index]["orderId"] as int;
    final bool isRemovedTabActive = orderId == orderHelper.activeOrderId;

    print("\n================= 🗑 REMOVE TAB START =================");
    print("👉 Removing Tab Index: $index");
    print("👉 Removing Order ID: $orderId");
    print("👉 Is Active Order Being Removed? $isRemovedTabActive");
    print("======================================================\n");

    setState(() => _isLoading = true);

    try {
      final offlineBox = StorageProvider.offlineOrders;
      final deletedBox = StorageProvider.deletedOrders;

      print(
          "📦 Offline Orders Box Contains ID? ${await offlineBox.containsKey(orderId.toString())}");

      final bool isOfflineOrder =
          await offlineBox.containsKey(orderId.toString());
      if (isOfflineOrder) {
        print("\n🟡 OFFLINE ORDER DETECTED — Performing Offline Delete Flow");
        await OrderRepository().saveOfflineOrderTotals(orderId);

        // ⭐ 1️⃣ READ ORDER DATA BEFORE DELETE
        final orderData = await offlineBox.get(orderId.toString());
        print("📤 Original Offline Order Data:\n$orderData");

        if (orderData == null) {
          print("⚠️ orderData is NULL — cannot sync or backup!");
          return;
        }

        // ⭐ 2️⃣ Sync attempt BEFORE deleting locally
        print("🌐 Attempting to sync deleted offline order to backend…");

        final result =
            await OrderRepository().syncOfflineDeletedOrders([orderData]);
        final bool syncSuccess = result["success"] == true;
        final int? syncedWooId = result["wooOrderId"];

// ******************************************************************
// 🔥 ALWAYS SAVE CASHBACK + TAX + WOO ORDER ID IN orderExtras BOX
// ******************************************************************
        final extrasBox = StorageProvider.orderExtras;

// 1️⃣ Resolve Woo Order ID correctly (supports all key formats)
        // if server returned Woo Order ID → use it
        final wooOrderId = (syncedWooId ??
                orderData["woo_order_id"] ??
                orderData["wooOrderId"] ??
                orderId)
            .toString();

// 2️⃣ Resolve Cashback Fee from ALL possible key names
        final cashbackFee = (orderData["cashbackFee"] ??
                orderData["order_cashback_fee"] ??
                orderData["cashback_fee"] ??
                orderData["cashbackFeeTotal"] ??
                orderData["cashback"] ??
                0)
            .toDouble();

// 3️⃣ Resolve Tax (all supported variations)
        final tax = (orderData["tax"] ??
                orderData["wooTax"] ??
                orderData["order_tax"] ??
                orderData["totalTax"] ??
                0)
            .toDouble();

// 4️⃣ Save final extras
        await extrasBox.put(wooOrderId, {
          "woo_order_id": wooOrderId,
          "local_offline_id": orderId,
          "cashback_fee": cashbackFee,
          "tax": tax,
          "synced": syncSuccess,
          "saved_at": DateTime.now().toIso8601String(),
        });

        print("💾 SAVED TO orderExtras BOX:");
        print("   WooID: $wooOrderId");
        print("   Cashback Fee: $cashbackFee");
        print("   Tax: $tax");
        print("   Synced: $syncSuccess");
        print("📦 Current orderExtras: ${await extrasBox.get(wooOrderId)}");
// ******************************************************************

        if (syncSuccess) {
          print("✅ Deleted order synced successfully → No Hive backup needed");

          await offlineBox.delete(orderId.toString());
          await orderHelper.deleteOrder(orderId);

          // ── FIX: clear stale items immediately so they never flash on the next tab ──
          setState(() {
            tabs.removeAt(index);
            orderItems = []; // ← ADD THIS
            _isSwitchingOrder = true; // ← ADD THIS
            _currentOrderVersion++; // ← ADD THIS
            _listVersion++; // ← ADD THIS
          });

          if (tabs.isEmpty) {
            orderHelper.activeOrderId = null;
            print("🧹 No tabs left → FINAL display reset");
            await CustomerDisplayService.resetDisplay();
            await _initializeTabController();
            if (mounted)
              setState(() {
                _isLoading = false;
                _isSwitchingOrder = false; // ← ADD THIS
              });
            return;
          }

          // ── after removing, switch active order and fetch fresh items ──
          final int newIndex = index >= tabs.length ? tabs.length - 1 : index;
          final int newActiveOrderId = tabs[newIndex]["orderId"] as int;

          if (isRemovedTabActive) {
            await orderHelper.setActiveOrder(newActiveOrderId);
            await orderHelper.saveLastActiveOrderId(newActiveOrderId);
          }

          await _initializeTabController();

          // ── FIX: only load items if offline data exists for this order ──
          if (await offlineBox.containsKey(newActiveOrderId.toString())) {
            await fetchOrderItems();
          } else {
            if (mounted) setState(() => orderItems = []);
          }

          if (mounted)
            setState(() {
              _isLoading = false;
              _isSwitchingOrder = false; // ← ADD THIS
            });
          return;
        }
        // ❌ Sync failed → store in deletedOrders
        print("⚠️ Sync FAILED → Storing in deletedOrders Hive box...");

        final userData = await UserDbHelper().getUserData();
        final currentUserId = userData?[AppDBConst.userId];
        final currentUserName = userData?[AppDBConst.username] ?? "";
        final currentShiftId = await UserDbHelper().getUserShiftId();

        final enhancedDeletedOrder = {
          ...orderData,
          "deleted_order_id": orderId,
          "client_order_id": orderId.toString(),
          "deleted_by_user_id": currentUserId,
          "deleted_by_user_name": currentUserName,
          "deleted_shift_id": currentShiftId,
          "deleted_at": DateTime.now().toIso8601String(),
        };
        await deletedBox.put(orderId.toString(), enhancedDeletedOrder);

        // Delete from offline and UI cleanup
        await offlineBox.delete(orderId.toString());
        await orderHelper.deleteOrder(orderId);

        orderHelper.orders.removeWhere((o) =>
            o[AppDBConst.orderServerId] == orderId ||
            o[AppDBConst.orderId] == orderId);
        orderHelper.orderIds.remove(orderId);

        setState(() {
          tabs.removeAt(index);
          for (int i = 0; i < tabs.length; i++) {
            tabs[i]["subtitle"] = "Tab ${i + 1}";
          }
        });

        if (tabs.isEmpty) {
          orderHelper.activeOrderId = null;
          orderItems = [];
          await _initializeTabController();
          setState(() => _isLoading = false);
          return;
        }

        final int newIndex = index >= tabs.length ? tabs.length - 1 : index;
        final int newActiveOrderId = tabs[newIndex]["orderId"] as int;

        if (isRemovedTabActive) {
          await orderHelper.setActiveOrder(newActiveOrderId);
          await orderHelper.saveLastActiveOrderId(newActiveOrderId);
        }

        await _initializeTabController();
        await fetchOrderItems();

        _tabController!.index = newIndex;

        setState(() => _isLoading = false);
        return;
      }

      // ============================================================
      // ===============  ONLINE ORDER DELETE AREA  ================
      // ============================================================

      print("\n🔵 ONLINE ORDER DETECTED — Calling API to cancel order…");

      final int serverOrderId = orderId;

      _updateOrderSubscription?.cancel();
      _updateOrderSubscription =
          orderBloc.changeOrderStatusStream.listen((response) async {
        if (!mounted) return;

        print("🌐 Server Cancel Status: ${response.status}");

        if (response.status == Status.COMPLETED) {
          print("✅ Server confirmed order cancellation");

          await orderHelper.deleteOrder(orderId);
          orderHelper.cancelledOrderId = serverOrderId;

          print("🧹 Removing order tab from UI…");
          setState(() {
            tabs.removeAt(index);
            for (int i = 0; i < tabs.length; i++) {
              tabs[i]["subtitle"] = "Tab ${i + 1}";
            }
          });

          if (tabs.isEmpty) {
            print("❗ All tabs closed after delete");
            orderHelper.activeOrderId = null;
            orderItems = [];
            await _initializeTabController();
            setState(() => _isLoading = false);
            return;
          }

          final int newIndex = index >= tabs.length ? tabs.length - 1 : index;
          final int newActiveOrderId = tabs[newIndex]["orderId"] as int;

          print(
              "🔄 New active tab index: $newIndex, OrderId: $newActiveOrderId");

          if (isRemovedTabActive) {
            print("🔄 Updating active order due to removal");
            await orderHelper.setActiveOrder(newActiveOrderId);
            await orderHelper.saveLastActiveOrderId(newActiveOrderId);
          }

          print("🔧 Reinitializing tab controller…");
          await _initializeTabController();

          if (await offlineBox.containsKey(newActiveOrderId.toString())) {
            print("📥 Loading offline items for new order");
            await fetchOrderItems();
          } else {
            print("⚠️ No offline items found for this order");
            setState(() => orderItems = []);
          }

          _tabController!.index = newIndex;

          print(
              "================= 🗑 REMOVE TAB END (ONLINE) ================\n");

          setState(() => _isLoading = false);
        }
      });

      print("🌐 Sending cancel order request to server…");
      await orderBloc.changeOrderStatus(
        orderId: serverOrderId,
        status: TextConstants.cancelled,
      );
    } catch (e) {
      print("❌ ERROR in removeTab(): $e");
      setState(() => _isLoading = false);
    }
  }

  int totalItems = 0;
  Future<void> deleteOfflineItem(Map<String, dynamic> orderItem,
      {int? itemIndex}) async {
    if (orderHelper.activeOrderId == null) return;

    final offlineBox = StorageProvider.offlineOrders;
    final String orderKey = orderHelper.activeOrderId.toString();
    final rawOfflineOrder = await offlineBox.get(orderKey);

    if (rawOfflineOrder == null) return;

    final Map<String, dynamic> offlineOrder =
        Map<String, dynamic>.from(rawOfflineOrder);

    // ============================
    // 🛑 CHECK: LAST ITEM + MERCHANT DISCOUNT
    // ============================

    // ============================
// 🛑 CHECK: MERCHANT DISCOUNT WHEN DELETING ITEMS
// ============================
    double productsTotal =
        ((offlineOrder['products'] as List?) ?? []).fold(0.0, (sum, p) {
      final price = double.tryParse(p['price']?.toString() ?? '0') ?? 0;
      final qty = int.tryParse(p['quantity']?.toString() ??
              p['items_count']?.toString() ??
              '1') ??
          1;
      return sum + (price * qty);
    });

    double customTotal =
        ((offlineOrder['custom_items'] as List?) ?? []).fold(0.0, (sum, c) {
      final price = double.tryParse(c['custom_item_price']?.toString() ??
              c['amount']?.toString() ??
              c['price']?.toString() ??
              '0') ??
          0;
      final qty = int.tryParse(c['quantity']?.toString() ??
              c['items_count']?.toString() ??
              '1') ??
          1;
      return sum + (price * qty);
    });

    double cashbackTotal =
        ((offlineOrder['cashbacks'] as List?) ?? []).fold(0.0, (sum, c) {
      final amount = double.tryParse(c['amount']?.toString() ?? '0') ?? 0.0;
      return sum + amount;
    });

    final double itemPrice = double.tryParse(
            orderItem['item_price']?.toString() ??
                orderItem[AppDBConst.itemPrice]?.toString() ??
                '0') ??
        0;

    final int itemQty = int.tryParse(orderItem['items_count']?.toString() ??
            orderItem[AppDBConst.itemCount]?.toString() ??
            '1') ??
        1;

    final double itemLineTotal = itemPrice * itemQty;

    final double currentTotal = productsTotal + customTotal;
    final double newTotal = currentTotal - itemLineTotal;
    final double merchantDiscount = (offlineOrder['merchantDiscount'] is num)
        ? (offlineOrder['merchantDiscount'] as num).toDouble()
        : 0.0;

    // If no discount → allow delete
    // 🔍 Detect type FIRST
    final String itemType = (orderItem['item_type'] ?? orderItem['type'] ?? '')
        .toString()
        .toLowerCase();

    final bool isPayout = itemType == 'payout';
    final bool isCashback = itemType == 'cashback';

    // ✅ Skip merchant discount handling for payout & cashback
    if (merchantDiscount > 0 && !isPayout && !isCashback) {
      double productsTotal =
          ((offlineOrder['products'] as List?) ?? []).fold(0.0, (sum, p) {
        final price = double.tryParse(p['price']?.toString() ?? '0') ?? 0;
        final qty = int.tryParse(p['quantity']?.toString() ??
                p['items_count']?.toString() ??
                '1') ??
            1;
        return sum + (price * qty);
      });

      double customTotal =
          ((offlineOrder['custom_items'] as List?) ?? []).fold(0.0, (sum, c) {
        final price = double.tryParse(c['custom_item_price']?.toString() ??
                c['amount']?.toString() ??
                c['price']?.toString() ??
                '0') ??
            0;
        final qty = int.tryParse(c['quantity']?.toString() ??
                c['items_count']?.toString() ??
                '1') ??
            1;
        return sum + (price * qty);
      });

      final double currentTotal = productsTotal + customTotal;

      final double itemPrice = double.tryParse(
              orderItem['item_price']?.toString() ??
                  orderItem[AppDBConst.itemPrice]?.toString() ??
                  '0') ??
          0;

      final int itemQty = int.tryParse(orderItem['items_count']?.toString() ??
              orderItem[AppDBConst.itemCount]?.toString() ??
              '1') ??
          1;

      final double itemLineTotal = itemPrice * itemQty;
      final double newTotal = currentTotal - itemLineTotal;

      if (newTotal < merchantDiscount) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Merchant discount is more than the new order total. Please remove merchant discount first before decreasing items.",
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        // Block decreasing / deleting this item until user removes discount.
        return;
      }
    }
    if (!isPayout && !isCashback && cashbackTotal > 0) {
      if (cashbackTotal > newTotal) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.red,
            content: Text(
              "Cashback is more than the new order total. Please remove cashback first before deleting items.",
            ),
          ),
        );
        return;
      }
    }
    // ============================
    // CONTINUE WITH NORMAL DELETE LOGIC
    // ============================

    // 🔍 Detect type: product / payout / cashback
    // final String itemType =
    //     (orderItem['item_type'] ?? '').toString().toLowerCase();

    final List<Map<String, dynamic>> products =
        (offlineOrder['products'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e))
                .toList() ??
            [];

    final List<Map<String, dynamic>> customItems =
        (offlineOrder['custom_items'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e))
                .toList() ??
            [];

    final List<Map<String, dynamic>> payouts =
        (offlineOrder['payouts'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e))
                .toList() ??
            [];

    final List<Map<String, dynamic>> cashbacks =
        (offlineOrder['cashbacks'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e))
                .toList() ??
            [];

    // Index-based removal: orderItems = [products..., custom_items..., payouts..., cashbacks...]
    final int productsLen = products.length;
    final int customLen = customItems.length;
    final int payoutsLen = payouts.length;
    final bool useIndex = itemIndex != null && itemIndex >= 0;

    // 🟦 DELETE PAYOUT
    if (itemType == 'payout') {
      if (useIndex) {
        if (itemIndex! < productsLen) {
          products.removeAt(itemIndex);
          offlineOrder['products'] = products;
        } else {
          final payoutsStart = productsLen + customLen;
          if (itemIndex >= payoutsStart &&
              itemIndex < payoutsStart + payoutsLen) {
            payouts.removeAt(itemIndex - payoutsStart);
          }
        }
      } else {
        payouts.removeWhere((p) {
          final amt1 = double.tryParse(p['amount']?.toString() ?? '0') ?? 0;
          final amt2 =
              double.tryParse(orderItem['item_price']?.toString() ?? '0') ?? 0;
          return amt1 == amt2;
        });
      }
      offlineOrder['payouts'] = payouts;
    }

    // 🟪 DELETE CUSTOM ITEM (from custom_items or products with type custom)
    else if (itemType.contains('custom')) {
      if (useIndex) {
        if (itemIndex! < productsLen) {
          products.removeAt(itemIndex);
        } else if (itemIndex >= productsLen &&
            itemIndex < productsLen + customLen) {
          customItems.removeAt(itemIndex - productsLen);
        }
        offlineOrder['products'] = products;
        offlineOrder['custom_items'] = customItems;
      } else {
        final tappedName =
            (orderItem['item_name'] ?? orderItem[AppDBConst.itemName] ?? '')
                .toString()
                .toLowerCase();
        final tappedPrice = double.tryParse(
                orderItem['item_price']?.toString() ??
                    orderItem[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
            0;

        customItems.removeWhere((c) {
          final name =
              (c['custom_item_name'] ?? c['item_name'] ?? c['name'] ?? '')
                  .toString()
                  .toLowerCase();
          final price = double.tryParse(c['custom_item_price']?.toString() ??
                  c['amount']?.toString() ??
                  c['price']?.toString() ??
                  '0') ??
              0;
          return name == tappedName && (price - tappedPrice).abs() < 0.001;
        });
        offlineOrder['custom_items'] = customItems;

        products.removeWhere((p) {
          final type =
              (p['item_type'] ?? p['type'] ?? '').toString().toLowerCase();
          if (!type.contains('custom')) return false;
          final name =
              (p['name'] ?? p['custom_item_name'] ?? p['product_name'] ?? '')
                  .toString()
                  .toLowerCase();
          final price = double.tryParse(p['price']?.toString() ??
                  p['custom_item_price']?.toString() ??
                  '0') ??
              0;
          return name == tappedName && (price - tappedPrice).abs() < 0.001;
        });
        offlineOrder['products'] = products;
      }
    }

    // 🟩 DELETE CASHBACK
    else if (itemType == 'cashback') {
      if (useIndex) {
        final cashbacksStart = productsLen + customLen + payoutsLen;

        if (itemIndex! >= cashbacksStart &&
            itemIndex < cashbacksStart + cashbacks.length) {
          cashbacks.removeAt(itemIndex - cashbacksStart);
        }
      } else {
        cashbacks.removeWhere((cb) {
          final amt1 = double.tryParse(cb['amount']?.toString() ?? '0') ?? 0;
          final amt2 =
              double.tryParse(orderItem['item_price']?.toString() ?? '0') ?? 0;
          return (amt1 - amt2).abs() < 0.001;
        });
      }

      offlineOrder['cashbacks'] = cashbacks;
      if (cashbacks.isEmpty) {
        offlineOrder['cashbackFee'] = 0.0;
        offlineOrder['cashback_fee'] = 0.0;
      }
    }

    // 🛒 DELETE PRODUCT (includes variant)
    else {
      int deletedProductId = -1;
      String matchedSku = "";
      Map<String, dynamic>? removedProduct;

      if (useIndex && itemIndex! < productsLen) {
        removedProduct = products.removeAt(itemIndex);
        if (removedProduct != null) {
          deletedProductId = (removedProduct['product_id'] ??
                  removedProduct['id'] ??
                  removedProduct['fast_key_product_id'] ??
                  removedProduct['serverItemId'] ??
                  -1) is num
              ? ((removedProduct['product_id'] ??
                      removedProduct['id'] ??
                      removedProduct['fast_key_product_id'] ??
                      removedProduct['serverItemId'] ??
                      -1) as num)
                  .toInt()
              : -1;
          matchedSku = (removedProduct['sku'] ??
                  removedProduct['item_sku'] ??
                  removedProduct['product_sku'] ??
                  removedProduct['fast_key_item_sku'] ??
                  '')
              .toString()
              .toLowerCase()
              .trim();
        }
      } else {
        final orderProductId = (orderItem['product_id'] as num?)?.toInt() ?? -1;
        final orderVariationId =
            (orderItem['variation_id'] as num?)?.toInt() ?? 0;
        final orderSku =
            (orderItem['sku'] ?? '').toString().toLowerCase().trim();

        bool matchProduct(Map<String, dynamic> p) {
          if (orderProductId >= 0) {
            final pid = (p['product_id'] ?? p['id'] ?? -1) is num
                ? ((p['product_id'] ?? p['id'] ?? -1) as num).toInt()
                : -1;
            final vid = (p['variation_id'] ??
                    p['variationId'] ??
                    p['item_variation'] ??
                    0) is num
                ? ((p['variation_id'] ??
                        p['variationId'] ??
                        p['item_variation']) as num)
                    .toInt()
                : 0;
            if (pid == orderProductId && vid == orderVariationId) return true;
          }
          if (orderSku.isNotEmpty) {
            final pSku = (p['sku'] ?? p['item_sku'] ?? '')
                .toString()
                .toLowerCase()
                .trim();
            if (pSku == orderSku) return true;
          }
          final name1 =
              (p['name'] ?? p['product_name'] ?? p['fast_key_item_name'] ?? '')
                  .toString()
                  .toLowerCase();
          final name2 = (orderItem['item_name'] ?? '').toString().toLowerCase();
          final price1 = double.tryParse(p['price']?.toString() ?? '0') ?? 0;
          final price2 =
              double.tryParse(orderItem['item_price']?.toString() ?? '0') ?? 0;
          return name1 == name2 && (price1 - price2).abs() < 0.001;
        }

        products.removeWhere((p) {
          final match = matchProduct(p);
          if (match) {
            deletedProductId = (p['product_id'] ??
                    p['id'] ??
                    p['fast_key_product_id'] ??
                    p['serverItemId'] ??
                    -1) is num
                ? ((p['product_id'] ??
                        p['id'] ??
                        p['fast_key_product_id'] ??
                        p['serverItemId'] ??
                        -1) as num)
                    .toInt()
                : -1;
            matchedSku = (p['sku'] ??
                    p['item_sku'] ??
                    p['product_sku'] ??
                    p['fast_key_item_sku'] ??
                    '')
                .toString()
                .toLowerCase()
                .trim();
          }
          return match;
        });
      }

      offlineOrder['products'] = products;

      // -------------------------------
      // RESET VARIABLE PRICE FLAGS
      // -------------------------------
      if (deletedProductId != -1) {
        offlineOrder.remove("variable_price_added_$deletedProductId");
        offlineOrder.remove("selected_price_$deletedProductId");

        print(
            "🧹 Cleared variable price flags for product → $deletedProductId");
      } else {
        print("⚠️ Could not determine product_id for cleanup.");
      }

      // ---------------------------------
      // CLEAN MEMORY & HIVE SKU CACHE
      // ---------------------------------
      if (matchedSku.isNotEmpty) {
        print("🔍 Cleaning caches for SKU → $matchedSku");

        try {
          OrderHelper.removeFromCache(matchedSku);
          print("🧠 In-memory product cache cleared → $matchedSku");
        } catch (e) {
          print("⚠️ Memory cache cleanup failed → $e");
        }

        try {
          final productBox = StorageProvider.productCache;
          final cacheKey = "sku_$matchedSku";

          if (await productBox.containsKey(cacheKey)) {
            await productBox.delete(cacheKey);
            print("💽 HIVE productCache cleared → $cacheKey");
          } else {
            print("💽 No Hive cache entry found for $cacheKey");
          }
        } catch (e) {
          print("⚠️ Hive cache cleanup failed → $e");
        }
      } else {
        print("⚠️ SKU could not be extracted → Cannot clean cache.");
      }
    }

    // Recalculate totals after delete
    double productTotal = 0.0;
    for (final p in products) {
      final qty = int.tryParse(p['quantity']?.toString() ??
              p['items_count']?.toString() ??
              '1') ??
          1;
      final price = double.tryParse(p['price']?.toString() ?? '0') ?? 0.0;
      productTotal += price * qty;
    }
    for (final c in customItems) {
      final qty = int.tryParse(c['quantity']?.toString() ??
              c['items_count']?.toString() ??
              '1') ??
          1;
      final price = double.tryParse(c['custom_item_price']?.toString() ??
              c['amount']?.toString() ??
              c['price']?.toString() ??
              '0') ??
          0.0;
      productTotal += price * qty;
    }
    double payoutsTotal = payouts.fold<double>(0,
        (s, p) => s + (double.tryParse(p['amount']?.toString() ?? '0') ?? 0));
    double cashbacksTotal = cashbacks.fold<double>(0,
        (s, c) => s + (double.tryParse(c['amount']?.toString() ?? '0') ?? 0));
    // final grossTotal = productTotal + payoutsTotal + cashbacksTotal;

    final double grossTotal = productTotal + payoutsTotal + cashbacksTotal;
    final double orderDiscount =
        (offlineOrder['orderDiscount'] as num?)?.toDouble() ?? 0.0;
    final double merchantDiscountVal =
        (offlineOrder['merchantDiscount'] as num?)?.toDouble() ?? 0.0;
    final double cashbackFee =
        (offlineOrder['cashbackFee'] as num?)?.toDouble() ?? 0.0;

    // 🔁 RECOMPUTE ORDER TAX FROM UPDATED ITEMS
    double orderTax = 0.0;
    for (final p in products) {
      final String itemType =
          (p['item_type'] ?? p['type'] ?? '').toString().toLowerCase();
      final int qty = int.tryParse(p['quantity']?.toString() ??
              p['items_count']?.toString() ??
              '1') ??
          1;
      final double price =
          double.tryParse(p['price']?.toString() ?? '0') ?? 0.0;

      if (!itemType.contains('custom')) {
        const double defaultNonEbtTaxRate = 9.1;
        final int productId =
            int.tryParse((p['product_id'] ?? p['id'])?.toString() ?? '0') ?? 0;
        final bool isEbt = p['is_ebt_eligible'] == true;
        final lineTaxStatus =
            (p['tax_status'] ?? 'taxable').toString().toLowerCase();
        final lineTaxRate =
            double.tryParse((p['tax_rate'] ?? '0').toString()) ?? 0.0;
        if (isEbt) {
          orderTax += 0.0;
        } else if (lineTaxStatus == 'taxable' && lineTaxRate > 0) {
          orderTax += roundTaxHalfUp(((price * qty) * lineTaxRate) / 100);
        } else {
          double fallbackTax = getProductTaxFromHive(productId, price, qty);
          if (fallbackTax <= 0 && lineTaxStatus != 'none') {
            fallbackTax =
                roundTaxHalfUp(((price * qty) * defaultNonEbtTaxRate) / 100);
          }
          orderTax += fallbackTax;
        }
      } else {
        orderTax += getCustomItemTax(
          taxClass: p['tax_class'] ?? '',
          unitPrice: price,
          qty: qty,
          taxes: await _assetDBHelper.getTaxList(),
          taxRate: p['tax_rate'],
        );
      }
    }
    orderTax = roundTaxHalfUp(orderTax);
    offlineOrder['order_tax'] = orderTax;

    offlineOrder['gross_total'] = grossTotal;
    offlineOrder['net_total'] =
        grossTotal - orderDiscount - merchantDiscountVal;
    offlineOrder['net_payable'] =
        offlineOrder['net_total'] + orderTax + cashbackFee;

    // 💾 Save updated order back to offline storage
    await offlineBox.put(orderKey, offlineOrder);
    await orderHelper.loadData();

    // Build products list for customer display
    final List productsForDisplay = products.map((p) {
      return {
        "name": p["name"] ?? p["product_name"] ?? "",
        "quantity": p["quantity"] ?? p["items_count"] ?? 1,
        "price": p["price"] ?? 0,
      };
    }).toList();

    // Send update directly via CustomerService
    // Do not block UI; display publishing can be slow.
    // unawaited(CustomerService.publishCartUpdate(
    //   orderHelper.activeOrderId!,
    //   productsForDisplay,
    //   subtotal: grossTotal,
    //   tax: orderTax,
    //   total: (offlineOrder['net_payable'] as num?)?.toDouble() ?? 0.0,
    // ));

    OrderHelper.notifyOrderPanelToRefresh();

    // 🔁 Refresh UI - rebuild will use updated order from loadData
    if (mounted) {
      setState(() {
        orderItems.removeWhere((i) {
          final it = (i['item_type'] ?? i[AppDBConst.itemType] ?? '')
              .toString()
              .toLowerCase();
          if (it == 'payout') {
            final amt1 = double.tryParse(i['item_price']?.toString() ??
                    i[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
                0;
            final amt2 = double.tryParse(orderItem['item_price']?.toString() ??
                    orderItem[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
                0;
            return amt1 == amt2;
          }
          if (it == 'cashback') {
            final amt1 = double.tryParse(i['item_price']?.toString() ??
                    i[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
                0;
            final amt2 = double.tryParse(orderItem['item_price']?.toString() ??
                    orderItem[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
                0;
            return amt1 == amt2;
          }
          if (it.contains('custom')) {
            final n1 = (i['item_name'] ?? i[AppDBConst.itemName] ?? '')
                .toString()
                .toLowerCase();
            final n2 =
                (orderItem['item_name'] ?? orderItem[AppDBConst.itemName] ?? '')
                    .toString()
                    .toLowerCase();
            final p1 = double.tryParse(i['item_price']?.toString() ??
                    i[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
                0;
            final p2 = double.tryParse(orderItem['item_price']?.toString() ??
                    orderItem[AppDBConst.itemPrice]?.toString() ??
                    '0') ??
                0;
            return n1 == n2 && (p1 - p2).abs() < 0.001;
          }
          final pid1 = (i['product_id'] as num?)?.toInt() ?? -1;
          final pid2 = (orderItem['product_id'] as num?)?.toInt() ?? -1;
          final vid1 = (i['variation_id'] as num?)?.toInt() ?? 0;
          final vid2 = (orderItem['variation_id'] as num?)?.toInt() ?? 0;
          final sku1 = (i['sku'] ?? '').toString().toLowerCase();
          final sku2 = (orderItem['sku'] ?? '').toString().toLowerCase();
          final n1 = (i['item_name'] ?? i[AppDBConst.itemName] ?? '')
              .toString()
              .toLowerCase();
          final n2 =
              (orderItem['item_name'] ?? orderItem[AppDBConst.itemName] ?? '')
                  .toString()
                  .toLowerCase();
          final p1 = double.tryParse(i['item_price']?.toString() ??
                  i[AppDBConst.itemPrice]?.toString() ??
                  '0') ??
              0;
          final p2 = double.tryParse(orderItem['item_price']?.toString() ??
                  orderItem[AppDBConst.itemPrice]?.toString() ??
                  '0') ??
              0;
          if (pid2 >= 0 && pid1 == pid2 && vid1 == vid2) return true;
          if (sku2.isNotEmpty && sku1 == sku2) return true;
          return n1 == n2 && (p1 - p2).abs() < 0.001;
        });
        _listVersion++;
      });
    }
  }

  double getCustomItemTax({
    required String taxClass,
    required double unitPrice, //  make this explicit
    required int qty,
    required List<Tax> taxes,
    double? taxRate,
  }) {
    try {
      double rate = 0.0;

      // 🟣 1️⃣ Direct rate
      if (taxRate != null && taxRate > 0) {
        rate = taxRate;
      }
      // 🔵 2️⃣ Resolve from tax class
      else {
        final selected = taxes.firstWhere(
          (t) => t.slug == taxClass,
          orElse: () => Tax(slug: "", name: ""),
        );

        if (selected.slug.isEmpty) {
          debugPrint("⚠ No tax class mateh → tax = 0.0");
          return 0.0;
        }

        final rateString = selected.slug.replaceAll(RegExp(r'[^0-9.]'), '');
        rate = double.tryParse(rateString) ?? 0.0;
      }

      // ✅ EXACTLY like product tax
      final double taxableBase = unitPrice * qty;
      final double taxAmount = (taxableBase * rate) / 100;

      debugPrint(
        "🔥 Custom Item Tax → unit:$unitPrice qty:$qty "
        "taxableBase:$taxableBase rate:$rate tax:$taxAmount",
      );

      return taxAmount;
    } catch (e) {
      debugPrint("❌ ERROR in getCustomItemTax → $e");
      return 0.0;
    }
  }

  //
  // double getProductTaxFromHive(
  //     int productId,
  //     double price,
  //     int qty,
  //     ) {
  //   try {
  //     final box = StorageProvider.productCache;
  //
  //     // 🔹 get auto discount FIRST
  //     final double autoDiscount = getProductDiscountFromHive(productId, qty);
  //
  //     final double originalTotal = price * qty;
  //
  //     // ✅ discounted base (never negative)
  //     final double taxableBase =
  //     (originalTotal - autoDiscount).clamp(0.0, double.infinity);
  //
  //     for (var key in box.keys) {
  //       if (!key.toString().startsWith("products_")) continue;
  //
  //       final cached = box.get(key);
  //       if (cached == null) continue;
  //
  //       final List products = json.decode(cached['data']);
  //
  //       final product = products.firstWhere(
  //             (p) => p['id'] == productId,
  //         orElse: () => null,
  //       );
  //
  //       if (product == null) continue;
  //
  //       if (product['tax'] != null &&
  //           product['tax']['tax_rates'] is List &&
  //           product['tax']['tax_rates'].isNotEmpty) {
  //
  //         double taxTotal = 0.0;
  //
  //         for (final tax in product['tax']['tax_rates']) {
  //           final rate =
  //               double.tryParse(tax['rate']?.toString() ?? '0') ?? 0.0;
  //
  //           final taxAmount = (taxableBase * rate) / 100;
  //
  //           taxTotal += double.parse(taxAmount.toStringAsFixed(2));
  //         }
  //
  //         return taxTotal;
  //       }
  //     }
  //   } catch (e) {
  //     print("❌ Tax error (discounted base) → $e");
  //   }
  //
  //   return 0.0;
  // }
  double getProductTaxFromHive(
    int productId,
    double discountedUnitPrice,
    int qty,
  ) {
    try {
      debugPrint(
          "🧾 TAX START → productId:$productId unit:$discountedUnitPrice qty:$qty");

      // ✅ TAX BASE = DISCOUNTED TOTAL
      final double taxableBase = discountedUnitPrice * qty;
      debugPrint("💰 Taxable base (after discount) → $taxableBase");

      final isar = IsarService.sync;
      if (isar == null) return 0.0;

      final allProductsEntry = isar.isarCacheEntrys
          .where()
          .keyEqualTo("productCache::all_products_list")
          .findFirstSync();
      if (allProductsEntry == null) {
        debugPrint("🧾 TAX DEBUG → all_products_list cache entry missing");
        return 0.0;
      }

      final dynamic decoded = json.decode(allProductsEntry.json);
      final List allProducts = decoded is List ? decoded : <dynamic>[];
      final Map<int, dynamic> uniqueProducts = {};

      for (final raw in allProducts) {
        try {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          final dynamic normalized = (item["products"] is List &&
                  (item["products"] as List).isNotEmpty)
              ? (item["products"] as List).first
              : item;
          if (normalized is! Map) continue;
          final product = Map<String, dynamic>.from(normalized);
          final int? pid = int.tryParse(
              (product["fast_key_product_id"] ?? product["id"] ?? "")
                  .toString());
          if (pid == null) continue;
          uniqueProducts[pid] = product;
        } catch (_) {}
      }

      final product = uniqueProducts[productId];
      if (product == null) {
        unawaited(_agentDebugLog(
          hypothesisId: "H1",
          location: "widget_order_panel.dart:getProductTaxFromHive:notFound",
          message: "product missing from all_products_list",
          data: {
            "productId": productId,
            "allProductsCount": allProducts.length,
            "uniqueProductsCount": uniqueProducts.length,
          },
        ));
        debugPrint(
            "🧾 TAX DEBUG → productId:$productId not found in all_products_list (raw:${allProducts.length}, unique:${uniqueProducts.length})");
        return 0.0;
      }

      unawaited(_agentDebugLog(
        hypothesisId: "H4",
        location:
            "widget_order_panel.dart:getProductTaxFromHive:allProductsLookup",
        message: "product matched in all_products_list",
        data: {
          "productId": productId,
          "allProductsCount": allProducts.length,
          "uniqueProductsCount": uniqueProducts.length,
          "taxStatus": product["tax_status"],
          "hasFlatTaxRates": product["tax_rates"] is List,
          "hasNestedTaxRates": product["tax"]?["tax_rates"] is List,
          "scalarTaxRate": product["tax_rate"] ?? product["tax"]?["rate"],
        },
      ));
      debugPrint(
          "🧾 TAX DEBUG → product found in all_products_list (raw:${allProducts.length}, unique:${uniqueProducts.length})");

      final taxStatus =
          (product["tax_status"] ?? "taxable").toString().toLowerCase();
      if (taxStatus == "none") {
        debugPrint(
            "🧾 TAX DEBUG → tax source:none (tax_status=none) in all_products_list");
        return 0.0;
      }

      final bool hasFlatTaxRates = product["tax_rates"] is List &&
          (product["tax_rates"] as List).isNotEmpty;
      final bool hasNestedTaxRates = product["tax"]?["tax_rates"] is List &&
          (product["tax"]?["tax_rates"] as List).isNotEmpty;
      final taxRates = product["tax_rates"] ?? product["tax"]?["tax_rates"];
      if (taxRates is List && taxRates.isNotEmpty) {
        final source = hasFlatTaxRates
            ? "all_products_list.tax_rates"
            : (hasNestedTaxRates
                ? "all_products_list.tax.tax_rates"
                : "all_products_list.tax_rates(unknown-shape)");
        debugPrint(
            "🧾 TAX DEBUG → tax source:$source | rate_count:${taxRates.length}");
        double taxTotal = 0.0;
        for (final tax in taxRates) {
          final double rate =
              double.tryParse(tax["rate"]?.toString() ?? "0") ?? 0.0;
          final double rawTax = (taxableBase * rate) / 100;
          final double roundedTax = roundTaxHalfUp(rawTax);
          taxTotal += roundedTax;
        }
        final double finalTax = roundTaxHalfUp(taxTotal);
        debugPrint("🧾 TAX DEBUG → final tax:$finalTax");
        return finalTax;
      }

      final fallbackRate = double.tryParse(
            (product["tax_rate"] ?? product["tax"]?["rate"] ?? "0").toString(),
          ) ??
          0.0;
      if (fallbackRate > 0) {
        final fallbackTax = roundTaxHalfUp((taxableBase * fallbackRate) / 100);
        debugPrint(
            "🧾 TAX DEBUG → tax source:all_products_list.tax_rate rate:$fallbackRate tax:$fallbackTax");
        return fallbackTax;
      }
    } catch (e, st) {
      debugPrint("❌ Tax error → $e");
      debugPrint(st.toString());
    }
    return 0.0;
  }

  bool engineExecuted = false;

  final AssetDBHelper _assetDBHelper = AssetDBHelper.instance;

// Current Order UI
  Widget buildCurrentOrder() {
    final theme = Theme.of(context);
    bool isKeyboardVisible = View.of(context).viewInsets.bottom > 0;
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final ScrollController scrollController = ScrollController();

    //  EARLY RETURN WHEN NO ACTIVE ORDER
    if (orderHelper.activeOrderId == null) {
      if (orderItems.isNotEmpty && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              orderHelper.activeOrderId == null &&
              orderItems.isNotEmpty) {
            setState(() {
              orderItems.clear();
              _currentOrderVersion++;
            });
          }
        });
      }
      return Stack(
        // children: [
        //   Column(
        //     children: [
        //       InkWell(
        //           onTap: () async {
        //             await enablePhoneInput();
        //           },
        //
        //       Container(
        //         color: themeHelper.themeMode == ThemeMode.dark
        //             ? ThemeNotifier.primaryBackground
        //             : null,
        //         padding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
        //         child: Column(
        //           crossAxisAlignment: CrossAxisAlignment.start,
        //           children: [
        //             Text(
        //               "All updated discounts will be reflected after checkout.",
        //               style: TextStyle(
        //                 fontSize: 13,
        //                 fontWeight: FontWeight.w600,
        //                 color: Theme.of(context).brightness == Brightness.dark
        //                     ? Colors.white
        //                     : const Color(0xFF1878DE),
        //               ),
        //               maxLines: 2,
        //               overflow: TextOverflow.ellipsis,
        //             ),
        //             const SizedBox(height: 6),
        //             Row(
        //               mainAxisAlignment: MainAxisAlignment.spaceBetween,
        //               children: [
        //                 Row(
        //                   children: [
        //                     SvgPicture.asset(
        //                       'assets/svg/calendar.svg',
        //                       width: 20,
        //                       height: 20,
        //                       color: Theme.of(context).brightness == Brightness.dark
        //                           ? Colors.white
        //                           : Colors.black,
        //                     ),
        //                     const SizedBox(width: 4),
        //                     Text(
        //                       DateFormat(TextConstants.dateFormat).format(DateTime.now()),
        //                       style: TextStyle(
        //                         fontSize: 14,
        //                         fontWeight: FontWeight.bold,
        //                         color: Theme.of(context).brightness == Brightness.dark
        //                             ? Colors.white
        //                             : Colors.black,
        //                       ),
        //                     ),
        //                   ],
        //                 ),
        //                 Row(
        //                   children: [
        //                     SvgPicture.asset(
        //                       'assets/svg/clock.svg',
        //                       width: 20,
        //                       height: 20,
        //                       color: Theme.of(context).brightness == Brightness.dark
        //                           ? Colors.white
        //                           : Colors.black,
        //                     ),
        //                     const SizedBox(width: 4),
        //                     Text(
        //                       DateFormat(TextConstants.timeFormat).format(DateTime.now()),
        //                       style: TextStyle(
        //                         fontSize: 14,
        //                         fontWeight: FontWeight.bold,
        //                         color: Theme.of(context).brightness == Brightness.dark
        //                             ? Colors.white
        //                             : Colors.black,
        //                       ),
        //                     ),
        //                   ],
        //                 ),
        //               ],
        //             ),
        //           ],
        //         ),
        //       ),
        //       if (tabs.isNotEmpty)
        //         Padding(
        //           padding: const EdgeInsets.symmetric(horizontal: 10),
        //           child: DottedLine(
        //             dashLength: 4,
        //             dashGapLength: 4,
        //             lineThickness: 1,
        //             dashColor: theme.secondaryHeaderColor,
        //           ),
        //         ),
        //       const SizedBox(height: 10),
        //     ],
        //   ),
        // ],

        children: [
          Column(
            children: [
              InkWell(
                onTap: () async {
                  await enablePhoneInput();
                },
                child: Container(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.primaryBackground
                      : null,
                  padding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "All updated discounts will be reflected after checkout.",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : const Color(0xFF1878DE),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              SvgPicture.asset(
                                'assets/svg/calendar.svg',
                                width: 20,
                                height: 20,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                DateFormat(TextConstants.dateFormat)
                                    .format(DateTime.now()),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white
                                      : Colors.black,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              SvgPicture.asset(
                                'assets/svg/clock.svg',
                                width: 20,
                                height: 20,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                DateFormat(TextConstants.timeFormat)
                                    .format(DateTime.now()),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white
                                      : Colors.black,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (tabs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: DottedLine(
                    dashLength: 4,
                    dashGapLength: 4,
                    lineThickness: 1,
                    dashColor: theme.secondaryHeaderColor,
                  ),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ],
      );
    }

    // ============ ACTIVE ORDER EXISTS – LOAD ORDER-LEVEL DATA ============
    if (kDebugMode) {
      print("keyBoard visible : $isKeyboardVisible");
    }
    if (kDebugMode) {
      print(
          "Building Current Order Widget _isLoading: $_isLoading and orderHelper.activeOrderId : ${orderHelper.activeOrderId}");
    }

    // Order-level variables
    double orderDiscount = 0.0;
    double merchantDiscount = 0.0;
    double cashbackFee = 0.0;
    String displayDate =
        DateFormat(TextConstants.dateFormat).format(DateTime.now());
    String displayTime =
        DateFormat(TextConstants.timeFormat).format(DateTime.now());

    // Read from offline order (Hive) – only for discounts and dates, NOT for items
    final activeId = orderHelper.activeOrderId;
    final idx = orderHelper.orders.indexWhere((o) {
      final oid = o['order_id'] ?? o['id'] ?? o[AppDBConst.orderServerId];
      if (oid == null || activeId == null) return false;
      return oid == activeId || oid.toString() == activeId.toString();
    });
    final rawOfflineOrder = idx >= 0 ? orderHelper.orders[idx] : null;

    if (rawOfflineOrder != null) {
      // Order discount
      orderDiscount = (rawOfflineOrder['orderDiscount'] is num)
          ? (rawOfflineOrder['orderDiscount'] as num).toDouble()
          : 0.0;

      // Merchant discount
      if (rawOfflineOrder.containsKey('merchantDiscountType')) {
        merchantDiscount = getCurrentMerchantDiscount(rawOfflineOrder);
      } else {
        merchantDiscount = (rawOfflineOrder['merchantDiscount'] is num)
            ? (rawOfflineOrder['merchantDiscount'] as num).toDouble()
            : 0.0;
      }

      // Cashback fee
      cashbackFee = (rawOfflineOrder['cashbackFee'] is num)
          ? (rawOfflineOrder['cashbackFee'] as num).toDouble()
          : 0.0;

      // Creation date
      if (rawOfflineOrder['created_at'] != null) {
        try {
          final createdAt = DateTime.parse(rawOfflineOrder['created_at']);
          displayDate = DateFormat(TextConstants.dateFormat).format(createdAt);
          displayTime = DateFormat(TextConstants.timeFormat).format(createdAt);
        } catch (e) {
          if (kDebugMode) print("⚠️ Failed to parse offline order date: $e");
        }
      }
    }

    double grossTotal = 0.0;
    double orderTax = 0.0;
    int totalItems = 0;

    for (final item in orderItems) {
      final itemType = (item['item_type'] ?? '').toString().toLowerCase();

      //  FIX: Skip merchant discount line items — already handled via merchantDiscount from Hive
      // Prevents double-subtraction: once via negative price in grossTotal, once via merchantDiscount in netTotal
      if (itemType == 'discount') continue;

      final qty = (item['items_count'] ?? 1) as int;
      final price = ((item['item_price'] ?? 0) as num).toDouble();
      final itemTotal = price * qty;
      grossTotal += itemTotal;
      totalItems += qty;

      final bool isPayout = itemType.contains('payout');
      final bool isCashback = itemType.contains('cashback');
      final bool isCoupon = itemType.contains('coupon');

      final double taxRate = double.tryParse(item['tax_rate']?.toString() ??
              item['tax_Rate']?.toString() ??
              '0') ??
          0.0;
      // final double taxRate = double.tryParse(
      //     item['tax_rate']?.toString() ??
      //         item['tax_Rate']?.toString() ??
      //         '0') ??
      //     0.0;
      double itemTax =
          taxRate > 0 ? roundTaxHalfUp(((price * taxRate) / 100) * qty) : 0.0;

      if (!isPayout && !isCashback && !isCoupon) {
        // First try the stored item_tax
        itemTax = ((item['item_tax'] ?? 0) as num).toDouble();

        // If item_tax is zero/missing, compute it
        if (itemTax <= 0) {
          final bool isEbt = item['is_ebt_eligible'] == true;
          final int productId =
              int.tryParse((item['product_id'] ?? 0).toString()) ?? 0;

          final String taxClass = (item['tax_class'] ?? '').toString();

          final double taxRate = double.tryParse(
                  (item['tax_rate'] ?? item['tax_Rate'] ?? '0').toString()) ??
              0.0;

          final String lineTaxStatus =
              (item['tax_status'] ?? 'taxable').toString().toLowerCase();

          const double defaultNonEbtTaxRate = 9.1;

          if (isEbt) {
            itemTax = 0.0;
          } else if (itemType.contains('custom')) {
            if (taxRate > 0) {
              itemTax = roundTaxHalfUp(((price * taxRate) / 100) * qty);
            }
          } else if (productId > 0) {
            final lineTaxRate =
                double.tryParse((item['tax_rate'] ?? '0').toString()) ?? 0.0;

            if (lineTaxStatus == 'taxable' && lineTaxRate > 0) {
              itemTax = ((price * qty) * lineTaxRate) / 100;
            } else {
              itemTax = getProductTaxFromHive(productId, price, qty);

              if (itemTax <= 0 && lineTaxStatus != 'none') {
                itemTax = ((price * qty) * defaultNonEbtTaxRate) / 100;
              }
            }
          }
        }

        orderTax += itemTax;
      }
    }

    final String mdType =
        rawOfflineOrder?['merchantDiscountType']?.toString() ?? 'fixed';
    final double mdPerc = double.tryParse(
            rawOfflineOrder?['merchantDiscountPercentage']?.toString() ??
                '0') ??
        0.0;

    double calculatedPerc = 0.0;
    if (mdType == 'percentage' && mdPerc > 0) {
      calculatedPerc = mdPerc;
    } else if (mdType == 'fixed' && merchantDiscount.abs() > 0) {
      double base = grossTotal - orderDiscount;
      if (base > 0) {
        calculatedPerc = (merchantDiscount.abs() / base) * 100.0;
      }
    }

    if (calculatedPerc > 0) {
      orderTax = orderTax * (1 - calculatedPerc / 100.0);
      orderTax = roundTaxHalfUp(orderTax);
    }

    final double netTotal = grossTotal - orderDiscount - merchantDiscount;
    final double netPayable = netTotal + orderTax + cashbackFee;

    // ============ RENDER FULL UI (SAME AS BEFORE, TOTALS NOW CORRECT) ============
    return Stack(
      children: [
        Column(
          children: [
            // Header with date/time
            Container(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.primaryBackground
                  : null,
              padding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "All updated discounts will be reflected after checkout.",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : const Color(0xFF1878DE),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          SvgPicture.asset('assets/svg/calendar.svg',
                              width: 20,
                              height: 20,
                              color: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black),
                          const SizedBox(width: 4),
                          Text(displayDate,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                              )),
                        ],
                      ),
                      Row(
                        children: [
                          SvgPicture.asset('assets/svg/clock.svg',
                              width: 20,
                              height: 20,
                              color: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black),
                          const SizedBox(width: 4),
                          Text(displayTime,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                              )),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (tabs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: DottedLine(
                    dashLength: 4,
                    dashGapLength: 4,
                    lineThickness: 1,
                    dashColor: theme.secondaryHeaderColor),
              ),
            const SizedBox(height: 10),

            // Order items list (only shown if there are items)
            Expanded(
              child: orderItems.isEmpty
                  ? Container()
                  : Container(
                      color: themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.primaryBackground
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 0, right: 0),
                        child: Scrollbar(
                          controller: scrollController,
                          scrollbarOrientation: ScrollbarOrientation.right,
                          thumbVisibility: true,
                          thickness: 8.0,
                          interactive: false,
                          radius: const Radius.circular(8),
                          trackVisibility: true,
                          child: ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            onReorder: (oldIndex, newIndex) {
                              if (kDebugMode)
                                print(
                                    "Reordering item from $oldIndex to $newIndex");
                              if (oldIndex < newIndex) newIndex -= 1;
                              setState(() {
                                final movedItem = orderItems.removeAt(oldIndex);
                                orderItems.insert(newIndex, movedItem);
                              });
                            },
                            scrollController: scrollController,
                            itemCount: orderItems.length,
                            proxyDecorator: (Widget child, int index,
                                Animation<double> animation) {
                              return Material(
                                  color: Colors.transparent, child: child);
                            },
                            itemBuilder: (context, index) {
                              final orderItem = orderItems[index];

                              final _itemTypeCheck =
                                  orderItem[AppDBConst.itemType]
                                          ?.toString()
                                          .toLowerCase() ??
                                      '';
                              if (_itemTypeCheck == 'discount') {
                                return SizedBox.shrink(
                                    key: ValueKey('hidden_discount_$index'));
                              }

                              if (kDebugMode) {
                                print(
                                    "@@@@@@@@@@@@@@@@@ orderItem Data : $orderItem");
                              }

                              if (kDebugMode) {
                                print(
                                    "@@@@@@@@@@@@@@@@@ orderItem Data : $orderItem");
                              }

                              // --------------------------
                              // THIS IS YOUR EXISTING ITEM BUILDER (UNCHANGED)
                              // --------------------------
                              final itemType = orderItem[AppDBConst.itemType]
                                      ?.toString()
                                      .toLowerCase() ??
                                  '';
                              final bool isVariant =
                                  (orderItem['is_variant'] == true) ||
                                      (itemType == 'variant');
                              final isCashback = itemType.contains("cashback");
                              final isPayout =
                                  itemType.contains(TextConstants.payoutText);
                              final isCoupon =
                                  itemType.contains(TextConstants.couponText);
                              final isCustomItem = itemType
                                  .contains(TextConstants.customItemText);
                              final isCouponOrPayout =
                                  isPayout || isCoupon || isCashback;

                              final originalName =
                                  orderItem[AppDBConst.itemName]?.toString() ??
                                      '';
                              final variationName =
                                  orderItem[AppDBConst.itemVariationCustomName]
                                          ?.toString() ??
                                      'N/A';
                              final variationCount =
                                  orderItem[AppDBConst.itemVariationCount] ?? 0;
                              String displayName = originalName;
                              if (isPayout)
                                displayName = 'Payout';
                              else if (isCashback)
                                displayName = 'Cashback';
                              else if (isCoupon) {
                                final visiblePartLength = 4;
                                final nameLength = originalName.length;
                                if (nameLength > visiblePartLength) {
                                  final maskedLength =
                                      nameLength - visiblePartLength;
                                  final maskedPart = 'X' * maskedLength;
                                  final visiblePart = originalName.substring(
                                      nameLength - visiblePartLength);
                                  displayName = '$maskedPart$visiblePart';
                                }
                              }

                              final salesPrice = (orderItem[
                                              AppDBConst.itemSalesPrice] ==
                                          null ||
                                      (orderItem[AppDBConst.itemSalesPrice]
                                                  ?.toDouble() ??
                                              0.0) ==
                                          0.0)
                                  ? ((orderItem[AppDBConst.itemRegularPrice] ==
                                              null ||
                                          (orderItem[AppDBConst
                                                          .itemRegularPrice]
                                                      ?.toDouble() ??
                                                  0.0) ==
                                              0.0)
                                      ? orderItem[AppDBConst.itemUnitPrice]
                                              ?.toDouble() ??
                                          0.0
                                      : orderItem[AppDBConst.itemRegularPrice]!
                                          .toDouble())
                                  : orderItem[AppDBConst.itemSalesPrice]!
                                      .toDouble();

                              final bool isEbtEligible =
                                  orderItem["is_ebt_eligible"] == true;

                              return ClipRRect(
                                key: ValueKey(
                                    '${orderItem[AppDBConst.itemServerId]}_${_listVersion}_ClipRRect_$index'),
                                borderRadius: BorderRadius.circular(20),
                                child: SizedBox(
                                  height:
                                      MediaQuery.of(context).size.height * 0.11,
                                  child: Slidable(
                                    key: ValueKey(
                                        '${orderItem[AppDBConst.itemServerId]}_${_listVersion}_Slidable_$index'),
                                    closeOnScroll: true,
                                    direction: Axis.horizontal,
                                    endActionPane: ActionPane(
                                      motion: const DrawerMotion(),
                                      children: [
                                        CustomSlidableAction(
                                          onPressed: (context) async {
                                            if (kDebugMode)
                                              print(
                                                  "🗑️ Delete tapped for item: $orderItem");
                                            final bool isOffline = orderHelper
                                                        .activeOrderId !=
                                                    null &&
                                                (await StorageProvider
                                                    .offlineOrders
                                                    .containsKey(orderHelper
                                                        .activeOrderId
                                                        .toString()));
                                            try {
                                              int itemQty =
                                                  orderItem["items_count"] ?? 0;
                                              double itemTotal = (orderItem[
                                                          "item_sum_price"] ??
                                                      0)
                                                  .toDouble();
                                              int productId =
                                                  orderItem["product_id"] ?? 0;
                                              final userData =
                                                  await UserDbHelper()
                                                      .getUserData();
                                              final String token = userData?[
                                                      AppDBConst.userToken] ??
                                                  "";
                                              final int? shiftId =
                                                  await UserDbHelper()
                                                      .getUserShiftId();
                                              final uri = Uri.parse(
                                                  '${UrlHelper.baseUrl}${UrlHelper.pinakaPosV1}orders/track-void-items-event${UrlHelper.apiKey}');
                                              final headers = <String, String>{
                                                'Content-Type':
                                                    'application/json',
                                                if (token.isNotEmpty)
                                                  'Authorization':
                                                      'Bearer $token',
                                              };
                                              var body = jsonEncode({
                                                "offline_orderid":
                                                    orderHelper.activeOrderId,
                                                "shift_id": shiftId,
                                                "item_id": productId,
                                                "item_total": itemTotal,
                                                "item_qty": itemQty,
                                                "timestamp":
                                                    DateTime.now().toString(),
                                                "deleted_by":
                                                    orderHelper.activeUserId
                                              });
                                              await http.post(uri,
                                                  headers: headers, body: body);
                                              await deleteOfflineItem(orderItem,
                                                  itemIndex: index);
                                            } catch (e) {
                                              if (kDebugMode)
                                                print("❌ Delete error: $e");
                                            }
                                          },
                                          backgroundColor: Colors.transparent,
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.delete,
                                                  color: Colors.red),
                                              const SizedBox(height: 4),
                                              const Text(
                                                  TextConstants.deleteText,
                                                  style: TextStyle(
                                                      color: Colors.red,
                                                      fontWeight:
                                                          FontWeight.bold)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    child: GestureDetector(
                                      onTap: () async {
                                        if (isCouponOrPayout) return;
                                        if (kDebugMode)
                                          print(
                                              "🟩 Tapped on product item (offline mode)");
                                        showDialog(
                                          context: context,
                                          barrierColor: Colors.black
                                              .withValues(alpha: 0.5),
                                          barrierDismissible: false,
                                          builder:
                                              (BuildContext dialogContext) {
                                            return EditProduct(
                                              orderItem: {
                                                AppDBConst.itemName:
                                                    orderItem['item_name'],
                                                AppDBConst.itemUnitPrice:
                                                    orderItem['item_price'],
                                                AppDBConst.itemRegularPrice:
                                                    orderItem['item_price'],
                                                AppDBConst.itemCount:
                                                    orderItem['items_count'],
                                                AppDBConst.itemImage:
                                                    orderItem['item_image'],
                                                'product_id':
                                                    orderItem['product_id'],
                                                'variation_id':
                                                    orderItem['variation_id'],
                                                'sku': orderItem['sku'],
                                                'item_type':
                                                    orderItem['item_type'],
                                              },
                                              onQuantityUpdated:
                                                  (newQuantity) async {
                                                try {
                                                  if (orderHelper
                                                          .activeOrderId ==
                                                      null) return;

                                                  final String orderKey =
                                                      orderHelper.activeOrderId
                                                          .toString();
                                                  final offlineBox =
                                                      StorageProvider
                                                          .offlineOrders;
                                                  final rawOfflineOrder =
                                                      await offlineBox
                                                          .get(orderKey);

                                                  if (rawOfflineOrder == null)
                                                    return;

                                                  // Convert to editable map
                                                  final Map<String, dynamic>
                                                      offlineOrder =
                                                      Map<String, dynamic>.from(
                                                          rawOfflineOrder);

                                                  // -------- NORMAL PRODUCTS ----------
                                                  final List<
                                                          Map<String, dynamic>>
                                                      products =
                                                      (offlineOrder['products']
                                                                  as List?)
                                                              ?.map((e) => Map<
                                                                  String,
                                                                  dynamic>.from(e))
                                                              .toList() ??
                                                          [];

                                                  // -------- CUSTOM ITEMS ----------
                                                  final List<
                                                          Map<String, dynamic>>
                                                      customItems =
                                                      (offlineOrder['custom_items']
                                                                  as List?)
                                                              ?.map((e) => Map<
                                                                  String,
                                                                  dynamic>.from(e))
                                                              .toList() ??
                                                          [];

                                                  final tappedItemType =
                                                      (orderItem['item_type'] ??
                                                              'product')
                                                          .toString()
                                                          .toLowerCase();
                                                  final productsLen =
                                                      products.length;
                                                  final customLen =
                                                      customItems.length;

                                                  // Index-based update: orderItems = [products..., custom_items..., payouts..., cashbacks...]
                                                  // Update only the tapped line so variants do not impact each other
                                                  if (index < productsLen) {
                                                    final product =
                                                        products[index];
                                                    final price =
                                                        double.tryParse(product[
                                                                        'price']
                                                                    ?.toString() ??
                                                                '0') ??
                                                            0.0;

                                                    // Before applying the quantity change, enforce merchant discount rule:
                                                    // If there is a merchant discount and reducing qty would make
                                                    // merchantDiscount > (new gross - orderDiscount), then block
                                                    // the change, show a snackbar, and remove the merchant discount.
                                                    final currentProducts = List<
                                                            Map<String,
                                                                dynamic>>.from(
                                                        products);
                                                    double
                                                        simulatedProductTotal =
                                                        0.0;
                                                    for (int i = 0;
                                                        i <
                                                            currentProducts
                                                                .length;
                                                        i++) {
                                                      final p =
                                                          currentProducts[i];
                                                      final pPrice = double
                                                              .tryParse(p['price']
                                                                      ?.toString() ??
                                                                  '0') ??
                                                          0.0;
                                                      final pQty = int.tryParse((i ==
                                                                          index
                                                                      ? newQuantity
                                                                      : p['quantity'])
                                                                  ?.toString() ??
                                                              '1') ??
                                                          1;
                                                      simulatedProductTotal +=
                                                          pPrice * pQty;
                                                    }

                                                    double
                                                        simulatedCustomTotal =
                                                        0.0;
                                                    for (final c
                                                        in customItems) {
                                                      final cQty = int.tryParse(c[
                                                                      'quantity']
                                                                  ?.toString() ??
                                                              '1') ??
                                                          1;
                                                      final cPrice = double.tryParse(c[
                                                                      'custom_item_price']
                                                                  ?.toString() ??
                                                              c['amount']
                                                                  ?.toString() ??
                                                              c['price']
                                                                  ?.toString() ??
                                                              '0') ??
                                                          0.0;
                                                      simulatedCustomTotal +=
                                                          cPrice * cQty;
                                                    }

                                                    final double simulatedGross = simulatedProductTotal +
                                                        simulatedCustomTotal +
                                                        (((offlineOrder['payouts']
                                                                    as List?) ??
                                                                [])
                                                            .fold<double>(
                                                                0,
                                                                (s, p) =>
                                                                    s +
                                                                    (double.tryParse(p['amount']?.toString() ?? '0') ??
                                                                        0.0))) +
                                                        (((offlineOrder['cashbacks']
                                                                    as List?) ??
                                                                [])
                                                            .fold<double>(
                                                                0,
                                                                (s, c) =>
                                                                    s +
                                                                    (double.tryParse(c['amount']?.toString() ?? '0') ??
                                                                        0.0)));

                                                    final double
                                                        orderDiscountSim =
                                                        (offlineOrder[
                                                                    'orderDiscount']
                                                                is num)
                                                            ? (offlineOrder[
                                                                        'orderDiscount']
                                                                    as num)
                                                                .toDouble()
                                                            : 0.0;
                                                    double merchantDiscountSim =
                                                        (offlineOrder[
                                                                    'merchantDiscount']
                                                                is num)
                                                            ? (offlineOrder[
                                                                        'merchantDiscount']
                                                                    as num)
                                                                .toDouble()
                                                            : 0.0;

                                                    final double
                                                        maxAllowedDiscountSim =
                                                        (simulatedGross -
                                                                orderDiscountSim)
                                                            .clamp(
                                                                0.0,
                                                                double
                                                                    .infinity);

                                                    if (merchantDiscountSim >
                                                        maxAllowedDiscountSim) {
                                                      ScaffoldMessenger.of(
                                                              context)
                                                          .showSnackBar(
                                                        const SnackBar(
                                                          backgroundColor:
                                                              Colors.red,
                                                          content: Text(
                                                            'Reduce quantity not allowed: please remove merchant discount first.',
                                                            style: TextStyle(
                                                                color: Colors
                                                                    .white),
                                                          ),
                                                        ),
                                                      );

                                                      // Do not apply quantity change
                                                      return;
                                                    }

                                                    product['quantity'] =
                                                        newQuantity;
                                                    product['items_count'] =
                                                        newQuantity;
                                                    product['subtotal'] =
                                                        price * newQuantity;
                                                    if (kDebugMode) {
                                                      print(
                                                          "🟢 Updated PRODUCT → ${product['name'] ?? product['product_name']} | Qty: $newQuantity");
                                                    }
                                                  } else if (tappedItemType
                                                          .contains('custom') &&
                                                      index >= productsLen &&
                                                      index <
                                                          productsLen +
                                                              customLen) {
                                                    final custom = customItems[
                                                        index - productsLen];
                                                    final price = double.tryParse(custom[
                                                                    'custom_item_price']
                                                                ?.toString() ??
                                                            custom['amount']
                                                                ?.toString() ??
                                                            custom['price']
                                                                ?.toString() ??
                                                            '0') ??
                                                        0.0;
                                                    custom['quantity'] =
                                                        newQuantity;
                                                    custom['items_count'] =
                                                        newQuantity;
                                                    custom['subtotal'] =
                                                        price * newQuantity;
                                                    if (kDebugMode) {
                                                      final customName = (custom[
                                                                  'custom_item_name'] ??
                                                              custom[
                                                                  'item_name'] ??
                                                              '')
                                                          .toString();
                                                      print(
                                                          "🟣 Updated CUSTOM ITEM → $customName | Qty: $newQuantity");
                                                    }
                                                  }

                                                  // Save updated lists back
                                                  offlineOrder['products'] =
                                                      products;
                                                  offlineOrder['custom_items'] =
                                                      customItems;

                                                  // Recalculate totals
                                                  double productTotal = 0.0;
                                                  for (final p in products) {
                                                    final qty = int.tryParse(p[
                                                                    'quantity']
                                                                ?.toString() ??
                                                            '1') ??
                                                        1;
                                                    final price = double
                                                            .tryParse(p['price']
                                                                    ?.toString() ??
                                                                '0') ??
                                                        0.0;
                                                    productTotal += price * qty;
                                                  }
                                                  for (final c in customItems) {
                                                    final qty = int.tryParse(c[
                                                                    'quantity']
                                                                ?.toString() ??
                                                            '1') ??
                                                        1;
                                                    final price = double.tryParse(
                                                            c['custom_item_price']
                                                                    ?.toString() ??
                                                                c['amount']
                                                                    ?.toString() ??
                                                                '0') ??
                                                        0.0;
                                                    productTotal += price * qty;
                                                  }
                                                  double payoutsTotal = ((offlineOrder[
                                                                  'payouts']
                                                              as List?) ??
                                                          [])
                                                      .fold<double>(
                                                          0,
                                                          (s, p) =>
                                                              s +
                                                              (double.tryParse(
                                                                      p['amount']
                                                                              ?.toString() ??
                                                                          '0') ??
                                                                  0.0));
                                                  double cashbacksTotal = ((offlineOrder[
                                                                  'cashbacks']
                                                              as List?) ??
                                                          [])
                                                      .fold<double>(
                                                          0,
                                                          (s, c) =>
                                                              s +
                                                              (double.tryParse(
                                                                      c['amount']
                                                                              ?.toString() ??
                                                                          '0') ??
                                                                  0.0));
                                                  final grossTotal =
                                                      productTotal +
                                                          payoutsTotal +
                                                          cashbacksTotal;
                                                  final orderDiscount = (offlineOrder[
                                                              'orderDiscount']
                                                          is num)
                                                      ? (offlineOrder[
                                                                  'orderDiscount']
                                                              as num)
                                                          .toDouble()
                                                      : 0.0;
                                                  final merchantDiscount =
                                                      (offlineOrder[
                                                                  'merchantDiscount']
                                                              is num)
                                                          ? (offlineOrder[
                                                                      'merchantDiscount']
                                                                  as num)
                                                              .toDouble()
                                                          : 0.0;
                                                  final cashbackFee = (offlineOrder[
                                                          'cashbackFee'] is num)
                                                      ? (offlineOrder[
                                                                  'cashbackFee']
                                                              as num)
                                                          .toDouble()
                                                      : 0.0;
                                                  double orderTax = 0.0;
                                                  for (final p in products) {
                                                    final String itemType =
                                                        (p['item_type'] ??
                                                                p['type'] ??
                                                                '')
                                                            .toString()
                                                            .toLowerCase();
                                                    final int qty = int.tryParse(p[
                                                                    'quantity']
                                                                ?.toString() ??
                                                            p['items_count']
                                                                ?.toString() ??
                                                            '1') ??
                                                        1;
                                                    final double price = double
                                                            .tryParse(p['price']
                                                                    ?.toString() ??
                                                                '0') ??
                                                        0.0;

                                                    if (!itemType
                                                        .contains('custom')) {
                                                      final int productId = int.tryParse(
                                                              (p['product_id'] ??
                                                                          p['id'])
                                                                      ?.toString() ??
                                                                  '0') ??
                                                          0;
                                                      orderTax +=
                                                          getProductTaxFromHive(
                                                              productId,
                                                              price,
                                                              qty);
                                                    } else {
                                                      orderTax +=
                                                          getCustomItemTax(
                                                        taxClass:
                                                            p['tax_class'] ??
                                                                '',
                                                        unitPrice: price,
                                                        qty: qty,
                                                        taxes:
                                                            await _assetDBHelper
                                                                .getTaxList(),
                                                        taxRate: p['tax_rate'],
                                                      );
                                                    }
                                                  }
                                                  offlineOrder['order_tax'] =
                                                      orderTax;

// Update net_total / net_payable
                                                  offlineOrder['gross_total'] =
                                                      grossTotal;
                                                  offlineOrder['net_total'] =
                                                      grossTotal -
                                                          orderDiscount -
                                                          merchantDiscount;
                                                  offlineOrder['net_payable'] =
                                                      offlineOrder[
                                                              'net_total'] +
                                                          orderTax +
                                                          cashbackFee;

                                                  await offlineBox.put(
                                                      orderKey, offlineOrder);
                                                  await orderHelper.loadData();
                                                  OrderHelper
                                                      .notifyOrderPanelToRefresh();

// 🖥 Update customer display with FRESH values
                                                  final int orderId =
                                                      orderHelper
                                                              .activeOrderId ??
                                                          0;
                                                  final List
                                                      productsForDisplay =
                                                      products.map((item) {
                                                    return {
                                                      "name": item["name"] ??
                                                          item[
                                                              "product_name"] ??
                                                          "",
                                                      "quantity": item[
                                                              "quantity"] ??
                                                          item["items_count"] ??
                                                          1,
                                                      "price":
                                                          item["price"] ?? 0,
                                                    };
                                                  }).toList();

                                                  // await CustomerService.publishCartUpdate(
                                                  //   orderId,
                                                  //   productsForDisplay,
                                                  //   subtotal: grossTotal,
                                                  //   tax: orderTax,
                                                  //   total: (offlineOrder['net_payable'] as num?)?.toDouble() ?? 0.0,
                                                  // );
                                                  // 🔁 Refresh UI instantly
                                                  if (mounted) {
                                                    setState(() {
                                                      // Rebuild products
                                                      final updatedProducts =
                                                          products.map((item) {
                                                        final price = double
                                                                .tryParse(item[
                                                                            'price']
                                                                        ?.toString() ??
                                                                    '0') ??
                                                            0.0;
                                                        final qty = int.tryParse(
                                                                item['quantity']
                                                                        ?.toString() ??
                                                                    '1') ??
                                                            1;

                                                        return {
                                                          'item_name': item[
                                                                  'name'] ??
                                                              item[
                                                                  'product_name'] ??
                                                              '',
                                                          'item_price': price,
                                                          'items_count': qty,
                                                          'item_sum_price':
                                                              price * qty,
                                                          'item_type':
                                                              'product',
                                                          'item_image':
                                                              resolveProductImageFromMap(
                                                                  item),
                                                        };
                                                      }).toList();

                                                      // Rebuild custom items
                                                      final updatedCustom =
                                                          customItems
                                                              .map((item) {
                                                        final price = double.tryParse(item[
                                                                        'custom_item_price']
                                                                    ?.toString() ??
                                                                item['amount']
                                                                    ?.toString() ??
                                                                '0') ??
                                                            0.0;
                                                        final qty = int.tryParse(
                                                                item['quantity']
                                                                        ?.toString() ??
                                                                    '1') ??
                                                            1;

                                                        return {
                                                          'item_name': item[
                                                                  'custom_item_name'] ??
                                                              item[
                                                                  'item_name'] ??
                                                              "",
                                                          'item_price': price,
                                                          'items_count': qty,
                                                          'item_sum_price':
                                                              price * qty,
                                                          'item_type':
                                                              'custom item',
                                                          'item_image': () {
                                                            final img =
                                                                resolveProductImageFromMap(
                                                                    item);
                                                            return img
                                                                    .isNotEmpty
                                                                ? img
                                                                : 'assets/custom.png';
                                                          }(),
                                                        };
                                                      }).toList();

                                                      // Payout & Cashback maps intact
                                                      final updatedPayouts =
                                                          ((offlineOrder[
                                                                      'payouts'] ??
                                                                  []) as List)
                                                              .map((e) => Map<
                                                                  String,
                                                                  dynamic>.from(e))
                                                              .toList();

                                                      final updatedCashbacks =
                                                          ((offlineOrder[
                                                                      'cashbacks'] ??
                                                                  []) as List)
                                                              .map((e) => Map<
                                                                  String,
                                                                  dynamic>.from(e))
                                                              .toList();

                                                      // FINAL ORDER ITEMS
                                                      orderItems = [
                                                        ...updatedProducts,
                                                        ...updatedCustom,
                                                        ...updatedPayouts
                                                            .map((payout) => {
                                                                  'item_name':
                                                                      'Payout',
                                                                  'item_price':
                                                                      double.tryParse(payout['amount']?.toString() ??
                                                                              '0') ??
                                                                          0.0,
                                                                  'items_count':
                                                                      1,
                                                                  'item_sum_price':
                                                                      double.tryParse(payout['amount']?.toString() ??
                                                                              '0') ??
                                                                          0.0,
                                                                  'item_image':
                                                                      'assets/svg/payout.svg',
                                                                  'item_type':
                                                                      'payout',
                                                                }),
                                                        ...updatedCashbacks
                                                            .map((cb) => {
                                                                  'item_name':
                                                                      'Cashback',
                                                                  'item_price':
                                                                      double.tryParse(cb['amount']?.toString() ??
                                                                              '0') ??
                                                                          0.0,
                                                                  'items_count':
                                                                      1,
                                                                  'item_sum_price':
                                                                      double.tryParse(cb['amount']?.toString() ??
                                                                              '0') ??
                                                                          0.0,
                                                                  'item_image': cb[
                                                                          'product_image'] ??
                                                                      cb['item_image'] ??
                                                                      cb['image'] ??
                                                                      "",
                                                                  'item_type':
                                                                      'cashback',
                                                                }),
                                                      ];
                                                    });
                                                  }

                                                  if (kDebugMode) {
                                                    print(
                                                        "✅ Quantity updated for PRODUCT or CUSTOM ITEM");
                                                  }
                                                } catch (e) {
                                                  if (kDebugMode)
                                                    print(
                                                        "❌ Failed updating quantity: $e");
                                                }
                                              },
                                              isDialog: true,
                                            );
                                          },
                                        );
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(
                                            vertical: 1, horizontal: 8),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: themeHelper.themeMode ==
                                                  ThemeMode.dark
                                              ? Color(0xFF252837)
                                              : Color(0xFFE8E8E8),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceEvenly,
                                                children: [
                                                  Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Row(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Expanded(
                                                            child: Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              children: [
                                                                Row(
                                                                  children: [
                                                                    Expanded(
                                                                      child:
                                                                          Column(
                                                                        crossAxisAlignment:
                                                                            CrossAxisAlignment.start,
                                                                        children: [
                                                                          Text(
                                                                            displayName.length > 40
                                                                                ? displayName.substring(0, 40) + "..."
                                                                                : displayName,
                                                                            maxLines:
                                                                                1,
                                                                            overflow:
                                                                                TextOverflow.ellipsis,
                                                                            style:
                                                                                TextStyle(
                                                                              fontSize: 14,
                                                                              fontWeight: FontWeight.bold,
                                                                              color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.textDark : ThemeNotifier.textLight,
                                                                            ),
                                                                          ),
                                                                          if ((orderItem['auto_discount'] ?? 0) >
                                                                              0)
                                                                            Padding(
                                                                              padding: const EdgeInsets.only(top: 2),
                                                                              child: Text(
                                                                                "Auto Discount: -${TextConstants.currencySymbol}${orderItem['auto_discount'].toStringAsFixed(2)}",
                                                                                style: const TextStyle(
                                                                                  fontSize: 11,
                                                                                  color: Colors.red,
                                                                                  fontWeight: FontWeight.w600,
                                                                                ),
                                                                              ),
                                                                            ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      if (variationCount != 0)
                                                        Row(
                                                          children: [
                                                            Text(
                                                              variationName ==
                                                                      ''
                                                                  ? ""
                                                                  : "($variationName)",
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                  fontSize: 12,
                                                                  color: themeHelper
                                                                              .themeMode ==
                                                                          ThemeMode
                                                                              .dark
                                                                      ? ThemeNotifier
                                                                          .textDark
                                                                      : Colors
                                                                          .grey),
                                                            ),
                                                            const SizedBox(
                                                                width: 4),
                                                            SvgPicture.asset(
                                                                "assets/svg/variation.svg",
                                                                height: 10,
                                                                width: 10),
                                                            const SizedBox(
                                                                width: 4),
                                                            Text(
                                                                "$variationCount",
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: const TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                    color: Color(
                                                                        0xFFFE6464))),
                                                          ],
                                                        ),
                                                    ],
                                                  ),
                                                  Row(
                                                    children: [
                                                      if (!isCouponOrPayout)
                                                        Builder(
                                                          builder: (_) {
                                                            final String
                                                                itemTypeStr =
                                                                (orderItem['item_type'] ??
                                                                        '')
                                                                    .toString()
                                                                    .toLowerCase();
                                                            final bool
                                                                isWeightedRow =
                                                                itemTypeStr
                                                                    .contains(
                                                                        'weighted');
                                                            if (isWeightedRow) {
                                                              final dynamic
                                                                  rawQty =
                                                                  orderItem[
                                                                          'display_qty'] ??
                                                                      orderItem[
                                                                          'weight_qty'] ??
                                                                      orderItem[
                                                                          'quantity'] ??
                                                                      1;
                                                              final double qty = (rawQty
                                                                      is num)
                                                                  ? rawQty
                                                                      .toDouble()
                                                                  : double.tryParse(
                                                                          rawQty
                                                                              .toString()) ??
                                                                      1.0;
                                                              final double
                                                                  lineTotal =
                                                                  ((orderItem['original_total'] ??
                                                                          orderItem[
                                                                              'item_price'] ??
                                                                          0) as num)
                                                                      .toDouble();
                                                              final double
                                                                  unitPrice =
                                                                  qty > 0
                                                                      ? lineTotal /
                                                                          qty
                                                                      : lineTotal;
                                                              return Text(
                                                                "${TextConstants.currencySymbol}${unitPrice.toStringAsFixed(2)} × $qty",
                                                                style:
                                                                    TextStyle(
                                                                  color: themeHelper
                                                                              .themeMode ==
                                                                          ThemeMode
                                                                              .dark
                                                                      ? ThemeNotifier
                                                                          .textDark
                                                                      : Colors
                                                                          .black54,
                                                                  fontSize: 14,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              );
                                                            }
                                                            final double price =
                                                                ((orderItem['item_price'] ??
                                                                        orderItem[
                                                                            'price'] ??
                                                                        0) as num)
                                                                    .toDouble();
                                                            final dynamic
                                                                rawQty =
                                                                orderItem[
                                                                        'display_qty'] ??
                                                                    orderItem[
                                                                        'items_count'] ??
                                                                    orderItem[
                                                                        'quantity'] ??
                                                                    1;
                                                            return Text(
                                                              "${TextConstants.currencySymbol}${price.toStringAsFixed(2)} × $rawQty",
                                                              style: TextStyle(
                                                                color: themeHelper
                                                                            .themeMode ==
                                                                        ThemeMode
                                                                            .dark
                                                                    ? ThemeNotifier
                                                                        .textDark
                                                                    : Colors
                                                                        .black54,
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                      if (!isCouponOrPayout &&
                                                          (isEbtEligible ||
                                                              isVariant))
                                                        const SizedBox(
                                                            width: 6),
                                                      if (isEbtEligible)
                                                        Container(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  horizontal: 6,
                                                                  vertical: 2),
                                                          decoration: BoxDecoration(
                                                              color:
                                                                  Colors.green,
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          4)),
                                                          child: const Text(
                                                              "EBT",
                                                              style: TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 6,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold)),
                                                        ),
                                                      if (isEbtEligible &&
                                                          isVariant)
                                                        const SizedBox(
                                                            width: 6),
                                                      if (isVariant)
                                                        Row(
                                                          children: [
                                                            SvgPicture.asset(
                                                                SvgUtils
                                                                    .variationIcon,
                                                                height: 10,
                                                                width: 10),
                                                          ],
                                                        ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 20),
                                            Builder(
                                              builder: (context) {
                                                final int qty =
                                                    (orderItem['items_count'] ??
                                                        orderItem['quantity'] ??
                                                        1);
                                                final double originalTotal = (orderItem[
                                                            'original_total'] ??
                                                        ((orderItem['item_price'] ??
                                                                orderItem[
                                                                    'price'] ??
                                                                0) *
                                                            qty))
                                                    .toDouble();
                                                final double discount =
                                                    (orderItem['auto_discount'] ??
                                                            0)
                                                        .toDouble();
                                                final double finalTotal =
                                                    originalTotal - discount;
                                                return Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.end,
                                                  children: [
                                                    if (discount > 0)
                                                      Text(
                                                        "${TextConstants.currencySymbol}${originalTotal.toStringAsFixed(2)}",
                                                        style: const TextStyle(
                                                          fontSize: 14,
                                                          color: Colors.grey,
                                                          decoration:
                                                              TextDecoration
                                                                  .lineThrough,
                                                        ),
                                                      ),
                                                    Text(
                                                      isPayout || isCoupon
                                                          ? "-${TextConstants.currencySymbol}${finalTotal.abs().toStringAsFixed(2)}"
                                                          : "${TextConstants.currencySymbol}${finalTotal.toStringAsFixed(2)}",
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: isPayout ||
                                                                isCoupon
                                                            ? Colors.red
                                                            : themeHelper
                                                                        .themeMode ==
                                                                    ThemeMode
                                                                        .dark
                                                                ? ThemeNotifier
                                                                    .textDark
                                                                : ThemeNotifier
                                                                    .textLight,
                                                      ),
                                                    ),
                                                  ],
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
            ),

            // ---------------------- SUMMARY & PAYMENT SECTION (UNCHANGED) ----------------------
            Container(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.primaryBackground
                  : null,
              child: Column(
                children: [
                  if (tabs.isNotEmpty)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child: (!isKeyboardVisible && _showFullSummary)
                          ? Container(
                              margin: const EdgeInsets.only(
                                  top: 8, right: 6, left: 6),
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.only(
                                    topRight: Radius.circular(8),
                                    topLeft: Radius.circular(8)),
                                color: themeHelper.themeMode == ThemeMode.dark
                                    ? ThemeNotifier.orderPanelSummary
                                    : Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        themeHelper.themeMode == ThemeMode.dark
                                            ? const Color(0xFFF0F0F0)
                                                .withOpacity(0.15)
                                            : Colors.black.withOpacity(0.25),
                                    offset: const Offset(0, 4),
                                    blurRadius: 6,
                                    spreadRadius: -0.5,
                                  ),
                                  BoxShadow(
                                    color:
                                        themeHelper.themeMode == ThemeMode.dark
                                            ? const Color(0xFFF0F0F0)
                                                .withOpacity(0.15)
                                            : Colors.black.withOpacity(0.15),
                                    offset: const Offset(0, -4),
                                    blurRadius: 6,
                                    spreadRadius: -0.5,
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(TextConstants.subTotalText,
                                          style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              color: themeHelper.themeMode ==
                                                      ThemeMode.dark
                                                  ? ThemeNotifier.textDark
                                                  : ThemeNotifier.textLight)),
                                      Text(
                                        (() {
                                          final bool hasOnlyPayoutItems =
                                              orderItems.isNotEmpty &&
                                                  orderItems.every((item) {
                                                    final name = (item[AppDBConst
                                                                .itemName] ??
                                                            item['item_name'] ??
                                                            '')
                                                        .toString()
                                                        .toLowerCase();
                                                    final type = (item[AppDBConst
                                                                .itemType] ??
                                                            item['item_type'] ??
                                                            '')
                                                        .toString()
                                                        .toLowerCase();
                                                    final isRefunded = item[
                                                                AppDBConst
                                                                    .isRefundItem] ==
                                                            1 ||
                                                        item[AppDBConst
                                                                .isRefundItem] ==
                                                            true;
                                                    if (isRefunded) return true;
                                                    return name.contains(
                                                            TextConstants
                                                                .payoutText) ||
                                                        type.contains(
                                                            TextConstants
                                                                .payoutText);
                                                  });
                                          final double grossTotalValue =
                                              (grossTotal as num).toDouble();
                                          final double displayGrossTotal =
                                              hasOnlyPayoutItems
                                                  ? -grossTotalValue.abs()
                                                  : grossTotalValue;
                                          return displayGrossTotal < 0
                                              ? "-${TextConstants.currencySymbol}${displayGrossTotal.abs().toStringAsFixed(2)}"
                                              : "${TextConstants.currencySymbol}${displayGrossTotal.toStringAsFixed(2)}";
                                        })(),
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                            color: themeHelper.themeMode ==
                                                    ThemeMode.dark
                                                ? ThemeNotifier.textDark
                                                : ThemeNotifier.textLight),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(TextConstants.taxText,
                                          style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 13,
                                              color: themeHelper.themeMode ==
                                                      ThemeMode.dark
                                                  ? Colors.white54
                                                  : Colors.grey)),
                                      Text(
                                          "${TextConstants.currencySymbol}${orderTax.toStringAsFixed(2)}",
                                          style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12,
                                              color: themeHelper.themeMode ==
                                                      ThemeMode.dark
                                                  ? Colors.white54
                                                  : Colors.grey)),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  if (merchantDiscount > 0.000001)
                                    // ✅ CHANGE 1: was `>= 0.01`, now `> 0.0` — shows any non-zero discount
                                    //   if (merchantDiscount > 0.0)
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          spacing: 5,
                                          children: [
                                            // SvgPicture.asset("assets/svg/discount_star.svg",
                                            //   height: 12, width: 12,
                                            //   colorFilter: ColorFilter.mode(Colors.blueAccent, BlendMode.srcIn),),
                                            Text(TextConstants.merchantDiscount,
                                                style: TextStyle(
                                                  color: Color(0xFF007BFF),
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                )),
                                            // ✅ CHANGE 2: was `toStringAsFixed(2) == '0.00'`
                                            // now checks the actual value so delete icon shows for tiny discounts
                                            merchantDiscount <= 0.0
                                                ? SizedBox()
                                                : GestureDetector(
                                                    // Inside buildCurrentOrder(), in the merchantDiscount Row's GestureDetector onTap:
                                                    onTap: () async {
                                                      if (kDebugMode) {
                                                        print(
                                                            "####################### Remove Merchant Discount locally");
                                                      }

                                                      final activeOrderId =
                                                          orderHelper
                                                              .activeOrderId;
                                                      if (activeOrderId ==
                                                          null) {
                                                        _scaffoldMessenger
                                                            .showSnackBar(
                                                          const SnackBar(
                                                              content: Text(
                                                                  "No active order found"),
                                                              backgroundColor:
                                                                  Colors.red),
                                                        );
                                                        return;
                                                      }

                                                      await CustomDialog
                                                          .showRemoveSpecialOrderItemsConfirmation(
                                                        context,
                                                        confirm: () async {
                                                          setState(() =>
                                                              _isLoading =
                                                                  true);

                                                          final offlineBox =
                                                              StorageProvider
                                                                  .offlineOrders;
                                                          final rawOrder =
                                                              await offlineBox.get(
                                                                  activeOrderId
                                                                      .toString());

                                                          if (rawOrder ==
                                                              null) {
                                                            setState(() =>
                                                                _isLoading =
                                                                    false);
                                                            return;
                                                          }

                                                          final Map<String,
                                                              dynamic> order = Map<
                                                                  String,
                                                                  dynamic>.from(
                                                              rawOrder);
                                                          order['order_id'] =
                                                              activeOrderId; // Ensure ID preserved

                                                          // === COMPREHENSIVE CLEANUP ===
                                                          bool hadDiscount =
                                                              false;
                                                          final discountKeys = [
                                                            'merchantDiscount',
                                                            'merchantDiscountIds',
                                                            'discounts',
                                                            'merchantDiscountType',
                                                            'merchantDiscountPercentage',
                                                            'merchantDiscountFixed',
                                                            'merchantDiscountBaseGross',
                                                            'merchantDiscountIsPercentage',
                                                            'merchant_discount_calculated',
                                                            'merchantDiscountApplied',
                                                            'appliedMerchantDiscount',
                                                            'merchantDiscountAmount',
                                                          ];

                                                          for (final key
                                                              in discountKeys) {
                                                            if (order
                                                                .containsKey(
                                                                    key)) {
                                                              order.remove(key);
                                                              hadDiscount =
                                                                  true;
                                                            }
                                                          }

                                                          // Also clean any string/number variants
                                                          order.removeWhere((key,
                                                                  value) =>
                                                              key
                                                                  .toString()
                                                                  .toLowerCase()
                                                                  .contains(
                                                                      'merchantdiscount') ||
                                                              key
                                                                  .toString()
                                                                  .toLowerCase()
                                                                  .contains(
                                                                      'merchant_discount'));

                                                          // Recalculate totals with discount = 0
                                                          final products = (order[
                                                                          'products']
                                                                      as List?)
                                                                  ?.map((e) => Map<
                                                                      String,
                                                                      dynamic>.from(e))
                                                                  .toList() ??
                                                              [];
                                                          final customItems = (order[
                                                                          'custom_items']
                                                                      as List?)
                                                                  ?.map((e) => Map<
                                                                      String,
                                                                      dynamic>.from(e))
                                                                  .toList() ??
                                                              [];

                                                          double productTotal =
                                                              0.0;
                                                          for (final p
                                                              in products) {
                                                            final qty = int.tryParse(p[
                                                                            'quantity']
                                                                        ?.toString() ??
                                                                    p['items_count']
                                                                        ?.toString() ??
                                                                    '1') ??
                                                                1;
                                                            final price = double
                                                                    .tryParse(p['price']
                                                                            ?.toString() ??
                                                                        '0') ??
                                                                0.0;
                                                            productTotal +=
                                                                price * qty;
                                                          }
                                                          for (final c
                                                              in customItems) {
                                                            final qty = int.tryParse(c[
                                                                            'quantity']
                                                                        ?.toString() ??
                                                                    c['items_count']
                                                                        ?.toString() ??
                                                                    '1') ??
                                                                1;
                                                            final price = double.tryParse(c[
                                                                            'custom_item_price']
                                                                        ?.toString() ??
                                                                    c['amount']
                                                                        ?.toString() ??
                                                                    '0') ??
                                                                0.0;
                                                            productTotal +=
                                                                price * qty;
                                                          }

                                                          final payoutsTotal = ((order[
                                                                          'payouts']
                                                                      as List?) ??
                                                                  [])
                                                              .fold(
                                                                  0.0,
                                                                  (s, p) =>
                                                                      s +
                                                                      (double.tryParse(p['amount']?.toString() ??
                                                                              '0') ??
                                                                          0));
                                                          final cashbacksTotal =
                                                              ((order['cashbacks']
                                                                          as List?) ??
                                                                      [])
                                                                  .fold(
                                                                      0.0,
                                                                      (s, c) =>
                                                                          s +
                                                                          (double.tryParse(c['amount']?.toString() ?? '0') ??
                                                                              0));

                                                          final grossTotal =
                                                              productTotal +
                                                                  payoutsTotal +
                                                                  cashbacksTotal;
                                                          final orderDiscount =
                                                              (order['orderDiscount']
                                                                          as num?)
                                                                      ?.toDouble() ??
                                                                  0.0;
                                                          final orderTax =
                                                              (order['order_tax']
                                                                          as num?)
                                                                      ?.toDouble() ??
                                                                  0.0;
                                                          final cashbackFee =
                                                              (order['cashbackFee']
                                                                          as num?)
                                                                      ?.toDouble() ??
                                                                  0.0;

                                                          order['gross_total'] =
                                                              grossTotal;
                                                          order['net_total'] =
                                                              grossTotal -
                                                                  orderDiscount;
                                                          order['net_payable'] =
                                                              order['net_total']! +
                                                                  orderTax +
                                                                  cashbackFee;

                                                          await offlineBox.put(
                                                              activeOrderId
                                                                  .toString(),
                                                              order);
                                                          await orderHelper
                                                              .loadData();

                                                          OrderHelper
                                                              .notifyOrderPanelToRefresh();
                                                          await CustomerDisplayHelper
                                                              .updateCustomerDisplay(
                                                                  activeOrderId);

                                                          if (mounted) {
                                                            setState(() =>
                                                                _isLoading =
                                                                    false);
                                                          }

                                                          // if (hadDiscount) {
                                                          //   _scaffoldMessenger.showSnackBar(
                                                          //     const SnackBar(content: Text("Merchant discount removed successfully"), backgroundColor: Colors.green),
                                                          //   );
                                                          // }
                                                        },
                                                      );
                                                    },
                                                    child: SvgPicture.asset(
                                                      "assets/svg/delete.svg",
                                                      height: 24,
                                                      width: 24,
                                                    ),
                                                  ),
                                          ],
                                        ),
                                        // ✅ CHANGE 3: was `toStringAsFixed(2)` — now shows full precision
                                        // so ₹0.00013 displays as "-₹0.00013" instead of "-₹0.00"
                                        Text(
                                            "-${TextConstants.currencySymbol}${merchantDiscount.toStringAsFixed(merchantDiscount < 0.01 ? 5 : 2)}",
                                            style: TextStyle(
                                              color: Colors.blue,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            )),
                                      ],
                                    ),
                                  const SizedBox(height: 2),
                                  if (cashbackFee > 0)
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          spacing: 5,
                                          children: [
                                            // Icon(Icons.wallet_giftcard,
                                            //     size: 14,
                                            //     color: Color(0XFF55CBCD)),
                                            Text(
                                              TextConstants.cashbackFee,
                                              style: TextStyle(
                                                color: Color(0XFF55CBCD),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Text(
                                          "${TextConstants.currencySymbol}${cashbackFee.toStringAsFixed(2)}",
                                          style: TextStyle(
                                            color: Color(0XFF55CBCD),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  if (tabs.isNotEmpty)
                    GestureDetector(
                      onTap: isKeyboardVisible ? null : _toggleSummary,
                      child: Container(
                        margin:
                            const EdgeInsets.only(top: 0, right: 6, left: 6),
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.only(
                              bottomRight: Radius.circular(8),
                              bottomLeft: Radius.circular(8)),
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? const Color(0xFF2A2C36)
                              : Colors.grey.shade300,
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withOpacity(0.25),
                                offset: const Offset(0, 4),
                                blurRadius: 6,
                                spreadRadius: 1),
                            BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                offset: const Offset(0, -4),
                                blurRadius: 6,
                                spreadRadius: 1),
                          ],
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("${TextConstants.totalItemsText}: $totalItems",
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                Text(
                                  'Amount: ${netPayable < 0 ? '-${TextConstants.currencySymbol}${netPayable.abs().toStringAsFixed(2)}' : '${TextConstants.currencySymbol}${netPayable.toStringAsFixed(2)}'}',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(width: 8),
                                Icon(_showFullSummary
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_up),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (tabs.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      width: double.infinity,
                      height: MediaQuery.of(context).size.height * 0.0585,
                      child: ElevatedButton(
                        onPressed: (orderItems.isNotEmpty && !_isPayBtnLoading)
                            ? () async {
                                await enablePhoneInput();
                                if (kDebugMode) {
                                  debugPrint(" CHECK OUT BUTTON CLICKED ");
                                }

                                setState(() => _isPayBtnLoading = true);
                                // 🔥 ADD THIS LINE
                                // await Future.delayed(Duration(milliseconds: 100));

                                try {
                                  final int? frozenCheckoutOrderId =
                                      orderHelper.activeOrderId;
                                  if (frozenCheckoutOrderId == null) {
                                    if (mounted) {
                                      setState(() => _isPayBtnLoading = false);
                                    }
                                    _showError(
                                        'Unable to open payment: no active order.');
                                    return;
                                  }

                                  final List<Map<String, dynamic>>
                                      workingItems = orderItems
                                          .map((e) =>
                                              Map<String, dynamic>.from(e))
                                          .toList();

                                  int? serverOrderId;

                                  // =======================================================
                                  // 🔹 LOAD VALUES FOR SUMMARY
                                  // =======================================================
                                  final box = StorageProvider.offlineOrders;
                                  final hiveKey =
                                      frozenCheckoutOrderId.toString();

                                  double totalEbtAfterDiscount = 0.0;

                                  final boxData = await box.get(hiveKey);
                                  final double discountAmount = ((boxData is Map
                                              ? boxData["discount_amount"]
                                              : null) ??
                                          0.0)
                                      .toDouble();

                                  // =======================================================
                                  // 🔹 PREPARE CART FOR ENGINE
                                  // =======================================================
                                  final List<Map<String, dynamic>> cartItems =
                                      orderItems
                                          .where((item) =>
                                              item['product_id'] != null &&
                                              (item['product_id'] as int) > 0)
                                          .map((item) {
                                    return {
                                      'product_id': item['product_id'],
                                      'price': item['item_price'],
                                      'qty': item['items_count'],
                                    };
                                  }).toList();

                                  // =======================================================
                                  // 🔥 CALL DISCOUNT ENGINE
                                  // =======================================================
                                  final rawEngineDiscounts =
                                      await DiscountEngine.applyAll(
                                          AppDB.isar, cartItems);

// 🔧 Normalize keys to int (CRITICAL FIX)
                                  final Map<int, EngineDiscountResult>
                                      engineDiscounts = {
                                    for (final entry
                                        in rawEngineDiscounts.entries)
                                      int.tryParse(entry.key.toString()) ?? -1:
                                          entry.value
                                  };

                                  if (kDebugMode) {
                                    print(
                                        "🔥 NORMALIZED ENGINE MAP = $engineDiscounts");
                                  }

                                  if (kDebugMode) {
                                    print(
                                        "🔥 ENGINE RESULT MAP = $engineDiscounts");
                                  }

                                  // =======================================================
                                  // 🔥 APPLY + NORMALIZE ENGINE RESULTS (ONCE)
                                  // =======================================================
                                  // for (final item in workingItems) {
                                  //   final pid = int.tryParse(
                                  //       item['product_id']?.toString() ?? '');
                                  //   final engineResult = pid != null
                                  //       ? engineDiscounts[pid]
                                  //       : null;
                                  //
                                  //   item['auto_discount'] =
                                  //       engineResult?.amount ?? 0.0;
                                  //   item['discount_type'] =
                                  //       engineResult?.ruleType ?? '';
                                  //   item['discount_source'] =
                                  //   engineResult != null ? 'engine' : '';
                                  //   item['rule_id'] =
                                  //       engineResult?.ruleId ?? '';
                                  // }
                                  for (final item in workingItems) {
                                    final pid = int.tryParse(
                                        item['product_id']?.toString() ?? '');
                                    final engineResult = pid != null
                                        ? engineDiscounts[pid]
                                        : null;

                                    item['auto_discount'] =
                                        engineResult?.amount ?? 0.0;
                                    item['discount_type'] =
                                        engineResult?.ruleType ?? '';
                                    item['discount_source'] =
                                        engineResult != null ? 'engine' : '';
                                    item['rule_id'] =
                                        engineResult?.ruleId ?? '';

                                    // ✅ Seed item_tax from the already-computed panel totals loop
                                    // so checkout tax fallback has a real value, not 0.0
                                    final String wItemType =
                                        (item['item_type'] ?? '')
                                            .toString()
                                            .toLowerCase();
                                    final bool wIsPayout =
                                        wItemType.contains('payout');
                                    final bool wIsCashback =
                                        wItemType.contains('cashback');
                                    final bool wIsCoupon =
                                        wItemType.contains('coupon');
                                    if (!wIsPayout &&
                                        !wIsCashback &&
                                        !wIsCoupon) {
                                      double seededTax =
                                          ((item['item_tax'] ?? 0) as num)
                                              .toDouble();
                                      if (seededTax <= 0) {
                                        final int wProductId = int.tryParse(
                                                (item['product_id'] ?? 0)
                                                    .toString()) ??
                                            0;
                                        final double wPrice =
                                            ((item['item_price'] ?? 0) as num)
                                                .toDouble();
                                        final int wQty =
                                            ((item['items_count'] ?? 1) as num)
                                                .toInt();
                                        final bool wIsEbt =
                                            item['is_ebt_eligible'] == true;
                                        final String wTaxStatus =
                                            (item['tax_status'] ?? 'taxable')
                                                .toString()
                                                .toLowerCase();
                                        final double wTaxRate = double.tryParse(
                                                (item['tax_rate'] ??
                                                        item['tax_Rate'] ??
                                                        '0')
                                                    .toString()) ??
                                            0.0;
                                        const double defaultNonEbtTaxRate = 9.1;

                                        if (wIsEbt) {
                                          seededTax = 0.0;
                                        } else if (wItemType
                                            .contains('custom')) {
                                          if (wTaxRate > 0) {
                                            seededTax = roundTaxHalfUp(
                                                ((wPrice * wTaxRate) / 100) *
                                                    wQty);
                                          }
                                        } else if (wProductId > 0) {
                                          if (wTaxStatus == 'taxable' &&
                                              wTaxRate > 0) {
                                            seededTax =
                                                ((wPrice * wQty) * wTaxRate) /
                                                    100;
                                          } else {
                                            seededTax = getProductTaxFromHive(
                                                wProductId, wPrice, wQty);
                                            if (seededTax <= 0 &&
                                                wTaxStatus != 'none') {
                                              seededTax = ((wPrice * wQty) *
                                                      defaultNonEbtTaxRate) /
                                                  100;
                                            }
                                          }
                                        }
                                      }
                                      item['item_tax'] =
                                          seededTax; // ✅ now checkout loop can reliably read this
                                    }
                                  }

                                  // =======================================================
                                  // 🔹 CALCULATE TAX & TOTALS
                                  // =======================================================
                                  double totalTaxAfterDiscount = 0.0;
                                  final List<Tax> taxList =
                                      await _assetDBHelper.getTaxList();

                                  for (final item in workingItems) {
                                    final int productId = int.tryParse(
                                            item['product_id']?.toString() ??
                                                '0') ??
                                        0;
                                    final double price =
                                        (item['item_price'] as num?)
                                                ?.toDouble() ??
                                            0.0;
                                    final int qty =
                                        (item['items_count'] as num?)
                                                ?.toInt() ??
                                            1;
                                    final double autoDiscount =
                                        (item['auto_discount'] as num?)
                                                ?.toDouble() ??
                                            0.0;

                                    final double discountedUnitPrice =
                                        (price * qty - autoDiscount) / qty;

                                    double itemTax = 0.0;
                                    if (productId > 0) {
                                      final bool isEbt =
                                          item['is_ebt_eligible'] == true;
                                      const double defaultNonEbtTaxRate = 9.1;
                                      final lineTaxStatus =
                                          (item['tax_status'] ?? 'taxable')
                                              .toString()
                                              .toLowerCase();
                                      final lineTaxRate = double.tryParse(
                                              (item['tax_rate'] ?? '0')
                                                  .toString()) ??
                                          0.0;
                                      if (isEbt) {
                                        itemTax = 0.0;
                                      } else if (lineTaxStatus == 'taxable' &&
                                          lineTaxRate > 0) {
                                        // Use stored item_tax (now seeded above) as primary, recompute as fallback
                                        itemTax = (item['item_tax'] as num?)
                                                ?.toDouble() ??
                                            0.0;
                                        if (itemTax <= 0) {
                                          itemTax =
                                              ((discountedUnitPrice * qty) *
                                                      lineTaxRate) /
                                                  100;
                                        }
                                      } else {
                                        itemTax = getProductTaxFromHive(
                                            productId,
                                            discountedUnitPrice,
                                            qty);
                                        if (itemTax <= 0 &&
                                            lineTaxStatus != 'none') {
                                          // Fallback to seeded item_tax from panel totals
                                          itemTax = (item['item_tax'] as num?)
                                                  ?.toDouble() ??
                                              0.0;
                                          if (itemTax <= 0) {
                                            const double defaultNonEbtTaxRate =
                                                9.1;
                                            itemTax =
                                                ((discountedUnitPrice * qty) *
                                                        defaultNonEbtTaxRate) /
                                                    100;
                                          }
                                        }
                                      }
                                    } else if (item['item_type'] == 'custom') {
                                      itemTax = getCustomItemTax(
                                        taxClass: item['tax_class'] ?? '',
                                        unitPrice: discountedUnitPrice,
                                        qty: qty,
                                        taxes: taxList,
                                        taxRate: item['tax_rate'],
                                      );
                                    }

                                    totalTaxAfterDiscount += itemTax;
                                    item['tax_after_discount'] = itemTax;
                                  }
                                  totalTaxAfterDiscount =
                                      roundTaxHalfUp(totalTaxAfterDiscount);
                                  for (final item in workingItems) {
                                    final double price =
                                        (item['item_price'] as num?)
                                                ?.toDouble() ??
                                            0.0;
                                    final int qty =
                                        (item['items_count'] as num?)
                                                ?.toInt() ??
                                            1;
                                    final double autoDiscount =
                                        (item['auto_discount'] as num?)
                                                ?.toDouble() ??
                                            0.0;

                                    final double discountedUnitPrice =
                                        (price * qty - autoDiscount) / qty;

                                    if (item['is_ebt_eligible'] == true) {
                                      totalEbtAfterDiscount +=
                                          discountedUnitPrice * qty;
                                    }
                                  }

                                  double grossAfterDiscount =
                                      workingItems.fold(0.0, (sum, item) {
                                    final double price =
                                        (item['item_price'] as num?)
                                                ?.toDouble() ??
                                            0.0;
                                    final int qty = item['items_count'] ?? 1;
                                    final double autoDiscount =
                                        (item['auto_discount'] as num?)
                                                ?.toDouble() ??
                                            0.0;
                                    return sum + ((price * qty) - autoDiscount);
                                  });
                                  grossAfterDiscount = double.parse(
                                      grossAfterDiscount.toStringAsFixed(2));

                                  // =======================================================
                                  // 🔒 FREEZE SNAPSHOT FOR SUMMARY
                                  // =======================================================
                                  final List<Map<String, dynamic>>
                                      summaryItems = workingItems
                                          .map((e) =>
                                              Map<String, dynamic>.from(e))
                                          .toList();

                                  // =======================================================
                                  // 🔹 SAVE TO HIVE
                                  // =======================================================
                                  final localKey =
                                      frozenCheckoutOrderId.toString();
                                  final existingLocal = await box.get(localKey);
                                  final Map<String, dynamic> updated =
                                      existingLocal != null
                                          ? Map<String, dynamic>.from(
                                              existingLocal)
                                          : <String, dynamic>{
                                              'order_id': frozenCheckoutOrderId,
                                              'id': frozenCheckoutOrderId,
                                              'products':
                                                  <Map<String, dynamic>>[],
                                            };

                                  // Recalculate percentage-based merchant discount w.r.t grossAfterDiscount
                                  final String mdType =
                                      updated['merchantDiscountType']
                                              ?.toString() ??
                                          'fixed';
                                  final double mdPerc = double.tryParse(
                                          updated['merchantDiscountPercentage']
                                                  ?.toString() ??
                                              '0') ??
                                      0.0;
                                  double recalculatedMerchantDiscount =
                                      merchantDiscount;
                                  if (mdType == 'percentage' && mdPerc > 0) {
                                    double base = grossAfterDiscount -
                                        orderDiscount.abs();
                                    if (base > 0) {
                                      recalculatedMerchantDiscount =
                                          (base * mdPerc) / 100.0;
                                    } else {
                                      recalculatedMerchantDiscount = 0.0;
                                    }
                                    updated['merchantDiscount'] =
                                        recalculatedMerchantDiscount;

                                    if (updated['discounts'] is List) {
                                      final List list =
                                          updated['discounts'] as List;
                                      final updatedDiscounts =
                                          <Map<String, dynamic>>[];
                                      for (final item in list) {
                                        if (item is Map) {
                                          final m =
                                              Map<String, dynamic>.from(item);
                                          final name = (m['name'] ?? '')
                                              .toString()
                                              .toLowerCase();
                                          if (name.contains(
                                                  'merchant discount') ||
                                              name.contains('discount')) {
                                            m['discount_amount'] =
                                                -recalculatedMerchantDiscount;
                                            m['display_amount'] =
                                                recalculatedMerchantDiscount;
                                            m[AppDBConst.itemPrice] =
                                                recalculatedMerchantDiscount;
                                            m[AppDBConst.itemSumPrice] =
                                                recalculatedMerchantDiscount;
                                          }
                                          updatedDiscounts.add(m);
                                        }
                                      }
                                      updated['discounts'] = updatedDiscounts;
                                    }
                                  }

                                  double calculatedPerc = 0.0;
                                  if (mdType == 'percentage' && mdPerc > 0) {
                                    calculatedPerc = mdPerc;
                                  } else if (mdType == 'fixed' &&
                                      recalculatedMerchantDiscount.abs() > 0) {
                                    double base = grossAfterDiscount -
                                        orderDiscount.abs();
                                    if (base > 0) {
                                      calculatedPerc =
                                          (recalculatedMerchantDiscount.abs() /
                                                  base) *
                                              100.0;
                                    }
                                  }
                                  if (calculatedPerc > 0) {
                                    totalTaxAfterDiscount =
                                        totalTaxAfterDiscount *
                                            (1 - calculatedPerc / 100.0);
                                    totalTaxAfterDiscount =
                                        roundTaxHalfUp(totalTaxAfterDiscount);
                                  }

                                  updated["tax_discount"] =
                                      totalTaxAfterDiscount;
                                  updated["order_tax"] = totalTaxAfterDiscount;

                                  updated["cashback_fee"] = double.parse(
                                      cashbackFee.toStringAsFixed(2));

                                  updated['net_total'] = grossAfterDiscount -
                                      orderDiscount.abs() -
                                      recalculatedMerchantDiscount;
                                  updated['net_payable'] =
                                      updated['net_total'] +
                                          totalTaxAfterDiscount +
                                          cashbackFee;
                                  merchantDiscount =
                                      recalculatedMerchantDiscount;

// =======================================================
// 🔥 BUILD DISCOUNT LINES (SOURCE OF TRUTH)
// =======================================================

                                  final Map<String, dynamic> discountLines = {};

                                  for (final item in workingItems) {
                                    final pid = item['product_id']?.toString();
                                    if (pid == null || pid == "0") continue;

                                    discountLines[pid] = {
                                      "amount": (item['auto_discount'] ?? 0)
                                          .toDouble(),
                                      "type": item['discount_type'] ?? "",
                                      "source": item['discount_source'] ?? "",
                                      "rule_id": item['rule_id'] ?? "",
                                    };
                                  }

// SAVE ONLY ONCE HERE
                                  updated['discount_lines'] = discountLines;
                                  updated['_update_source'] = 'checkout';

// 🔥 ONLY WRITE IN WHOLE CHECKOUT
                                  await box.put(localKey, updated);

// DEBUG

                                  // ===== VERIFY HIVE WRITE =====
                                  final verifyWrite = await box.get(localKey);

                                  debugPrint(
                                      "\n🟥🟥🟥 VERIFY AFTER SAVE (CHECKOUT) 🟥🟥🟥");
                                  debugPrint("OrderID: $localKey");

                                  final items = verifyWrite?['items'] ?? [];
                                  for (final i in items) {
                                    debugPrint(
                                        "ITEM → ${i['item_name']} | discount_meta=${i['discount_meta']}");
                                  }

                                  final products =
                                      verifyWrite?['products'] ?? [];
                                  for (final p in products) {
                                    debugPrint(
                                        "PRODUCT → ${p['name']} | discount_meta=${p['discount_meta']}");
                                  }

                                  debugPrint("🟥🟥🟥 END VERIFY 🟥🟥🟥\n");

                                  final finalStored = await box.get(localKey);
                                  debugPrint(
                                      "🧠 FINAL STORED HIVE ORDER =====================");
                                  debugPrint(const JsonEncoder.withIndent('  ')
                                      .convert(finalStored));
                                  debugPrint(
                                      "===============================================");
// DEBUG
                                  final verify = await box.get(localKey);
                                  debugPrint("🧠 STORED ORDER AFTER SAVE:");
                                  debugPrint(jsonEncode(verify));
                                  await CustomerDisplayHelper
                                      .updateCustomerDisplay(
                                          frozenCheckoutOrderId,
                                          summaryEnabled: true);

                                  // =======================================================
                                  // 🔹 NAVIGATE TO SUMMARY SCREEN
                                  // =======================================================
                                  final result = await Navigator.push(
                                    context,
                                    PageRouteBuilder(
                                      pageBuilder: (context, animation,
                                              secondaryAnimation) =>
                                          OrderSummaryScreen(
                                        formattedDate: displayDate,
                                        formattedTime: displayTime,
                                        orderItems: summaryItems,
                                        grossTotal: grossTotal,
                                        orderDiscount: orderDiscount,
                                        merchantDiscount: merchantDiscount,
                                        orderTax: totalTaxAfterDiscount,
                                        netPayable: updated['net_payable'] ??
                                            (grossAfterDiscount +
                                                totalTaxAfterDiscount -
                                                merchantDiscount),
                                        orderId: serverOrderId ??
                                            frozenCheckoutOrderId,
                                        isOfflineSynced: serverOrderId != null,
                                        offlineOrderId: frozenCheckoutOrderId,
                                        cashbackFee: cashbackFee,
                                        ebtAmount: totalEbtAfterDiscount,
                                        discountAmount: discountAmount,
                                      ),
                                      transitionDuration:
                                          const Duration(milliseconds: 220),
                                      transitionsBuilder: (context, animation,
                                          secondaryAnimation, child) {
                                        final curved = CurvedAnimation(
                                          parent: animation,
                                          curve: Curves.easeOutCubic,
                                        );

                                        return FadeTransition(
                                          opacity: curved,
                                          child: SlideTransition(
                                            position: Tween<Offset>(
                                              begin: const Offset(0.05,
                                                  0), // slight right → natural feel
                                              end: Offset.zero,
                                            ).animate(curved),
                                            child: child,
                                          ),
                                        );
                                      },
                                    ),
                                  );
                                } catch (e, s) {
                                  debugPrint("❌ Error syncing order: $e");
                                  debugPrint("$s");
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text("Failed to sync order")),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() => _isPayBtnLoading = false);
                                  }
                                }
                              }
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              (orderItems.isNotEmpty && !_isPayBtnLoading)
                                  ? const Color(0xFFFF6B6B)
                                  : Colors.grey,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: _isPayBtnLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text("Check Out",
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// //Build #1.0.2 : Added showNumPadDialog if user tap on order layout list item
}
