import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pinaka_pos/Database/storage/storage_provider.dart';
import 'package:pinaka_pos/Database/user_db_helper.dart';
import 'package:pinaka_pos/Repositories/Orders/order_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:isar/isar.dart'; // Build #1.0.104
import '../Constants/text.dart';
import '../Helper/Extentions/money_rounding_helper.dart';
import '../Helper/customerdisplayhelper.dart';
import '../Models/Category/category_product_model.dart';
import '../Models/Orders/get_orders_model.dart' as model;
import '../Screens/Home/isar_payments/local_payments_db_helper.dart';
import '../services/CustomerDisplayService.dart';
import '../services/customer_services.dart';
import 'db_helper.dart';
import 'isar_service.dart'; // Build #1.0.104
import 'isar_cache_entry.dart'; // Build #1.0.104

/// Resolves product image URL from various possible keys (image, product_image, images array, etc.)
/// Top-level function for use across the app; OrderHelper.resolveProductImage delegates to this.
String resolveProductImageFromMap(dynamic map) {
  if (map == null || map is! Map) return '';
  final m = map;

  final image = m['image'];
  if (image is String && image.trim().isNotEmpty) return image;
  final productImage = m['product_image'];
  if (productImage is String && productImage.trim().isNotEmpty)
    return productImage;
  final itemImage = m['item_image'];
  if (itemImage is String && itemImage.trim().isNotEmpty) return itemImage;
  final customItemImage = m['custom_item_image'];
  if (customItemImage is String && customItemImage.trim().isNotEmpty)
    return customItemImage;
  final fastKeyImage = m['fast_key_item_image'];
  if (fastKeyImage is String && fastKeyImage.trim().isNotEmpty)
    return fastKeyImage;

  if (image is Map && image['src'] != null) {
    final src = image['src'].toString();
    if (src.isNotEmpty) return src;
  }

  final images = m['images'];
  if (images is List && images.isNotEmpty) {
    final first = images.first;
    if (first is String && first.isNotEmpty) return first;
    if (first is Map && first['src'] != null) return first['src'].toString();
  }

  return '';
}

// Build #1.0.64: Add ItemType enum
enum ItemType {
  customProduct(TextConstants.customItem),
  coupon(TextConstants.couponText),
  payout(TextConstants.payoutText), //Build #1.0.68
  product(TextConstants.productText);

  final String value;
  const ItemType(this.value);
}

class OrderHelper {
  // Build #1.0.10 - Naveen: Added Order Helper to Maintain Order data
  static final OrderHelper _instance = OrderHelper
      ._internal(); // Singleton instance to ensure only one instance of OrderHelper exists
  factory OrderHelper() => _instance;
  static bool isOrderPanelLoaded = false;

  /// Notifier so RightOrderPanel can refresh when a new order is created (e.g. from grid).
  static final ValueNotifier<int> orderPanelRefreshNotifier = ValueNotifier(0);
  static final Map<int, double> _manualRefundAmounts = {};

  static void notifyOrderPanelToRefresh() {
    orderPanelRefreshNotifier.value++;
  }

  static void setManualRefundAmount({
    required int orderId,
    required double amount,
  }) {
    _manualRefundAmounts[orderId] = amount;
    notifyOrderPanelToRefresh();
  }

  static double? getManualRefundAmount(int orderId) {
    return _manualRefundAmounts[orderId];
  }

  // static void notifyOrderPanelToRefresh() {
  //   orderPanelRefreshNotifier.value++;
  // }

  /// When ensureOrderExists fails, this holds the error message for UI feedback.
  static String? lastEnsureOrderError;

  Map<int, bool> orderAgeVerifiedFlags = {};
  int? activeOrderId; // Stores the currently active order ID
  int? activeUserId; // Stores the active user ID
  int?
      selectedOrderId; // Build #1.0.248 : save & persists across rebuilds of theme selection change
  int? cancelledOrderId; // Build #1.0.189: Stores the cancelled order ID
  List<int> orderIds = []; // List of order IDs for the active user
  List<Map<String, dynamic>> orders = [];

  /// Build 1.0.171: Concurrency Control: _syncFuture ensures only one sync operation runs at a time by checking if a sync is in progress; if so, it waits for completion, preventing data corruption or race conditions.
  /// Reliable Sync Process: Using a Completer, _syncFuture manages the sync, clears and updates the database with API orders, handles errors, and resets to allow new syncs, maintaining data consistency.
  static Future<void>? _syncFuture;

  /// Ensures only one ensureOrderExists runs at a time to avoid race conditions.
  static Future<int?>? _ensureOrderInProgress;

  OrderHelper._internal() {
    if (kDebugMode) {
      print("#### OrderHelper initialized!");
    }
    loadData(); // Load existing order data on initialization
  }

  double getCurrentMerchantDiscount(Map<String, dynamic> order,
      {double? grossTotal, double? orderDiscount, double? orderTax}) {
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
    if (type == 'percentage' && perc > 0) {
      double discVal =
          orderDiscount ?? (order['orderDiscount'] as num?)?.toDouble() ?? 0.0;
      double base = currentGross - discVal;
      return (base * perc) / 100.0;
    } else {
      return fixed;
    }
  }

  double getProductTaxFromHive(
      int productId, double discountedUnitPrice, int qty) {
    try {
      final double taxableBase = discountedUnitPrice * qty;
      final isar = IsarService.sync;
      if (isar == null) return 0.0;

      final cachedEntries = isar.isarCacheEntrys
          .where()
          .filter()
          .keyStartsWith("products_")
          .findAllSync();

      for (final entry in cachedEntries) {
        final List products = json.decode(entry.json);

        final product = products.firstWhere(
          (p) {
            final pid = int.tryParse(
                    (p["fast_key_product_id"] ?? p["id"] ?? "").toString()) ??
                -1;
            return pid == productId;
          },
          orElse: () => null,
        );

        if (product == null) continue;

        final taxStatus =
            (product["tax_status"] ?? "taxable").toString().toLowerCase();

        if (taxStatus == "none") return 0.0;

        // Support both cached shapes:
        // 1) product["tax_rates"] (flat)
        // 2) product["tax"]["tax_rates"] (nested)
        final taxRates = product["tax_rates"] ?? product["tax"]?["tax_rates"];

        if (taxRates is List && taxRates.isNotEmpty) {
          double taxTotal = 0.0;

          for (final tax in taxRates) {
            final double rate =
                double.tryParse(tax["rate"]?.toString() ?? "0") ?? 0.0;

            final double rawTax = (taxableBase * rate) / 100;
            final double roundedTax = roundTaxHalfUp(rawTax);

            taxTotal += roundedTax;

            print("🧾 TAX LINE → rate:$rate base:$taxableBase tax:$roundedTax");
          }

          print("✅ TOTAL TAX → $taxTotal");
          return roundTaxHalfUp(taxTotal);
        }

        // Fallback: some cached products store a single tax rate instead of tax_rates array.
        final fallbackRate = double.tryParse(
              (product["tax_rate"] ?? product["tax"]?["rate"] ?? "0")
                  .toString(),
            ) ??
            0.0;
        if (fallbackRate > 0) {
          final tax = roundTaxHalfUp((taxableBase * fallbackRate) / 100);
          print(
              "🧾 TAX FALLBACK → rate:$fallbackRate base:$taxableBase tax:$tax");
          return tax;
        }
      }

      // Fallback: check all_products_list cache when product is not in current products_* buckets.
      final allProductsEntry = isar.isarCacheEntrys
          .where()
          .keyEqualTo("productCache::all_products_list")
          .findFirstSync();
      if (allProductsEntry != null) {
        final dynamic decoded = json.decode(allProductsEntry.json);
        final List allProducts = decoded is List ? decoded : <dynamic>[];
        final product = allProducts.cast<dynamic>().firstWhere(
          (p) {
            final pid = int.tryParse(
                    (p["fast_key_product_id"] ?? p["id"] ?? "").toString()) ??
                -1;
            return pid == productId;
          },
          orElse: () => null,
        );

        if (product != null) {
          final taxStatus =
              (product["tax_status"] ?? "taxable").toString().toLowerCase();
          if (taxStatus == "none") return 0.0;

          final taxRates = product["tax_rates"] ?? product["tax"]?["tax_rates"];
          if (taxRates is List && taxRates.isNotEmpty) {
            double taxTotal = 0.0;
            for (final tax in taxRates) {
              final double rate =
                  double.tryParse(tax["rate"]?.toString() ?? "0") ?? 0.0;
              final double rawTax = (taxableBase * rate) / 100;
              final double roundedTax = roundTaxHalfUp(rawTax);
              taxTotal += roundedTax;
            }
            return roundTaxHalfUp(taxTotal);
          }

          final fallbackRate = double.tryParse(
                (product["tax_rate"] ?? product["tax"]?["rate"] ?? "0")
                    .toString(),
              ) ??
              0.0;
          if (fallbackRate > 0) {
            final tax = roundTaxHalfUp((taxableBase * fallbackRate) / 100);
            return tax;
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error calculating tax for product $productId: $e");
      }
    }
    return 0.0;
  }

  Future<void> saveOfflineOrder(int orderId, Map<String, dynamic> order) async {
    final box = StorageProvider.offlineOrders;

    // --- Recalculate Totals ---
    final products = (order['products'] as List?) ?? [];
    final customItems = (order['custom_items'] as List?) ?? [];
    final payouts = (order['payouts'] as List?) ?? [];
    final cashbacks = (order['cashbacks'] as List?) ?? [];

    double grossTotal = 0.0;
    double orderTax = 0.0;

    // 1. Products
    for (final p in products) {
      final qty = int.tryParse(p['quantity']?.toString() ?? '1') ?? 1;
      final price = double.tryParse(p['price']?.toString() ?? '0') ?? 0.0;
      grossTotal += price * qty;

      // Build #1.0.280: If tax_rate is present on the product map (custom items), use it directly.
      final pid = int.tryParse((p['product_id'] ?? p['id']).toString()) ?? 0;

      final lineTaxStatus =
          (p['tax_status'] ?? 'taxable').toString().toLowerCase();
      final lineTaxRate =
          double.tryParse((p['tax_rate'] ?? '0').toString()) ?? 0.0;

      if (lineTaxStatus == 'taxable' && lineTaxRate > 0) {
        orderTax += roundTaxHalfUp(((price * qty) * lineTaxRate) / 100);
      } else if (pid > 0) {
        orderTax += getProductTaxFromHive(pid, price, qty);
      } else {
        final pid = int.tryParse((p['product_id'] ?? p['id']).toString()) ?? 0;
        if (pid > 0) {
          orderTax += getProductTaxFromHive(pid, price, qty);
        }
      }
    }

    // 2. Custom Items
    for (final c in customItems) {
      final qty = int.tryParse(c['quantity']?.toString() ?? '1') ?? 1;
      final price = double.tryParse(c['price']?.toString() ?? '0') ?? 0.0;
      grossTotal += price * qty;

      final taxRate = double.tryParse(c['tax_rate']?.toString() ?? '0') ?? 0.0;
      if (taxRate > 0) {
        orderTax += roundTaxHalfUp(((price * taxRate) / 100) * qty);
      }
    }

    orderTax = roundTaxHalfUp(orderTax);

    // 3. Payouts & cashbacks
    double payoutTotal = payouts.fold(0.0,
        (s, p) => s + (double.tryParse(p['amount']?.toString() ?? '0') ?? 0.0));
    double cashbackTotal = cashbacks.fold(0.0,
        (s, c) => s + (double.tryParse(c['amount']?.toString() ?? '0') ?? 0.0));
    double cbFee = (order['cashbackFee'] as num?)?.toDouble() ?? 0.0;
    if (cashbacks.isEmpty) cbFee = 0.0;

    grossTotal += payoutTotal + cashbackTotal;

    double orderDiscount = (order['orderDiscount'] as num?)?.toDouble() ?? 0.0;
    double merchantDiscount = getCurrentMerchantDiscount(order,
        grossTotal: grossTotal,
        orderDiscount: orderDiscount,
        orderTax: orderTax);
    print("🟢 merchant discount: $merchantDiscount");

    final String mdType = order['merchantDiscountType']?.toString() ?? 'fixed';
    final double mdPerc = double.tryParse(
            order['merchantDiscountPercentage']?.toString() ?? '0') ??
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

    double netTotal = grossTotal - orderDiscount - merchantDiscount;
    double netPayable = netTotal + orderTax + cbFee;

    // Update the map
    order['gross_total'] = grossTotal;
    order['orderDiscount'] = orderDiscount;
    order['merchantDiscount'] = merchantDiscount;
    order['cashbackFee'] = cbFee;
    order['order_tax'] = orderTax;
    order['net_total'] = netTotal;
    order['net_payable'] = netPayable;

    // Save to Hive and Memory
    await box.put(orderId.toString(), order);
    _upsertOfflineOrderInMemory(orderId, order);

    if (kDebugMode) {
      print(
          "💾 Saved complete order $orderId with totals (net_payable: $netPayable)");
    }
  }

  void _upsertOfflineOrderInMemory(
      int orderId, Map<String, dynamic> updatedOrder) {
    // Keep the in-memory offline snapshot in sync without re-reading the entire Hive box.
    // ⚡ Ensure orders is mutable (convert fixed-length list to growable if needed)
    if (orders is! List || orders.isEmpty) {
      orders = <Map<String, dynamic>>[];
    } else {
      // Convert to mutable list if it's read-only
      orders = List<Map<String, dynamic>>.from(orders);
    }

    final idx = orders.indexWhere((o) {
      final oid = o['order_id'] ?? o['id'];
      if (oid is int) return oid == orderId;
      return int.tryParse(oid?.toString() ?? '') == orderId;
    });

    if (idx != -1) {
      orders[idx] = updatedOrder;
    } else {
      orders.add(updatedOrder);
    }

    if (!orderIds.contains(orderId)) {
      orderIds.add(orderId);
    }

    // Maintain a sensible active order pointer.
    activeOrderId ??= orderId;
  }

  // Loads processing order data from the local database and shared preferences
  Future<void> loadProcessingData() async {
    final prefs = await SharedPreferences.getInstance();
    activeOrderId =
        prefs.getInt('activeOrderId'); // Retrieve the saved active order ID
    activeUserId = await getUserIdFromDB();
    // Debugging logs
    if (kDebugMode) {
      print(
          "#### Order Panel DB helper loadData: before activeOrderId = $activeOrderId, activeUserId= $activeUserId ");
      print("#### DEBUG orders: $orders"); // Build #1.0.189
      print("#### DEBUG orders length >>>>> : ${orders.length}");
      print("#### DEBUG orderIds >>>>> : $orderIds");
    }
    // Fetch the user's orders from the database
    final db = await DBHelper.instance.database;
    final queryResult = await db.query(
      AppDBConst.orderTable,
      where: '${AppDBConst.userId} = ? AND ${AppDBConst.orderStatus} = ?',
      whereArgs: [activeUserId ?? 0, 'processing'],

      /// Build #1.0.161
      /// If required "asc" orders list, un-comment this line (order id's order low to high)
      /// Build #1.0.251 : FIXED - We have to use orderServerId rather than orderDate, it is already latest based on backend
      orderBy:
          '${AppDBConst.orderServerId} ASC', // Ensure orders are sorted by creation date
    );
    // ⚡ Ensure mutable list (db.query returns fixed-length list)
    orders = List<Map<String, dynamic>>.from(queryResult);

    if (orders.isNotEmpty) {
      // Convert order list from DB into a list of order IDs
      orderIds = orders
          .map((order) => order[AppDBConst.orderServerId] as int)
          .toList();
      // If activeOrderId is null or invalid, set it to the last available order ID
      if (activeOrderId == null || !orderIds.contains(activeOrderId)) {
        activeOrderId = orders.last[AppDBConst.orderServerId];

        ///changed to order server id
        await prefs.setInt('activeOrderId', activeOrderId!);
      }
    } else {
      // No orders found, reset values
      activeOrderId = null;
      orderIds = [];
      orders = [];
    }

    // Debugging logs
    if (kDebugMode) {
      print(
          "#### Order Panel DB helper loadData: activeOrderId = $activeOrderId");
      print(
          "#### Order Panel DB helper loadData: orderIds = $orderIds, activeUserId: $activeUserId");
    }
  }

  Future<void> loadData() async {
    final prefs = await SharedPreferences.getInstance();
    // Use local variables to avoid race conditions with other async tasks
    int? currentActiveOrderId = prefs.getInt('activeOrderId');

    // Build #1.0.287: Try to recover from lastActiveOrderId if activeOrderId is missing (fixes navigation focus jump)
    if (currentActiveOrderId == null ||
        currentActiveOrderId == 0 ||
        currentActiveOrderId == -1) {
      currentActiveOrderId = prefs.getInt('lastActiveOrderId');
    }

    activeUserId = await getUserIdFromDB();

    // Build #1.0.312: Defensive check for user ID during transitions
    if (activeUserId == 0) {
      if (kDebugMode)
        print("⚠ activeUserId is 0 in loadData, attempting one retry...");
      // Small pause and retry once
      await Future.delayed(const Duration(milliseconds: 100));
      activeUserId = await getUserIdFromDB();
      if (activeUserId == 0 && kDebugMode)
        print("⚠ activeUserId still 0 after retry");
    }

    List<int> localOrderIds = [];
    List<Map<String, dynamic>> localOrders = [];

    // Always offline
    if (kDebugMode) print("📴 Loading offline orders");

    final box = StorageProvider.offlineOrders;
    final allOfflineOrders = await box.toMap();

    // Build #1.0.285: Strict user isolation & session safety
    if (activeUserId == null || activeUserId == 0) {
      if (kDebugMode) {
        print(
            "#### loadData: No active user ID found ($activeUserId). Clearing orders for safety.");
      }
      orderIds = [];
      orders = [];
      activeOrderId =
          null; // ✅ Reset activeOrderId to avoid pointing to stale order
      return;
    }

    final validEntries = allOfflineOrders.entries.where((entry) {
      if (entry.value is! Map) return false;
      final order = entry.value as Map;
      if (order.containsKey('map_to_local')) return false;

      // Extract user ID from order (handles multiple possible keys)
      final dynamic rawOrderUserId =
          order['user_id'] ?? order[AppDBConst.userId];

      // Strict comparison using toString() to guard against int/string mismatch in Hive
      if (rawOrderUserId?.toString() != activeUserId.toString()) {
        if (kDebugMode) {
          print(
              "#### loadData: Filtered out order for another user. Current: $activeUserId, Order: $rawOrderUserId");
        }
        return false;
      }
      return true;
    }).map((entry) {
      // ✅ Normalize the root map
      final normalized = Map<String, dynamic>.from(entry.value as Map);

      // Build #1.0.287: Ensure order_id is present in the map content (fallback to Hive Key)
      // This prevents focus jumps if some code saved the order map without an internal ID.
      if (!normalized.containsKey('order_id') &&
          !normalized.containsKey('id') &&
          !normalized.containsKey(AppDBConst.orderServerId)) {
        final keyId = int.tryParse(entry.key.toString());
        if (keyId != null) {
          normalized['order_id'] = keyId;
        }
      }

      // ✅ Normalize nested 'products' list if present
      if (normalized['products'] is List) {
        final rawProducts = normalized['products'] as List;
        normalized['products'] = rawProducts
            .whereType<Map>()
            .map((p) => Map<String, dynamic>.from(p))
            .toList();
      } else {
        normalized['products'] = <Map<String, dynamic>>[];
      }

      // ✅ Normalize nested 'request' if present
      if (normalized['request'] is Map) {
        normalized['request'] =
            Map<String, dynamic>.from(normalized['request'] as Map);
      }

      // ✅ Normalize nested 'customer' if present
      if (normalized['customer'] is Map) {
        normalized['customer'] =
            Map<String, dynamic>.from(normalized['customer'] as Map);
      }

      // ✅ Normalize 'totals' or other nested objects if exist
      if (normalized['totals'] is Map) {
        normalized['totals'] =
            Map<String, dynamic>.from(normalized['totals'] as Map);
      }

      return MapEntry(entry.key, normalized);
    }).toList();

    if (validEntries.isNotEmpty) {
      // ⚡ Ensure mutable list (not fixed-length)
      localOrders =
          List<Map<String, dynamic>>.from(validEntries.map((e) => e.value));

      // ✅ Sort by created_at ascending (oldest first) so that new orders stay on the right
      localOrders.sort((a, b) {
        final aTime = a['created_at']?.toString() ?? '';
        final bTime = b['created_at']?.toString() ?? '';
        final cmp = aTime.compareTo(bTime);
        if (cmp != 0) return cmp;
        final aId = a['order_id'] ?? a['id'] ?? 0;
        final bId = b['order_id'] ?? b['id'] ?? 0;
        return ((aId as num).toDouble()).compareTo((bId as num).toDouble());
      });

      // ✅ Extract order IDs from sorted orders (keeps orderIds in sync)
      localOrderIds = localOrders
          .map((map) {
            if (map.containsKey('order_id')) return map['order_id'] as int?;
            if (map.containsKey('id')) return map['id'] as int?;
            return int.tryParse(
                map['order_id']?.toString() ?? map['id']?.toString() ?? '');
          })
          .whereType<int>()
          .toList();

      // Build #1.0.285: Validate if restored activeOrderId belongs to current user
      if (currentActiveOrderId != null) {
        final box = StorageProvider.offlineOrders;
        final raw = await box.get(currentActiveOrderId.toString());
        if (raw != null && raw is Map) {
          final dynamic orderUserId = raw['user_id'] ?? raw[AppDBConst.userId];
          if (orderUserId?.toString() != activeUserId.toString() &&
              activeUserId != 0) {
            if (kDebugMode)
              print(
                  "🚫 Restored Order $currentActiveOrderId filtered: Wrong User $orderUserId (activeUser: $activeUserId)");
            currentActiveOrderId = null;
          }
        } else {
          // check DB if not in hive
          final dbOrders = await getOrderById(currentActiveOrderId);
          if (dbOrders.isEmpty) {
            currentActiveOrderId = null;
          }
        }
      }

      // ✅ Set active order ID if not found or invalid
      if (currentActiveOrderId == null ||
          currentActiveOrderId <= 0 ||
          !localOrderIds.contains(currentActiveOrderId)) {
        // Build #1.0.316: Prioritize lastActiveOrderId for focus persistence across screens
        final checkpointId = prefs.getInt('lastActiveOrderId');
        if (checkpointId != null &&
            checkpointId > 0 &&
            localOrderIds.contains(checkpointId)) {
          if (kDebugMode)
            print(
                "🔄 loadData: Restoring focus from lastActiveOrderId: $checkpointId");
          currentActiveOrderId = checkpointId;
        } else if (localOrderIds.isNotEmpty) {
          // Final fallback to newest order ONLY if no valid checkpoint exists
          currentActiveOrderId = localOrderIds.last;
          if (kDebugMode)
            print(
                "🔄 loadData: Fallback to newest order: $currentActiveOrderId");
        }

        if (currentActiveOrderId != null) {
          await prefs.setInt('activeOrderId', currentActiveOrderId);
        }
      }
    } else {
      if (kDebugMode) print("⚠ No valid offline order maps found in Hive");
      currentActiveOrderId = null;
      localOrderIds = [];
      localOrders = [];
    }

    // Final assignment to class properties
    orderIds = localOrderIds;
    orders = localOrders;
    activeOrderId = currentActiveOrderId;

    if (kDebugMode) {
      print("#### Offline Orders Loaded ####");
      print("Active Order ID: $activeOrderId");
      print("Order IDs: $orderIds");
      print("Total Orders Loaded: ${orders.length}");
    }
  }

  /// Same id resolution as order panel tabs (`widget_order_panel` _getOrderTabs).
  int? _normalizeOrderIdForShiftCheck(Map<String, dynamic> order) {
    final dynamic raw =
        order[AppDBConst.orderServerId] ?? order['order_id'] ?? order['id'];
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString());
  }

  bool _hasShiftBlockingItems(Map<String, dynamic> order) {
    final List products = order['products'] as List? ?? [];
    final List customItems = order['custom_items'] as List? ?? [];
    final List payouts = order['payouts'] as List? ?? [];
    final List cashbacks = order['cashbacks'] as List? ?? [];

    if ([products, customItems, payouts, cashbacks].any((l) => l.isNotEmpty)) {
      return true;
    }

    final request = order['request'];
    if (request is Map) {
      final lineItems = request['line_items'];
      if (lineItems is List && lineItems.isNotEmpty) return true;
    }
    return false;
  }

  // Build #1.0.281: Check if there are any active orders that should block closing shift
  Future<bool> hasActiveOrders() async {
    await loadData(); // Load offline orders

    if (orders.isEmpty) {
      if (kDebugMode) print("#### No orders found for user $activeUserId");
      return false;
    }

    // If a draft active order session exists (current activeOrderId) with no cart items,
    // block close shift so user can explicitly clear/close that cart first.
    if (activeOrderId != null && activeOrderId! > 0) {
      Map<String, dynamic>? activeOrder;
      for (final o in orders) {
        final id = _normalizeOrderIdForShiftCheck(o);
        if (id == activeOrderId) {
          activeOrder = o;
          break;
        }
      }
      if (activeOrder != null && !_hasShiftBlockingItems(activeOrder)) {
        if (kDebugMode) {
          print(
            "#### BLOCKED - Active order $activeOrderId exists with empty cart; close shift not allowed",
          );
        }
        return true;
      }
    }

    // Build #1.0.286: Block shift while any order would still appear on the order panel.
    // Tabs hide only after LocalPaymentDB has at least one payment for that order id.
    for (final order in orders) {
      final int? panelOrderId = _normalizeOrderIdForShiftCheck(order);
      if (panelOrderId == null || panelOrderId == 0) continue;
      if (!_hasShiftBlockingItems(order)) {
        if (kDebugMode) {
          print(
            "#### SKIP - Order $panelOrderId has no cart items, ignoring for shift close",
          );
        }
        continue;
      }
      final panelPayments = await LocalPaymentDBHelper.instance
          .getPaymentsByOrderId(panelOrderId, userId: activeUserId);
      if (panelPayments.isEmpty) {
        if (kDebugMode) {
          print(
            "#### BLOCKED - Order $panelOrderId still on order panel (no payments); shift close not allowed",
          );
        }
        return true;
      }
    }

    for (var order in orders) {
      // Determine order ID
      final int? orderId = order[AppDBConst.orderServerId] as int? ??
          order['order_id'] as int? ??
          order[AppDBConst.orderId] as int? ??
          order['id'] as int?;

      // Get all order items
      final List products = order['products'] as List? ?? [];
      final List customItems = order['custom_items'] as List? ?? [];
      final List payouts = order['payouts'] as List? ?? [];
      final List cashbacks = order['cashbacks'] as List? ?? [];

      final bool hasItems = [products, customItems, payouts, cashbacks]
          .any((list) => list.isNotEmpty);

      if (!hasItems) {
        if (kDebugMode)
          print("#### Order skipped — no items (orderId=$orderId)");
        continue; // skip empty orders
      }

      // Invalid order ID with items → block immediately
      if (orderId == null || orderId == 0) {
        print("#### BLOCKED - Order has invalid ID but contains items");
        return true;
      }

      // ✅ Get payment summary for the order
      final summary = await LocalPaymentDBHelper.instance
          .getPaymentStatusSummary(orderId, userId: activeUserId);

      final bool fullyPaid = summary['fullyPaid'] as bool? ?? false;
      final bool hasPayments = (summary['hasPayments'] as bool? ?? false) ||
          ((summary['paymentCount'] as num?)?.toInt() ?? 0) > 0;
      final double remaining = (summary['remainingBalance'] ?? 0).toDouble();
      final double total = (summary['orderTotal'] ?? 0).toDouble();

      if (kDebugMode) {
        print(
            "#### Order $orderId → fullyPaid: $fullyPaid, remaining: $remaining, total: $total");
      }

      // If any payment exists and no remaining balance, allow close shift.
      // Some rows can carry total=0 while still having completed payments.
      if (hasPayments && remaining <= 0) {
        print(
            "#### Order $orderId has payments and zero balance → allowed to close shift");
        continue;
      }

      // Block only when genuinely unpaid (no payments recorded).
      if (!hasPayments && !fullyPaid && remaining == total) {
        print("#### BLOCKED - Order $orderId has items but no payment at all");
        return true;
      }

      // Partially paid → allow
      if (!fullyPaid && remaining < total) {
        print("#### Order $orderId partially paid → allowed to close shift");
        continue;
      }

      // Fully paid → allow
      print("#### Order $orderId fully paid → allowed to close shift");
    }

    print("#### SUCCESS - All orders settled/partially paid. Shift can close.");
    return false;
  }

  Future<int> getUserIdFromDB() async {
    var userId = 0;
    try {
      final userData = await UserDbHelper().getUserData();

      if (userData != null && userData[AppDBConst.userId] != null) {
        userId = userData[AppDBConst.userId] as int;
      }
    } catch (e) {
      if (kDebugMode) {
        print("OrderPanelDBHelper: Exception in getUserFromDB: $e");
      }
    }
    return userId;
  }

  // Update an orderID from API
  Future<void> updateServerOrderIDInDB(int orderServerId) async {
    ///Call to Create order REST API here, it should be done on add order at UI
    // OrderBloc orderBloc = OrderBloc(OrderRepository());
    // ///Create metadata for the order
    // OrderMetaData device = OrderMetaData(key: OrderMetaData.posDeviceId, value: "b31b723b92047f4b"); /// need to add code for device id later
    // OrderMetaData placedBy = OrderMetaData(key: OrderMetaData.posPlacedBy, value: '$activeUserId');
    // List<OrderMetaData> metaData = [device,placedBy];
    // ///call create order API
    // await orderBloc.createOrder(metaData).whenComplete(() async {
    //   if (kDebugMode) {
    //     print('createOrderStream completed');
    //   }
    // });

    // await orderBloc.createOrderStream.listen((event) async {
    //   if (kDebugMode) {
    //     print('createOrderStream status: ${event.status}');
    //   }
    //   if (event.status == Status.ERROR) {
    //     if (kDebugMode) {
    //       print(
    //           'OrderPanelDBHelper createOrder: completed with ERROR');
    //     }
    //     orderBloc.createOrderSink.add(APIResponse.error(TextConstants.retryText));
    //     orderBloc.dispose();
    //   } else if (event.status == Status.COMPLETED) {
    //     final order = event.data!;
    //     orderServerId = order.id;
    //     orderStatus = order.status;
    //     if (kDebugMode) {
    //       print('>>>>>>>>>>> OrderPanelDBHelper Order created with id: $orderServerId');
    //     }
    //   }
    // });

    ///check if 'orderServerId' is 0 or not, if yes show alert
    final db = await DBHelper.instance.database;
    await db.update(
      AppDBConst.orderTable,
      {
        AppDBConst.orderId: orderServerId, // Update order_id to API id
        AppDBConst.orderServerId: orderServerId,
        AppDBConst.orderDate: DateTime.now().toString(),
        AppDBConst.orderTime: DateTime.now().toString(),
      },
      where: '${AppDBConst.orderId} = ?',
      whereArgs: [activeOrderId],
    );

    // Update activeOrderId to the new server ID
    activeOrderId = orderServerId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('activeOrderId', activeOrderId!);

    if (kDebugMode) {
      print(
          "#### Order updated with ID: Active DBOrder ID $activeOrderId, serverOrderID $orderServerId, orderDate: ${DateTime.now().toString()}");
    }
  }

  //Build #1.0.40: syncOrdersFromApi
  Future<void> syncOrdersFromApi(List<model.OrderModel> apiOrders) async {
    // Build 1.0.171: Check if a sync operation is already in progress
    if (_syncFuture != null) {
      if (kDebugMode) {
        print(
            "#### DEBUG: syncOrdersFromApi - Sync already in progress, waiting for completion");
      }
      await _syncFuture; // Wait for the existing sync to complete
      return;
    }

    // Create a Completer to manage the sync operation's future
    final completer = Completer<void>();
    _syncFuture = completer.future;
    if (kDebugMode) {
      print("#### DEBUG: syncOrdersFromApi - Starting new sync operation");
    }

    try {
      final db = await DBHelper.instance.database;
      activeUserId =
          await getUserIdFromDB(); // Build #1.0.165: to load user before update order table, to filter user based processing order only
      // Build #1.0.80: Count orders in the database
      final dbOrdersCount = await db.query(AppDBConst.orderTable);
      final apiOrdersCount = apiOrders.length;

      if (kDebugMode) {
        print(
            "#### DEBUG: syncOrdersFromApi - API orders count: $apiOrdersCount, DB orders count: ${dbOrdersCount.length}, activeUserId :${activeUserId ?? 0}");
      }

      // Check if counts match
      //Build #1.0.165: delete db every time because of user filter logic applied for order table
      // if (dbOrdersCount.length != apiOrdersCount) {
      if (kDebugMode) {
        print(
            "#### DEBUG: syncOrdersFromApi - Counts do not match, deleting DB orders");
      }
      // Build #1.0.80: Delete all orders in the database
      // await db.delete(AppDBConst.orderTable);
      /// Build #1.0.207: Fixed -> No popup warning for open orders when closing shift via Vendor Payouts [SCRUM- 360]
      /// When ever navigating to orderPanel to orderScreenPanel related screen's, deleting all orders
      /// If we go to order screen - prev all processing orders will remove that the cause of checking processing orders while closing shift
      if (apiOrders.isNotEmpty) {
        // Check if we're syncing processing orders
        final isSyncingProcessingOrders =
            apiOrders.any((order) => order.status == 'processing');
        if (kDebugMode) {
          print(
              "#### DEBUG: isSyncingProcessingOrders $isSyncingProcessingOrders");
        }
        if (isSyncingProcessingOrders) {
          // If syncing processing orders, only delete processing orders
          // when ever orderPanel calls like - fastKey/categories/add screens prev processing orders will remove and re-adding below
          await db.delete(
            AppDBConst.orderTable,
            where: '${AppDBConst.userId} = ? AND ${AppDBConst.orderStatus} = ?',
            whereArgs: [activeUserId ?? 0, 'processing'],
          );
        } else {
          // If syncing non-processing orders, only delete non-processing orders
          // when ever orderScreenPanel calls like - order screen prev non-processing orders will remove and re-adding below
          await db.delete(
            AppDBConst.orderTable,
            where:
                '${AppDBConst.userId} = ? AND ${AppDBConst.orderStatus} != ?',
            whereArgs: [activeUserId ?? 0, 'processing'],
          );
        }
      } else {
        ///  BUILD 1.0.213: FIXED RE-OPENED ISSUE [SCRUM-360]: No popup warning for open orders when closing shift via Vendor Payouts
        // DON'T delete all orders when apiOrders is empty
        // Just skip the deletion and proceed with sync (which will do nothing)
        if (kDebugMode) {
          print(
              "#### DEBUG: syncOrdersFromApi - No orders to sync, skipping deletion");
        }
        // await db.delete(AppDBConst.orderTable); // NO NEED TO DELETE COMPLETE ORDER TABLE
      }
      //  delete purchasedItemsTable related data
      /// Build #1.0.226: purchasedItemsTable foreign key has ON DELETE CASCADE which means when a parent order is deleted, all child purchased items are automatically deleted
      // await db.delete(AppDBConst.purchasedItemsTable); // NO NEED HERE
      OrderHelper.isOrderPanelLoaded = false;

      /// set 'false' to load 'processing' orders in order panel again, if db is empty by orders screen loading.
      // }
      // if(!isProcessing) {
      //   if (kDebugMode) {
      //     print("#### DEBUG: syncOrdersFromApi - Counts do not match, deleting DB orders");
      //   }
      //   // Build #1.0.80: Delete all orders in the database
      //   await db.delete(AppDBConst.orderTable, where: '${AppDBConst.orderStatus} != ?', whereArgs: ['processing']);
      //   //  delete purchasedItemsTable related data
      //   await db.delete(AppDBConst.purchasedItemsTable, where: '${AppDBConst.orderStatus} != ?', whereArgs: ['processing']);
      // }
      // Proceed with syncing only if counts match or after clearing DB
      if (kDebugMode) {
        print(
            "#### DEBUG: syncOrdersFromApi - Processing ${apiOrders.length} orders");
      }

      for (var apiOrder in apiOrders) {
        if (kDebugMode) {
          print(
              "#### DEBUG: syncOrdersFromApi - Processing order serverId: ${apiOrder.id}");
        }
        // Check if order exists in DB by API id
        final existingOrders = await db.query(
          AppDBConst.orderTable,
          where: '${AppDBConst.orderServerId} = ?', //Build #1.0.78
          whereArgs: [apiOrder.id],
        );

        if (kDebugMode) {
          print(
              "#### DEBUG: syncOrdersFromApi - existingOrders: ${existingOrders.length}");
        }

        if (existingOrders.isNotEmpty) {
          await db.update(
            AppDBConst.orderTable,
            {
              AppDBConst.orderServerId: apiOrder.id,
              AppDBConst.orderTotal: double.tryParse(apiOrder.total) ?? 0.0,
              AppDBConst.orderStatus: apiOrder.status,
              AppDBConst.orderDate: apiOrder.dateCreated,
              AppDBConst.orderTime: apiOrder.dateCreated,
              AppDBConst.orderPaymentMethod: apiOrder.paymentMethod,
              AppDBConst.orderDiscount:
                  double.tryParse(apiOrder.discountTotal) ??
                      0.0, // Store discount
              AppDBConst.orderTax:
                  double.tryParse(apiOrder.totalTax) ?? 0.0, // Store tax
              AppDBConst.orderAgeRestricted: apiOrder.metaData
                  .firstWhere(
                    //Build #1.0.234: Saving Age Restricted value in order table
                    (meta) => meta.key == TextConstants.ageRestrictedKey,
                    orElse: () =>
                        model.MetaData(id: 0, key: '', value: 'false'),
                  )
                  .value
                  .toString(),
            },
            where: '${AppDBConst.orderServerId} = ?',
            whereArgs: [apiOrder.id],
          );
          if (kDebugMode) {
            print(
                "#### DEBUG: syncOrdersFromApi Updated order with serverId: ${apiOrder.id}, orderTotal: ${apiOrder.total}");
          }
        } else {
          await db.insert(AppDBConst.orderTable, {
            // AppDBConst.orderId: apiOrder.id,
            AppDBConst.userId: activeUserId ?? 0,
            AppDBConst.orderServerId: apiOrder.id,
            AppDBConst.orderTotal: double.tryParse(apiOrder.total) ?? 0.0,
            AppDBConst.orderStatus: apiOrder.status,
            AppDBConst.orderType: apiOrder.createdVia ?? 'in-store',
            AppDBConst.orderDate: apiOrder.dateCreated,
            AppDBConst.orderTime: apiOrder.dateCreated,
            AppDBConst.orderPaymentMethod: apiOrder.paymentMethod,
            AppDBConst.orderDiscount: double.tryParse(apiOrder.discountTotal) ??
                0.0, // Store discount
            AppDBConst.orderTax:
                double.tryParse(apiOrder.totalTax) ?? 0.0, // Store tax
            AppDBConst.orderShipping: double.tryParse(apiOrder.shippingTotal) ??
                0.0, // Store shipping
            AppDBConst.orderAgeRestricted: apiOrder
                .metaData //Build #1.0.234: Saving Age Restricted value in order table
                .firstWhere(
                  (meta) => meta.key == TextConstants.ageRestrictedKey,
                  orElse: () => model.MetaData(id: 0, key: '', value: 'false'),
                )
                .value
                .toString(),
          });
          if (kDebugMode) {
            print(
                "#### DEBUG: syncOrdersFromApi Inserted new order with serverId: ${apiOrder.id}, orderTotal: ${apiOrder.total}");
          }
        }

        // Sync line items using API order id
        // await updateOrderItems(apiOrder.id, apiOrder.lineItems);
        await updateOrderItems(apiOrder.id, apiOrder.lineItems,
            apiOrder); // ✅ Pass the entire apiOrder

        // await updateOrderPayoutItems(apiOrder.id, apiOrder.feeLines ?? []); // Build #1.0.64
        await updateOrderPayoutItem(
            apiOrder.id, apiOrder.lineItems); // Build #1.0.198
        // Build #1.0.207: Fixed Issue - Always Merchant discount showing "0"
        // Ex: updateOrderPayoutItem modified to lineItems but discount we are getting in fee lines only , we are not using this, that's why merchant discount calculation is 0.
        await updateOrderMerchantDiscount(
            apiOrder.id,
            apiOrder.lineItems ??
                []); // Build #1.0.274 : updated fee lines to line items change
        await updateOrderCouponItems(apiOrder.id, apiOrder.couponLines ?? []);
      }

      if (kDebugMode) {
        // Calculate order total from items
        for (var order in apiOrders) {
          final items = await getOrderItems(order.id);
          for (var item in items) {
            print(
                "#### DEBUG: Check after insert if Order items ID: ${item[AppDBConst.itemId]},  ${item[AppDBConst.itemServerId]} for order ${order.id} is correct?, loadOrderItems 3");
          }
        }
        print("#### DEBUG: syncOrdersFromApi - Refreshing local data");
      }
      await loadData();
      // Complete the sync operation
      if (kDebugMode) {
        print("#### DEBUG: syncOrdersFromApi - Sync completed successfully");
      }
      completer.complete();
    } catch (e) {
      // Build 1.0.171
      // Handle errors and propagate them
      if (kDebugMode) {
        print("#### DEBUG: syncOrdersFromApi - Error occurred: $e");
      }
      completer.completeError(e);
      rethrow;
    } finally {
      // Build 1.0.171
      // Reset _syncFuture to allow new sync operations
      _syncFuture = null;
      if (kDebugMode) {
        print(
            "#### DEBUG: syncOrdersFromApi - Sync future reset, ready for new sync");
      }
    }
  }

  //Build #1.0.40: update order items using item id

  Future<void> updateOrderItems(int orderId, List<model.LineItem> apiItems,
      model.OrderModel orderModel) async {
    if (kDebugMode) {
      print("#### DEBUG: updateOrderItems orderId: $orderId");
      print(
          "#### DEBUG: Order-level auto discount: ${orderModel.orderLevelAutoDiscountAmount}"); // ✅ Log the discount
      // NEW: Log combo and display auto discounts
      print(
          "#### DEBUG: Total combo discount: ${orderModel.totalComboDiscount}");
      print(
          "#### DEBUG: Total display auto discount: ${orderModel.totalDisplayAutoDiscount}");
    }
    final db = await DBHelper.instance.database;
    final existingItems = await db.query(
      AppDBConst.purchasedItemsTable,
      where: '${AppDBConst.orderIdForeignKey} = ?',
      whereArgs: [orderId],
    );

    final existingItemsMap = {
      for (var item in existingItems)
        item[AppDBConst.itemServerId].toString(): item,
    };

    if (kDebugMode) {
      print(
          "#### DEBUG: updateOrderItems - Processing ${apiItems.length} items for order $orderId, existing items: ${existingItemsMap.length}");
    }
    // final bool isRefunded = apiItem.isRefundItem == true;

    for (var apiItem in apiItems) {
      if (apiItem.name.contains('Payout') ||
          apiItem.name == TextConstants.discountText) {
        continue;
      }
      final bool isRefunded = apiItem.isRefundItem == true;
      final itemId = apiItem.id.toString();
      final double itemPrice = apiItem.productData.price == ''
          ? double.parse(apiItem.productData.price ?? '0.0')
          : double.parse(apiItem.productData.price ?? '0.0');
      final int itemQuantity = apiItem.quantity ?? 0;
      final double itemSumPrice = double.parse(apiItem.subtotal);

      if (kDebugMode) {
        print("salesPrice: ${apiItem.productData.salePrice ?? "0.0"}, "
            "regularPrice:${apiItem.productData.regularPrice ?? "0.0"},"
            " unitPrice: ${apiItem.productData.price ?? "0.0"}");
      }

      String variationName = apiItem.productVariationData?.metaData
              ?.firstWhere(
                (e) => e.key == "custom_name",
                orElse: () => model.MetaData(id: 0, key: "", value: ""),
              )
              .value ??
          "";

// 🔹 Fallback → check attribute metadata (pa_*)
      if (variationName.isEmpty) {
        for (var meta in apiItem.metaData) {
          final key = meta.key?.toLowerCase() ?? "";
          if (key.startsWith("pa_")) {
            variationName = meta.value?.toString() ?? "";
            break;
          }
        }
      }

// 🔹 Fallback → use item name
      if (variationName.isEmpty) {
        variationName = apiItem.name ?? "";
      }

      print("🟣 VARIANT NAME -> $variationName");
      final int variationCount = apiItem.productData.variations?.length ?? 0;
      final String combo = apiItem.metaData
              .firstWhere((e) => e.value.contains('Combo'),
                  orElse: () => model.MetaData(id: 0, key: "", value: ""))
              .value
              .split(' ')
              .first ??
          "";
      bool isEbtEligible = false;

// 🔍 Print all meta keys for debugging
      for (var meta in apiItem.metaData) {
        print("META KEY -> ${meta.key} | VALUE -> ${meta.value}");
      }

// ✅ Detect EBT eligibility
      isEbtEligible = apiItem.metaData.any((meta) {
        final key = meta.key?.toString().toLowerCase() ?? "";
        final value = meta.value?.toString().toLowerCase() ?? "";

        return (key == "is_ebt_eligible" || key == "_is_ebt_eligible") &&
            (value == "1" || value == "true" || value == "yes");
      });

      print("EBT RESULT -> $isEbtEligible");
      final bool hasVariations = apiItem.productData.variations != null &&
          apiItem.productData.variations!.isNotEmpty;
      final double salesPrice = hasVariations
          ? double.tryParse(
                  apiItem.productVariationData?.salePrice?.isNotEmpty == true
                      ? apiItem.productVariationData!.salePrice!
                      : "0.0") ??
              0.0
          : double.tryParse(apiItem.productData.salePrice?.isNotEmpty == true
                  ? apiItem.productData.salePrice!
                  : "0.0") ??
              0.0;
      final double regularPrice = hasVariations
          ? double.tryParse(
                  apiItem.productVariationData?.regularPrice?.isNotEmpty == true
                      ? apiItem.productVariationData!.regularPrice!
                      : "0.0") ??
              0.0
          : double.tryParse(apiItem.productData.regularPrice?.isNotEmpty == true
                  ? apiItem.productData.regularPrice!
                  : "0.0") ??
              0.0;
      final double unitPrice = hasVariations
          ? double.tryParse(
                  apiItem.productVariationData?.price?.isNotEmpty == true
                      ? apiItem.productVariationData!.price!
                      : "0.0") ??
              0.0
          : double.tryParse(apiItem.productData.price?.isNotEmpty == true
                  ? apiItem.productData.price!
                  : "0.0") ??
              0.0;

      if (kDebugMode) {
        print(
            "#### DEBUG: updateOrderItems - Processing API item ID: $itemId, name: ${apiItem.name}, price: $itemPrice, quantity: $itemQuantity, sumPrice: $itemSumPrice");
        print(
            "variationName $variationName, variationCount:$variationCount, combo:$combo, salesPrice: $salesPrice, regularPrice: $regularPrice, unitPrice: $unitPrice");
        // NEW: Log item-level discounts
        print(
            "Item discounts - Multipack: ${apiItem.multipackDiscountAmount}, Auto: ${apiItem.autoDiscountAmount}, Combo: ${apiItem.comboDiscountAmount}, Display Auto: ${apiItem.displayAutoDiscountAmount}");
      }

      if (existingItemsMap.containsKey(itemId)) {
        final existingItem = existingItemsMap[itemId]!;
        await db.update(
          AppDBConst.purchasedItemsTable,
          {
            AppDBConst.itemName: apiItem.name ?? 'Unknown Item',
            AppDBConst.itemPrice: itemPrice,
            AppDBConst.itemCount: itemQuantity,
            AppDBConst.itemSumPrice: itemSumPrice,
            AppDBConst.itemImage: apiItem.image.src ?? '',
            AppDBConst.itemSKU: apiItem.sku ?? '',
            AppDBConst.itemSalesPrice: salesPrice,
            AppDBConst.itemRegularPrice: regularPrice,
            AppDBConst.itemUnitPrice: unitPrice,
            AppDBConst.itemProductId: apiItem.productId,
            AppDBConst.itemVariationId: apiItem.variationId,
            AppDBConst.multipackDiscount: apiItem.multipackDiscountAmount,
            AppDBConst.autoDiscountTotal: apiItem.autoDiscountAmount,
            // NEW: Add combo discount and display auto discount
            AppDBConst.comboDiscountTotal: apiItem.comboDiscountAmount,
            AppDBConst.displayAutoDiscount: apiItem.displayAutoDiscountAmount,
            AppDBConst.isRefundItem: isRefunded ? 1 : 0,
            AppDBConst.isEbtEligible: isEbtEligible ? 1 : 0,
          },
          where: '${AppDBConst.itemServerId} = ?',
          whereArgs: [existingItem[AppDBConst.itemServerId]],
        );
        if (kDebugMode) {
          print("#### DEBUG: Updated item ID: $itemId for order $orderId");
        }
        existingItemsMap.remove(itemId);
      } else {
        bool isCustomItem = false;
        if (apiItem.productData != null &&
            apiItem.productData.tags != null &&
            apiItem.productData.tags.isNotEmpty) {
          isCustomItem = apiItem.productData.tags
              .any((tag) => tag.name == TextConstants.customItem);
        }
        await db.insert(AppDBConst.purchasedItemsTable, {
          AppDBConst.itemServerId: apiItem.id,
          AppDBConst.itemName: apiItem.name ?? 'Unknown Item',
          AppDBConst.itemSKU: apiItem.sku ?? '',
          AppDBConst.itemPrice: itemPrice,
          AppDBConst.itemImage: apiItem.image.src ?? '',
          AppDBConst.itemCount: itemQuantity,
          AppDBConst.itemSumPrice: itemSumPrice,
          AppDBConst.orderIdForeignKey: orderId,
          AppDBConst.itemType: isCustomItem
              ? ItemType.customProduct.value
              : ItemType.product.value,
          AppDBConst.itemVariationCustomName: variationName,
          AppDBConst.itemVariationCount: variationCount,
          AppDBConst.itemCombo: combo,
          AppDBConst.itemSalesPrice: salesPrice,
          AppDBConst.itemRegularPrice: regularPrice,
          AppDBConst.itemUnitPrice: unitPrice,
          AppDBConst.itemProductId: apiItem.productId,
          AppDBConst.itemVariationId: apiItem.variationId,
          AppDBConst.multipackDiscount: apiItem.multipackDiscountAmount,
          AppDBConst.autoDiscountTotal: apiItem.autoDiscountAmount,
          // NEW: Add combo discount and display auto discount
          AppDBConst.comboDiscountTotal: apiItem.comboDiscountAmount,
          AppDBConst.displayAutoDiscount: apiItem.displayAutoDiscountAmount,
          AppDBConst.isEbtEligible: isEbtEligible ? 1 : 0,

          AppDBConst.isRefundItem: isRefunded ? 1 : 0,
        });
        if (kDebugMode) {
          print("#### DEBUG: Inserted new item ID: $itemId for order $orderId");
          print(
            "DB SAVE -> ${apiItem.name} "
            "AUTO:${apiItem.autoDiscountAmount} "
            "DISPLAY:${apiItem.displayAutoDiscountAmount} "
            "COMBO:${apiItem.comboDiscountAmount} "
            "MULTIPACK:${apiItem.multipackDiscountAmount}",
          );
        }
      }
    }

    for (var item in existingItemsMap.values) {
      await db.delete(
        AppDBConst.purchasedItemsTable,
        where: '${AppDBConst.itemServerId} = ?',
        whereArgs: [item[AppDBConst.itemServerId]],
      );
      if (kDebugMode) {
        print(
            "#### DEBUG: Deleted obsolete item ID: ${item[AppDBConst.itemServerId]} for order $orderId");
      }
    }

    // 3️⃣ ADD ORDER-LEVEL AUTO DISCOUNT UPDATE HERE
    // Update the order table with order-level auto discount and other discounts
    await db.update(
      AppDBConst.orderTable,
      {
        AppDBConst.autoDiscountTotal: orderModel
            .orderLevelAutoDiscountAmount, // ✅ CORRECT: Use instance property
        // NEW: Update order-level combo and display auto discounts
        AppDBConst.comboDiscountTotal: orderModel.totalComboDiscount,
        AppDBConst.displayAutoDiscount: orderModel.totalDisplayAutoDiscount,
        // NEW: Also update multipack discount from order model
        AppDBConst.multipack_discount_total: orderModel.totalMultipackDiscount,
      },
      where: '${AppDBConst.orderServerId} = ?',
      whereArgs: [orderId],
    );

    if (kDebugMode) {
      print("#### DEBUG: Updated order $orderId with order-level discounts:");
      print("  - Auto discount: ${orderModel.orderLevelAutoDiscountAmount}");
      print("  - Combo discount: ${orderModel.totalComboDiscount}");
      print(
          "  - Display auto discount: ${orderModel.totalDisplayAutoDiscount}");
      print("  - Multipack discount: ${orderModel.totalMultipackDiscount}");
    }

    final items = await getOrderItems(orderId);
    for (var item in items) {
      if (kDebugMode) {
        print(
            "#### DEBUG: Check after insert if Order items ID: ${item[AppDBConst.itemId]},  ${item[AppDBConst.itemServerId]} for order $orderId is correct?, loadOrderItems 2");
        // NEW: Check if discounts are saved correctly
        print(
            "Item discounts saved - Multipack: ${item[AppDBConst.multipack_discount_total]}, Auto: ${item[AppDBConst.autoDiscountTotal]}, Combo: ${item[AppDBConst.comboDiscountTotal]}, Display Auto: ${item[AppDBConst.displayAutoDiscount]}");
      }
    }

    if (kDebugMode) {
      print("#### DEBUG: updateOrderItems for order id $orderId completed...");
    }
  }

  // Build #1.0.64 : Modified updateOrderPayoutItems to align with updateOrderItems
  @Deprecated(
      "This API is deprecated and replaced by 'updateOrderPayoutItem' with line_item")
  Future<void> updateOrderPayoutItems(
      int orderId, List<model.FeeLine> feeLines) async {
    if (kDebugMode) {
      print("#### DEBUG: updateOrderPayoutItems orderId: $orderId");
    }
    final db = await DBHelper.instance.database;
    final existingItems = await db.query(
      AppDBConst.purchasedItemsTable,
      where:
          '${AppDBConst.orderIdForeignKey} = ? AND ${AppDBConst.itemType} = ?',
      whereArgs: [orderId, ItemType.payout.value],
    );

    final existingItemsMap = {
      for (var item in existingItems)
        item[AppDBConst.itemServerId].toString(): item,
    };

    if (kDebugMode) {
      print(
          "#### DEBUG: updateOrderPayoutItems - Processing ${feeLines.length} payout items for order $orderId, existing items: ${existingItems.length}");
    }
    double merchantDiscount = 0.0;
    var merchantDiscountIds = "";
    for (var feeLine in feeLines) {
      final itemId = feeLine.id.toString();
      if (kDebugMode) {
        print("item id $itemId");
      }
      if (kDebugMode) {
        print("item price value === ${feeLine.total}");
      }
      final double itemPrice = double.parse(feeLine.total ?? '0.0');
      final int itemQuantity = 1;
      final double itemSumPrice = itemPrice;

      if (kDebugMode) {
        print(
            "#### DEBUG: updateOrderPayoutItems - Processing payout item ID: $itemId, name: ${feeLine.name}, price: $itemPrice, quantity: $itemQuantity, sumPrice: $itemSumPrice");
      }

      if (feeLine.name == TextConstants.payout) {
        if (existingItemsMap.containsKey(itemId)) {
          final existingItem = existingItemsMap[itemId]!;
          await db.update(
            AppDBConst.purchasedItemsTable,
            {
              AppDBConst.itemName: feeLine.name ?? 'Payout',
              AppDBConst.itemPrice: itemPrice,
              AppDBConst.itemCount: itemQuantity,
              AppDBConst.itemSumPrice: itemSumPrice,
              AppDBConst.itemImage: 'assets/svg/payout.svg',
              AppDBConst.itemSKU: '',
            },
            where: '${AppDBConst.itemServerId} = ?',
            whereArgs: [existingItem[AppDBConst.itemServerId]],
          );
          if (kDebugMode) {
            print(
                "#### DEBUG: Updated payout item ID: $itemId for order $orderId");
          }
          existingItemsMap.remove(itemId);
        } else {
          await db.insert(AppDBConst.purchasedItemsTable, {
            //   AppDBConst.itemId: orderId,
            AppDBConst.itemServerId: feeLine.id, //Build #1.0.67: updated
            AppDBConst.itemName: feeLine.name ?? 'Payout',
            AppDBConst.itemSKU: '',
            AppDBConst.itemPrice: itemPrice,
            AppDBConst.itemImage: 'assets/svg/payout.svg',
            AppDBConst.itemCount: itemQuantity,
            AppDBConst.itemSumPrice: itemSumPrice,
            AppDBConst.orderIdForeignKey: orderId,
            AppDBConst.itemType: ItemType.payout.value,
          });
          if (kDebugMode) {
            print(
                "#### DEBUG: Inserted new payout item ID: $itemId for order $orderId");
          }
        }
      }
      if (feeLine.name == TextConstants.discountText) {
        merchantDiscount += itemPrice.abs();
        merchantDiscountIds = "$merchantDiscountIds,${feeLine.id}";
      }
    }
    await db.update(
      AppDBConst.orderTable,
      {
        AppDBConst.merchantDiscount: merchantDiscount,
        AppDBConst.merchantDiscountIds: merchantDiscountIds,
      },
      where: '${AppDBConst.orderServerId} = ?',
      whereArgs: [orderId],
    );
    if (kDebugMode) {
      print(
          "#### DEBUG: updateOrderPayoutItems - Processing merchantDiscount item IDs: $merchantDiscountIds, discountTotal: $merchantDiscount");
    }

    for (var item in existingItemsMap.values) {
      await db.delete(
        AppDBConst.purchasedItemsTable,
        where: '${AppDBConst.itemServerId} = ?',
        whereArgs: [item[AppDBConst.itemServerId]],
      );
      if (kDebugMode) {
        print(
            "#### DEBUG: Deleted obsolete payout item ID: ${item[AppDBConst.itemServerId]} for order $orderId");
      }
    }
  }

  //  Build #1.0.198 : Modified updateOrderPayoutItem to align with new payout API changes
  Future<void> updateOrderPayoutItem(
      int orderId, List<model.LineItem> lineItems) async {
    if (kDebugMode) {
      print("#### DEBUG: updateOrderPayoutItems orderId: $orderId");
    }
    final db = await DBHelper.instance.database;
    final existingItems = await db.query(
      AppDBConst.purchasedItemsTable,
      where:
          '${AppDBConst.orderIdForeignKey} = ? AND ${AppDBConst.itemType} = ?',
      whereArgs: [orderId, ItemType.payout.value],
    );

    final existingItemsMap = {
      for (var item in existingItems)
        item[AppDBConst.itemServerId].toString(): item,
    };

    if (kDebugMode) {
      print(
          "#### DEBUG: updateOrderPayoutItems - Processing ${lineItems.length} payout items for order $orderId, existing items: ${existingItems.length}");
    }
    double merchantDiscount = 0.0;
    var merchantDiscountIds = "";
    for (var lineItem in lineItems) {
      final itemId = lineItem.id.toString();
      if (kDebugMode) {
        print("item id $itemId");
      }
      if (kDebugMode) {
        print("item price value === ${lineItem.total}");
      }
      final double itemPrice = double.parse(lineItem.total ?? '0.0');
      final int itemQuantity = 1;
      final double itemSumPrice = itemPrice;

      if (kDebugMode) {
        print(
            "#### DEBUG: updateOrderPayoutItems - Processing payout item ID: $itemId, name: ${lineItem.name}, price: $itemPrice, quantity: $itemQuantity, sumPrice: $itemSumPrice");
      }

      if (lineItem.name == TextConstants.payout) {
        if (existingItemsMap.containsKey(itemId)) {
          final existingItem = existingItemsMap[itemId]!;
          await db.update(
            AppDBConst.purchasedItemsTable,
            {
              AppDBConst.itemName: lineItem.name ?? 'Payout',
              AppDBConst.itemPrice: itemPrice,
              AppDBConst.itemCount: itemQuantity,
              AppDBConst.itemSumPrice: itemSumPrice,
              AppDBConst.itemImage: 'assets/svg/payout.svg',
              AppDBConst.itemSKU: '',
            },
            where: '${AppDBConst.itemServerId} = ?',
            whereArgs: [existingItem[AppDBConst.itemServerId]],
          );
          if (kDebugMode) {
            print(
                "#### DEBUG: Updated payout item ID: $itemId for order $orderId");
          }
          existingItemsMap.remove(itemId);
        } else {
          await db.insert(AppDBConst.purchasedItemsTable, {
            //   AppDBConst.itemId: orderId,
            AppDBConst.itemServerId: lineItem.id, //Build #1.0.67: updated
            AppDBConst.itemName: lineItem.name ?? 'Payout',
            AppDBConst.itemSKU: '',
            AppDBConst.itemPrice: itemPrice,
            AppDBConst.itemImage: 'assets/svg/payout.svg',
            AppDBConst.itemCount: itemQuantity,
            AppDBConst.itemSumPrice: itemSumPrice,
            AppDBConst.orderIdForeignKey: orderId,
            AppDBConst.itemType: ItemType.payout.value,
          });
          if (kDebugMode) {
            print(
                "#### DEBUG: Inserted new payout item ID: $itemId for order $orderId");
          }
        }
      }
      if (lineItem.name == TextConstants.discountText) {
        merchantDiscount += itemPrice.abs();
        merchantDiscountIds = "$merchantDiscountIds,${lineItem.id}";
      }
    }
    await db.update(
      AppDBConst.orderTable,
      {
        AppDBConst.merchantDiscount: merchantDiscount,
        AppDBConst.merchantDiscountIds: merchantDiscountIds,
      },
      where: '${AppDBConst.orderServerId} = ?',
      whereArgs: [orderId],
    );
    if (kDebugMode) {
      print(
          "#### DEBUG: updateOrderPayoutItems - Processing merchantDiscount item IDs: $merchantDiscountIds, discountTotal: $merchantDiscount");
    }

    for (var item in existingItemsMap.values) {
      await db.delete(
        AppDBConst.purchasedItemsTable,
        where: '${AppDBConst.itemServerId} = ?',
        whereArgs: [item[AppDBConst.itemServerId]],
      );
      if (kDebugMode) {
        print(
            "#### DEBUG: Deleted obsolete payout item ID: ${item[AppDBConst.itemServerId]} for order $orderId");
      }
    }
  }

  Future<void> updateOrderField(
      int orderId, String fieldKey, dynamic value) async {
    try {
      // ✅ Update SQLite
      final db = await DBHelper.instance.database;

      final existingOrders = await db.query(
        AppDBConst.orderTable,
        where: '${AppDBConst.orderServerId} = ?',
        whereArgs: [orderId],
      );

      if (existingOrders.isNotEmpty) {
        await db.update(
          AppDBConst.orderTable,
          {fieldKey: value},
          where: '${AppDBConst.orderServerId} = ?',
          whereArgs: [orderId],
        );

        if (kDebugMode) {
          print(
              "✅ updateOrderField → Updated $fieldKey = $value for Order #$orderId in SQLite");
        }

        // ✅ Update in-memory list
        final orderIndex = orders.indexWhere(
          (order) => order[AppDBConst.orderServerId] == orderId,
        );
        if (orderIndex != -1) {
          orders[orderIndex][fieldKey] = value;
        }

        // ✅ Update storage (only JSON-safe data)
        final box = StorageProvider.offlineOrders;
        final orderKey = orderId.toString();
        final existingOrder = await box.get(orderKey);

        if (existingOrder != null && existingOrder is Map) {
          final updatedOrder = Map<String, dynamic>.from(existingOrder);

          // ✅ Convert any complex types to JSON-safe before saving
          updatedOrder[fieldKey] = _convertToJsonSafe(value);

          await box.put(orderKey, updatedOrder);

          if (kDebugMode) {
            print("💾 Order updated → $fieldKey = $value for Order #$orderId");
          }
        } else {
          if (kDebugMode) print("⚠ Order #$orderId not found");
        }

        // ✅ Refresh in-memory orders
        await loadData();
        if (kDebugMode) print("🔄 Orders list refreshed after update.");
      } else {
        if (kDebugMode)
          print("⚠ updateOrderField: Order ID $orderId not found in SQLite.");
      }
    } catch (e, s) {
      if (kDebugMode) print("❌ updateOrderField failed: $e\n$s");
    }
  }

  dynamic _convertToJsonSafe(dynamic value) {
    if (value == null) return null;

    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _convertToJsonSafe(v)));
    } else if (value is List) {
      return value.map(_convertToJsonSafe).toList();
    } else if (value is Tags) {
      // Convert your model object to a Map before storing
      return value.toJson();
    } else {
      // Primitive (String, int, bool, double) — safe to store
      return value;
    }
  }

  // Build #1.0.207: Fixed Issue - Always Merchant discount showing "0"
  // Ex: updateOrderPayoutItem modified to lineItems but discount we are getting in fee lines only , we are not using this, that's why merchant discount calculation is 0.
  // Added this function to handle merchant discounts from feeLines
  Future<void> updateOrderMerchantDiscount(
      int orderId, List<model.LineItem> lineItems) async {
    // Build #1.0.274 : updated fee lines to line items
    final db = await DBHelper.instance.database;
    double merchantDiscount = 0.0;
    // Use a list instead of string concatenation
    List<String> merchantDiscountIdsList =
        []; // Build #1.0.216: FIXED Issue - Merchant discount not deleting, showing error "Payout ID not found"

    for (var lineItem in lineItems) {
      final name = (lineItem.name ?? '').toLowerCase();

      if (name.contains('discount')) {
        merchantDiscount += double.parse(lineItem.total ?? '0.0').abs();
        merchantDiscountIdsList.add(lineItem.id.toString());
      }
    }
    // Build #1.0.216: Join with commas and ensure no leading comma
    String merchantDiscountIds = merchantDiscountIdsList.join(',');

    await db.update(
      AppDBConst.orderTable,
      {
        AppDBConst.merchantDiscount: merchantDiscount,
        AppDBConst.merchantDiscountIds: merchantDiscountIds,
      },
      where: '${AppDBConst.orderServerId} = ?',
      whereArgs: [orderId],
    );
  }

  // Build #1.0.64 : Modified updateOrderCouponItems to align with updateOrderItems
  Future<void> updateOrderCouponItems(
      int orderId, List<model.CouponLine> couponLines) async {
    if (kDebugMode) {
      print("#### DEBUG: updateOrderCouponItems orderId: $orderId");
    }
    final db = await DBHelper.instance.database;
    final existingItems = await db.query(
      AppDBConst.purchasedItemsTable,
      where:
          '${AppDBConst.orderIdForeignKey} = ? AND ${AppDBConst.itemType} = ?',
      whereArgs: [orderId, ItemType.coupon.value],
    );

    final existingItemsMap = {
      for (var item in existingItems)
        item[AppDBConst.itemServerId].toString(): item,
    };

    if (kDebugMode) {
      print(
          "#### DEBUG: updateOrderCouponItems - Processing ${couponLines.length} coupon items for order $orderId, existing items: ${existingItems.length}");
    }

    for (var coupon in couponLines) {
      final itemId = coupon.id.toString();
      final double itemPrice = coupon.nominalAmount ?? 0.0;
      final int itemQuantity = 1;
      final double itemSumPrice = itemPrice;

      if (kDebugMode) {
        print(
            "#### DEBUG: updateOrderCouponItems - Processing coupon item ID: $itemId, code: ${coupon.code}, price: $itemPrice, quantity: $itemQuantity, sumPrice: $itemSumPrice");
      }

      if (existingItemsMap.containsKey(itemId)) {
        final existingItem = existingItemsMap[itemId]!;
        await db.update(
          AppDBConst.purchasedItemsTable,
          {
            AppDBConst.itemName: coupon.code ?? 'Coupon',
            AppDBConst.itemPrice: itemPrice,
            AppDBConst.itemCount: itemQuantity,
            AppDBConst.itemSumPrice: itemSumPrice,
            AppDBConst.itemImage: 'assets/svg/coupon.svg',
            AppDBConst.itemSKU: '',
          },
          where:
              '${AppDBConst.itemServerId} = ?', //Build #1.0.128: Updated - itemId to itemServerId
          whereArgs: [existingItem[AppDBConst.itemServerId]],
        );
        if (kDebugMode) {
          print(
              "#### DEBUG: Updated coupon item ID: $itemId for order $orderId");
        }
        existingItemsMap.remove(itemId);
      } else {
        await db.insert(AppDBConst.purchasedItemsTable, {
          //   AppDBConst.itemId: orderId,
          AppDBConst.itemServerId: coupon.id, //Build #1.0.67: updated
          AppDBConst.itemName: coupon.code ?? 'Coupon',
          AppDBConst.itemSKU: '',
          AppDBConst.itemPrice: itemPrice,
          AppDBConst.itemImage: 'assets/svg/coupon.svg',
          AppDBConst.itemCount: itemQuantity,
          AppDBConst.itemSumPrice: itemSumPrice,
          AppDBConst.orderIdForeignKey: orderId,
          AppDBConst.itemType: ItemType.coupon.value,
        });
        if (kDebugMode) {
          print(
              "#### DEBUG: Inserted new coupon item ID: $itemId for order $orderId");
        }
      }
    }

    for (var item in existingItemsMap.values) {
      await db.delete(
        AppDBConst.purchasedItemsTable,
        where:
            '${AppDBConst.itemServerId} = ?', //Build #1.0.128: Updated - itemId to itemServerId
        whereArgs: [item[AppDBConst.itemServerId]],
      );
      if (kDebugMode) {
        print(
            "#### DEBUG: Deleted obsolete coupon item ID: ${item[AppDBConst.itemServerId]} for order $orderId");
      }
    }
  }

  Future<int?> ensureOrderExists() async {
    // Concurrency: if another ensureOrderExists is in progress, wait for it
    if (_ensureOrderInProgress != null) {
      final result = await _ensureOrderInProgress!;
      if (activeOrderId != null) return activeOrderId;
      return result;
    }

    _ensureOrderInProgress = _doEnsureOrderExists();
    try {
      final result = await _ensureOrderInProgress!;
      return result;
    } finally {
      _ensureOrderInProgress = null;
    }
  }

  Future<int?> _doEnsureOrderExists() async {
    lastEnsureOrderError = null;

    // 1️⃣ Reset if no user logged in
    final uId = await getUserIdFromDB();
    if (uId == 0) {
      if (kDebugMode) print("⛔ ensureOrderExists blocked: No user ID active");
      return null;
    }

    // 1️⃣ If already active
    if (activeOrderId != null) return activeOrderId;

    // 2️⃣ Load orders from offline storage
    await loadData();

    // 3️⃣ Try reuse unpaid order
    for (final order in orders) {
      final oid =
          order[AppDBConst.orderServerId] ?? order['order_id'] ?? order['id'];
      final int? orderId =
          oid is int ? oid : int.tryParse(oid?.toString() ?? '');
      if (orderId == null) continue;
      final payments =
          await LocalPaymentDBHelper.instance.getPaymentsByOrderId(orderId);

      if (payments.isEmpty) {
        await setActiveOrder(orderId);
        await saveLastActiveOrderId(orderId);
        return orderId;
      }
    }

    // 4️⃣ Create new order (with error handling)
    try {
      final repo = OrderRepository();
      final response = await repo.createOrder();
      final int newOrderId = response.id!;

      // 5️⃣ Activate + persist
      await setActiveOrder(newOrderId);
      await saveLastActiveOrderId(newOrderId);

      // 5b. Persist new order to SQLite so order panel and addItemToOrder see it
      await createOrder(serverOrderId: newOrderId);

      // 6️⃣ Reload orders from offline storage so panel has full order data
      await loadData();

      // Restore active order
      await restoreActiveOrderId();

      // Force order panel to refresh so new order tab appears
      OrderHelper.isOrderPanelLoaded = false;
      OrderHelper.notifyOrderPanelToRefresh();

      if (kDebugMode) {
        print("🆕 ensureOrderExists → $newOrderId");
        print("🎯 ActiveOrderId → $activeOrderId");
      }

      return newOrderId;
    } catch (e, s) {
      lastEnsureOrderError = e is Exception
          ? e.toString().replaceFirst('Exception: ', '')
          : e.toString();
      if (kDebugMode) {
        print("❌ ensureOrderExists failed: $e");
        print("Stack: $s");
      }
      return null;
    }
  }

  Future<int> createOrder({int? serverOrderId}) async {
    // Build #1.0.11 : updated
    final db = await DBHelper.instance.database;

    // When serverOrderId is provided (offline or API), avoid duplicate insert
    if (serverOrderId != null) {
      final existing = await db.query(
        AppDBConst.orderTable,
        where: '${AppDBConst.orderServerId} = ? AND ${AppDBConst.userId} = ?',
        whereArgs: [serverOrderId, activeUserId ?? 0],
      );
      if (existing.isNotEmpty) {
        activeOrderId = serverOrderId;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('activeOrderId', activeOrderId!);
        final box = StorageProvider.offlineOrders;
        if (!(await box.containsKey(serverOrderId.toString()))) {
          final minimalOrder = {
            'order_id': serverOrderId,
            'id': serverOrderId,
            'user_id': activeUserId ??
                0, // Build #1.0.285: Do NOT default to 1, use current user
            AppDBConst.orderServerId: serverOrderId,
            'products': <Map<String, dynamic>>[],
          };
          await box.put(serverOrderId.toString(), minimalOrder);
          _upsertOfflineOrderInMemory(serverOrderId, minimalOrder);
        }
        await loadData();
        if (kDebugMode)
          print(
              "#### Order already in DB, synced activeOrderId: $activeOrderId");
        return activeOrderId!;
      }
    }

    activeOrderId = serverOrderId;
    await db.insert(AppDBConst.orderTable, {
      AppDBConst.userId: activeUserId ?? 0,
      if (serverOrderId != null) AppDBConst.orderServerId: serverOrderId,
      AppDBConst.orderTotal: 0.0,
      AppDBConst.orderStatus: "processing",
      AppDBConst.orderType: 'in-store',
      AppDBConst.orderDate: DateTime.now().toString(),
      AppDBConst.orderTime: DateTime.now().toString(),
    });

    await db.rawUpdate('''
    UPDATE ${AppDBConst.userTable}
    SET ${AppDBConst.userOrderCount} = ${AppDBConst.userOrderCount} + 1
    WHERE ${AppDBConst.userId} = ?
    ''', [activeUserId ?? 0]);

    // When order was created on server/offline, ensure storage has it (only if not already)
    if (serverOrderId != null) {
      final box = StorageProvider.offlineOrders;
      if (!(await box.containsKey(serverOrderId.toString()))) {
        final minimalOrder = {
          'order_id': serverOrderId,
          'id': serverOrderId,
          AppDBConst.orderServerId: serverOrderId,
          'products': <Map<String, dynamic>>[],
        };
        await box.put(serverOrderId.toString(), minimalOrder);
        _upsertOfflineOrderInMemory(serverOrderId, minimalOrder);
        if (kDebugMode) {
          print(
              "#### Order $serverOrderId added for order panel & addItemToOrder");
        }
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('activeOrderId', activeOrderId!);

    await loadData();

    if (kDebugMode) {
      print("#### Order created with ID: $activeOrderId");
    }

    return activeOrderId!;
  }

  // Deletes an order from the database and offline storage
  Future<void> deleteOrder(int orderId) async {
    // Remove from offline storage (Isar) - required for orders to disappear from UI
    final offlineBox = StorageProvider.offlineOrders;
    await offlineBox.delete(orderId.toString());

    final db = await DBHelper.instance.database;
    await db.delete(
      //Build #1.0.78 : delete from db -> purchasedItemsTable
      AppDBConst.purchasedItemsTable,
      where: '${AppDBConst.orderIdForeignKey} = ?',
      whereArgs: [orderId],
    );
    await db.delete(
      //Build #1.0.78 : delete from db -> orderTable
      AppDBConst.orderTable,
      where: '${AppDBConst.orderServerId} = ?',
      whereArgs: [orderId],
    );

    // Build #1.0.189: Remove the orderId from orderIds list
    orderIds.remove(orderId);

    final prefs = await SharedPreferences.getInstance();

    // If the deleted order was the active order, reset the activeOrderId
    if (orderId == activeOrderId) {
      activeOrderId = orderIds.isNotEmpty ? orderIds.last : null;
      await prefs.remove('activeOrderId');
    }

    // Prevent restoreActiveOrderId() from reviving a deleted or last-deleted cart
    if (prefs.getInt('lastActiveOrderId') == orderId || orderIds.isEmpty) {
      await prefs.remove('lastActiveOrderId');
    }
    if (orderIds.isEmpty) {
      activeOrderId = null;
      await prefs.remove('activeOrderId');
    }

    await loadData();

// ✅ Capture final state AFTER loadData
    final int? finalActiveId = activeOrderId;

    print("🎯 Final activeOrderId after loadData: $finalActiveId");

// 🔥 SYNC CUSTOMER DISPLAY AFTER DELETE
    if (finalActiveId != null) {
      print("🔄 Active order exists → updating display: $finalActiveId");

      await CustomerDisplayHelper.updateCustomerDisplay(finalActiveId);
    } else {
      print("🧹 No active order → resetting display");

      await CustomerDisplayService.resetDisplay();
    }
    // Debugging logs
    if (kDebugMode) {
      print('#### Order deleted with ID: $orderId');
      print('#### Updated activeOrderId: $activeOrderId');
      print('#### Updated orderIds: $orderIds');
    }
  }

  // Sets a specific order as the active order
  Future<void> setActiveOrder(int? orderId) async {
    activeOrderId = orderId;

    final prefs = await SharedPreferences.getInstance();

    if (orderId == null) {
      await prefs.remove('activeOrderId');
    } else {
      await prefs.setInt('activeOrderId', orderId);
    }

    if (kDebugMode) {
      print("#### Active order set to: $activeOrderId");
    }
  }

  // Build #1.0.161: Store current active order before leaving
  /// we are using same "activeOrderId" for both orderPanel & total order screen
  /// we have to save order panel activeOrderId in "lastActiveOrderId" pref value when comes back assign it
  /// Issue: when comes from orders screen to order panel screens selected orderId changing
  Future<void> saveLastActiveOrderId(int orderId) async {
    activeOrderId = orderId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lastActiveOrderId', orderId);
    // Build #1.0.316: Also sync with activeOrderId to ensure consistency during transitions
    await prefs.setInt('activeOrderId', orderId);
    if (kDebugMode) {
      print(
          "##### Saved last active order ID: $orderId (synced with activeOrderId)");
    }
  }

  /// True if this order still exists in offline (Hive) for the current user, or in SQLite.
  Future<bool> localOrderExistsForActiveUser(int orderId) async {
    final offlineBox = StorageProvider.offlineOrders;
    final dynamic raw = await offlineBox.get(orderId.toString());
    if (raw != null && raw is Map) {
      final order = Map<String, dynamic>.from(raw);
      final currentUserId = await getUserIdFromDB();
      final dynamic orderUserId = order['user_id'] ?? order[AppDBConst.userId];
      if (orderUserId?.toString() == currentUserId.toString()) {
        return true;
      }
    }
    final rows = await getOrderById(orderId);
    return rows.isNotEmpty;
  }

  /// Clears in-memory and persisted cart selection (fixes ghost cart after delete/restart).
  Future<void> clearPersistedCartSelection() async {
    activeOrderId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('activeOrderId');
    await prefs.remove('lastActiveOrderId');
    if (kDebugMode) {
      print("##### Cleared persisted cart selection (active + lastActive)");
    }
  }

  // Build #1.0.161: Restore active order when returning
  Future<void> restoreActiveOrderId() async {
    final prefs = await SharedPreferences.getInstance();
    final lastOrderId = prefs.getInt('lastActiveOrderId');

    if (lastOrderId == null || lastOrderId == -1) return;

    if (!await localOrderExistsForActiveUser(lastOrderId)) {
      await clearPersistedCartSelection();
      if (kDebugMode) {
        print(
            "##### Skipped restore: lastActiveOrderId $lastOrderId has no local order — cleared prefs");
      }
      return;
    }

    await setActiveOrder(lastOrderId);
    if (kDebugMode) {
      print("##### Restored active order ID: $lastOrderId");
    }
  }

  // Fetch all orders for a specific user
  Future<List<Map<String, dynamic>>> getUserOrders(int userID) async {
    // Build #1.0.11 : added here from db_helper
    final db = await DBHelper.instance.database;
    return await db.query(
      AppDBConst.orderTable,
      where: '${AppDBConst.userId} = ?',
      whereArgs: [userID],
    );
  }

  // Fetch order for a specific orderId - Build #1.0.285: Filter by user ID
  Future<List<Map<String, dynamic>>> getOrderById(int orderId) async {
    final db = await DBHelper.instance.database;
    final uId = await getUserIdFromDB();
    return await db.query(
      AppDBConst.orderTable,
      where: '${AppDBConst.orderServerId} = ? AND ${AppDBConst.userId} = ?',
      whereArgs: [orderId, uId],
    );
  }

  // Fetch all items for a specific order - Build #1.0.285: Verify order ownership
  Future<List<Map<String, dynamic>>> getOrderItems(int orderID) async {
    final db = await DBHelper.instance.database;
    final uId = await getUserIdFromDB();

    final order = await db.query(
      AppDBConst.orderTable,
      where: '${AppDBConst.orderServerId} = ? AND ${AppDBConst.userId} = ?',
      whereArgs: [orderID, uId],
    );

    if (order.isEmpty) return [];

    return await db.query(
      AppDBConst.purchasedItemsTable,
      where: '${AppDBConst.orderIdForeignKey} = ?',
      whereArgs: [orderID],
    );
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  /// Hive/SQLite may store EBT as bool, 0/1, or string — not only `== true`.
  static bool offlineLineItemEbtEligible(dynamic v) {
    if (v == true || v == 1) return true;
    if (v is String) {
      final s = v.toLowerCase().trim();
      return s == '1' || s == 'true' || s == 'yes';
    }
    return false;
  }

  static int offlineLineItemVariationId(Map<String, dynamic> map) {
    final raw = map['variation_id'] ??
        map['variationId'] ??
        map['item_variation'] ??
        map['item_variation_id'] ??
        0;
    final v = raw is num ? raw.toInt() : int.tryParse(raw.toString()) ?? 0;
    return v < 0 ? 0 : v;
  }

  static String offlineLineItemVariationName(Map<String, dynamic> map) {
    final n = map['variation_name'] ??
        map['item_variation_custom_name'] ??
        map['attribute_variant'];
    return n?.toString().trim() ?? '';
  }

  /// Resolves product image URL from various possible keys. Delegates to top-level [resolveProductImageFromMap].
  static String resolveProductImage(dynamic map) =>
      resolveProductImageFromMap(map);

  /// Gets order items from offline storage (products, order_items, payouts, cashbacks, discounts).
  /// Returns empty list if order not found.
  /// Items are converted to display format (item_name, item_price, items_count, etc.).
  /// Supports both "products" (Categories/Fast Keys) and "order_items" (Order Summary) structures.
  Future<List<Map<String, dynamic>>> getOrderItemsFromOffline(
      int orderID) async {
    final box = StorageProvider.offlineOrders;
    final dynamic raw = await box.get(orderID.toString());
    if (raw == null || raw is! Map) return [];

    // Build #1.0.285: STRICT User check
    final order = Map<String, dynamic>.from(raw);
    final currentUserId = await getUserIdFromDB();
    final dynamic orderUserId = order['user_id'] ?? order[AppDBConst.userId];

    if (orderUserId?.toString() != currentUserId.toString()) {
      if (kDebugMode)
        print(
            "⛔ getOrderItemsFromOffline blocked: Order $orderID belongs to another user ($orderUserId). Requested by $currentUserId.");
      return [];
    }

    final List<Map<String, dynamic>> items = [];

    // 1️⃣ Products (primary) or order_items fallback (from Order Summary screen)
    var products = (order['products'] as List?) ?? [];
    if (products.isEmpty) {
      final orderItems = (order['order_items'] as List?) ?? [];
      for (final oi in orderItems) {
        final map = Map<String, dynamic>.from(oi is Map ? oi : {});
        final name = map['item_name'] ?? map['name'] ?? '';
        final price = (map['item_price'] ?? map['price'] ?? 0).toDouble();
        final qty = (map['items_count'] ?? map['quantity'] ?? 1).toInt();
        final itemType =
            (map['item_type'] ?? map['type'] ?? 'product').toString();
        // Skip discount type - we add from discounts list separately
        if (itemType.toLowerCase().contains('discount')) continue;
        final multipack = _toDouble(
            map['multipack_discount_total'] ?? map['multipackDiscount'] ?? 0);
        final auto = _toDouble(map['auto_discount_total'] ??
            map['autoDiscountTotal'] ??
            map['auto_discount'] ??
            0);
        final combo = _toDouble(
            map['combo_discount_total'] ?? map['comboDiscountTotal'] ?? 0);
        final vid = offlineLineItemVariationId(map);
        final vName = offlineLineItemVariationName(map);
        final itemTypeLower = itemType.toLowerCase();
        items.add({
          AppDBConst.itemName: name,
          AppDBConst.itemPrice: price,
          AppDBConst.itemCount: qty,
          AppDBConst.itemSumPrice: price * qty,
          AppDBConst.itemImage: resolveProductImageFromMap(map),
          AppDBConst.itemType: itemType,
          'is_ebt_eligible': offlineLineItemEbtEligible(map['is_ebt_eligible']),
          'product_id': (map['product_id'] as num?)?.toInt() ?? 0,
          'variation_id': vid,
          'variationId': vid,
          'item_variation': vid,
          'item_variation_id': vid,
          'variation_name': vName,
          'is_variant': vid > 0 ||
              itemTypeLower == 'variant' ||
              itemTypeLower == 'variation',
          'sku': map['sku'] ?? map['item_sku'] ?? '',
          AppDBConst.multipackDiscount: multipack,
          AppDBConst.autoDiscountTotal: auto,
          AppDBConst.comboDiscountTotal: combo,
        });
      }
    } else {
      for (final p in products) {
        final map = Map<String, dynamic>.from(p is Map ? p : {});
        final itemType = (map['item_type'] ?? map['type'] ?? 'product')
            .toString()
            .toLowerCase();
        // Skip discount type - we add from discounts list separately
        if (itemType.contains('discount')) continue;
        final name = map['name'] ?? map['product_name'] ?? '';
        final price = (map['price'] as num?)?.toDouble() ?? 0.0;
        final qty = (map['quantity'] as num?)?.toInt() ?? 1;
        final sumPrice = price * qty;

        final multipack = _toDouble(
            map['multipack_discount_total'] ?? map['multipackDiscount'] ?? 0);
        final auto = _toDouble(map['auto_discount_total'] ??
            map['autoDiscountTotal'] ??
            map['auto_discount'] ??
            0);
        final combo = _toDouble(
            map['combo_discount_total'] ?? map['comboDiscountTotal'] ?? 0);

        final vid = offlineLineItemVariationId(map);
        final vName = offlineLineItemVariationName(map);
        items.add({
          AppDBConst.itemName: name,
          AppDBConst.itemPrice: price,
          AppDBConst.itemCount: qty,
          AppDBConst.itemSumPrice: sumPrice,
          AppDBConst.itemImage: resolveProductImageFromMap(map),
          AppDBConst.itemType: map['item_type'] ?? map['type'] ?? 'product',
          'is_ebt_eligible': offlineLineItemEbtEligible(map['is_ebt_eligible']),
          'product_id': (map['product_id'] as num?)?.toInt() ?? 0,
          'variation_id': vid,
          'variationId': vid,
          'item_variation': vid,
          'item_variation_id': vid,
          'variation_name': vName,
          'is_variant':
              vid > 0 || itemType == 'variant' || itemType == 'variation',
          'sku': map['sku'] ?? '',
          AppDBConst.multipackDiscount: multipack,
          AppDBConst.autoDiscountTotal: auto,
          AppDBConst.comboDiscountTotal: combo,
        });
      }
    }

    // 2️⃣ Payouts
    final payouts = (order['payouts'] as List?) ?? [];
    for (final p in payouts) {
      final map = Map<String, dynamic>.from(p is Map ? p : {});
      final price = (map['amount'] as num?)?.toDouble() ?? 0.0;
      items.add({
        AppDBConst.itemName: 'Payout',
        AppDBConst.itemPrice: price,
        AppDBConst.itemCount: 1,
        AppDBConst.itemSumPrice: price,
        AppDBConst.itemImage: 'assets/svg/payout.svg',
        AppDBConst.itemType: 'payout',
      });
    }

    // 3️⃣ Cashbacks
    final cashbacks = (order['cashbacks'] as List?) ?? [];
    for (final c in cashbacks) {
      final map = Map<String, dynamic>.from(c is Map ? c : {});
      final price = (map['amount'] as num?)?.toDouble() ?? 0.0;
      items.add({
        AppDBConst.itemName: 'Cashback',
        AppDBConst.itemPrice: price,
        AppDBConst.itemCount: 1,
        AppDBConst.itemSumPrice: price,
        AppDBConst.itemImage:
            map['product_image'] ?? map['item_image'] ?? map['image'] ?? '',
        AppDBConst.itemType: 'cashback',
      });
    }

    // 4️⃣ Merchant discounts (from discounts list)
    // Use negative item_sum_price so _computeOrderData extraction (discountValue < 0) finds it
    final discounts = (order['discounts'] as List?) ?? [];
    for (final d in discounts) {
      final map = Map<String, dynamic>.from(d is Map ? d : {});
      final amount = (map[AppDBConst.itemPrice] ??
              map['discount_amount'] ??
              map['display_amount'] ??
              0)
          .toDouble()
          .abs();
      final name =
          map[AppDBConst.itemName] ?? map['name'] ?? 'Merchant Discount';
      items.add({
        AppDBConst.itemName: name,
        AppDBConst.itemPrice: -amount,
        AppDBConst.itemCount: 1,
        AppDBConst.itemSumPrice: -amount,
        AppDBConst.itemImage: map['product_image'] ?? '',
        AppDBConst.itemType: 'discount',
      });
    }

    return items;
  }

// Delete an item from an order
  Future<void> deleteItem(int itemServerId) async {
    // delete the item/product based on serverID not item id
    final db = await DBHelper.instance.database;
    await db.delete(
      AppDBConst.purchasedItemsTable,
      where:
          '${AppDBConst.itemServerId} = ?', // Build #1.0.92: using item server id , checked used places!!
      whereArgs: [itemServerId],
    );

    if (kDebugMode) {
      print('#### Item deleted with ID: $itemServerId');
    }
  }

  //Build 1.1.36: Clears all items for a specific order before updating order items in order bloc -> updateOrderProducts
  Future<void> clearOrderItems(int orderId) async {
    final db = await DBHelper.instance.database;
    await db.delete(
      AppDBConst.purchasedItemsTable,
      where: '${AppDBConst.orderIdForeignKey} = ?',
      whereArgs: [orderId],
    );

    if (kDebugMode) {
      print('#### Cleared all items for order: $orderId');
    }
  }

  // Adds an item to the currently active order; creates an order if none exists

  // Adds an item to the currently active order; creates an order if none exists

  //// code added here **88
  static final Set<String> _activeAdds = {};

  double _combinedTaxRate(dynamic taxRates, dynamic fallbackRate) {
    if (taxRates is List && taxRates.isNotEmpty) {
      double total = 0.0;
      for (final t in taxRates) {
        total += double.tryParse((t["rate"] ?? "0").toString()) ?? 0.0;
      }
      if (total > 0) return total;
    }
    return double.tryParse((fallbackRate ?? "0").toString()) ?? 0.0;
  }

  Future<Map<String, dynamic>> _resolveProductTaxMeta(int productId) async {
    String status = "taxable";
    String taxClass = "";
    double rate = 0.0;

    try {
      final isar = IsarService.sync;
      if (isar != null) {
        final cachedEntries = isar.isarCacheEntrys
            .where()
            .filter()
            .keyStartsWith("products_")
            .findAllSync();

        for (final entry in cachedEntries) {
          final List products = json.decode(entry.json);
          final product = products.firstWhere(
            (p) {
              final pid = int.tryParse(
                      (p["fast_key_product_id"] ?? p["id"] ?? "").toString()) ??
                  -1;
              return pid == productId;
            },
            orElse: () => null,
          );

          if (product == null) continue;
          status = (product["tax_status"] ?? "taxable").toString();
          taxClass = (product["tax_class"] ?? "").toString();
          final taxRates = product["tax_rates"] ?? product["tax"]?["tax_rates"];
          rate = _combinedTaxRate(
            taxRates,
            product["tax_rate"] ?? product["tax"]?["rate"],
          );
          return {
            "tax_status": status,
            "tax_class": taxClass,
            "tax_rate": rate,
          };
        }
      }

      // Fallback to flattened product list cache.
      final allProducts =
          await StorageProvider.productCache.get("all_products_list");
      if (allProducts is List) {
        final product = allProducts.cast<dynamic>().firstWhere(
          (p) {
            final pid = int.tryParse(
                    (p["fast_key_product_id"] ?? p["id"] ?? "").toString()) ??
                -1;
            return pid == productId;
          },
          orElse: () => null,
        );

        if (product != null) {
          status = (product["tax_status"] ?? "taxable").toString();
          taxClass = (product["tax_class"] ?? "").toString();
          final taxRates = product["tax_rates"] ?? product["tax"]?["tax_rates"];
          rate = _combinedTaxRate(
            taxRates,
            product["tax_rate"] ?? product["tax"]?["rate"],
          );
        }
      }
    } catch (_) {}

    return {
      "tax_status": status,
      "tax_class": taxClass,
      "tax_rate": rate,
    };
  }

  Future<void> addItemToOrder(
    int? serverItemId,
    String name,
    String image,
    double price,
    int quantity,
    String sku,
    int orderId, {
    VoidCallback? onItemAdded,
    String? type,
    double? weightQty,
    int? productId = -1,
    int? variationId = -1,
    String? variationName,
    int? variationCount,
    String? combo,
    double? salesPrice,
    double? regularPrice,
    double? unitPrice,
    bool isEbtEligible = false,
    String? taxStatus,
    String? taxClass,
    double? taxRate,
  }) async {
    print("🍏 addItemToOrder() CALLED for: $name | EBT: $isEbtEligible");

    final key = '$orderId-$productId-$variationId';

    // 🛡 Prevent double execution
    if (_activeAdds.contains(key)) {
      print("⚠ Duplicate addItemToOrder ignored for $key");
      return;
    }
    _activeAdds.add(key);

    try {
      // Block adding items to orders that have payments (pending orders)
      final payments =
          await LocalPaymentDBHelper.instance.getPaymentsByOrderId(orderId);
      if (payments.isNotEmpty) {
        if (kDebugMode) {
          print(
              "⚠ addItemToOrder blocked: order $orderId has payments (pending) - cannot add line items");
        }
        return;
      }

      final box = StorageProvider.offlineOrders;
      final rawOrder = await box.get(orderId.toString());
      if (rawOrder == null || rawOrder is! Map) {
        print("⚠ No offline order found for $orderId");
        return;
      }
      final order = Map<String, dynamic>.from(rawOrder);

      // Clone products
      final List<Map<String, dynamic>> products = (order['products'] ?? [])
          .map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p))
          .toList();

      final normProductId = (productId ?? -1).toInt();
      // Treat null / 0 / -1 as "no variation" so different callers (scanner,
      // categories, search) don't create separate rows for the same simple item.
      final rawNormVar = (variationId ?? 0).toInt();
      final normVariationId = rawNormVar <= 0 ? 0 : rawNormVar;

      const double defaultNonEbtTaxRate = 9.1;
      String effectiveTaxStatus = (taxStatus ?? '').trim();
      String? effectiveTaxClass = taxClass;
      double effectiveTaxRate = taxRate ?? 0.0;
      if (normProductId > 0 &&
          (effectiveTaxStatus.isEmpty || effectiveTaxRate <= 0)) {
        final meta = await _resolveProductTaxMeta(normProductId);
        effectiveTaxStatus =
            (meta["tax_status"]?.toString().trim().isNotEmpty == true)
                ? meta["tax_status"].toString()
                : (effectiveTaxStatus.isEmpty ? "taxable" : effectiveTaxStatus);
        effectiveTaxClass = (meta["tax_class"]?.toString().isNotEmpty == true)
            ? meta["tax_class"].toString()
            : effectiveTaxClass;
        effectiveTaxRate =
            (meta["tax_rate"] as num?)?.toDouble() ?? effectiveTaxRate;
      }
      // Business rule: all non-EBT items are taxable; EBT items are tax-free.
      if (isEbtEligible) {
        effectiveTaxStatus = "none";
        effectiveTaxRate = 0.0;
      } else {
        effectiveTaxStatus = "taxable";
        if (effectiveTaxRate <= 0) {
          effectiveTaxRate = defaultNonEbtTaxRate;
        }
      }

      // Find existing item to merge quantity (scan/search/selection)
      final existingIndex = products.indexWhere((p) {
        // Normalize stored ids to int because some flows store them as String/num
        // (e.g. scanner vs category/search), which would otherwise fail equality
        // and create duplicate entries for the same product.
        final dynamic rawPid = p['product_id'] ?? p['id'] ?? -1;
        final dynamic rawVid =
            p['variation_id'] ?? p['item_variation'] ?? p['variationId'] ?? 0;

        int pid;
        if (rawPid is int) {
          pid = rawPid;
        } else {
          pid = int.tryParse(rawPid.toString()) ?? -1;
        }

        int vid;
        if (rawVid is int) {
          vid = rawVid;
        } else {
          vid = int.tryParse(rawVid.toString()) ?? 0;
        }
        // Normalize stored variation id: <= 0 means "no variation"
        if (vid <= 0) vid = 0;

        final matchesIds = pid == normProductId && vid == normVariationId;

        // If it's a custom item (productId 0 or -1), we MUST also match the SKU
        if (normProductId == 0 || normProductId == -1) {
          final storedSku = normalizeSku(p['sku']?.toString() ?? '');
          final newSku = normalizeSku(sku);
          return matchesIds && storedSku == newSku;
        }
        // For normal products, also allow merge when SKU matches and there is
        // effectively no variation on either side. This handles flows where one
        // caller passes a different internal product id for the same barcode.
        // Only when at least one side has no reliable product id — otherwise
        // many items share placeholders like "N/A" and would incorrectly merge.
        if (!matchesIds) {
          final ambiguousIncoming = normProductId <= 0;
          final ambiguousStored = pid <= 0;
          if (ambiguousIncoming || ambiguousStored) {
            final storedSku = normalizeSku(p['sku']?.toString() ?? '');
            final newSku = normalizeSku(sku);
            final bothNoVariation = vid == 0 && normVariationId == 0;
            if (bothNoVariation &&
                storedSku.isNotEmpty &&
                storedSku == newSku) {
              return true;
            }
          }
        }
        return matchesIds;
      });

      if (existingIndex != -1) {
        final existing = products[existingIndex];
        final incomingType = (type ?? '').toString().toLowerCase();
        final existingType = (existing['type'] ?? '').toString().toLowerCase();
        final bool incomingWeighted = incomingType.contains('weighted');
        final bool existingWeighted = existingType.contains('weighted');

        final oldQty = (existing['quantity'] ?? 0).toInt();
        final int newQty;
        final double unitPrice = (existing['unit_price'] as num?)?.toDouble() ??
            (existing['regular_price'] as num?)?.toDouble() ??
            (existing['sales_price'] as num?)?.toDouble() ??
            (existing['price'] as num?)?.toDouble() ??
            0.0;

        // For weighted items, we merge by accumulating weight + total price,
        // while keeping quantity fixed at 1 (so totals remain correct).
        double mergedLinePrice;
        double mergedWeightQty = 0.0;
        if (incomingWeighted || existingWeighted) {
          newQty = 1;

          final double oldLinePrice =
              (existing['price'] as num?)?.toDouble() ?? 0.0;
          mergedLinePrice = oldLinePrice + price;

          final double oldWeight =
              (existing['weight_qty'] as num?)?.toDouble() ??
                  ((unitPrice > 0) ? (oldLinePrice / unitPrice) : 0.0);
          final double addWeight =
              weightQty ?? ((unitPrice > 0) ? (price / unitPrice) : 0.0);
          mergedWeightQty = oldWeight + addWeight;
        } else {
          newQty = oldQty + quantity;
          mergedLinePrice = (existing['price'] ?? 0).toDouble();
        }

        final mergedEbt =
            (existing['is_ebt_eligible'] == true) || (isEbtEligible == true);
        double itemTaxRate = double.tryParse(
                (existing['tax_rate'] ?? effectiveTaxRate).toString()) ??
            0.0;
        String itemTaxStatus = (existing['tax_status'] ?? effectiveTaxStatus)
            .toString()
            .toLowerCase();
        if (mergedEbt) {
          itemTaxStatus = "none";
          itemTaxRate = 0.0;
        } else {
          itemTaxStatus = "taxable";
          if (itemTaxRate <= 0) itemTaxRate = defaultNonEbtTaxRate;
        }

        double itemTax = 0.0;

        if (itemTaxStatus == "taxable" && itemTaxRate > 0) {
          final double taxableBase = (incomingWeighted || existingWeighted)
              ? mergedLinePrice
              : (mergedLinePrice * newQty);
          itemTax = roundTaxHalfUp(taxableBase * (itemTaxRate / 100));
          print("🔁 UPDATED TAX → rate:$itemTaxRate qty:$newQty tax:$itemTax");
        }

        print("🔁 EXISTING ITEM FOUND → $name");
        print("   Old Qty: $oldQty → New Qty: $newQty");
        print("   EBT (existing or new): $mergedEbt");

        products[existingIndex] = {
          ...existing,
          'quantity': newQty,
          'is_ebt_eligible': mergedEbt,
          'price': mergedLinePrice,
          'tax_status': itemTaxStatus,
          'tax_class': existing['tax_class'] ?? effectiveTaxClass,
          'tax_rate': itemTaxRate,

          // 🔥 UPDATE TAX
          'item_tax': itemTax,
          if (incomingWeighted || existingWeighted)
            'weight_qty': mergedWeightQty,
        };

        print("🔁 SAME PRODUCT → Qty incremented.");
      } else {
        print("🆕 ADDING NEW PRODUCT → $name");
        print("   EBT Eligible: $isEbtEligible");

        products.add({
          'server_item_id': serverItemId,
          'name': name,
          'image': image,
          'price': price,
          'quantity': (type ?? '').toString().toLowerCase().contains('weighted')
              ? 1
              : quantity,
          'sku': sku,
          'type': (variationId != null && variationId > 0)
              ? 'variant'
              : (type ?? 'product'),

          'product_id': productId,
          // ✅ ADD ALL THREE KEYS (safe + backward compatible)
          'variation_id': variationId,
          'item_variation': variationId,
          'variationId': variationId,

          'variation_name': variationName,
          'variation_count': variationCount,
          'combo': combo,
          'sales_price': salesPrice,
          'regular_price': regularPrice,
          'unit_price': unitPrice,
          if ((type ?? '').toString().toLowerCase().contains('weighted'))
            'weight_qty': weightQty ??
                ((unitPrice != null && unitPrice > 0)
                    ? (price / unitPrice)
                    : 0.0),

          /// ⭐ NOW SAVED CORRECTLY
          'is_ebt_eligible': isEbtEligible,
          'tax_status':
              effectiveTaxStatus.isEmpty ? "taxable" : effectiveTaxStatus,
          'tax_class': effectiveTaxClass,
          'tax_rate': effectiveTaxRate,

          // Discount fields (0 for new items; preserve when merged from existing)
          'auto_discount': 0.0,
          'auto_discount_total': 0.0,
          'multipack_discount_total': 0.0,
          'combo_discount_total': 0.0,
        });
      }

      print("💾 ORDER UPDATED → Product Count: ${products.length}");
      for (var p in products) {
        print(
            "   ▶ ${p['name']} | Qty: ${p['quantity']} | EBT: ${p['is_ebt_eligible']}");
      }

      final updatedOrder = <String, dynamic>{...order, 'products': products};

      await saveOfflineOrder(orderId, updatedOrder);

      final double subtotal =
          (updatedOrder['gross_total'] as num?)?.toDouble() ?? 0.0;
      final double tax = (updatedOrder['order_tax'] as num?)?.toDouble() ?? 0.0;
      final double total =
          (updatedOrder['net_payable'] as num?)?.toDouble() ?? 0.0;

// refresh UI FIRST
      notifyOrderPanelToRefresh();
      if (onItemAdded != null) onItemAdded();

      try {
        await const MethodChannel(
          'com.alekta.pinakapos/sunmi_display',
        ).invokeMethod(
          'showCustomerData',
          {
            'orderId': orderId,
            'items': products,
            'grossTotal': subtotal,
            'discount': (updatedOrder['discount'] as num?)?.toDouble() ?? 0.0,
            'merchantDiscount':
                (updatedOrder['merchant_discount'] as num?)?.toDouble() ?? 0.0,
            'netTotal':
                (updatedOrder['net_total'] as num?)?.toDouble() ?? subtotal,
            'tax': tax,
            'netPayable': total,
            'orderDate': updatedOrder['order_date']?.toString() ?? '',
            'orderTime': updatedOrder['order_time']?.toString() ?? '',
            'cashbackFee':
                (updatedOrder['cashback_fee'] as num?)?.toDouble() ?? 0.0,
            'loyaltyContact': updatedOrder['loyalty_contact']?.toString() ?? '',
            'availablePoints':
                (updatedOrder['available_points'] as num?)?.toInt() ?? 0,
            'summaryEnabled': false,
          },
        );
      } catch (e) {
        print("Customer display unavailable: $e");
      }
      notifyOrderPanelToRefresh();
      if (onItemAdded != null) onItemAdded();
    } finally {
      _activeAdds.remove(key);
    }
  }

  static Map<String, dynamic> _inMemoryProductCache = {};

  static String normalizeSku(String s) {
    return s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-]'), '');
  }

  ///
  // Future<void> addItemToOrder(
  //   int? serverItemId,
  //   String name,
  //   String image,
  //   double price,
  //   int quantity,
  //   String sku,
  //   int orderId, {
  //   VoidCallback? onItemAdded,
  //   String? type,
  //   int? productId = -1,
  //   int? variationId = -1,
  //   String? variationName,
  //   int? variationCount,
  //   String? combo,
  //   double? salesPrice,
  //   double? regularPrice,
  //   double? unitPrice,
  //   bool isEbtEligible = false,
  //   String? taxStatus,
  //   String? taxClass,
  //   double? taxRate,
  // }) async {
  //   print("🍏 addItemToOrder() CALLED for: $name | EBT: $isEbtEligible");

  //   final key = '$orderId-$productId-$variationId';

  //   // 🛡 Prevent double execution
  //   if (_activeAdds.contains(key)) {
  //     print("⚠ Duplicate addItemToOrder ignored for $key");
  //     return;
  //   }
  //   _activeAdds.add(key);

  //   try {
  //     // Block adding items to orders that have payments (pending orders)
  //     final payments =
  //         await LocalPaymentDBHelper.instance.getPaymentsByOrderId(orderId);
  //     if (payments.isNotEmpty) {
  //       if (kDebugMode) {
  //         print(
  //             "⚠ addItemToOrder blocked: order $orderId has payments (pending) - cannot add line items");
  //       }
  //       return;
  //     }

  //     final box = StorageProvider.offlineOrders;
  //     final rawOrder = await box.get(orderId.toString());
  //     if (rawOrder == null || rawOrder is! Map) {
  //       print("⚠ No offline order found for $orderId");
  //       return;
  //     }
  //     final order = Map<String, dynamic>.from(rawOrder);

  //     // Clone products
  //     final List<Map<String, dynamic>> products = (order['products'] ?? [])
  //         .map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p))
  //         .toList();

  //     final normProductId = (productId ?? -1).toInt();
  //     final normVariationId = (variationId ?? 0).toInt();

  //     // Find existing item to merge quantity (scan/search/selection)
  //     final existingIndex = products.indexWhere((p) {
  //       final pid = (p['product_id'] ?? p['id'] ?? -1);
  //       final vid = (p['variation_id'] ?? p['item_variation'] ?? 0);
  //       final matchesIds = pid == normProductId && vid == normVariationId;

  //       // If it's a custom item (productId 0 or -1), we MUST also match the SKU
  //       if (normProductId == 0 || normProductId == -1) {
  //         final storedSku = normalizeSku(p['sku']?.toString() ?? '');
  //         final newSku = normalizeSku(sku);
  //         return matchesIds && storedSku == newSku;
  //       }
  //       return matchesIds;
  //     });

  //     if (existingIndex != -1) {
  //       final existing = products[existingIndex];
  //       final oldQty = (existing['quantity'] ?? 0).toInt();
  //       final newQty = oldQty + quantity;

  //       final mergedEbt =
  //           (existing['is_ebt_eligible'] == true) || (isEbtEligible == true);

  //       print("🔁 EXISTING ITEM FOUND → $name");
  //       print("   Old Qty: $oldQty → New Qty: $newQty");
  //       print("   EBT (existing or new): $mergedEbt");

  //       products[existingIndex] = {
  //         ...existing,
  //         'quantity': newQty,
  //         'is_ebt_eligible': mergedEbt,
  //         'price': existing['price'],
  //       };

  //       print("🔁 SAME PRODUCT → Qty incremented.");
  //     } else {
  //       print("🆕 ADDING NEW PRODUCT → $name");
  //       print("   EBT Eligible: $isEbtEligible");

  //       products.add({
  //         'server_item_id': serverItemId,
  //         'name': name,
  //         'image': image,
  //         'price': price,
  //         'quantity': quantity,
  //         'sku': sku,
  //         'type': (variationId != null && variationId > 0)
  //             ? 'variant'
  //             : (type ?? 'product'),

  //         'product_id': productId,
  //         // ✅ ADD ALL THREE KEYS (safe + backward compatible)
  //         'variation_id': variationId,
  //         'item_variation': variationId,
  //         'variationId': variationId,

  //         'variation_name': variationName,
  //         'variation_count': variationCount,
  //         'combo': combo,
  //         'sales_price': salesPrice,
  //         'regular_price': regularPrice,
  //         'unit_price': unitPrice,

  //         /// ⭐ NOW SAVED CORRECTLY
  //         'is_ebt_eligible': isEbtEligible,
  //         'tax_status': taxStatus,
  //         'tax_class': taxClass,
  //         'tax_rate': taxRate,

  //         // Discount fields (0 for new items; preserve when merged from existing)
  //         'auto_discount': 0.0,
  //         'auto_discount_total': 0.0,
  //         'multipack_discount_total': 0.0,
  //         'combo_discount_total': 0.0,
  //       });
  //     }

  //     print("💾 ORDER UPDATED → Product Count: ${products.length}");
  //     for (var p in products) {
  //       print(
  //           "   ▶ ${p['name']} | Qty: ${p['quantity']} | EBT: ${p['is_ebt_eligible']}");
  //     }

  //     final updatedOrder = <String, dynamic>{...order, 'products': products};

  //     // Calculate totals and save to Hive + Memory
  //     await saveOfflineOrder(orderId, updatedOrder);

  //     notifyOrderPanelToRefresh();
  //     if (onItemAdded != null) onItemAdded();
  //   } finally {
  //     _activeAdds.remove(key);
  //   }
  // }

  // static Map<String, dynamic> _inMemoryProductCache = {};

  // static String normalizeSku(String s) {
  //   return s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-]'), '');
  // }

  static void addToCache(
    String sku,
    Map<String, dynamic> productJson, {
    int? variationId,
  }) {
    final normalizedSku = normalizeSku(sku);

    _inMemoryProductCache[normalizedSku] = {
      "product": productJson,
      "variation_id": variationId, // ✅ CRITICAL FIX
    };

    if (kDebugMode) {
      print("🔥 Updated in-memory product cache");
      print("   SKU → $normalizedSku");
      print("   Variation → $variationId");
    }
  }

  static Map<String, dynamic>? getFromCache(String sku) {
    return _inMemoryProductCache[normalizeSku(sku)];
  }

  static void removeFromCache(String sku) {
    final key = normalizeSku(sku); // 🔥 USE SAME NORMALIZATION

    if (_inMemoryProductCache.containsKey(key)) {
      _inMemoryProductCache.remove(key);
      print("🧹 MEMORY CACHE CLEARED for SKU → $key");
    } else {
      print("⚠ MEMORY CACHE KEY NOT FOUND → $key");
    }
  }

  static Future<bool> existsInOrderBySku(int orderId, String sku) async {
    final box = StorageProvider.offlineOrders;
    final order = await box.get(orderId.toString());

    if (order == null || order["products"] == null) return false;

    final normalized = normalizeSku(sku);

    for (final p in order["products"]) {
      final storedSku = (p["sku"] ??
              p["item_sku"] ??
              p["product_sku"] ??
              p["fast_key_item_sku"] ??
              "")
          .toString();

      final storedSkuNormalized = normalizeSku(storedSku);

      if (storedSkuNormalized == normalized) {
        return true; // MATCH FOUND → PRODUCT ALREADY EXISTS
      }
    }

    return false; // NO MATCH
  }

  Future<bool> orderHasItems(int orderId) async {
    try {
      final db = await DBHelper.instance.database;

      // 🧾 Check if the order has any associated items in order_items table
      final List<Map<String, dynamic>> items = await db.query(
        AppDBConst
            .orderTable, // ✅ Replace with your correct order items table name constant
        where: '${AppDBConst.orderServerId} = ?',
        whereArgs: [orderId],
        limit: 1, // Optimization: we only need to know if at least one exists
      );

      final hasItems = items.isNotEmpty;

      if (kDebugMode) {
        print("🧾 [ORDER CHECK] Order ID $orderId has items: $hasItems");
      }

      return hasItems;
    } catch (e, s) {
      if (kDebugMode) {
        print(
            "❌ [orderHasItems] Failed to check items for Order ID $orderId: $e\n$s");
      }
      return false;
    }
  }

  @Deprecated("Removed from current version, please use Rest API to update")
  //Build 1.1.36: required this func for issue of Edit item not updating count in order panel
  Future<void> updateItemQuantity(int itemId, int newQuantity) async {
    final db = await DBHelper.instance.database;

    // Fetch the item's current price to calculate the new sum price
    final item = await db.query(
      AppDBConst.purchasedItemsTable,
      where: '${AppDBConst.itemId} = ?',
      whereArgs: [itemId],
    );

    if (item.isNotEmpty) {
      double price = (item.first[AppDBConst.itemPrice] as num).toDouble();
      double newSumPrice = price * newQuantity;

      // Update the quantity and sum price in the database
      await db.update(
        AppDBConst.purchasedItemsTable,
        {
          AppDBConst.itemCount: newQuantity,
          AppDBConst.itemSumPrice: newSumPrice,
        },
        where: '${AppDBConst.itemId} = ?',
        whereArgs: [itemId],
      );

      // Update the order total in the orders table
      final items =
          await getOrderItems(item.first[AppDBConst.orderIdForeignKey] as int);
      double orderTotal = items.fold(
          0.0,
          (sum, item) =>
              sum + (item[AppDBConst.itemSumPrice] as num).toDouble());

      await db.update(
        AppDBConst.orderTable,
        {AppDBConst.orderTotal: orderTotal},
        where: '${AppDBConst.orderId} = ?',
        whereArgs: [item.first[AppDBConst.orderIdForeignKey]],
      );

      if (kDebugMode) {
        print(
            '#### Item quantity updated: ID=$itemId, Quantity=$newQuantity, New Sum Price=$newSumPrice');
        print(
            '#### Order total updated: Order ID=${item.first[AppDBConst.orderIdForeignKey]}, Total=$orderTotal');
      }
    }
  }

// If using a StatefulWidget
// Future<void> updateItemQuantity(int itemId, int quantity) async {
//   final db = await DBHelper.instance.database;
//
//   // Calculate the new sum price based on the updated quantity
//   final item = await db.query(
//     AppDBConst.purchasedItemsTable,
//     where: '${AppDBConst.itemId} = ?',
//     whereArgs: [itemId],
//   );
//
//   if (item.isNotEmpty) {
//     double price = (item.first[AppDBConst.itemPrice] as num).toDouble();
//     double newSumPrice = price * quantity;
//
//     await db.update(
//         AppDBConst.purchasedItemsTable,
//         {
//           AppDBConst.itemCount: quantity,
//           AppDBConst.itemSumPrice: newSumPrice
//         },
//         where: '${AppDBConst.itemId} = ?',
//         whereArgs: [itemId]
//     );
//
//     if (kDebugMode) {
//       print('#### Item quantity updated: ID=$itemId, Quantity=$quantity');
//     }
//
//     // After database update, refresh the UI
//     // setState(() {
//     //   // If needed, update any widget state variables here
//     // });
//
//     // Or if using a provider
//     // Provider.of<YourProvider>(context, listen: false).refreshItems();
//   }
// }

// Add this method in OrderHelper class
  static Map<String, dynamic> buildLineItemForApi(Map<String, dynamic> item) {
    final String itemType = (item[AppDBConst.itemType] ?? item['type'] ?? '')
        .toString()
        .toLowerCase();

    if (itemType.contains('custom')) {
      final int productId = int.tryParse(item['product_id']?.toString() ??
              item[AppDBConst.itemProductId]?.toString() ??
              '0') ??
          60303;

      final String taxStatus =
          (item['tax_status']?.toString() ?? 'none').toLowerCase();

      final String name =
          item[AppDBConst.itemName] ?? item['name'] ?? "Custom Item";
      final int quantity = item['quantity'] ?? item[AppDBConst.itemCount] ?? 1;
      final double sumPrice =
          (item[AppDBConst.itemSumPrice] ?? item['price'] ?? 0.0).toDouble();

      final Map<String, dynamic> line = {
        "product_id": productId,
        "name": name,
        "quantity": quantity,
        "subtotal": sumPrice.toStringAsFixed(2),
        "total": sumPrice.toStringAsFixed(2),
        "tax_status": taxStatus,
        "type": "custom",
      };

      final String sku = item['sku']?.toString() ?? '';
      if (sku.isNotEmpty) {
        line["sku"] = sku;
      }

      return line;
    }

    // Normal product (unchanged)
    return {
      "product_id": item['product_id'] ?? item[AppDBConst.itemProductId],
      "quantity": item['quantity'] ?? item[AppDBConst.itemCount] ?? 1,
      "total": (item[AppDBConst.itemSumPrice] ?? item['price'] ?? 0.0)
          .toStringAsFixed(2),
      "subtotal": (item[AppDBConst.itemSumPrice] ?? item['price'] ?? 0.0)
          .toStringAsFixed(2),
      "name": item[AppDBConst.itemName] ?? item['name'],
      "meta_data": item['meta_data'] ?? [],
    };
  }

  Future<void> deleteOrderWithItems(int orderId) async {
    final db = await DBHelper.instance.database;

    // 1. Delete order items (purchased_items_table)
    await db.delete(
      AppDBConst.purchasedItemsTable,
      where: '${AppDBConst.orderIdForeignKey} = ?',
      whereArgs: [orderId],
    );

    // 2. Delete the order itself
    await db.delete(
      AppDBConst.orderTable,
      where: '${AppDBConst.orderServerId} = ?',
      whereArgs: [orderId],
    );

    // 3. Also clean up Isar payments and Hive offline data
    // await LocalPaymentDBHelper.instance.deletePaymentsByOrderId(orderId);
    final box = StorageProvider.offlineOrders;
    await box.delete(orderId.toString());

    // 4. Refresh in-memory lists
    await loadData();
    notifyOrderPanelToRefresh();

    print("✅ Order $orderId and all items deleted.");
  }
}

//this is original grocery_v2 code
