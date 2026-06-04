import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dotted_line/dotted_line.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_barcode_listener/flutter_barcode_listener.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_svg/svg.dart';
import 'package:pinaka_pos/Database/storage/storage_provider.dart';
import 'package:intl/intl.dart'; // Added for date formatting
import 'package:pinaka_pos/Database/assets_db_helper.dart';
import 'package:pinaka_pos/Helper/Extentions/extensions.dart';
import 'package:pinaka_pos/Screens/Home/redeem_points_popup_screen.dart';
import 'package:pinaka_pos/Utilities/printer_settings.dart';
import 'package:provider/provider.dart';
import 'package:thermal_printer/esc_pos_utils_platform/esc_pos_utils_platform.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../Blocs/Orders/order_bloc.dart';
import '../../Blocs/Payment/payment_bloc.dart';
import '../../Constants/misc_features.dart';
import '../../Constants/text.dart';
import '../../Database/db_helper.dart';
import '../../Database/order_panel_db_helper.dart';
import '../../Database/printer_db_helper.dart';
import '../../Database/store_db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Helper/api_response.dart';
import '../../Helper/customerdisplayhelper.dart';
import '../../Models/Payment/payment_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Orders/order_repository.dart';
import '../../Repositories/Payment/payment_repository.dart';
import '../../Utilities/global_utility.dart';
import '../../Utilities/responsive_layout.dart';
import '../../Utilities/result_utility.dart';
import '../../Utilities/svg_images_utility.dart';
import '../../Widgets/PaymentNumPad.dart';
import '../../Widgets/offline_order_sync_service.dart';
import '../../Widgets/scanner_guard.dart';
import '../../Widgets/widget_custom_num_pad.dart';
import '../../Widgets/widget_payment_dialog.dart';
import '../../Widgets/widget_topbar.dart';
import '../../services/CustomerDisplayService.dart';
import '../../services/customer_services.dart';
import '../Auth/login_screen.dart';
import 'Settings/image_utils.dart';
import 'Settings/printer_setup_screen.dart';
import 'categories_screen.dart';
import 'edit_product_screen.dart';
import 'package:android_intent_plus/android_intent.dart';

import 'package:thermal_printer/thermal_printer.dart';

import 'pos_home_screen.dart';
import 'isar_payments/local_payments_db_helper.dart';
import 'isar_payments/local_payments_model.dart';

class LastPaymentInfo {
  final String method;
  final double amount;
  late final String? paymentId;

  // ⭐ SUNMI FIELDS
  final String? sunmiTxnId;
  final String? sunmiOrderId;
  final String? sunmiDeviceId; // ⭐ ADD THIS

  LastPaymentInfo({
    required this.method,
    required this.amount,
    this.paymentId,
    this.sunmiTxnId,
    this.sunmiOrderId,
    this.sunmiDeviceId,
  });

  Map<String, dynamic> toJson() => {
    "method": method,
    "amount": amount,
    "paymentId": paymentId,
    "sunmiTxnId": sunmiTxnId,
    "sunmiOrderId": sunmiOrderId,
    "sunmiDeviceId": sunmiDeviceId,
  };

  factory LastPaymentInfo.fromJson(Map<String, dynamic> json) {
    return LastPaymentInfo(
      method: json["method"],
      amount: (json["amount"] as num).toDouble(),
      paymentId: json["paymentId"],
      sunmiTxnId: json["sunmiTxnId"],
      sunmiOrderId: json["sunmiOrderId"],
      sunmiDeviceId: json["sunmiDeviceId"],
    );
  }
}

/// SQLite / Hive often store flags as 0/1; summary UI used strict `== true`.
bool _orderSummaryLineEbtEligible(Map<String, dynamic> item) {
  bool truthy(dynamic v) {
    if (v == true || v == 1) return true;
    if (v is String) {
      final s = v.toLowerCase().trim();
      return s == '1' || s == 'true' || s == 'yes';
    }
    return false;
  }

  return truthy(item['is_ebt_eligible']) || truthy(item['ebt_eligible']);
}

/// Issued (generate for customer) → `generate_type` false. Redeemed on order → true.
bool _couponHiveEntryIsRedeem(Map<String, dynamic> c) {
  final gt = c['generate_type'];
  if (gt == true) return true;
  if (gt == false) return false;
  final keys = c.keys.toSet();
  return keys.length == 1 && keys.contains('code');
}

Map<String, dynamic> _mergeRedeemIntoCouponResponse(
    dynamic prevCouponResponse,
    String redeemCode,
    ) {
  Map<String, dynamic> base = {};
  if (prevCouponResponse is Map) {
    base = Map<String, dynamic>.from(prevCouponResponse);
  }
  final prevCoupons = <Map<String, dynamic>>[];
  final rawList = base['coupons'];
  if (rawList is List) {
    for (final x in rawList) {
      if (x is Map) {
        prevCoupons.add(Map<String, dynamic>.from(x));
      }
    }
  }
  final trimmed = redeemCode.trim();
  final keptIssued =
  prevCoupons.where((c) => !_couponHiveEntryIsRedeem(c)).toList();
  final otherRedeems = prevCoupons
      .where((c) =>
  _couponHiveEntryIsRedeem(c) &&
      c['code']?.toString().trim() != trimmed)
      .toList();
  base['coupons'] = [
    ...keptIssued,
    ...otherRedeems,
    <String, dynamic>{'code': redeemCode, 'generate_type': true},
  ];
  return base;
}

void _enrichRedeemCouponIdsFromWoo(
    Map<String, dynamic> offlineOrder,
    Map<String, dynamic> wooResult,
    String appliedCode,
    ) {
  final cr = offlineOrder['coupon_response'];
  if (cr is! Map) return;
  final map = Map<String, dynamic>.from(cr);
  final coupons = map['coupons'];
  if (coupons is! List) return;
  final lines = wooResult['coupon_lines'] as List? ?? [];
  final trimmed = appliedCode.trim();
  final updated = <dynamic>[];
  for (final c in coupons) {
    if (c is! Map) {
      updated.add(c);
      continue;
    }
    final m = Map<String, dynamic>.from(c);
    if (m['generate_type'] == true &&
        m['code']?.toString().trim() == trimmed) {
      for (final line in lines) {
        if (line is! Map) continue;
        if (line['code']?.toString().trim() == trimmed) {
          final wid = line['id'];
          if (wid != null) m['id'] = wid;
          break;
        }
      }
    }
    updated.add(m);
  }
  map['coupons'] = updated;
  offlineOrder['coupon_response'] = map;
}

int _orderSummaryLineVariationId(Map<String, dynamic> item) {
  final raw = item['variation_id'] ??
      item['variationId'] ??
      item['item_variation_id'] ??
      item['item_variation'] ??
      0;
  final v = raw is num ? raw.toInt() : int.tryParse(raw.toString()) ?? 0;
  return v < 0 ? 0 : v;
}

String _orderSummaryLineVariationName(Map<String, dynamic> item) {
  final n = item['variation_name'] ??
      item['item_variation_custom_name'] ??
      item['attribute_variant'];
  return n?.toString().trim() ?? '';
}

String _orderSummaryNormalizeSku(dynamic raw) {
  return (raw ?? '').toString().trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
}

bool _cachedProductMapIndicatesEbt(Map<String, dynamic> p) {
  if (_orderSummaryLineEbtEligible(p)) return true;
  final meta = p['meta_data'];
  if (meta is List) {
    for (final x in meta) {
      if (x is! Map) continue;
      final key = (x['key'] ?? '').toString().toLowerCase();
      if (key != 'is_ebt_eligible' &&
          key != '_is_ebt_eligible' &&
          key != '_ebt_eligible') {
        continue;
      }
      final v = x['value'];
      if (v == true || v == 1) return true;
      if (v is String) {
        final s = v.toLowerCase().trim();
        if (s == '1' || s == 'true' || s == 'yes') return true;
      }
    }
  }
  final tags = p['tags'];
  if (tags is List) {
    for (final t in tags) {
      if (t is! Map) continue;
      final name = (t['name'] ?? '').toString().toLowerCase();
      final slug = (t['slug'] ?? '').toString().toLowerCase();
      if (name.contains('ebt') || slug.contains('ebt')) return true;
    }
  }
  return false;
}

/// When SQLite/Hive mismatch left lines without badges, use TopBar merged product list (same as POS search).
Future<void> _mergeOrderSummaryLineItemsFromProductCache(
    List<Map<String, dynamic>> lineItems,
    ) async {
  try {
    final all = await TopBar.mergedCachedProductsForSearch();
    final byId = <int, Map<String, dynamic>>{};
    for (final raw in all) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final idRaw = m['fast_key_product_id'] ?? m['product_id'] ?? m['id'];
      final id = idRaw is int ? idRaw : int.tryParse(idRaw?.toString() ?? '');
      if (id != null && id > 0) {
        byId[id] = m;
      }
    }

    for (final line in lineItems) {
      final lt = (line['item_type'] ?? '').toString().toLowerCase();
      final nm = (line[AppDBConst.itemName] ?? line['item_name'] ?? '')
          .toString()
          .toLowerCase();
      if (lt.contains('discount') ||
          lt.contains('coupon') ||
          lt.contains('payout') ||
          lt.contains('cashback') ||
          lt.contains('loyalty') ||
          nm.contains('merchant discount')) {
        continue;
      }

      final pidRaw = line['product_id'] ??
          line[AppDBConst.itemProductId] ??
          line['item_product_id'];
      final int? pid =
      pidRaw is int ? pidRaw : int.tryParse(pidRaw?.toString() ?? '');
      if (pid == null || pid <= 0) continue;

      final p = byId[pid];
      if (p == null) continue;

      if (!_orderSummaryLineEbtEligible(line) && _cachedProductMapIndicatesEbt(p)) {
        line['is_ebt_eligible'] = 1;
        line['ebt_eligible'] = 1;
      }

      // Only back-fill variant badges from cache for real child variations.
      // Do not use parent_id != null — API/maps often send parent_id: 0, which
      // incorrectly marked every simple product as a variant.
      if (_orderSummaryLineVariationId(line) <= 0 &&
          _orderSummaryLineVariationName(line).isEmpty) {
        final typeStr = (p['type'] ?? '').toString().toLowerCase();
        final parentRaw = p['parent_id'];
        final parentId = parentRaw is int
            ? parentRaw
            : int.tryParse(parentRaw?.toString() ?? '') ?? 0;
        final isChildVariation = (typeStr == 'variation' ||
            typeStr == 'variant') &&
            parentId > 0;
        if (!isChildVariation) continue;

        final vId = int.tryParse(
          (p['id'] ?? p['variation_id'] ?? 0).toString(),
        ) ??
            0;
        if (vId <= 0) continue;

        line['variation_id'] = vId;
        line['variationId'] = vId;
        line['item_variation_id'] = vId;
        line['item_variation'] = vId;
        final vName = (p['name'] ?? '').toString().trim();
        if (vName.isNotEmpty) {
          line['variation_name'] = vName;
          line['item_variation_custom_name'] = vName;
          line['attribute_variant'] = vName;
        }
        line['is_variant'] = 1;
        final lType = (line['item_type'] ?? '').toString().toLowerCase();
        if (lType.isEmpty || lType == 'product') {
          line['item_type'] = 'variant';
        }
      }
    }
  } catch (_) {}
}


/// Pending orders often load line items from SQLite without EBT/variation flags
/// while the same cart still exists in Hive `products`. Merge so badges match the order panel.
void _mergeOrderSummaryLineItemsFromHive(
    List<Map<String, dynamic>> lineItems,
    Map<String, dynamic>? hiveOrder,
    ) {
  if (hiveOrder == null) return;
  final rawProducts = hiveOrder['products'];
  if (rawProducts is! List || rawProducts.isEmpty) return;

  for (final line in lineItems) {
    final name =
    (line[AppDBConst.itemName] ?? line['item_name'] ?? '').toString().trim();
    final pidRaw = line['product_id'] ??
        line[AppDBConst.itemProductId] ??
        line['item_product_id'];
    final int? pid = pidRaw is int
        ? pidRaw
        : int.tryParse(pidRaw?.toString() ?? '');

    Map<String, dynamic>? matched;
    for (final p in rawProducts) {
      if (p is! Map) continue;
      final m = Map<String, dynamic>.from(p);
      final pPidRaw = m['product_id'] ?? m['id'];
      final pPid = pPidRaw is int
          ? pPidRaw
          : int.tryParse(pPidRaw?.toString() ?? '');
      if (pid != null && pPid != null && pPid == pid) {
        matched = m;
        break;
      }
    }
    if (matched == null && name.isNotEmpty) {
      for (final p in rawProducts) {
        if (p is! Map) continue;
        final m = Map<String, dynamic>.from(p);
        if ((m['name'] ?? '').toString().trim() == name) {
          matched = m;
          break;
        }
      }
    }
    if (matched == null) {
      final lineSku = _orderSummaryNormalizeSku(
        line[AppDBConst.itemSKU] ?? line['sku'],
      );
      if (lineSku.isNotEmpty) {
        for (final p in rawProducts) {
          if (p is! Map) continue;
          final m = Map<String, dynamic>.from(p);
          if (_orderSummaryNormalizeSku(m['sku']) == lineSku) {
            matched = m;
            break;
          }
        }
      }
    }
    if (matched == null) continue;

    if (!_orderSummaryLineEbtEligible(line)) {
      final dynamic ebt = matched['is_ebt_eligible'];
      if (ebt == true ||
          ebt == 1 ||
          (ebt is String &&
              (ebt == '1' || ebt.toLowerCase() == 'true'))) {
        line['is_ebt_eligible'] = 1;
        line['ebt_eligible'] = 1;
      } else if (_cachedProductMapIndicatesEbt(matched)) {
        line['is_ebt_eligible'] = 1;
        line['ebt_eligible'] = 1;
      }
    }

    final dynamic vidRaw = matched['variation_id'] ??
        matched['variationId'] ??
        matched['item_variation'];
    int vNum = 0;
    if (vidRaw is num) {
      vNum = vidRaw.toInt();
    } else {
      vNum = int.tryParse(vidRaw?.toString() ?? '') ?? 0;
    }
    if (vNum < 0) vNum = 0;

    final vName = (matched['variation_name'] ?? '').toString().trim();
    final pType = (matched['type'] ?? '').toString().toLowerCase();

    final bool showVariantBadge = pType == 'variant' || vNum > 0;

    if (showVariantBadge) {
      if (vNum > 0) {
        line['variation_id'] = vNum;
        line['variationId'] = vNum;
        line['item_variation_id'] = vNum;
        line['item_variation'] = vNum;
      }
      if (vName.isNotEmpty) {
        line['variation_name'] = vName;
        line['item_variation_custom_name'] = vName;
        line['attribute_variant'] = vName;
      }
      line['is_variant'] = 1;
      final lt = (line['item_type'] ?? '').toString().toLowerCase();
      if (lt.isEmpty || lt == 'product') {
        if (pType == 'variant') {
          line['item_type'] = 'variant';
        }
      }
    }
  }
}

class OrderSummaryScreen extends StatefulWidget {
  final String formattedDate;
  final String formattedTime;
  final List<Map<String, dynamic>> orderItems;
  final double grossTotal;
  final double orderDiscount;
  final double merchantDiscount;
  final double orderTax;
  final double netPayable;
  final int? orderId;
  final bool isOfflineSynced;
  final int? offlineOrderId;
  final double cashbackFee;
  final double? balanceamount;
  final double ebtAmount; //  NEW
  final double discountAmount;
  final bool itemPricesAlreadyAdjusted;

  const OrderSummaryScreen({
    required this.formattedDate,
    required this.formattedTime,
    required this.orderItems,
    required this.grossTotal,
    required this.orderDiscount,
    required this.merchantDiscount,
    required this.orderTax,
    required this.netPayable,
    required this.orderId,
    required this.cashbackFee,
    required this.ebtAmount,
    this.isOfflineSynced = false,
    this.offlineOrderId,
    super.key,
    this.balanceamount,
    required this.discountAmount,
    this.itemPricesAlreadyAdjusted = false,
  });

  @override
  State<OrderSummaryScreen> createState() => _OrderSummaryScreenState();
}

class NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child; // prevents scrollbar from showing
  }
}

class _OrderSummaryScreenState extends State<OrderSummaryScreen> {
  List<Map<String, dynamic>> orderItems = [];
  String selectedPaymentMethod = "";
  TextEditingController amountController = TextEditingController();
  bool _paymentDialogShown = false;
  bool get isOrderPending => orderStatus == 'pending';
  LastPaymentInfo? _lastPayment;

  final PaymentBloc paymentBloc =
  PaymentBloc(PaymentRepository()); // Added PaymentBloc
  final ScrollController _scrollController = ScrollController();
  int? userId; // Build #1.0.29: To store user ID
  String? userDisplayName; // Build #1.0.29: To store user ID
  String? userRole;
  int? orderId; // server id from order table
  String? orderDateTime = "";
  double oldTax = 0.0;
  int shiftId = 1; // Hardcoded as per requirement
  int vendorId = 1; // Hardcoded as per requirement
  String serviceType = "default"; // Hardcoded as per requirement
  double total = 0.0;
  double orderTotal = 0.0; // Build #1.0.137
  String orderStatus = TextConstants.processing; // Build  #1.0.177
  double grossTotal = 0.0;
  double netTotal = 0.0;
  double payableAmount = 0.0;
  double balanceAmount = 0.0;
  double tenderAmount = 0.0; // Build #1.0.33 : added new variables
  double paidAmount = 0.0;
  double changeAmount = 0.0;
  double discount = 0.0; // Add this to track discount
  double merchantDiscount = 0.0; // Add this to track merchant discount
  double tax = 0.0;
  double cashback = 0.0;
  double servicecharges = 0.0;
  bool isRedeemActive = false;
  bool isCouponActive = false;
  bool isGiftReceiptActive = false;
  double cashbackFee = 0.0;
  bool isPhoneValid = false;
  bool isEmailValid = false;
  Map<String, dynamic>? loyaltyData;
  bool isAddLoading = false;
// ⭐ store full API data globally
  bool isPaymentDone = false;
  Map<String, dynamic> _order = {};
  bool couponPopupActive = false;
  bool _successPopupShown = false;
  bool isAddButtonEnabled = true;
  bool isButtonDisabled = false;

  final bool enableCardPayment = false;
  final bool enableWalletPayment = false;

  bool _isShowingPartialDialog = false;

  bool _isShowingPaymentDialog = false;
  bool _isVoiding = false;
  bool _isOrderSyncInProgress = false;
  String? _activeSyncOrderKey;
  DateTime? _lastOrderSyncAt;
  String? _lastSyncedOrderKey;

  double ebtTotal = 0.0;
  double payByEbt = 0.0; // ADD THIS
  TextEditingController ebtAmountController = TextEditingController();

  PaymentMode _paymentModeFromMethod(dynamic method) {
    final String m = (method ?? '').toString().trim().toLowerCase();
    if (m == TextConstants.ebtText.toLowerCase()) return PaymentMode.ebt;
    if (m == TextConstants.card.toLowerCase()) return PaymentMode.card;
    if (m == TextConstants.wallet.toLowerCase()) return PaymentMode.wallet;
    return PaymentMode.cash;
  }

  PaymentMode _currentDialogPaymentMode() {
    // Prefer the latest persisted payment method from the payment result path.
    final String? lastPaymentMethod = _lastPayment?.method;
    if (lastPaymentMethod != null && lastPaymentMethod.trim().isNotEmpty) {
      return _paymentModeFromMethod(lastPaymentMethod);
    }

    // Fallback to last in-memory progression details, then current selection.
    final dynamic lastMethod = _lastPaymentDetails?['method'];
    return _paymentModeFromMethod(lastMethod ?? selectedPaymentMethod);
  }

  static const bool offline_PAYMENT_SUCCESS = true; // ← toggle this

  bool _dialogGuard = false;
  bool _successDialogAlreadyShown = false;
  bool _partialDialogAlreadyShown = false;

  double NetTotal = 0.0;
  // AddED tax variable
  double payByCash = 0.0;
  double payByOther = 0.0;
  // String? orderStatus = ""; // Build #1.0.175: save orderStatus value
  StreamSubscription? _paymentListSubscription;
  bool isLoading = false; // Add this to track loading state
  bool isSummaryLoading = false;
  String?
  _processingPaymentMethod; // Track which payment method is currently processing
  // final TextEditingController _paymentController = TextEditingController();
  var _printerSettings = PrinterSettings();
  List<int> bytes = [];
  String? paymentId; // To store the transaction ID after wallet payment
  late OrderBloc orderBloc;
  bool _showFullSummary = false;
  String? _amountErrorText;
  bool _isAmountEntered = false;
  bool _userManuallyEnteredAmount = false;
  double payByCard = 0.0;
  Map<String, dynamic>? offlineOrder;

  double?
  _currentPaymentRemainingBalance; // Track remaining balance from current payment
  Map<String, dynamic>? _lastPaymentDetails; // Store details of last payment

  double discountValue = 0.0;

  // Determine the date and time to display
  String _displayDate = "";
  String _displayTime = "";
  int _rawAmount = 0;
  double computedNetPayable = 0.0;
// holds value in paise/cents, e.g. 2345
  bool showCustomerInput = false;
  final TextEditingController mobileController = TextEditingController();
  int availablePoints = 0; // from backend API
  double orderTotalAmount = 0.0; // from order helper / cart total
  bool isMobileValid = false;
  double redeemedValue = 0.0;
  bool isPaymentStarted = false;
  bool isRedeemAppliedFromApi = false;
  bool isCouponAppliedFromApi = false;
  double couponValue = 0;
  double couponDiscount = 0.0;

  bool _isProcessing = false; // Add this flag

  // Add this method to calculate actual balance from payment history

  // Future<void> _calculateBalanceFromPaymentHistory() async {
  //   try {
  //     if (orderId == null || orderId == 0) {
  //       setState(() {
  //         balanceAmount = computedNetPayable;
  //         _currentPaymentRemainingBalance = null;
  //         _lastPaymentDetails = null;
  //       });
  //       return;
  //     }
  //
  //     final payments =
  //     await LocalPaymentDBHelper.instance.getPaymentsByOrderId(orderId!);
  //     final box = StorageProvider.offlineOrders;
  //     final key = orderId.toString();
  //     final rawStored = await box.get(key);
  //     final stored = Map<String, dynamic>.from(rawStored is Map ? rawStored : {});
  //     final double originalEbt =
  //         (stored["originalEbt"] as num?)?.toDouble() ?? ebtTotal;
  //
  //     if (payments.isEmpty) {
  //       final double remainingEbt =
  //           (stored["remainingEbt"] as num?)?.toDouble() ?? originalEbt;
  //       setState(() {
  //         balanceAmount = computedNetPayable;
  //         _currentPaymentRemainingBalance = null;
  //         _lastPaymentDetails = null;
  //         payByEbt = 0.0;
  //         ebtTotal = remainingEbt;
  //       });
  //       return;
  //     }
  //
  //     payments.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  //
  //     double totalPaid = 0.0;
  //     double runningBalance = computedNetPayable;
  //     LocalPayment? lastPayment;
  //     double previousBalance = computedNetPayable;
  //
  //     print("\n📊 PAYMENT HISTORY PROGRESSION FOR ORDER #$orderId:");
  //     print("=" * 60);
  //     print("Starting Balance: \$${computedNetPayable.toStringAsFixed(2)}");
  //     print("-" * 60);
  //
  //     // Track balance progression
  //     for (var i = 0; i < payments.length; i++) {
  //       final payment = payments[i];
  //       final paymentAmount = payment.amount;
  //
  //       double balanceBeforePayment = runningBalance;
  //       totalPaid += paymentAmount;
  //       runningBalance -= paymentAmount;
  //       if (runningBalance < 0) runningBalance = 0.0;
  //
  //       lastPayment = payment;
  //
  //       print(
  //           "Payment ${i + 1}: ${payment.paymentMethod} - \$${paymentAmount.toStringAsFixed(2)}");
  //       print("  Balance Before: \$${balanceBeforePayment.toStringAsFixed(2)}");
  //       print("  Balance After: \$${runningBalance.toStringAsFixed(2)}");
  //       print("  " + "-" * 40);
  //
  //       previousBalance = balanceBeforePayment; // Store for next iteration
  //     }
  //
  //     // for (var i = 0; i < payments.length; i++) {
  //     //   final payment = payments[i];
  //     //   final paymentAmount = payment.amount;
  //     //   final isVoid = paymentAmount < 0; // or payment.status == 'void'
  //     //
  //     //   double balanceBeforePayment = runningBalance;
  //     //
  //     //   if (isVoid) {
  //     //     runningBalance -= paymentAmount; // subtract negative = add back
  //     //   } else {
  //     //     runningBalance -= paymentAmount;
  //     //     totalPaid += paymentAmount; // only count actual paid towards totalPaid
  //     //   }
  //     //
  //     //   if (runningBalance < 0) runningBalance = 0.0;
  //     //
  //     //   lastPayment = payment;
  //     //
  //     //   print("Payment ${i + 1}: ${payment.paymentMethod} - \$${paymentAmount.toStringAsFixed(2)}"
  //     //       "${isVoid ? ' (VOID)' : ''}");
  //     //   print("  Balance Before: \$${balanceBeforePayment.toStringAsFixed(2)}");
  //     //   print("  Balance After: \$${runningBalance.toStringAsFixed(2)}");
  //     //   print("  " + "-" * 40);
  //     //
  //     //   previousBalance = balanceBeforePayment;
  //     // }
  //
  //     double actualRemaining = computedNetPayable - totalPaid;
  //     if (actualRemaining < 0) actualRemaining = 0.0;
  //
  //     print("\n📈 FINAL SUMMARY:");
  //     print("Total Paid: \$${totalPaid.toStringAsFixed(2)}");
  //     print("Remaining Balance: \$${actualRemaining.toStringAsFixed(2)}");
  //     print(
  //         "Previous Balance Before Last Payment: \$${previousBalance.toStringAsFixed(2)}");
  //     print("=" * 60);
  //
  //     // Set last payment details with progression info
  //     if (lastPayment != null) {
  //       _lastPaymentDetails = {
  //         'amount': lastPayment.amount,
  //         'method': lastPayment.paymentMethod,
  //         'remainingBalance': actualRemaining,
  //         'previousBalance': previousBalance, //  ADD THIS
  //         'datetime': lastPayment.datetime,
  //         'paymentId': lastPayment.id,
  //         'totalPaid': totalPaid, //  ADD THIS
  //         'paymentNumber': payments.length, //  ADD THIS
  //       };
  //     }
  //
  //     setState(() {
  //       tenderAmount = totalPaid;
  //       balanceAmount = actualRemaining;
  //
  //       if (actualRemaining > 0) {
  //         _currentPaymentRemainingBalance = actualRemaining;
  //       } else {
  //         _currentPaymentRemainingBalance = null;
  //       }
  //
  //       // Payment method totals
  //       payByCash = payments
  //           .where((p) =>
  //       p.paymentMethod.toLowerCase() ==
  //           TextConstants.cash.toLowerCase())
  //           .fold(0.0, (sum, p) => sum + p.amount);
  //
  //       payByCard = payments
  //           .where((p) =>
  //       p.paymentMethod.toLowerCase() ==
  //           TextConstants.card.toLowerCase())
  //           .fold(0.0, (sum, p) => sum + p.amount);
  //
  //       payByEbt = payments
  //           .where((p) =>
  //       p.paymentMethod.toLowerCase() ==
  //           TextConstants.ebtText.toLowerCase())
  //           .fold(0.0, (sum, p) => sum + p.amount);
  //
  //       payByOther = payments
  //           .where((p) =>
  //       p.paymentMethod.toLowerCase() !=
  //           TextConstants.cash.toLowerCase() &&
  //           p.paymentMethod.toLowerCase() !=
  //               TextConstants.card.toLowerCase() &&
  //           p.paymentMethod.toLowerCase() !=
  //               TextConstants.ebtText.toLowerCase())
  //           .fold(0.0, (sum, p) => sum + p.amount);
  //
  //       // Match API-path logic: non-EBT overflow should reduce remaining EBT.
  //       final double nonEbtOrderValue =
  //       (computedNetPayable - originalEbt).clamp(0.0, double.infinity);
  //       final double nonEbtPaid = payByCash + payByOther;
  //       final double overflowToEbt =
  //       nonEbtPaid > nonEbtOrderValue ? nonEbtPaid - nonEbtOrderValue : 0.0;
  //       final double remainingEbt =
  //       (originalEbt - payByEbt).clamp(0.0, double.infinity);
  //       ebtTotal = (remainingEbt - overflowToEbt).clamp(0.0, double.infinity);
  //
  //       isPaymentStarted = totalPaid > 0;
  //     });
  //
  //     stored["originalEbt"] = originalEbt;
  //     stored["remainingEbt"] = ebtTotal;
  //     stored["redeemed_value"] = redeemedValue;   // ensure saved
  //     await box.put(key, stored);
  //   } catch (e, stackTrace) {
  //     if (kDebugMode) {
  //       print(" Error calculating balance from payment history: $e");
  //       print(stackTrace);
  //     }
  //     setState(() {
  //       balanceAmount = computedNetPayable;
  //       _currentPaymentRemainingBalance = null;
  //       _lastPaymentDetails = null;
  //
  //     });
  //   }
  // }

  // void _recalculateGrossAndNetFromLineItemDiscounts() {
  //   if (orderItems.isEmpty) return;
  //
  //   double toDouble(dynamic v) =>
  //       v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;
  //
  //   double recalculatedGrossTotal = 0.0;
  //   double totalLineItemDiscount = 0.0;
  //
  //   for (final item in orderItems) {
  //     final String itemType = (item['item_type'] ?? '').toString().toLowerCase();
  //     final String itemName = (item['item_name'] ?? '').toString().toLowerCase();
  //
  //     // Skip non-product lines for discount calculation
  //     if (itemType.contains('discount') ||
  //         itemType.contains('coupon') ||
  //         itemType.contains('payout') ||
  //         itemType.contains('cashback') ||
  //         itemType.contains('loyalty') ||
  //         itemName.contains('merchant discount')) {
  //       continue;
  //     }
  //
  //     final double itemSumPrice = toDouble(item['item_sum_price']);
  //     final double unitPrice = toDouble(item['item_price'] ?? item['price']);
  //     final int qty = (item['items_count'] ?? item['quantity'] ?? 1).toInt();
  //     final double lineOriginalTotal = unitPrice * qty;
  //
  //     // Use item_sum_price if available (more accurate from OrderScreenPanel)
  //     // Otherwise calculate from unit price × quantity
  //     final double lineGross = itemSumPrice > 0 ? itemSumPrice : lineOriginalTotal;
  //     recalculatedGrossTotal += lineGross;
  //
  //     final String dtype = (item['discount_type'] ?? '').toString().toLowerCase();
  //
  //     // Extract all discount types
  //     double autoDiscount = [
  //       item['auto_discount'],
  //       item['auto_discount_total'],
  //       item['autoDiscount'],
  //       item['autoDiscountTotal'],
  //       item['display_auto_discount'],
  //       item['_pos_auto_discount'],
  //     ].map((e) => toDouble(e)).fold(0.0, (a, b) => a + b);
  //
  //     double comboDiscount = [
  //       item['combo_discount_total'],
  //       item['comboDiscountTotal'],
  //       item['combo_discount'],
  //     ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     double mixMatchDiscount = [
  //       item['mixmatch_discount_total'],
  //       item['mixMatchDiscountTotal'],
  //       item['mixmatch_discount'],
  //     ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     double multipackDiscount = [
  //       item['multipack_discount_total'],
  //       item['multipackDiscountTotal'],
  //       item['multipack_discount'],
  //     ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     // Fix: backend sometimes moves discount into auto_discount for typed discounts
  //     if (dtype == 'mixmatch' && autoDiscount > 0 && mixMatchDiscount == 0) {
  //       mixMatchDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //     if (dtype == 'combo' && autoDiscount > 0 && comboDiscount == 0) {
  //       comboDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //     if (dtype == 'multipack' && autoDiscount > 0 && multipackDiscount == 0) {
  //       multipackDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //
  //     final double itemDiscount = autoDiscount + comboDiscount + mixMatchDiscount + multipackDiscount;
  //     totalLineItemDiscount += itemDiscount;
  //   }
  //
  //   // Only update if we have discounted items
  //   if (totalLineItemDiscount <= 0 && (recalculatedGrossTotal - grossTotal).abs() <= 0.01) {
  //     return;
  //   }
  //
  //   // CRITICAL FIX: Use recalculatedGrossTotal as the new gross total
  //   // This ensures the gross total reflects the PRE-discount total from item_sum_price
  //   final double newGrossTotal = recalculatedGrossTotal > 0 ? recalculatedGrossTotal : grossTotal;
  //
  //   // NetTotal = GrossTotal - LineItemDiscounts + OrderDiscount + MerchantDiscount
  //   final double newNetTotal = newGrossTotal - totalLineItemDiscount + discount + merchantDiscount;
  //   final double newNetPayable = newNetTotal + tax + cashbackFee;
  //
  //   if (kDebugMode) {
  //     print('── LINE-ITEM DISCOUNT RECALCULATION ──');
  //     print('   Original Gross Total      : $grossTotal');
  //     print('   Recalculated Gross Total  : $newGrossTotal');
  //     print('   Total Line Item Discounts : $totalLineItemDiscount');
  //     print('   Order Discount            : $discount');
  //     print('   Merchant Discount         : $merchantDiscount');
  //     print('   Tax                       : $tax');
  //     print('   Cashback Fee              : $cashbackFee');
  //     print('   New Net Total             : $newNetTotal');
  //     print('   New Net Payable           : $newNetPayable');
  //   }
  //
  //   setState(() {
  //     grossTotal = newGrossTotal - totalLineItemDiscount + discount ; ////===
  //     //newNetTotal.clamp(0.0, double.infinity); // post-discount value
  //     NetTotal = newNetTotal.clamp(0.0, double.infinity);      NetTotal = newNetTotal.clamp(0.0, double.infinity);
  //     computedNetPayable = newNetPayable.clamp(0.0, double.infinity);
  //     orderTotal = computedNetPayable;
  //
  //     // Only reset balanceAmount if no payment has been made yet
  //     if (tenderAmount <= 0) {
  //       balanceAmount = computedNetPayable;
  //     }
  //   });
  // }

  Future<void> _calculateBalanceFromPaymentHistory() async {
    try {
      if (orderId == null || orderId == 0) {
        setState(() {
          balanceAmount = computedNetPayable;
          _currentPaymentRemainingBalance = null;
          _lastPaymentDetails = null;

        });
        return;
      }

      final payments =
      await LocalPaymentDBHelper.instance.getPaymentsByOrderId(orderId!);
      final box = StorageProvider.offlineOrders;
      final key = orderId.toString();
      final rawStored = await box.get(key);
      final stored = Map<String, dynamic>.from(rawStored is Map ? rawStored : {});
      final double originalEbt =
          (stored["originalEbt"] as num?)?.toDouble() ?? ebtTotal;
      redeemedValue = (stored["redeemed_value"] as num?)?.toDouble() ?? 0.0;
      final double effectivePayable =
      (computedNetPayable - redeemedValue)
          .clamp(0.0, double.infinity);

      if (payments.isEmpty) {
        final double remainingEbt =
            (stored["remainingEbt"] as num?)?.toDouble() ?? originalEbt;
        stored["redeemed_value"] = redeemedValue;   // ensure saved

        setState(() {
          balanceAmount = effectivePayable;
          _currentPaymentRemainingBalance = null;
          _lastPaymentDetails = null;
          payByEbt = 0.0;
          ebtTotal = remainingEbt;
        });
        return;
      }

      payments.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      double totalPaid = 0.0;
      // double runningBalance = computedNetPayable;
      LocalPayment? lastPayment;

      // double effectivePayable =
      // (computedNetPayable - redeemedValue).clamp(0.0, double.infinity);

      double runningBalance = effectivePayable;
      double previousBalance = effectivePayable;

      print("\n📊 PAYMENT HISTORY PROGRESSION FOR ORDER #$orderId:");
      print("=" * 60);
      print("Starting Balance: \$${effectivePayable.toStringAsFixed(2)}");
      print("-" * 60);

      // Track balance progression
      for (var i = 0; i < payments.length; i++) {
        final payment = payments[i];
        final paymentAmount = payment.amount;

        double balanceBeforePayment = runningBalance;
        totalPaid += paymentAmount;
        runningBalance -= paymentAmount;
        if (runningBalance < 0) runningBalance = 0.0;

        lastPayment = payment;

        print(
            "Payment ${i + 1}: ${payment.paymentMethod} - \$${paymentAmount.toStringAsFixed(2)}");
        print("  Balance Before: \$${balanceBeforePayment.toStringAsFixed(2)}");
        print("  Balance After: \$${runningBalance.toStringAsFixed(2)}");
        print("  " + "-" * 40);

        previousBalance = balanceBeforePayment; // Store for next iteration
      }

      // for (var i = 0; i < payments.length; i++) {
      //   final payment = payments[i];
      //   final paymentAmount = payment.amount;
      //   final isVoid = paymentAmount < 0; // or payment.status == 'void'
      //
      //   double balanceBeforePayment = runningBalance;
      //
      //   if (isVoid) {
      //     runningBalance -= paymentAmount; // subtract negative = add back
      //   } else {
      //     runningBalance -= paymentAmount;
      //     totalPaid += paymentAmount; // only count actual paid towards totalPaid
      //   }
      //
      //   if (runningBalance < 0) runningBalance = 0.0;
      //
      //   lastPayment = payment;
      //
      //   print("Payment ${i + 1}: ${payment.paymentMethod} - \$${paymentAmount.toStringAsFixed(2)}"
      //       "${isVoid ? ' (VOID)' : ''}");
      //   print("  Balance Before: \$${balanceBeforePayment.toStringAsFixed(2)}");
      //   print("  Balance After: \$${runningBalance.toStringAsFixed(2)}");
      //   print("  " + "-" * 40);
      //
      //   previousBalance = balanceBeforePayment;
      // }

      double actualRemaining = effectivePayable - totalPaid;

      if (actualRemaining < 0) {
        actualRemaining = 0.0;
      }

      print("\n📈 FINAL SUMMARY:");
      print("Total Paid: \$${totalPaid.toStringAsFixed(2)}");
      print("Remaining Balance: \$${actualRemaining.toStringAsFixed(2)}");
      print(
          "Previous Balance Before Last Payment: \$${previousBalance.toStringAsFixed(2)}");
      print("=" * 60);

      // Set last payment details with progression info
      if (lastPayment != null) {
        _lastPaymentDetails = {
          'amount': lastPayment.amount,
          'method': lastPayment.paymentMethod,
          'remainingBalance': actualRemaining,
          'previousBalance': previousBalance, //  ADD THIS
          'datetime': lastPayment.datetime,
          'paymentId': lastPayment.id,
          'totalPaid': totalPaid, //  ADD THIS
          'paymentNumber': payments.length, //  ADD THIS
        };
      }

      setState(() {
        tenderAmount = totalPaid;
        balanceAmount = actualRemaining;

        if (actualRemaining > 0) {
          _currentPaymentRemainingBalance = actualRemaining;
        } else {
          _currentPaymentRemainingBalance = null;
        }

        // Payment method totals
        payByCash = payments
            .where((p) =>
        p.paymentMethod.toLowerCase() ==
            TextConstants.cash.toLowerCase())
            .fold(0.0, (sum, p) => sum + p.amount);

        payByCard = payments
            .where((p) =>
        p.paymentMethod.toLowerCase() ==
            TextConstants.card.toLowerCase())
            .fold(0.0, (sum, p) => sum + p.amount);

        payByEbt = payments
            .where((p) =>
        p.paymentMethod.toLowerCase() ==
            TextConstants.ebtText.toLowerCase())
            .fold(0.0, (sum, p) => sum + p.amount);

        payByOther = payments
            .where((p) =>
        p.paymentMethod.toLowerCase() !=
            TextConstants.cash.toLowerCase() &&
            p.paymentMethod.toLowerCase() !=
                TextConstants.card.toLowerCase() &&
            p.paymentMethod.toLowerCase() !=
                TextConstants.ebtText.toLowerCase())
            .fold(0.0, (sum, p) => sum + p.amount);

        // Match API-path logic: non-EBT overflow should reduce remaining EBT.
        final double nonEbtOrderValue =
        (computedNetPayable - originalEbt).clamp(0.0, double.infinity);
        final double nonEbtPaid = payByCash + payByOther;
        final double overflowToEbt =
        nonEbtPaid > nonEbtOrderValue ? nonEbtPaid - nonEbtOrderValue : 0.0;
        final double remainingEbt =
        (originalEbt - payByEbt).clamp(0.0, double.infinity);
        ebtTotal = (remainingEbt - overflowToEbt).clamp(0.0, double.infinity);

        isPaymentStarted = totalPaid > 0;
      });

      stored["originalEbt"] = originalEbt;
      stored["remainingEbt"] = ebtTotal;
      await box.put(key, stored);
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print(" Error calculating balance from payment history: $e");
        print(stackTrace);
      }
      setState(() {
        balanceAmount = computedNetPayable;
        _currentPaymentRemainingBalance = null;
        _lastPaymentDetails = null;
      });
    }
  }
  Future<void> _printPaymentHistorySummary() async {
    if (orderId == null || orderId == 0) return;

    final payments =
    await LocalPaymentDBHelper.instance.getPaymentsByOrderId(orderId!);

    if (payments.isEmpty) {
      print("📊 No payment history found for Order #$orderId");
      return;
    }

    // Sort by creation date ascending
    payments.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    print("\n" + "=" * 70);
    print("📊 PAYMENT SESSION HISTORY - ORDER #$orderId");
    print("=" * 70);

    double totalPaid = 0.0;
    double currentBalance = computedNetPayable;

    for (var i = 0; i < payments.length; i++) {
      final p = payments[i];
      totalPaid += p.amount;

      double balanceBefore = currentBalance;
      currentBalance -= p.amount;
      if (currentBalance < 0) currentBalance = 0.0;

      final isPartial = p.status == PaymentDbStatus.pending;
      final isSuccessful = p.status == PaymentDbStatus.completed;

      print("Session ${i + 1}. ${p.createdAt.toString().split(' ')[1]} | "
          "ID:${p.id} | ${p.paymentMethod} | "
          "Paid:\$${p.amount.toStringAsFixed(2)} | "
          "Balance: \$${balanceBefore.toStringAsFixed(2)} → \$${currentBalance.toStringAsFixed(2)} | "
          "Status:${p.status?.name ?? 'unknown'} | "
          "local_order_id: \$${p.orderId} |"
          "${isPartial ? '← PARTIAL' : ''}"
          "${isSuccessful ? '← COMPLETE' : ''}");
    }

    // Compute current balance
    final actualBalance = computedNetPayable - totalPaid;
    final displayBalance = actualBalance > 0 ? actualBalance : 0.0;

    print("--" * 70);
    print("SESSION SUMMARY:");
    print("Net Payable: \$${computedNetPayable.toStringAsFixed(2)}");
    print("Total Paid: \$${totalPaid.toStringAsFixed(2)}");
    print("Current Balance: \$${displayBalance.toStringAsFixed(2)}");
    print(
        "Active Session: ${_currentPaymentRemainingBalance != null ? 'Yes' : 'No'}");
    if (_currentPaymentRemainingBalance != null) {
      print(
          "Session Balance: \$${_currentPaymentRemainingBalance!.toStringAsFixed(2)}");
    }
    print("=" * 70 + "\n");
  }

  Future<void> _savePaymentToHive({
    required double amount,
    required String paymentMethod,
    required String transactionId,
    LocalPayment? localPayment,
  }) async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      print(" [SAVE] Starting for order: $key");
      print(" [SAVE] Amount: $amount, Method: $paymentMethod");

      // 1. Make sure the order exists in Hive
      if (!(await box.containsKey(key))) {
        print(" Order not found → creating new entry: $key");
        await _createOfflineOrderEntry(key);
      }

      // 2. Read current data (FRESH COPY)
      final existingOrder = await box.get(key);
      if (existingOrder == null) {
        print(" Failed to read order after creation");
        return;
      }

      var order = Map<String, dynamic>.from(existingOrder);

      print(
          " [SAVE] Current payments count: ${(order['payments'] as List?)?.length ?? 0}");

      // 3. Current totals
      double totalPaid = (order['total_paid'] as num?)?.toDouble() ?? 0.0;
      double remaining = (order['remaining_balance'] as num?)?.toDouble() ??
          computedNetPayable;

      // 4. Calculate new values
      final newPaid = totalPaid + amount;
      double newRemaining = remaining - amount;
      double newChange = 0.0;

      if (newRemaining <= 0) {
        newChange = amount - remaining;
        newRemaining = 0.0;
      }

      final isComplete = newRemaining <= 0;

      // 5. Update payment method counters
      double payCash = (order['pay_by_cash'] as num?)?.toDouble() ?? 0.0;
      double payCard = (order['pay_by_card'] as num?)?.toDouble() ?? 0.0;
      double payEbt = (order['pay_by_ebt'] as num?)?.toDouble() ?? 0.0;
      double payOther = (order['pay_by_other'] as num?)?.toDouble() ?? 0.0;

      switch (paymentMethod.toLowerCase()) {
        case 'cash':
          payCash += amount;
          break;
        case 'card':
          payCard += amount;
          break;
        case 'ebt':
          payEbt += amount;
          break;
        default:
          payOther += amount;
      }

      // 6. Create payment entry
      final now = DateTime.now();
      final ts = now.toIso8601String();

      final Map<String, dynamic> historyEntry = {
        'local_id': localPayment?.id ?? 0,
        'amount': amount,
        'method': paymentMethod,
        'datetime': ts,
        'transaction_id': transactionId,
        'remaining_after': newRemaining,
        'status': isComplete ? 'completed' : 'partial',
        'synced': localPayment?.isSynced ?? false,

        // Additional fields from LocalPayment
        'title': localPayment?.title ?? paymentMethod,
        'orderId': localPayment?.orderId ?? orderId ?? 0,
        'shiftId': localPayment?.shiftId ?? shiftId,
        'vendorId': localPayment?.vendorId ?? vendorId,
        'userId': localPayment?.userId ?? userId ?? 0,
        'serviceType': localPayment?.serviceType ?? serviceType,
        'notes': localPayment?.notes ?? '',
        'remainingBalance': newRemaining,
        'isSynced': localPayment?.isSynced ?? false,
        'serverPaymentId': localPayment?.serverPaymentId,
        'syncError': localPayment?.syncError,
        'syncAttempts': localPayment?.syncAttempts,
        'sunmiTxnId': localPayment?.sunmiTxnId,
        'sunmiOrderId': localPayment?.sunmiOrderId,
        'sunmiDeviceId': localPayment?.sunmiDeviceId,
        'createdAt': localPayment?.createdAt.toIso8601String() ?? ts,
        'syncedAt': localPayment?.syncedAt?.toIso8601String(),
      };

      // 7.  CRITICAL FIX: Get existing payments and append new one
      List<dynamic> payments = [];

      if (order['payments'] != null) {
        // Convert existing payments to List
        if (order['payments'] is List) {
          payments = List<Map<String, dynamic>>.from((order['payments'] as List)
              .map((e) => Map<String, dynamic>.from(e)));
        }
      }

      // Add new payment
      payments.add(historyEntry);

      print(" [SAVE] Payments after adding: ${payments.length}");

      // 8. Update order with ALL fields
      order['payments'] = payments; // ← CRITICAL
      order['total_paid'] = newPaid;
      order['remaining_balance'] = newRemaining;
      order['balance_amount'] = newRemaining;
      order['tender_amount'] = newPaid;
      order['change_amount'] = newChange;
      order['pay_by_cash'] = payCash;
      order['pay_by_card'] = payCard;
      order['pay_by_ebt'] = payEbt;
      order['pay_by_other'] = payOther;
      order['last_payment_time'] = ts;
      order['order_status'] = isComplete ? 'processing' : 'pending_offline';
      order['updated_at'] = ts;

      // Save lastPayment
      if (_lastPayment != null) {
        order['lastPayment'] = _lastPayment!.toJson();
      }

      // 9. WRITE BACK TO HIVE
      await box.put(key, order);

      print(" [SAVE] Written to Hive successfully");

      // Debug output
      if (kDebugMode) {
        print('''
═══════════════════════════════════════════════════════
 PAYMENT SAVED TO HIVE ── payments[] UPDATED
═══════════════════════════════════════════════════════
Order:          $key
This payment:   $paymentMethod \$${amount.toStringAsFixed(2)}
Local ID:       ${localPayment?.id ?? '-'}
Payments now:   ${payments.length}
Total paid:     \$${newPaid.toStringAsFixed(2)}
Remaining:      \$${newRemaining.toStringAsFixed(2)}
Change:         \$${newChange.toStringAsFixed(2)}
Status:         ${order['order_status']}
Computed Net Payable: \$${computedNetPayable.toStringAsFixed(2)}
Previous Remaining: \$${remaining.toStringAsFixed(2)}
═══════════════════════════════════════════════════════
''');
      }

      //  CRITICAL FIX: Update UI state - CLEAR current payment remaining when complete
      setState(() {
        // Update main values
        tenderAmount = newPaid;
        balanceAmount = newRemaining;
        changeAmount = newChange;
        payByCash = payCash;
        payByCard = payCard;
        payByEbt = payEbt;
        payByOther = payOther;
        orderStatus = order['order_status'];
        isPaymentStarted = true;

        //  FIX: Only set current payment remaining if payment is NOT complete
        if (newRemaining > 0) {
          // Still have balance - show current payment remaining
          _currentPaymentRemainingBalance = newRemaining;
          _lastPaymentDetails = {
            'amount': amount,
            'method': selectedPaymentMethod,
            'remainingBalance': newRemaining,
            'datetime': DateTime.now().toIso8601String(),
          };
        } else {
          //  Payment COMPLETE - CLEAR current payment remaining
          _currentPaymentRemainingBalance = null;
          _lastPaymentDetails = null;
          print(" PAYMENT COMPLETE - Current Payment Remaining cleared!");
        }
      });

      //  If payment is complete, show success popup
      if (newRemaining <= 0) {
        print(" Order fully paid! Showing success popup...");

        // Small delay to ensure state is updated
        Future.delayed(Duration(milliseconds: 100), () async {
          if (mounted && !_successPopupShown) {
            _successPopupShown = true;
            final boxData = await box.get(key);
            final cr =
            boxData is Map ? (boxData as Map)["coupon_response"] : null;
            final couponResponse = cr is Map
                ? Map<String, dynamic>.from(cr as Map)
                : <String, dynamic>{};

            // _showPaymentDialog(
            //   context,
            //   tenderAmount,
            //   changeAmount: changeAmount,
            //   showChange: changeAmount != null && changeAmount! > 0,
            //   couponResponse: couponResponse,
            // );
          }
        });
      }
    } catch (e, st) {
      print(" _savePaymentToHive crashed: $e");
      print(st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Offline save failed: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _refreshPaymentData() async {
    // Recalculate balance from payment history
    await _calculateBalanceFromPaymentHistory();

    // Print updated summary
    await _printPaymentHistorySummary();

    // Force UI update
    if (mounted) {
      setState(() {});
    }
  }

  //  IMPROVED: Save LocalPayment data to Hive offline box

  Future<void> _saveLocalPaymentToHive(LocalPayment payment) async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (kDebugMode) {
        print("🔵 [SAVE LOCAL PAYMENT] Starting for order: $key");
        print("🔵 Payment ID: ${payment.id}");
        print("🔵 Amount: ${payment.amount}");
        print("🔵 Method: ${payment.paymentMethod}");
      }

      // 1. Make sure the order exists in Hive
      if (!(await box.containsKey(key))) {
        print("Order not found → creating new entry: $key");
        await _createOfflineOrderEntry(key);
      }

      // 2. Read current data (FRESH COPY)
      final existingOrder = await box.get(key);
      if (existingOrder == null) {
        print("Failed to read order after creation");
        return;
      }

      var order = Map<String, dynamic>.from(existingOrder);

      print(
          " [SAVE] Current payments count: ${(order['payments'] as List?)?.length ?? 0}");

      // 3. Get existing payments array or create new one
      List<dynamic> payments = [];
      if (order['payments'] != null) {
        if (order['payments'] is List) {
          payments = List<Map<String, dynamic>>.from((order['payments'] as List)
              .map((e) => Map<String, dynamic>.from(e)));
        }
      }

      // 4. Create payment entry from LocalPayment model
      final Map<String, dynamic> paymentEntry = {
        'local_id': payment.id,
        'orderId': payment.orderId,
        'title': payment.title,
        'amount': payment.amount,
        'paymentMethod': payment.paymentMethod,
        'shiftId': payment.shiftId,
        'vendorId': payment.vendorId,
        'userId': payment.userId,
        'serviceType': payment.serviceType,
        'datetime': payment.datetime,
        'notes': payment.notes,
        'remainingBalance': payment.remainingBalance,
        'isSynced': payment.isSynced,
        'status': payment.status?.name ?? 'pending',
        'serverPaymentId': payment.serverPaymentId,
        'syncError': payment.syncError,
        'syncAttempts': payment.syncAttempts,
        'sunmiTxnId': payment.sunmiTxnId,
        'sunmiOrderId': payment.sunmiOrderId,
        'sunmiDeviceId': payment.sunmiDeviceId,
        'createdAt': payment.createdAt.toIso8601String(),
        'syncedAt': payment.syncedAt?.toIso8601String(),
        'addedToOrderAt': DateTime.now().toIso8601String(),
      };

      // 5. Add new payment to the array
      payments.add(paymentEntry);

      print(" [SAVE] Payments after adding: ${payments.length}");

      // 6. Calculate totals
      double totalPaid = (order['total_paid'] as num?)?.toDouble() ?? 0.0;
      totalPaid += payment.amount;

      double remaining = payment.remainingBalance;
      double change = 0.0;

      if (remaining <= 0) {
        change = remaining.abs();
        remaining = 0.0;
      }

      // 7. Update payment method counters
      double payCash = (order['pay_by_cash'] as num?)?.toDouble() ?? 0.0;
      double payCard = (order['pay_by_card'] as num?)?.toDouble() ?? 0.0;
      double payEbt = (order['pay_by_ebt'] as num?)?.toDouble() ?? 0.0;
      double payOther = (order['pay_by_other'] as num?)?.toDouble() ?? 0.0;

      switch (payment.paymentMethod.toLowerCase()) {
        case 'cash':
          payCash += payment.amount;
          break;
        case 'card':
          payCard += payment.amount;
          break;
        case 'ebt':
          payEbt += payment.amount;
          break;
        default:
          payOther += payment.amount;
      }

      // 8. Update order with ALL fields
      order['payments'] = payments;
      order['total_paid'] = totalPaid;
      order['remaining_balance'] = remaining;
      order['balance_amount'] = remaining;
      order['tender_amount'] = totalPaid;
      order['change_amount'] = change;
      order['pay_by_cash'] = payCash;
      order['pay_by_card'] = payCard;
      order['pay_by_ebt'] = payEbt;
      order['pay_by_other'] = payOther;
      order['last_payment_time'] = DateTime.now().toIso8601String();
      order['order_status'] = remaining <= 0 ? 'processing' : 'pending_offline';
      order['updated_at'] = DateTime.now().toIso8601String();

      // Save lastPayment info
      if (_lastPayment != null) {
        order['lastPayment'] = _lastPayment!.toJson();
      }

      // 9.  WRITE BACK TO HIVE
      await box.put(key, order);

      print(" [SAVE] Written to Hive successfully");

      // 10. Verify it was saved
      final verification = await box.get(key);
      if (verification != null) {
        final verifyPayments = verification['payments'] as List?;
        print(" [VERIFY] Payments in Hive now: ${verifyPayments?.length ?? 0}");
      }

      // Debug output
      if (kDebugMode) {
        print('''
═══════════════════════════════════════════════════════
 LOCAL PAYMENT SAVED TO HIVE
═══════════════════════════════════════════════════════
Order:          $key
Payment ID:     ${payment.id}
Method:         ${payment.paymentMethod}
Amount:         \$${payment.amount.toStringAsFixed(2)}
Payments now:   ${payments.length}
Total paid:     \$${totalPaid.toStringAsFixed(2)}
Remaining:      \$${remaining.toStringAsFixed(2)}
Change:         \$${change.toStringAsFixed(2)}
Status:         ${order['order_status']}

 PAYMENT ENTRY:
${JsonEncoder.withIndent('  ').convert(paymentEntry)}
═══════════════════════════════════════════════════════
''');
      }

      // 11. Update UI
      if (mounted) {
        setState(() {
          tenderAmount = totalPaid;
          balanceAmount = remaining;
          changeAmount = change;
          payByCash = payCash;
          payByCard = payCard;
          payByEbt = payEbt;
          payByOther = payOther;
          orderStatus = order['order_status'];
          isPaymentStarted = true;
        });
      }
    } catch (e, st) {
      print(" _saveLocalPaymentToHive crashed: $e");
      print(st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to save payment to offline storage: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _savePaymentLocally(double amount) async {
    if (kDebugMode) {
      print("\n" + "🟦" * 30);
      print("💾 STARTING LOCAL PAYMENT SAVE");
      print("🟦" * 30);
      print("Amount: \$${amount.toStringAsFixed(2)}");
      print("Method: $selectedPaymentMethod");
      print("Order ID: $orderId");
      print("Balance Before: \$${balanceAmount.toStringAsFixed(2)}");
    }

    final String datetime =
    DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

    final localPayment = LocalPayment(
      orderId: orderId ?? 0,
      title: selectedPaymentMethod!,
      amount: widget.netPayable,
      paymentMethod: selectedPaymentMethod!,
      shiftId: shiftId,
      vendorId: vendorId,
      userId: userId ?? 0,
      serviceType: serviceType,
      datetime: datetime,
      notes: 'offline payment - ${DateTime.now().toIso8601String()}',
      isSynced: false,
      createdAt: DateTime.now(),
      remainingBalance: balanceAmount - widget.netPayable,
      // status: balanceAmount - widget.netPayable <= 0 ? PaymentDbStatus.completed : PaymentDbStatus.pending,
      status: PaymentDbStatus.pending, // line in _callCreatePaymentAPI
    );

    try {
      // Save to Isar
      final savedPayment =
      await LocalPaymentDBHelper.instance.savePayment(localPayment);

      if (kDebugMode) {
        print("\n PAYMENT SAVED TO ISAR SUCCESSFULLY!");
        print("Local Payment ID: ${savedPayment.id}");
        print("============================================================");
        print("LocalPayment {");
        print("  id: ${savedPayment.id},");
        print("  orderId: ${savedPayment.orderId},");
        print("  title: \"${savedPayment.title}\",");
        print("  amount: \$${savedPayment.amount.toStringAsFixed(2)},");
        print("  paymentMethod: \"${savedPayment.paymentMethod}\",");
        print("  shiftId: ${savedPayment.shiftId},");
        print("  vendorId: ${savedPayment.vendorId},");
        print("  userId: ${savedPayment.userId},");
        print("  serviceType: \"${savedPayment.serviceType}\",");
        print("  datetime: \"${savedPayment.datetime}\",");
        print("  notes: \"${savedPayment.notes}\",");
        print(
            "  remainingBalance: \$${savedPayment.remainingBalance.toStringAsFixed(2)},");
        print("  isSynced: ${savedPayment.isSynced},");
        print("  status: ${savedPayment.status?.name},");
        print("  serverPaymentId: ${savedPayment.serverPaymentId},");
        print("  syncError: ${savedPayment.syncError},");
        print("  syncAttempts: ${savedPayment.syncAttempts},");
        print("  sunmiTxnId: ${savedPayment.sunmiTxnId},");
        print("  sunmiOrderId: ${savedPayment.sunmiOrderId},");
        print("  sunmiDeviceId: ${savedPayment.sunmiDeviceId},");
        print("  createdAt: ${savedPayment.createdAt},");
        print("  syncedAt: ${savedPayment.syncedAt}");
        print("}");
        print("============================================================");
      }

      //  NEW: Save to Hive offline box
      await _saveLocalPaymentToHive(savedPayment);

      // Update local state
      _updateLocalPaymentState(amount, savedPayment);

      // Show success popup
      await _showPaymentSuccessPopup(amount, savedPayment);

      // Schedule sync
      _schedulePaymentSync(savedPayment);

      if (kDebugMode) {
        print("🟦" * 30 + "\n");
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print("\n❌ ERROR SAVING PAYMENT");
        print("Error: $e");
        print("Stack: $stackTrace");
        print("🟦" * 30 + "\n");
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Failed to save payment: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

//  NEW: Create complete offline order entry structure
  Future<void> _createOfflineOrderEntry(String key) async {
    try {
      final box = StorageProvider.offlineOrders;
      final now = DateTime.now();
      final timestamp = now.toIso8601String();

      final orderEntry = {
        'order_id': orderId,
        'offline_order_id': widget.offlineOrderId,
        'created_at': timestamp,
        'updated_at': timestamp,

        // Order items
        'order_items':
        orderItems.map((item) => Map<String, dynamic>.from(item)).toList(),

        // Financial details
        'gross_total': grossTotal,
        'orderDiscount': discount,
        'merchantDiscount': merchantDiscount,
        'order_tax': tax,
        'cashback_fee': cashbackFee,
        'ebtTotal': ebtTotal,
        'originalEbt': ebtTotal, // Store original EBT
        'redeemed_value': redeemedValue,
        'net_payable': computedNetPayable,

        // Payment tracking
        'payments': [],
        'total_paid': 0.0,
        'remaining_balance': computedNetPayable,
        'balance_amount': computedNetPayable,
        'tender_amount': 0.0,
        'change_amount': 0.0,
        'pay_by_cash': 0.0,
        'pay_by_card': 0.0,
        'pay_by_ebt': 0.0,
        'pay_by_other': 0.0,

        // Order metadata
        'order_status': TextConstants.processing,
        'order_date': _displayDate,
        'order_time': _displayTime,
        'user_id': userId,
        'user_name': userDisplayName,
        'user_role': userRole,

        // Loyalty & coupons
        'loyaltyContact': '',
        'available_points': 0,
        'coupon_response': {},

        // Sync status
        'is_synced': false,
        'last_payment_time': null,
      };

      await box.put(key, orderEntry);

      if (kDebugMode) {
        print("✅ Created new offline order entry for ID: $key");
      }
    } catch (e) {
      if (kDebugMode) {
        print("Error creating offline order entry: $e");
      }
    }
  }

//  IMPROVED: Update _updateHivePaymentData to use new structure
  Future<void> _updateHivePaymentData(LocalPayment payment) async {
    try {
      if (kDebugMode) {
        print("Updating Hive payment + price data...");
      }

      await _savePaymentToHive(
        amount: payment.amount,
        paymentMethod: payment.paymentMethod,
        transactionId: "local_${payment.id}",
        localPayment: payment,
      );

      // 🔁 Re-read updated order from Hive (source of truth)
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (!(await box.containsKey(key))) return;

      final rawUpdated = await box.get(key);
      final updatedOrder =
      Map<String, dynamic>.from(rawUpdated is Map ? rawUpdated : {});

      //  Extract updated values
      final double updatedPaid =
          (updatedOrder['total_paid'] as num?)?.toDouble() ?? 0.0;
      final double updatedBalance =
          (updatedOrder['remaining_balance'] as num?)?.toDouble() ?? 0.0;
      final double updatedChange =
          (updatedOrder['change_amount'] as num?)?.toDouble() ?? 0.0;

      final double updatedGrossTotal =
          (updatedOrder['gross_total'] as num?)?.toDouble() ?? grossTotal;
      final double updatedNetTotal =
          (updatedOrder['net_total'] as num?)?.toDouble() ?? 0.0;
      final double updatedPayable =
          (updatedOrder['payable_amount'] as num?)?.toDouble() ?? 0.0;

      final String updatedStatus =
          updatedOrder['order_status'] ?? TextConstants.pending;

      //  Update UI state AFTER Hive is correct
      if (mounted) {
        setState(() {
          tenderAmount = updatedPaid;
          balanceAmount = updatedBalance;
          changeAmount = updatedChange;

          grossTotal = updatedGrossTotal;
          netTotal = updatedNetTotal;
          payableAmount = updatedPayable;

          orderStatus = updatedStatus;
          isPaymentStarted = true;
        });
      }

      if (kDebugMode) {
        print(" Hive payment + price updated successfully");
        print("💰 Paid: $updatedPaid");
        print("📉 Balance: $updatedBalance");
        print("🔁 Change: $updatedChange");
        print("🧾 Payable: $updatedPayable");
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print("❌ Failed to update Hive payment data: $e");
        print(stackTrace);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to update payment"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _loadOfflineOrderData() async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (!(await box.containsKey(key))) {
        if (kDebugMode) {
          print(" No offline order found for ID: $key");
        }
        return null;
      }

      final rawData = await box.get(key);
      final data = Map<String, dynamic>.from(rawData is Map ? rawData : {});

      if (kDebugMode) {
        print("\n" + "📂" * 30);
        print("LOADED OFFLINE ORDER DATA");
        print("📂" * 30);
        print("Order ID: $key");
        print(
            "Total Paid: \$${(data['total_paid'] ?? 0.0).toStringAsFixed(2)}");
        print(
            "Balance: \$${(data['remaining_balance'] ?? 0.0).toStringAsFixed(2)}");
        print("Payments Count: ${(data['payments'] as List?)?.length ?? 0}");
        print("Status: ${data['order_status']}");
        print("📂" * 30 + "\n");
      }

      return data;
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error loading offline order: $e");
      }
      return null;
    }
  }

//  NEW: Get payment history from Hive
  Future<List<Map<String, dynamic>>> _getPaymentHistoryFromHive() async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (!(await box.containsKey(key))) {
        return [];
      }

      final rawExisting = await box.get(key);
      final existing =
      Map<String, dynamic>.from(rawExisting is Map ? rawExisting : {});
      final payments = existing['payments'] as List<dynamic>? ?? [];

      return payments.map((p) => Map<String, dynamic>.from(p)).toList();
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error getting payment history: $e");
      }
      return [];
    }
  }

//  NEW: Clear offline order after completion
  Future<void> _clearOfflineOrder() async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (await box.containsKey(key)) {
        await box.delete(key);

        if (kDebugMode) {
          print("️ Cleared offline order: $key");
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print("Error clearing offline order: $e");
      }
    }
  }

// Update _updateLocalPaymentState to use correct calculation:
  void _updateLocalPaymentState(double amount, LocalPayment payment) {
    if (kDebugMode) {
      print(
          "\n PROCESSING PAYMENT #${(_lastPaymentDetails?['paymentNumber'] ?? 0) + 1}");
      print("=" * 50);
    }

    double balanceBefore = balanceAmount;
    double newBalance = balanceAmount - amount;
    double change = 0.0;

    if (newBalance < 0) {
      change = newBalance.abs();
      newBalance = 0.0;
    }

    // Calculate payment number
    int paymentNumber = (_lastPaymentDetails?['paymentNumber'] ?? 0) + 1;
    double totalPaid = tenderAmount + amount;

    print("💰 PAYMENT DETAILS:");
    print("  Payment #: $paymentNumber");
    print("  Method: ${selectedPaymentMethod}");
    print("  Amount: \$${amount.toStringAsFixed(2)}");
    print("  Balance Before Payment: \$${balanceBefore.toStringAsFixed(2)}");
    print("  Balance After Payment: \$${newBalance.toStringAsFixed(2)}");
    print("  Total Paid So Far: \$${totalPaid.toStringAsFixed(2)}");
    print("  Change: \$${change.toStringAsFixed(2)}");
    print("  Complete: ${newBalance <= 0}");

    // Update payment method totals
    double newPayByCash = payByCash;
    double newPayByCard = payByCard;
    double newPayByEbt = payByEbt;
    double newPayByOther = payByOther;

    switch (selectedPaymentMethod!.toLowerCase()) {
      case 'cash':
        newPayByCash += amount;
        break;
      case 'card':
        newPayByCard += amount;
        break;
      case 'ebt':
        newPayByEbt += amount;
        break;
      default:
        newPayByOther += amount;
    }

    setState(() {
      isPaymentStarted = true;
      paidAmount = amount;
      paymentId = "local_${payment.id}";
      _lastPayment = LastPaymentInfo(
        method: selectedPaymentMethod!,
        amount: amount,
        paymentId: paymentId,
        sunmiTxnId: null,
      );

      // Update amounts
      tenderAmount = totalPaid;
      balanceAmount = newBalance;

      // CRITICAL: Store progression info
      _lastPaymentDetails = {
        'amount': amount,
        'method': selectedPaymentMethod!,
        'remainingBalance': newBalance,
        'previousBalance': balanceBefore, // Store previous balance
        'datetime': DateTime.now().toIso8601String(),
        'paymentId': "local_${payment.id}",
        'timestamp': DateTime.now(),
        'totalPaid': totalPaid, // Store total paid
        'paymentNumber': paymentNumber, // Store payment number
      };

      // Set current payment remaining
      if (newBalance > 0) {
        _currentPaymentRemainingBalance = newBalance;
      } else {
        _currentPaymentRemainingBalance = null;
      }

      // Update payment method totals
      payByCash = newPayByCash;
      payByCard = newPayByCard;
      payByEbt = newPayByEbt;
      payByOther = newPayByOther;

      changeAmount = change;
    });

    _updateHivePaymentData(payment);

    if (kDebugMode) {
      print("\n UPDATED STATE:");
      print("  Tender Amount: \$${tenderAmount.toStringAsFixed(2)}");
      print("  Balance Amount: \$${balanceAmount.toStringAsFixed(2)}");
      print(
          "  Current Payment Remaining: ${_currentPaymentRemainingBalance != null ? '\$${_currentPaymentRemainingBalance!.toStringAsFixed(2)}' : 'None'}");
      print("  Previous Balance: \$${balanceBefore.toStringAsFixed(2)}");
      print("  Payment Method Totals: Cash=\$${payByCash.toStringAsFixed(2)}");
      print("  " + "=" * 50 + "\n");
    }
  }

  void _autoSelectPaymentMethodAndFillAmount() {
    print("Starting auto-select payment. Current balanceAmount: $balanceAmount, " +
        "ebtTotal: $ebtTotal, Current Payment Remaining: $_currentPaymentRemainingBalance");

    //  FIX: Only auto-fill if there's a current payment remaining
    if (_currentPaymentRemainingBalance != null &&
        _currentPaymentRemainingBalance! > 0) {
      double amountToUse = _currentPaymentRemainingBalance!;

      //  Rule: If there's EBT balance, preselect EBT
      if (ebtTotal > 0 && amountToUse <= ebtTotal) {
        print(
            "EBT balance available. Preselecting EBT. Amount to use: $amountToUse");
        _selectPaymentMethod(
          TextConstants.ebtText,
          maxAllowedAmount: amountToUse,
        );
      }
      // Otherwise preselect Cash
      else {
        print(
            "No EBT or balance > EBT. Preselecting Cash. Amount to use: $amountToUse");
        _selectPaymentMethod(
          TextConstants.cash,
          maxAllowedAmount: amountToUse,
        );
      }

      // Auto-fill the amount
      print("Auto-filling current payment remaining balance: $amountToUse");
      _rawAmount = (amountToUse * 100).round();
      amountController.text =
      '${TextConstants.currencySymbol}${amountToUse.toStringAsFixed(2)}';

      setState(() {
        _isAmountEntered = true;
        _amountErrorText = null;
      });
    } else if (balanceAmount > 0) {
      // This is for fresh payments (no current payment remaining)
      print("No current payment remaining. Using main balance: $balanceAmount");

      // Rule: If there's EBT balance, preselect EBT
      if (ebtTotal > 0 && balanceAmount <= ebtTotal) {
        double amountToUse = min(balanceAmount, ebtTotal);
        print(
            "EBT balance available. Preselecting EBT. Amount to use: $amountToUse");
        _selectPaymentMethod(
          TextConstants.ebtText,
          maxAllowedAmount: amountToUse,
        );
      }
      // Otherwise preselect Cash
      else {
        print(
            "No EBT or balance > EBT. Preselecting Cash. Amount to use: $balanceAmount");
        _selectPaymentMethod(
          TextConstants.cash,
          maxAllowedAmount: balanceAmount,
        );
      }

      // Auto-fill the amount
      print("Auto-filling main balance: $balanceAmount");
      // _autoFillRemainingBalance();
    } else {
      print(
          "Balance amount is zero or negative. No payment method auto-selected.");
    }
  }

// Show success popup
  Future<void> _showPaymentSuccessPopup(
      double amount, LocalPayment payment) async {
    final bool isPaymentComplete = balanceAmount <= 0;

    //  Clear the payment-specific balance display when order is fully paid
    if (isPaymentComplete) {
      setState(() {
        _currentPaymentRemainingBalance = null;
        _lastPaymentDetails = null;
      });
    }

    if (kDebugMode) {
      print("\n PAYMENT STATUS");
      print("   Balance: \$${balanceAmount.toStringAsFixed(2)}");
      print("   Complete: $isPaymentComplete");
      print("   Current Payment Remaining: $_currentPaymentRemainingBalance");
      print("   Popup Shown: $_successPopupShown\n");
    }

    if (isPaymentComplete && !_successPopupShown) {
      _successPopupShown = true;
      // ✅ ADD THIS LINE (CRITICAL FIX)
      // await CustomerDisplayService.showThankYou();
      // ✅ STEP 2: CLEAR ACTIVE ORDER (CRITICAL)
      await orderHelper.setActiveOrder(null);

      // ✅ STEP 3: RESET DISPLAY (FINAL STATE)
      await CustomerDisplayService.resetDisplay();

      print("✅ Payment complete → display reset");
      // ✅ SHOW SUCCESS SNACKBAR
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Order successfully completed"),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();
      final boxDataKey = await box.get(key);
      final cr =
      boxDataKey is Map ? (boxDataKey as Map)["coupon_response"] : null;
      final couponResponse = cr is Map
          ? Map<String, dynamic>.from(cr as Map)
          : <String, dynamic>{};

      _showPaymentDialog(
        context,
        tenderAmount,
        changeAmount: changeAmount,
        showChange: changeAmount != null && changeAmount! > 0,
        couponResponse: couponResponse,
      );
    } else if (balanceAmount > 0) {
      //  AUTO-FILL BEFORE SHOWING PARTIAL DIALOG
      // _autoFillRemainingBalance();
      _showPartialPaymentDialog(context, amount);
    }
  }

//  Schedule sync
  Future<void> _schedulePaymentSync(LocalPayment payment) async {
    if (kDebugMode) {
      print("\n⏰ SCHEDULING SYNC");
      print("   Payment ID: ${payment.id}");
      print("   Delay: 500ms\n");
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      _syncPaymentToServer(payment);
    });
  }

//  Sync to server
  Future<void> _syncPaymentToServer(LocalPayment payment) async {
    if (kDebugMode) {
      print("\n" + "🔄" * 30);
      print("SYNCING PAYMENT TO SERVER");
      print("🔄" * 30);
      print("Local ID: ${payment.id}");
      print("Order ID: ${payment.orderId}");
      print("Amount: \$${payment.amount.toStringAsFixed(2)}");
      print("Method: ${payment.paymentMethod}");
    }

    final paymentRequest = PaymentRequestModel(
      title: payment.title,
      orderId: payment.orderId,
      amount: payment.amount,
      paymentMethod: payment.paymentMethod,
      shiftId: payment.shiftId,
      vendorId: payment.vendorId,
      userId: payment.userId,
      serviceType: payment.serviceType,
      datetime: payment.datetime,
      notes: payment.notes,
    );

    // paymentBloc.createPayment(paymentRequest);

    StreamSubscription? subscription;
    subscription = paymentBloc.createPaymentStream.listen(
          (paymentResponse) async {
        if (paymentResponse.status == Status.COMPLETED &&
            paymentResponse.data != null) {
          final serverPaymentId = paymentResponse.data!.paymentId;

          if (kDebugMode) {
            print("\n SYNC SUCCESS!");
            print("   Local ID: ${payment.id}");
            print("   Server ID: $serverPaymentId");
          }

          await LocalPaymentDBHelper.instance.markAsSynced(
            payment.id,
            serverPaymentId ?? 0,
          );

          if (mounted) {
            setState(() {
              paymentId = serverPaymentId.toString();
            });
          }

          _lastPayment = LastPaymentInfo(
            method: payment.paymentMethod,
            amount: payment.amount,
            paymentId: serverPaymentId.toString(),
            sunmiTxnId: null,
          );

          final box = StorageProvider.offlineOrders;
          final key = (orderId ?? 0).toString();
          final hasKey = await box.containsKey(key);
          final raw = hasKey ? await box.get(key) : null;
          final existing = Map<String, dynamic>.from(raw is Map ? raw : {});

          existing["lastPayment"] = _lastPayment!.toJson();
          existing["serverPaymentId"] = serverPaymentId;
          existing["localPaymentSynced"] = true;
          await box.put(key, existing);

          // Print updated payment
          await LocalPaymentDBHelper.instance
              .getLastPaymentForOrder(payment.orderId);

          if (kDebugMode) {
            print("🔄" * 30 + "\n");
          }
        } else if (paymentResponse.status == Status.ERROR) {
          if (kDebugMode) {
            print("\n❌ SYNC FAILED");
            print("   Error: ${paymentResponse.message}");
          }

          await LocalPaymentDBHelper.instance.updateSyncError(
            payment.id,
            paymentResponse.message ?? 'Unknown error',
          );

          await LocalPaymentDBHelper.instance.getUnsyncedPayments();

          if (kDebugMode) {
            print("🔄" * 30 + "\n");
          }

          if (mounted && Misc.showDebugSnackBar) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Payment saved locally. Will sync when online."),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }

        subscription?.cancel();
      },
    );
  }

  Future<void> retrySyncUnsyncedPayments() async {
    final unsyncedPayments =
    await LocalPaymentDBHelper.instance.getUnsyncedPayments();

    if (unsyncedPayments.isEmpty) {
      if (kDebugMode) {
        print(" No unsynced payments\n");
      }
      return;
    }

    if (kDebugMode) {
      print("\n🔁 RETRYING ${unsyncedPayments.length} PAYMENTS");
    }

    for (final payment in unsyncedPayments) {
      if ((payment.syncAttempts ?? 0) > 5) {
        if (kDebugMode) {
          print("⏭ Skipping ID ${payment.id} (too many attempts)");
        }
        continue;
      }

      await _syncPaymentToServer(payment);
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _fetchShiftId() async {
    final data = await UserDbHelper().getUserData();
    if (data != null && data["shift_id"] != null) {
      setState(() {
        shiftId = data["shift_id"];
      });
    }
  }

  void _selectPaymentMethod(
      String method, {
        bool autoFillAmount = false,
        double? maxAllowedAmount,
      }) {
    setState(() {
      selectedPaymentMethod = method;

      if (autoFillAmount && maxAllowedAmount != null) {
        _rawAmount = (maxAllowedAmount * 100).toInt();
        amountController.text =
        '${TextConstants.currencySymbol}${maxAllowedAmount.toStringAsFixed(2)}';
        _isAmountEntered = true;
        _amountErrorText = null;
      }
    });
  }

  void _onQuickAmountSelected(double amount) {
    setState(() {
      double allowedAmount = amount;

      // ---------- EBT LIMIT ----------
      if (selectedPaymentMethod == TextConstants.ebtText) {
        allowedAmount = min(amount, ebtTotal);
      }

      // ---------- CARD LIMIT ----------
      else if (selectedPaymentMethod == TextConstants.card) {
        allowedAmount = min(amount, balanceAmount);
      }

      // Convert to paise/cents
      _rawAmount = (allowedAmount * 100).round();

      amountController.text =
      '${TextConstants.currencySymbol}${allowedAmount.toStringAsFixed(2)}';

      _amountErrorText = null;
      _isAmountEntered = _rawAmount > 0;
    });
  }

  // void _handlePay() {
  //   final cleanAmount = amountController.text
  //       .replaceAll(TextConstants.currencySymbol, '')
  //       .trim();
  //
  //   final double amount = double.tryParse(cleanAmount) ?? 0.0;
  //
  //   if (amount <= 0 && computedNetPayable > 0) {
  //     setState(() {
  //       _amountErrorText = TextConstants.amountValidation;
  //     });
  //     return;
  //   }
  //
  //   _amountErrorText = null;
  //
  //   // EBT validation
  //   if (selectedPaymentMethod == TextConstants.ebtText) {
  //     if (ebtTotal <= 0) {
  //       setState(() {
  //         _amountErrorText = "No EBT balance available";
  //       });
  //       return;
  //     }
  //
  //     if (amount > ebtTotal) {
  //       setState(() {
  //         _amountErrorText =
  //         "Amount cannot exceed available EBT balance (\$${ebtTotal.toStringAsFixed(2)})";
  //       });
  //       return;
  //     }
  //   }
  //
  //   // CARD → Sunmi
  //   if (selectedPaymentMethod == TextConstants.card) {
  //     _showPaymentProgressDialog(context);
  //     _openSunmiSaleScreen(
  //       amount: amount,
  //       orderId: (widget.orderId ?? widget.offlineOrderId).toString(),
  //     );
  //     _resetAmountAfterPay();
  //     return;
  //   }
  //
  //   // ✅ FIX: Use current payment remaining if available, otherwise use main balance
  //   final double currentRemainingBalance = _currentPaymentRemainingBalance ?? balanceAmount;
  //
  //   print("🔍 PAYMENT CALCULATION:");
  //   print("💰 Amount entered: \$${amount.toStringAsFixed(2)}");
  //   print("💵 Tendered so far: \$${tenderAmount.toStringAsFixed(2)}");
  //   print("📊 Main balance: \$${balanceAmount.toStringAsFixed(2)}");
  //   print("🎯 Current payment remaining: \$${(_currentPaymentRemainingBalance ?? 0).toStringAsFixed(2)}");
  //   print("📈 Using for calculation: \$${currentRemainingBalance.toStringAsFixed(2)}");
  //
  //   final bool willCompletePayment = amount >= currentRemainingBalance;
  //   final double changeAmount = willCompletePayment ? (amount - currentRemainingBalance) : 0.0;
  //
  //   print("🎯 Will complete payment? $willCompletePayment");
  //   print("💵 Change if complete: \$${changeAmount.toStringAsFixed(2)}");
  //
  //   if (willCompletePayment) {
  //     _successPopupShown = true;
  //
  //     // Coupon data for popup
  //     final box = StorageProvider.offlineOrders;
  //     final key = (orderId ?? 0).toString();
  //     final couponResponse = (box.get(key)?["coupon_response"] as Map?)?.cast<String, dynamic>() ?? {};
  //
  //     print("✅ Showing FULL payment popup");
  //     _showPaymentDialog(
  //       context,
  //       tenderAmount + amount,
  //       changeAmount: changeAmount,
  //       showChange: changeAmount > 0,
  //       couponResponse: couponResponse,
  //     );
  //   } else {
  //     print("🟡 Showing PARTIAL payment popup");
  //     _showPartialPaymentDialog(context, amount);
  //   }
  //
  //   // Call API in background (no loading)
  //   _callCreatePaymentAPI(skipPopup: true);
  //   _resetAmountAfterPay();
  // }

  void _handlePay() {
    if (balanceAmount <= 0 &&
        (double.tryParse(amountController.text
            .replaceAll(TextConstants.currencySymbol, '')
            .trim()) ??
            0) > 0) {
      print(
          "⚠️ DEFENSIVE RESET: balance=0 but amount entered > 0 → forcing reset after possible void");
      setState(() {
        _successPopupShown = false;
        _currentPaymentRemainingBalance = null;
        isPaymentStarted = false;
      });
      _calculateBalanceFromPaymentHistory();
    }

    final cleanAmount = amountController.text
        .replaceAll(TextConstants.currencySymbol, '')
        .trim();

    final double amount = double.tryParse(cleanAmount) ?? 0.0;
    final int enteredCents = (amount * 100).round();
    final int ebtCents = (ebtTotal * 100).round();

    // Basic validation
    if (enteredCents <= 0 && computedNetPayable > 0) {
      setState(() {
        _amountErrorText = TextConstants.amountValidation;
      });
      return;
    }
    _amountErrorText = null;

    // EBT validation
    if (selectedPaymentMethod == TextConstants.ebtText) {
      if (ebtCents <= 0) {
        setState(() {
          _amountErrorText = "No EBT balance available";
        });
        return;
      }
      if (enteredCents > ebtCents) {
        setState(() {
          _amountErrorText = "Amount cannot exceed available EBT balance (\$${ebtTotal.toStringAsFixed(2)})";
        });
        return;
      }
    }

    // ✅ REMOVED the Sunmi‑only branch for Card.
    // Now Card payments go through the same flow as Cash / EBT.
    // The original code was:
    // if (selectedPaymentMethod == TextConstants.card) {
    //   _openSunmiSaleScreen(...);
    //   return;
    // }

    // ✅ All payment methods (Cash, Card, Wallet, EBT) now call the local storage API
    _callCreatePaymentAPI(); // uses validated amount
    _resetAmountAfterPay();
  }
//  ADD THIS METHOD (you might already have it, but here it is for reference)
  void _resetAmountAfterPay() {
    _rawAmount = 0;
    amountController.text = '${TextConstants.currencySymbol}0.00';
    setState(() {
      _isAmountEntered = false;
      _amountErrorText = null;
    });
  }

  //  UPDATED - Add Payment to Offline Order with Success Message
  Future<void> _addPaymentToOfflineOrder(LocalPayment payment) async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (!(await box.containsKey(key))) {
        if (kDebugMode) {
          print(" Offline order not found for key: $key");
        }

        // Show error message to user
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Error: Order not found"),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // Get existing order
      final rawExisting = await box.get(key);
      final existing =
      Map<String, dynamic>.from(rawExisting is Map ? rawExisting : {});

      // Get existing payments array or create new one
      List<dynamic> payments = existing['payments'] ?? [];

      // Get current timestamp
      final now = DateTime.now();
      final timestamp = now.toIso8601String();

      // Add new payment with timestamp
      payments.add({
        'id': payment.id,
        'orderId': payment.orderId,
        'title': payment.title,
        'amount': payment.amount,
        'paymentMethod': payment.paymentMethod,
        'shiftId': payment.shiftId,
        'vendorId': payment.vendorId,
        'userId': payment.userId,
        'serviceType': payment.serviceType,
        'datetime': payment.datetime,
        'notes': payment.notes,
        'remainingBalance': payment.remainingBalance,
        'isSynced': payment.isSynced,
        'status': payment.status?.name,
        'serverPaymentId': payment.serverPaymentId,
        'syncError': payment.syncError,
        'syncAttempts': payment.syncAttempts,
        'sunmiTxnId': payment.sunmiTxnId,
        'sunmiOrderId': payment.sunmiOrderId,
        'sunmiDeviceId': payment.sunmiDeviceId,
        'createdAt': payment.createdAt.toIso8601String(),
        'syncedAt': payment.syncedAt?.toIso8601String(),
        'addedToOrderAt': timestamp, // Track when added to order
      });

      // Update order with new payments array
      existing['payments'] = payments;

      // Also update totals
      final currentTotalPaid =
          (existing['total_paid'] as num?)?.toDouble() ?? 0.0;
      existing['remaining_balance'] = payment.remainingBalance;
      existing['total_paid'] = currentTotalPaid + payment.amount;
      existing['last_payment_time'] = timestamp; //  Track last payment time

      // Save back to Hive
      await box.put(key, existing);

      if (kDebugMode) {
        print(" Payment added to offline order successfully!");
        print("   Order ID: $key");
        print("   Payment ID: ${payment.id}");
        print("   wooo ID: ${payment.serverPaymentId}");

        print("   Payment Method: ${payment.paymentMethod}");
        print("   Amount: \$${payment.amount.toStringAsFixed(2)}");
        print("   Time: $timestamp");
        print("   Total Payments: ${payments.length}");
        print("   Total Paid: \$${existing['total_paid'].toStringAsFixed(2)}");
        print(
            "   Remaining Balance: \$${payment.remainingBalance.toStringAsFixed(2)}");
        print("   Status: ${payment.status?.name}");
      }

      //  Show success message to user
      if (mounted) {
        final bool isPartial = payment.remainingBalance > 0;
        final String statusText = isPartial ? "Partial" : "Full";
        final String timeText = DateFormat('HH:mm:ss').format(now);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  " $statusText Payment Recorded",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Amount: \$${payment.amount.toStringAsFixed(2)} (${payment.paymentMethod})",
                  style: const TextStyle(fontSize: 14),
                ),
                Text(
                  "Time: $timeText",
                  style: const TextStyle(fontSize: 12),
                ),
                if (isPartial)
                  Text(
                    "Remaining: \$${payment.remainingBalance.toStringAsFixed(2)}",
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.yellow,
                    ),
                  ),
              ],
            ),
            backgroundColor: isPartial ? Colors.orange : Colors.green,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print(" Error adding payment to offline order: $e");
        print("Stack trace: $stackTrace");
      }

      // Show error message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error saving payment: $e"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

//  OPTIONAL - View Payment History with Timestamps
  Future<void> _showPaymentHistory() async {
    final payments = await _getPaymentsFromOfflineOrder();

    if (payments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No payments recorded yet"),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Payment History"),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: payments.length,
            itemBuilder: (context, index) {
              final payment = payments[index];
              final amount = payment['amount'] ?? 0.0;
              final method = payment['paymentMethod'] ?? 'Unknown';
              final timeStr =
                  payment['addedToOrderAt'] ?? payment['createdAt'] ?? '';

              DateTime? time;
              try {
                time = DateTime.parse(timeStr);
              } catch (e) {
                time = null;
              }

              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.green,
                    child: Text('${index + 1}'),
                  ),
                  title: Text(
                    '\$${amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Method: $method'),
                      if (time != null)
                        Text(
                          'Time: ${DateFormat('HH:mm:ss').format(time)}',
                          style:
                          TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                    ],
                  ),
                  trailing: Icon(
                    payment['isSynced'] == true
                        ? Icons.cloud_done
                        : Icons.cloud_off,
                    color: payment['isSynced'] == true
                        ? Colors.green
                        : Colors.orange,
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  // OPTIONAL HELPER - Get Payments from Offline Order
  Future<List<Map<String, dynamic>>> _getPaymentsFromOfflineOrder() async {
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();

      if (!(await box.containsKey(key))) {
        return [];
      }

      final rawExisting = await box.get(key);
      final existing =
      Map<String, dynamic>.from(rawExisting is Map ? rawExisting : {});
      final payments = existing['payments'] as List<dynamic>? ?? [];

      return payments.map((p) => Map<String, dynamic>.from(p)).toList();
    } catch (e) {
      if (kDebugMode) {
        print(" Error getting payments from offline order: $e");
      }
      return [];
    }
  }

  /// Fills EBT / variant fields on summary lines from offline `products` when SQLite rows omit them (pending orders).
  Future<void> _enrichOrderItemsFromHiveProducts() async {
    final box = StorageProvider.offlineOrders;
    final wantIds = <int>{
      if (widget.offlineOrderId != null) widget.offlineOrderId!,
      if (orderId != null && orderId != 0) orderId!,
    };

    Map<String, dynamic>? hiveOrder;

    for (final id in wantIds) {
      final raw = await box.get(id.toString());
      if (raw is Map) {
        hiveOrder = Map<String, dynamic>.from(raw);
        break;
      }
    }

    if (hiveOrder == null && wantIds.isNotEmpty) {
      try {
        final all = await box.toMap();
        for (final entry in all.values) {
          if (entry is! Map) continue;
          final m = Map<String, dynamic>.from(entry);
          final oid = m['order_id'] ?? m['id'] ?? m[AppDBConst.orderServerId];
          final int? o =
          oid is int ? oid : int.tryParse(oid?.toString() ?? '');
          if (o != null && wantIds.contains(o)) {
            hiveOrder = m;
            break;
          }
        }
      } catch (_) {}
    }

    _mergeOrderSummaryLineItemsFromHive(orderItems, hiveOrder);
    await _mergeOrderSummaryLineItemsFromProductCache(orderItems);
  }

  static const MethodChannel customerDisplayChannel =
  MethodChannel(
    'com.example.flutter_customer_display/sunmi_display',
  );

  Future<void> _handleCustomerAddFromDisplay(String contact) async {
    try {
      final offlineBox = StorageProvider.offlineOrders;
      final localKey = widget.offlineOrderId?.toString();

      if (localKey == null) {
        throw Exception("Offline order not found");
      }

      final existing = await offlineBox.get(localKey);

      if (existing == null) {
        throw Exception("Order data missing");
      }

      final offlineOrder = Map<String, dynamic>.from(existing);

      final syncResponse =
      await orderBloc.syncSingleOfflineOrder(offlineOrder);

      if (syncResponse == null) {
        throw Exception("Sync failed");
      }

      final int syncedOrderId = syncResponse["id"] ?? 0;

      final rawResponse = await orderBloc.addLoyaltyPoints(
        orderId: syncedOrderId,
        contact: contact,
      );

      final result = jsonDecode(rawResponse);

      if (result["success"] != true) {
        throw Exception(result["message"]);
      }

      final data = result["data"] ?? {};

      final pts = int.tryParse(
        data["available_points"]?.toString() ?? "0",
      ) ?? 0;

      // final redeemedAmount =
      //     (data["value_redeemed"] as num?)?.toDouble() ?? 0.0;

      print("SENDING TO CUSTOMER DISPLAY");
      print("points=$pts");
      // print("redeemedAmount=$redeemedAmount");


      // UPDATE CUSTOMER DISPLAY
      await customerDisplayChannel.invokeMethod(
        "customerDisplayResult",
        {
          "success": true,
          "points": pts,
          // "redeemedAmount": redeemedAmount,
        },
      );

      setState(() {
        availablePoints = pts;

        // keep redeemed value
        // redeemedValue = redeemedAmount;

        mobileController.text = contact;
      });

    } catch (e) {
      print("ERROR: $e");
    }
  }
  Future<void> _applyRedeemFromCustomerDisplay() async {
    setState(() {
      isRedeemAppliedFromApi = true;

      // keep net payable unchanged
      // balanceAmount =
      //     (computedNetPayable - redeemedValue) - tenderAmount;
    });

    // await CustomerDisplayHelper.updateCustomerDisplay(
    //   widget.orderId ?? widget.offlineOrderId ?? 0,
    //   summaryEnabled: true,
    //   redeemedValue: redeemedValue, // ADD
    // );
  }

  ///srija tax issue???
  // double getAdjustedSummaryTax() {
  //   double totalSubtotal = 0.0;
  //   double totalDiscount = 0.0;
  //
  //   double _num(dynamic value) {
  //     if (value is num) return value.toDouble();
  //     return double.tryParse(value?.toString() ?? '') ?? 0.0;
  //   }
  //
  //   print("========== TAX ADJUST START ==========");
  //
  //   for (var item in orderItems) {
  //     final String itemName =
  //         item['item_name']?.toString() ?? 'Unknown';
  //
  //     // ✅ SKIP EBT PRODUCTS
  //     final bool isEbt =
  //         item['is_ebt'] == true ||
  //             item['ebt'] == true ||
  //             item['isEBT'] == true ||
  //             item['is_ebt_eligible'] == true;
  //
  //     if (isEbt) {
  //       print("🚫 EBT ITEM SKIPPED: $itemName");
  //       continue;
  //     }
  //
  //     final double price = _num(item['item_price']);
  //     final double qty = _num(item['items_count']);
  //
  //     final double itemSubtotal = price * qty;
  //
  //     final String discountType =
  //         item['discount_type']?.toString().toLowerCase() ?? '';
  //
  //     double autoDiscount =
  //     _num(item['auto_discount']) != 0
  //         ? _num(item['auto_discount'])
  //         : _num(item['auto_discount_total']) != 0
  //         ? _num(item['auto_discount_total'])
  //         : _num(item['autoDiscount']) != 0
  //         ? _num(item['autoDiscount'])
  //         : _num(item['autoDiscountTotal']) != 0
  //         ? _num(item['autoDiscountTotal'])
  //         : _num(item['display_auto_discount']);
  //
  //     // double comboDiscount = _num(orderItem['combo_discount_total']) +
  //     //     _num(orderItem['comboDiscountTotal']) +
  //     //     _num(orderItem['combo_discount']);
  //     //
  //     // double mixMatchDiscount = _num(orderItem['mixmatch_discount_total']) +
  //     //     _num(orderItem['mixMatchDiscountTotal']) +
  //     //     _num(orderItem['mixmatch_discount']);
  //     //
  //     // double multipackDiscount = _num(orderItem['multipack_discount_total']) +
  //     //     _num(orderItem['multipackDiscountTotal']) +
  //     //     _num(orderItem['multipack_discount']);
  //
  //     double comboDiscount = [
  //       item['combo_discount_total'],
  //       item['comboDiscountTotal'],
  //       item['combo_discount'],
  //     ]
  //         .map((e) => _num(e))
  //         .firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     double mixMatchDiscount = [
  //       item['mixmatch_discount_total'],
  //       item['mixMatchDiscountTotal'],
  //       item['mixmatch_discount'],
  //     ]
  //         .map((e) => _num(e))
  //         .firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     double multipackDiscount = [
  //       item['multipack_discount_total'],
  //       item['multipackDiscountTotal'],
  //       item['multipack_discount'],
  //     ]
  //         .map((e) => _num(e))
  //         .firstWhere((v) => v != 0, orElse: () => 0);
  //     if (discountType == 'mixmatch' &&
  //         autoDiscount > 0 &&
  //         mixMatchDiscount == 0) {
  //       mixMatchDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //
  //     if (discountType == 'combo' &&
  //         autoDiscount > 0 &&
  //         comboDiscount == 0) {
  //       comboDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //
  //     if (discountType == 'multipack' &&
  //         autoDiscount > 0 &&
  //         multipackDiscount == 0) {
  //       multipackDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //
  //     final double itemDiscount =
  //         autoDiscount +
  //             comboDiscount +
  //             mixMatchDiscount +
  //             multipackDiscount;
  //
  //     totalSubtotal += itemSubtotal;
  //     totalDiscount += itemDiscount;
  //
  //     print("🛒 ITEM: $itemName");
  //     print("Subtotal: $itemSubtotal");
  //     print("Discount: $itemDiscount");
  //   }
  //
  //   final double taxableAmount =
  //       totalSubtotal - totalDiscount;
  //
  //   final double rawTax = taxableAmount * 0.091;
  //
  //   final double roundedTax =
  //   double.parse(rawTax.toStringAsFixed(2));
  //
  //   print("Total Subtotal = $totalSubtotal");
  //   print("Total Discount = $totalDiscount");
  //   print("Taxable Amount = $taxableAmount");
  //   print("Raw Tax = $rawTax");
  //   print("Final Tax = $roundedTax");
  //
  //   print("========== TAX ADJUST END ==========");
  //
  //   return roundedTax;
  // }


  // /// bala tax code

  double _proportionalCouponDiscountForItem(Map<String, dynamic> item) {
    // Only distribute coupon discount across real product lines
    final String itemType = (item['item_type'] ?? '').toString().toLowerCase();
    final String itemName = (item['item_name'] ?? '').toString().toLowerCase();
    if (itemType.contains('discount') || itemType.contains('coupon') ||
        itemType.contains('payout') || itemType.contains('cashback') ||
        itemName.contains('merchant discount')) return 0.0;

    final double couponDisc = discount.abs(); // discount is already negative
    if (couponDisc <= 0 || grossTotal <= 0) return 0.0;

    // Distribute proportionally by line item's gross contribution
    double unitPrice = (item['item_price'] ?? item['price'] ?? 0).toDouble();
    int qty = (item['items_count'] ?? item['quantity'] ?? 1) is num
        ? (item['items_count'] ?? item['quantity'] ?? 1).toInt()
        : 1;
    double lineGross = unitPrice * qty;

    return (lineGross / grossTotal) * couponDisc;
  }

  double _extractTotalDiscountForItem(Map<String, dynamic> item) {
    double n(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;

    double posAuto = n(item['_pos_auto_discount']) +
        n(item['auto_discount']) +
        n(item['autoDiscount']) +
        n(item['auto_discount_total']) +
        n(item['display_auto_discount']);

    double combo = n(item['combo_discount_total']) + n(item['comboDiscountTotal']);
    double multipack = n(item['multipack_discount_total']) + n(item['multipackDiscountTotal']);
    double mixmatch = n(item['mixmatch_discount_total']);

    // ADD: proportional share of order-level coupon discount
    double couponShare = _proportionalCouponDiscountForItem(item);

    final String dtype = (item['discount_type'] ?? '').toString().toLowerCase();

    double lineDiscount;
    if (dtype == 'auto' || dtype.isEmpty) {
      lineDiscount = posAuto;
    } else if (dtype == 'combo' || dtype == 'mixmatch') {
      lineDiscount = combo > 0 ? combo : posAuto;
    } else if (dtype == 'multipack') {
      lineDiscount = multipack > 0 ? multipack : posAuto;
    } else {
      lineDiscount = posAuto + combo + multipack + mixmatch;
    }

    return lineDiscount + couponShare; // ✅ Include coupon share
  }

  Future<void> _recalculateTaxOnDiscountedItems() async {
    if (orderItems.isEmpty) return;

    double toDouble(dynamic v) =>
        v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;

    double resolveTaxRate(Map<String, dynamic> item) {
      for (final key in ['tax_rate', 'tax', 'tax_percent']) {
        final raw = item[key];
        if (raw != null) {
          final r = toDouble(raw);
          if (r > 0) return r / 100.0;
        }
      }
      return 0.0;
    }

    // ─── Only use item-level auto/combo/multipack discounts here.
    // Do NOT include coupon share — coupon is an order-level discount
    // already captured in the `discount` state variable.
    double lineItemOnlyDiscount(Map<String, dynamic> item) {
      double n(dynamic v) =>
          v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;

      double posAuto = n(item['_pos_auto_discount']) +
          n(item['auto_discount']) +
          n(item['autoDiscount']) +
          n(item['auto_discount_total']) +
          n(item['display_auto_discount']);

      double combo =
          n(item['combo_discount_total']) + n(item['comboDiscountTotal']);
      double multipack =
          n(item['multipack_discount_total']) + n(item['multipackDiscountTotal']);
      double mixmatch = n(item['mixmatch_discount_total']);

      final String dtype =
      (item['discount_type'] ?? '').toString().toLowerCase();

      if (dtype == 'auto' || dtype.isEmpty) return posAuto;
      if (dtype == 'combo' || dtype == 'mixmatch')
        return combo > 0 ? combo : posAuto;
      if (dtype == 'multipack') return multipack > 0 ? multipack : posAuto;
      return posAuto + combo + multipack + mixmatch;
    }

    double totalTax = 0.0;
    bool anyItemHasDiscountOrTaxRate = false;
    double totalLineGross = 0.0;
    double totalLineDiscount = 0.0;

    for (final item in orderItems) {
      final String itemType =
      (item['item_type'] ?? '').toString().toLowerCase();
      final String itemName =
      (item['item_name'] ?? '').toString().toLowerCase();

      if (itemType.contains('discount') ||
          itemType.contains('coupon') ||
          itemType.contains('payout') ||
          itemType.contains('cashback') ||
          itemType.contains('loyalty') ||
          itemName.contains('merchant discount')) {
        continue;
      }

      final double unitPrice = toDouble(item['item_price'] ?? item['price']);
      final int qty =
      (item['items_count'] ?? item['quantity'] ?? 1).toInt();
      final double lineTotal = unitPrice * qty;

      // Use ONLY item-level discount (no coupon share)
      final double itemDiscount = lineItemOnlyDiscount(item);
      final double taxableBase =
      (lineTotal - itemDiscount).clamp(0.0, double.infinity);

      totalLineGross += lineTotal;
      totalLineDiscount += itemDiscount;

      if (itemDiscount > 0) anyItemHasDiscountOrTaxRate = true;

      double itemTax = 0.0;
      final double taxRate = resolveTaxRate(item);

      if (taxRate > 0) {
        anyItemHasDiscountOrTaxRate = true;
        itemTax = taxableBase * taxRate;
      } else {
        final double rawTax =
        toDouble(item['item_tax'] ?? item['tax_amount']);
        if (rawTax > 0 && lineTotal > 0) {
          anyItemHasDiscountOrTaxRate = true;
          // Scale the original tax proportionally to the taxable base
          itemTax = rawTax * (taxableBase / lineTotal);
        }
      }

      totalTax += itemTax;
    }

    totalTax = double.parse(totalTax.toStringAsFixed(4));

    final double serverTax = widget.orderTax;

    // Net after ALL discounts (item-level + order-level coupon)
    final double netAfterDiscount =
        totalLineGross - totalLineDiscount + discount + merchantDiscount;

    double finalTax;

    if (!anyItemHasDiscountOrTaxRate) {
      // No item-level data at all — use server tax scaled by coupon discount ratio
      if (serverTax > 0 && discount < 0) {
        // Coupon was applied: scale server tax by (net / gross) ratio
        final double originalGross = widget.grossTotal;
        if (originalGross > 0) {
          final double taxableNet =
          (originalGross + discount).clamp(0.0, double.infinity);
          finalTax = serverTax * (taxableNet / originalGross);
        } else {
          finalTax = 0.0;
        }
      } else {
        finalTax = serverTax > 0 ? serverTax : totalTax;
      }
      if (kDebugMode) {
        print('── TAX: No item-level data. finalTax=$finalTax');
      }
    } else if (totalTax <= 0 && serverTax > 0) {
      // Recalc returned 0 but server has a value — check if net > 0
      if (netAfterDiscount > 0.005) {
        finalTax = serverTax;
      } else {
        finalTax = 0.0;
      }
      if (kDebugMode) {
        print('── TAX: Recalc=0, server=$serverTax, net=$netAfterDiscount → finalTax=$finalTax');
      }
    } else {
      // ── KEY FIX: if a coupon discount is also applied on top of
      // item discounts, scale the recalculated tax further by the
      // coupon ratio so we don't over-report tax.
      if (discount < 0 && totalLineGross > 0) {
        final double postCouponBase =
        (totalLineGross - totalLineDiscount + discount)
            .clamp(0.0, double.infinity);
        final double preCouponBase =
        (totalLineGross - totalLineDiscount).clamp(0.01, double.infinity);
        totalTax = totalTax * (postCouponBase / preCouponBase);
        totalTax = double.parse(totalTax.toStringAsFixed(4));
      }
      finalTax = totalTax;
      if (kDebugMode) {
        print('── TAX: Using recalculated value: $finalTax');
      }
    }

    if (kDebugMode) {
      print('── TAX RECALCULATION COMPLETE ──');
      print('   Gross Total        : $totalLineGross');
      print('   Line Discounts     : $totalLineDiscount');
      print('   Coupon/Order Disc  : $discount');
      print('   Net After Discount : $netAfterDiscount');
      print('   Server Tax         : $serverTax');
      print('   Recalculated Tax   : $totalTax');
      print('   Final Tax Used     : $finalTax');
    }

    final bool taxChanged = (finalTax - tax).abs() > 0.005;
    if (!taxChanged) return;

    final double newNetTotal = widget.grossTotal + discount + merchantDiscount;
    final double newNetPayable = newNetTotal + finalTax + cashbackFee;

    setState(() {
      tax = finalTax;
      NetTotal = newNetTotal;
      computedNetPayable = newNetPayable;
      orderTotal = newNetPayable;

      if (tenderAmount <= 0) {
        balanceAmount = newNetPayable;
      }
    });
    await Future.delayed(const Duration(milliseconds: 100));

    if (widget.offlineOrderId != null) {
      await CustomerDisplayHelper.updateCustomerDisplay(
        widget.offlineOrderId!,
        summaryEnabled: true,
      );
    }
  }

// ─────────────────────────────────────────────────────────────────────────────

  // void _recalculateGrossAndNetFromLineItemDiscounts() {
  //   if (orderItems.isEmpty) return;
  //
  //   double toDouble(dynamic v) =>
  //       v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;
  //
  //   double recalculatedGrossTotal = 0.0;
  //   double totalLineItemDiscount = 0.0;
  //   double payoutCashbackTotal = 0.0;
  //
  //   for (final item in orderItems) {
  //     final String itemType = (item['item_type'] ?? '').toString().toLowerCase();
  //     final String itemName = (item['item_name'] ?? '').toString().toLowerCase();
  //
  //     // ── Payout / cashback: accumulate separately, excluded from product gross.
  //     final bool isPayout = itemType.contains('payout') ||
  //         itemType.contains('cashback') ||
  //         itemName.contains('payout') ||
  //         itemName.contains('cashback');
  //
  //     if (isPayout) {
  //       final double sumPrice = toDouble(item['item_sum_price']);
  //       final double unitPrice = toDouble(item['item_price'] ?? item['price']);
  //       final int qty = (item['items_count'] ?? item['quantity'] ?? 1).toInt();
  //       payoutCashbackTotal += sumPrice != 0 ? sumPrice : unitPrice * qty;
  //       continue;
  //     }
  //
  //     // ── Skip non-product meta lines.
  //     if (itemType.contains('discount') ||
  //         itemType.contains('coupon') ||
  //         itemType.contains('loyalty') ||
  //         itemName.contains('merchant discount')) {
  //       continue;
  //     }
  //
  //     // ── Real product line.
  //     final double itemSumPrice = toDouble(item['item_sum_price']);
  //     final double unitPrice = toDouble(item['item_price'] ?? item['price']);
  //     final int qty = (item['items_count'] ?? item['quantity'] ?? 1).toInt();
  //     final double lineOriginalTotal = unitPrice * qty;
  //
  //     final double lineGross = itemSumPrice > 0 ? itemSumPrice : lineOriginalTotal;
  //     recalculatedGrossTotal += lineGross;
  //
  //     final String dtype = (item['discount_type'] ?? '').toString().toLowerCase();
  //
  //     double autoDiscount = [
  //       item['auto_discount'],
  //       item['auto_discount_total'],
  //       item['autoDiscount'],
  //       item['autoDiscountTotal'],
  //       item['display_auto_discount'],
  //       item['_pos_auto_discount'],
  //     ].map((e) => toDouble(e)).fold(0.0, (a, b) => a + b);
  //
  //     double comboDiscount = [
  //       item['combo_discount_total'],
  //       item['comboDiscountTotal'],
  //       item['combo_discount'],
  //     ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     double mixMatchDiscount = [
  //       item['mixmatch_discount_total'],
  //       item['mixMatchDiscountTotal'],
  //       item['mixmatch_discount'],
  //     ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     double multipackDiscount = [
  //       item['multipack_discount_total'],
  //       item['multipackDiscountTotal'],
  //       item['multipack_discount'],
  //     ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);
  //
  //     if (dtype == 'mixmatch' && autoDiscount > 0 && mixMatchDiscount == 0) {
  //       mixMatchDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //     if (dtype == 'combo' && autoDiscount > 0 && comboDiscount == 0) {
  //       comboDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //     if (dtype == 'multipack' && autoDiscount > 0 && multipackDiscount == 0) {
  //       multipackDiscount = autoDiscount;
  //       autoDiscount = 0;
  //     }
  //
  //     final double itemDiscount =
  //         autoDiscount + comboDiscount + mixMatchDiscount + multipackDiscount;
  //     totalLineItemDiscount += itemDiscount;
  //   }
  //
  //   // Nothing to recalculate if no discounts and gross matches.
  //   if (totalLineItemDiscount <= 0 &&
  //       payoutCashbackTotal == 0 &&
  //       (recalculatedGrossTotal - grossTotal).abs() <= 0.01) {
  //     return;
  //   }
  //
  //   final double newGrossTotal =
  //   recalculatedGrossTotal > 0 ? recalculatedGrossTotal : grossTotal;
  //
  //   final double newGrossAfterItemDiscounts = newGrossTotal - totalLineItemDiscount;
  //
  //   // ── KEY FIX ──────────────────────────────────────────────────────────────
  //   // Gross Total displayed = product gross after discounts + payout/cashback.
  //   // Payout(-10) brings it down: $21.93 + (-$10) = $11.93
  //   // Cashback(+5) brings it up:  $21.93 + (-$5) + $5 = $21.93
  //   final double newGrossForDisplay = newGrossAfterItemDiscounts + payoutCashbackTotal;
  //   // ─────────────────────────────────────────────────────────────────────────
  //
  //   // NetTotal = grossForDisplay + coupon + merchant discount (no payout double-count)
  //   final double newNetTotal = newGrossForDisplay +
  //       discount +        // order-level coupon (negative)
  //       merchantDiscount;
  //
  //   final double newNetPayable = newNetTotal + tax + cashbackFee;
  //
  //   if (kDebugMode) {
  //     print('── LINE-ITEM DISCOUNT RECALCULATION ──');
  //     print('   Product Gross (pre-discount)       : $newGrossTotal');
  //     print('   Total Line Item Discounts          : $totalLineItemDiscount');
  //     print('   Product Gross After Discounts      : $newGrossAfterItemDiscounts');
  //     print('   Payout / Cashback Total            : $payoutCashbackTotal');
  //     print('   Gross For Display (shown)          : $newGrossForDisplay');
  //     print('   Order Discount (coupon)            : $discount');
  //     print('   Merchant Discount                  : $merchantDiscount');
  //     print('   Tax                                : $tax');
  //     print('   Cashback Fee                       : $cashbackFee');
  //     print('   New Net Total                      : $newNetTotal');
  //     print('   New Net Payable                    : $newNetPayable');
  //   }
  //
  //   setState(() {
  //     // Gross Total = product prices after item discounts + payout/cashback
  //     // e.g. no payout:        $21.93
  //     //      payout -$10:      $11.93
  //     //      payout -$5 + cb +$5: $21.93
  //     grossTotal = newGrossForDisplay.clamp(0.0, double.infinity);
  //
  //     NetTotal = newNetTotal.clamp(0.0, double.infinity);
  //     computedNetPayable = newNetPayable.clamp(0.0, double.infinity);
  //     orderTotal = computedNetPayable;
  //
  //     if (tenderAmount <= 0) {
  //       balanceAmount = computedNetPayable;
  //     }
  //   });
  // }

  void _recalculateGrossAndNetFromLineItemDiscounts() {
    if (orderItems.isEmpty) return;

    double toDouble(dynamic v) =>
        v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;

    double recalculatedGrossTotal = 0.0;
    double totalLineItemDiscount = 0.0;
    double payoutCashbackTotal = 0.0;

    for (final item in orderItems) {
      final String itemType = (item['item_type'] ?? '').toString().toLowerCase();
      final String itemName = (item['item_name'] ?? '').toString().toLowerCase();

      // ── Payout / cashback detection — check BOTH item_type AND item_name
      // because some items have empty item_type but name = "Payout" or "Cashback"
      final bool isPayout = itemType.contains('payout') ||
          itemType.contains('cashback') ||
          itemName == 'payout' ||
          itemName == 'cashback' ||
          itemName.contains('payout') ||
          itemName.contains('cashback');

      if (isPayout) {
        final double unitPrice = toDouble(item['item_price'] ?? item['price']);
        final int qty = (item['items_count'] ?? item['quantity'] ?? 1).toInt();
        // Use item_price × qty — always the cashier-entered value.
        // Payout: item_price is negative (e.g. -10), cashback: positive (+5).
        payoutCashbackTotal += unitPrice * qty;
        continue; // ← CRITICAL: skip all further processing for this item
      }

      // ── Skip non-product meta lines.
      if (itemType.contains('discount') ||
          itemType.contains('coupon') ||
          itemType.contains('loyalty') ||
          itemName.contains('merchant discount')) {
        continue;
      }

      // ── Real product line — only reach here for actual products.
      final double itemSumPrice = toDouble(item['item_sum_price']);
      final double unitPrice = toDouble(item['item_price'] ?? item['price']);
      final int qty = (item['items_count'] ?? item['quantity'] ?? 1).toInt();
      final double lineOriginalTotal = unitPrice * qty;

      final double lineGross = itemSumPrice > 0 ? itemSumPrice : lineOriginalTotal;
      recalculatedGrossTotal += lineGross;

      final String dtype = (item['discount_type'] ?? '').toString().toLowerCase();

      double autoDiscount = [
        item['auto_discount'],
        item['auto_discount_total'],
        item['autoDiscount'],
        item['autoDiscountTotal'],
        item['display_auto_discount'],
        item['_pos_auto_discount'],
      ].map((e) => toDouble(e)).fold(0.0, (a, b) => a + b);

      double comboDiscount = [
        item['combo_discount_total'],
        item['comboDiscountTotal'],
        item['combo_discount'],
      ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);

      double mixMatchDiscount = [
        item['mixmatch_discount_total'],
        item['mixMatchDiscountTotal'],
        item['mixmatch_discount'],
      ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);

      double multipackDiscount = [
        item['multipack_discount_total'],
        item['multipackDiscountTotal'],
        item['multipack_discount'],
      ].map((e) => toDouble(e)).firstWhere((v) => v != 0, orElse: () => 0);

      if (dtype == 'mixmatch' && autoDiscount > 0 && mixMatchDiscount == 0) {
        mixMatchDiscount = autoDiscount;
        autoDiscount = 0;
      }
      if (dtype == 'combo' && autoDiscount > 0 && comboDiscount == 0) {
        comboDiscount = autoDiscount;
        autoDiscount = 0;
      }
      if (dtype == 'multipack' && autoDiscount > 0 && multipackDiscount == 0) {
        multipackDiscount = autoDiscount;
        autoDiscount = 0;
      }

      final double itemDiscount =
          autoDiscount + comboDiscount + mixMatchDiscount + multipackDiscount;
      totalLineItemDiscount += itemDiscount;
    }

    // ── Guard: nothing changed, skip setState.
    if (totalLineItemDiscount <= 0 &&
        payoutCashbackTotal == 0 &&
        (recalculatedGrossTotal - grossTotal).abs() <= 0.01) {
      return;
    }

    // ── Use widget.grossTotal as the product baseline when recalculatedGrossTotal
    //    is 0 (pure payout order — no real product lines at all).
    final double productGross = recalculatedGrossTotal != 0
        ? recalculatedGrossTotal
        : (widget.grossTotal > 0 ? widget.grossTotal : 0.0);

    // Product prices after item-level discounts.
    final double productGrossAfterDiscounts = productGross - totalLineItemDiscount;

    // Gross shown in UI = product gross after discounts + payout/cashback.
    // Pure payout order: productGrossAfterDiscounts = 0, payoutCashbackTotal = -10 → -10 ✓
    // Products + payout: 21.93 + (-10) = 11.93 ✓
    final double newGrossForDisplay = productGrossAfterDiscounts + payoutCashbackTotal;

    // NetTotal = grossForDisplay + coupon + merchant discount.
    final double newNetTotal = newGrossForDisplay + discount + merchantDiscount;

    // Net payable — allow negative for refund/payout-only orders.
    final double newNetPayable = newNetTotal + tax + cashbackFee;

    if (kDebugMode) {
      print('── LINE-ITEM DISCOUNT RECALCULATION ──');
      print('   Product Gross (pre-discount)       : $productGross');
      print('   Total Line Item Discounts          : $totalLineItemDiscount');
      print('   Product Gross After Discounts      : $productGrossAfterDiscounts');
      print('   Payout / Cashback Total            : $payoutCashbackTotal');
      print('   Gross For Display                  : $newGrossForDisplay');
      print('   Order Discount (coupon)            : $discount');
      print('   Merchant Discount                  : $merchantDiscount');
      print('   Tax                                : $tax');
      print('   Cashback Fee                       : $cashbackFee');
      print('   New Net Total                      : $newNetTotal');
      print('   New Net Payable                    : $newNetPayable');
    }

    setState(() {
      grossTotal = newGrossForDisplay;
      NetTotal = newNetTotal;
      computedNetPayable = newNetPayable;
      orderTotal = newNetPayable;

      if (tenderAmount <= 0) {
        balanceAmount = newNetPayable;
      }
    });
  }

  @override
  void initState() {
    super.initState();

    const MethodChannel _customerDisplayChannel = MethodChannel(
      'com.example.flutter_customer_display/sunmi_display',
    );

    _customerDisplayChannel.setMethodCallHandler((call) async {
      print("=================================");
      print("📥 FLUTTER RECEIVED: ${call.method}");
      print("ARGS = ${call.arguments}");

      if (call.method == "customerDisplayPopupClosed") {
        print("📥 POPUP CLOSED FROM CUSTOMER DISPLAY");

        if (mounted) {
          setState(() {
            isRedeemActive = false;
            isAddLoading = false;

            // keep phone number
            // do NOT clear mobileController

            // keep validation based on existing number
            isPhoneValid = mobileController.text.isNotEmpty;

            // enable Add button
            isButtonDisabled = false;
          });
        }

        return;
      }



      if (call.method == "customerDisplayRedeemClicked") {
        final String contact = call.arguments["contact"] ?? "";

        print("📱 CONTACT = $contact");
        // CLOSE POS KEYBOARD
        FocusManager.instance.primaryFocus?.unfocus();


        if (contact.isEmpty) {
          if (mounted) {
            setState(() {
              isButtonDisabled = false;
            });
          }
          return;
        }

        try {
          if (mounted) {
            setState(() {
              isButtonDisabled = true;
              isAddLoading = true;
            });
          }

          await _handleCustomerAddFromDisplay(contact);
          // CLOSE AGAIN after controller update
          FocusManager.instance.primaryFocus?.unfocus();

          await _customerDisplayChannel.invokeMethod(
            "customerDisplayResult",
            {
              "success": true,
              "points": availablePoints,
              "redeemedAmount": redeemedValue,
            },
          );

        } catch (e) {
          print("❌ ERROR = $e");

          if (mounted) {
            setState(() {
              isButtonDisabled = false;
              isAddLoading = false;
            });
          }

          await _customerDisplayChannel.invokeMethod(
            "customerDisplayResult",
            {
              "success": false,
              "message": e.toString(),
            },
          );
        }
      }

      print("=================================");
    });

    // remaining initState code...

    ScannerGuard.isCouponPopupOpen= true;

    orderItems = widget.orderItems
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    grossTotal = widget.grossTotal;
    discount =
    (widget.orderDiscount != 0) ? -(widget.orderDiscount.abs()) : 0.0;
    merchantDiscount =
    (widget.merchantDiscount != 0) ? -(widget.merchantDiscount.abs()) : 0.0;
    // tax = getAdjustedSummaryTax();
    orderId = widget.orderId;
    ebtTotal = widget.ebtAmount;

    _displayDate = widget.formattedDate;
    _displayTime = widget.formattedTime;
    cashbackFee = widget.cashbackFee;
    discountValue = widget.discountAmount;

    Future.delayed(Duration.zero, () async {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? 0).toString();
      if (await box.containsKey(key)) {
        final rawExisting = await box.get(key);
        final existing =
        Map<String, dynamic>.from(rawExisting is Map ? rawExisting : {});
        if (widget.ebtAmount > 0 && existing["originalEbt"] != widget.ebtAmount) {
          existing["originalEbt"] = widget.ebtAmount;
          existing["remainingEbt"] = widget.ebtAmount;
          await box.put(key, existing);
          if (kDebugMode) print("🛠 MIGRATED EBT → ${widget.ebtAmount}");
        }
      }

      final offlineBox = StorageProvider.offlineOrders;
      final orderIdKey = (orderId ?? 0).toString();
      if (await offlineBox.containsKey(orderIdKey)) {
        final raw = await offlineBox.get(orderIdKey);
        offlineOrder = raw is Map ? Map<String, dynamic>.from(raw) : null;

        if (offlineOrder != null &&
            offlineOrder!['tenderAmount'] != null &&
            offlineOrder!['balanceAmount'] != null) {
          tenderAmount = (offlineOrder!['tenderAmount'] as num).toDouble();
          balanceAmount = (offlineOrder!['balanceAmount'] as num).toDouble();
          payByCash = (offlineOrder!['payByCash'] as num?)?.toDouble() ?? 0.0;
          payByOther = (offlineOrder!['payByOther'] as num?)?.toDouble() ?? 0.0;

          if (offlineOrder!.containsKey("lastPayment")) {
            _lastPayment = LastPaymentInfo.fromJson(
              Map<String, dynamic>.from(offlineOrder!["lastPayment"]),
            );
          }
          if (balanceAmount > 0) {
            _currentPaymentRemainingBalance = balanceAmount;
            _lastPaymentDetails = {
              'amount': tenderAmount,
              'method': 'Cash',
              'remainingBalance': balanceAmount,
              'datetime': DateTime.now().toIso8601String(),
            };
          } else {
            _currentPaymentRemainingBalance = null;
            _lastPaymentDetails = null;
          }
        } else {
          balanceAmount = orderTotal;
          _currentPaymentRemainingBalance = null;
          _lastPaymentDetails = null;
        }
      } else {
        balanceAmount = orderTotal;
        _currentPaymentRemainingBalance = null;
        _lastPaymentDetails = null;
      }

      await _enrichOrderItemsFromHiveProducts();
      await _recalculateTaxOnDiscountedItems();
      if (!widget.itemPricesAlreadyAdjusted) {
        _recalculateGrossAndNetFromLineItemDiscounts();
      }

      if (mounted) setState(() {});

      await _calculateBalanceFromPaymentHistory();
      await _printPaymentHistorySummary();
      if (_currentPaymentRemainingBalance != null) {
        print("\n ACTIVE PAYMENT SESSION DETECTED");
        print(
            "Remaining Balance: \$${_currentPaymentRemainingBalance!.toStringAsFixed(2)}");
      } else {
        print("\n NO ACTIVE PAYMENT SESSION");
        print(
            "Starting fresh from balance: \$${balanceAmount.toStringAsFixed(2)}");
      }
      await retrySyncUnsyncedPayments();
      await _recalculateTaxOnDiscountedItems();
      if (!widget.itemPricesAlreadyAdjusted) {
        _recalculateGrossAndNetFromLineItemDiscounts();
      }
    });

    Future.delayed(Duration.zero, () async {
      if (kDebugMode) {
        print("\n ORDER SUMMARY INITIALIZED");
        print("Order ID: $orderId");
      }

      // Calculate balance from payment history first
      await _calculateBalanceFromPaymentHistory();

      // Print payment history summary
      await _printPaymentHistorySummary();

      await retrySyncUnsyncedPayments();
      await _recalculateTaxOnDiscountedItems();

    });

    Future.delayed(Duration.zero, () async {
      if (kDebugMode) {
        print("\n ORDER SUMMARY INITIALIZED");
        print("Order ID: $orderId");
      }

      await LocalPaymentDBHelper.instance.printAllPayments();
      await retrySyncUnsyncedPayments();
    });

    amountController.addListener(() {
      if (balanceAmount < 0 &&
          amountController.text != '${TextConstants.currencySymbol}0.00') {
        final value = '${TextConstants.currencySymbol}0.00';
        amountController.text = value;
        amountController.selection =
            TextSelection.collapsed(offset: value.length);
      }
    });

    Future.delayed(Duration.zero, () async {
      final key = (orderId ?? 0).toString();
      final box = StorageProvider.offlineOrders;

      if (!(await box.containsKey(key))) {
        await _createOfflineOrderEntry(key);
      } else {
        // Load existing data
        final data = await _loadOfflineOrderData();
        if (data != null) {
          // Restore state from Hive
          setState(() {
            tenderAmount = (data['tender_amount'] as num?)?.toDouble() ?? 0.0;
            balanceAmount = (data['remaining_balance'] as num?)?.toDouble() ??
                computedNetPayable;
            changeAmount = (data['change_amount'] as num?)?.toDouble() ?? 0.0;
            payByCash = (data['pay_by_cash'] as num?)?.toDouble() ?? 0.0;
            payByCard = (data['pay_by_card'] as num?)?.toDouble() ?? 0.0;
            payByOther = (data['pay_by_other'] as num?)?.toDouble() ?? 0.0;
            isPaymentStarted = tenderAmount > 0;
          });
        }
      }
    });

    _fetchShiftId();
    orderBloc = OrderBloc(OrderRepository());
    selectedPaymentMethod = TextConstants.cash;
    final bool isNegativeOrder = widget.grossTotal < 0;

    print("🏷 q = $discountValue");

    print(" EBT Total in Summary Screen = $ebtTotal");

    // Compute totals
    NetTotal = grossTotal + discount + merchantDiscount;
    computedNetPayable = NetTotal + tax + cashbackFee;

    orderTotal = computedNetPayable;

    print(" Computed Net Payable (Order Total) = $orderTotal");
    // Payment restoration is done in Future.delayed above (async storage)

    // Show restored payment state
    print("💵 Current Payment Breakdown:");
    print("   → payByCash = $payByCash");
    print("   → payByOther = $payByOther");
    print("   → tenderAmount = $tenderAmount");
    print("   → balanceAmount = $balanceAmount");

    // Redeem listener
    mobileController.addListener(() {
      setState(() {
        isMobileValid = RegExp(r'^[0-9]{10}$').hasMatch(mobileController.text);

        if (!isMobileValid) {
          isRedeemActive = false;
        }
      });
    });

    _fetchUserId();

    // Debug dump
    print("🧾 Order Summary Init:"
        "\nItems: ${widget.orderItems.length}"
        "\nGross: ${widget.grossTotal}"
        "\nDiscount: ${widget.orderDiscount}"
        "\nTax: ${widget.orderTax}"
        "\nCashback Fee: $cashbackFee"
        "\nNet Payable: ${widget.netPayable}");

    for (var item in orderItems) {
      print(jsonEncode(item));
    }

    print("💵 INITIAL PAYMENT STATE:");
    print("   payByCash = $payByCash");
    print("   payByOther = $payByOther");
    print("   tenderAmount = $tenderAmount");
    print("   balanceAmount = $balanceAmount");
    print("   orderTotal = $orderTotal");

    if (!isNegativeOrder) {
      _fetchPaymentsByOrderId(); // sale only
    } else {
      //  payout → no API, no loading
      setState(() {
        isLoading = false;
        isSummaryLoading = false;
        balanceAmount = widget.netPayable; // negative
      });
    }
  }

  @override
  void dispose() {
    //Build #1.0.99: Added Dispose
    ScannerGuard.isCouponPopupOpen = false;
    _paymentListSubscription?.cancel();
    paymentBloc.dispose();
    _scrollController.dispose();
    amountController.dispose();

    super.dispose();
  }

  Future<void> _fetchUserId() async {
    // Build #1.0.29: get the userId from db
    final userData = await UserDbHelper().getUserData();
    if (userData != null && userData[AppDBConst.userId] != null) {
      setState(() {
        userId = userData[AppDBConst.userId] as int;
        userDisplayName = userData[AppDBConst.userDisplayName];
        userRole = userData[AppDBConst.userRole];
      });
    }
  }

  static const MethodChannel _paymentChannel =
  MethodChannel("sunmi_payment_channel");

  Future<void> _openSunmiVoidScreen({
    required double amount,
    required String orderId,
    required String originTransactionId,
  }) async {
    if (kDebugMode) {
      print(" Starting CARD VOID → amount=$amount, orderId=$orderId");
    }

    final result = await _paymentChannel.invokeMethod("startVoid", {
      "amount": amount.toString(),
      "originOrderId": orderId,
      "originTransactionId": originTransactionId,
    });

    final data = jsonDecode(result);
    final fullSunmi = jsonDecode(data["fullResponse"]);

    final bool success = data["status"] == "SUCCESS";
    final double voidedAmount =
        double.tryParse(fullSunmi["processedAmount"] ?? "0") ?? 0.0;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Card void failed")),
      );
      return;
    }

    // -------------------------------
    // UPDATE FLUTTER TOTALS
    // -------------------------------
    payByCard = (payByCard - voidedAmount).clamp(0, double.infinity);
    tenderAmount = (tenderAmount - voidedAmount).clamp(0, double.infinity);

    balanceAmount = (orderTotal - tenderAmount).clamp(0, double.infinity);

    changeAmount = 0;

    if (kDebugMode) {
      print(" VOID SUCCESS");
      print("payByCard = $payByCard");
      print("tenderAmount = $tenderAmount");
      print("balanceAmount = $balanceAmount");
    }

    setState(() {});
    // --------------------------------------------------
    // OFFLINE DELETE (same as cash flow)
    // --------------------------------------------------
    if (widget.isOfflineSynced && widget.offlineOrderId != null) {
      try {
        final offlineId = widget.offlineOrderId!;
        final box = StorageProvider.offlineOrders;

        if (await box.containsKey(offlineId.toString())) {
          await box.delete(offlineId.toString());
        }

        await orderHelper.deleteOrder(offlineId);
      } catch (e) {
        print(" Failed deleting offline order: $e");
      }
    }

    // -------------------------------
    //  CALL EXISTING VOID API
    // -------------------------------
    _handleVoidPayment(context, isPartial: true);
  }

  Future<void> _openSunmiSaleScreen({
    required double amount,
    required String orderId,
  }) async {
    setState(() {
      _processingPaymentMethod = TextConstants.card;
      isLoading = true;
    });

    try {
      final result = await _paymentChannel.invokeMethod("startSale", {
        "amount": amount.toString(),
        "orderId": orderId,
      });

      final data = jsonDecode(result);
      final fullSunmi = jsonDecode(data["fullResponse"]);

      double paidAmount = double.tryParse(fullSunmi["processedAmount"] ?? "0") ?? 0.0;

      if (paidAmount <= 0) {
        throw Exception("Invalid paid amount from Sunmi");
      }

      // ==================== UNIFIED PAYMENT FLOW (Same as Cash) ====================
      selectedPaymentMethod = TextConstants.card;

      final String datetime = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

      final localPayment = LocalPayment(
        orderId: widget.orderId ?? 0,
        title: TextConstants.card,
        amount: paidAmount,
        paymentMethod: TextConstants.card,
        shiftId: shiftId,
        vendorId: vendorId,
        userId: userId ?? 0,
        serviceType: serviceType,
        datetime: datetime,
        notes: jsonEncode({
          "sunmiTransactionId": fullSunmi["transactionId"],
          "sunmiOrderId": fullSunmi["orderId"],
          "authCode": fullSunmi["authCode"],
          "cardType": fullSunmi["cardType"],
          "maskedCard": fullSunmi["maskedCardNumber"],
          "hostRef": fullSunmi["hostReferenceNumber"],
        }),
        isSynced: false,
        createdAt: DateTime.now(),
        remainingBalance: (balanceAmount - paidAmount).clamp(0.0, double.infinity),
        status: PaymentDbStatus.pending, // Will be marked completed later if needed
      );

      // 1. Save to Isar
      final savedPayment = await LocalPaymentDBHelper.instance.savePayment(localPayment);

      // 2. Save to Hive (this is what powers your session history)
      await _savePaymentToHive(
        amount: paidAmount,
        paymentMethod: TextConstants.card,
        transactionId: "sunmi_${savedPayment.id}",
        localPayment: savedPayment,
      );

      await _saveLocalPaymentToHive(savedPayment);

      // 3. Store last payment info (for void)
      _lastPayment = LastPaymentInfo(
        method: TextConstants.card,
        amount: paidAmount,
        paymentId: savedPayment.id.toString(),
        sunmiTxnId: fullSunmi["transactionId"]?.toString(),
        sunmiOrderId: fullSunmi["orderId"]?.toString(),
        sunmiDeviceId: fullSunmi["deviceID"]?.toString(),
      );

      // 4. Update local state
      _updateLocalPaymentState(paidAmount, savedPayment);

      // 5. Optional: Also try server sync
      _createPaymentFromSunmi(paidAmount, fullSunmi);

      // 6. Show appropriate dialog
      if (balanceAmount > 0) {
        _showPartialPaymentDialog(context, paidAmount);
      } else {
        _showPaymentSuccessPopup(paidAmount, savedPayment);
      }

    } catch (e, stack) {
      print("Sunmi Card Payment Error: $e");
      print(stack);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Card payment faileddddddd: $e"), backgroundColor: Colors.red),
      );
    } finally {
      setState(() {
        _processingPaymentMethod = null;
        isLoading = false;
      });
    }
  }

  Future<void> _createPaymentFromSunmi(
      double amount,
      Map<String, dynamic> sunmi,
      ) async {
    final String datetime =
    DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

    final paymentRequest = PaymentRequestModel(
      title: "Card",
      orderId: orderId ?? 0,
      amount: amount,
      paymentMethod: TextConstants.card,
      shiftId: shiftId,
      vendorId: vendorId,
      userId: userId ?? 0,
      serviceType: serviceType,
      datetime: datetime,
      notes: jsonEncode({
        "sunmiTransactionId": sunmi["transactionId"],
        "sunmiOrderId": sunmi["orderId"],
        "authCode": sunmi["authCode"],
        "cardType": sunmi["cardType"],
        "maskedCard": sunmi["maskedCardNumber"],
        "hostRef": sunmi["hostReferenceNumber"],
      }),
    );

    //  REQUEST LOG
    print(" ================= SUNMI PAYMENT REQUEST =================");
    print(paymentRequest);
    print("=========================================================");

    // paymentBloc.createPayment(paymentRequest);

    StreamSubscription? subscription;
    subscription =
        paymentBloc.createPaymentStream.listen((paymentResponse) async {
          print("");
          print(" ================= SUNMI PAYMENT FULL RESPONSE =================");

          print("STATUS → ${paymentResponse.status}");
          print("RAW RESPONSE OBJECT → $paymentResponse");

          //  ERROR
          if (paymentResponse.status == Status.ERROR) {
            print(" ERROR MESSAGE → ${paymentResponse.message}");
            print(" ERROR DATA → ${paymentResponse.data}");
            print(
                "===============================================================");
            subscription?.cancel();
            return;
          }

          //  SUCCESS
          if (paymentResponse.status == Status.COMPLETED &&
              paymentResponse.data != null) {
            final data = paymentResponse.data!;

            print(" MESSAGE → ${data.message}");
            print(" PAYMENT ID → ${data.paymentId}");
            print(" ORDER ID → ${data.orderId}");
            print("ORDER STATUS → ${data.orderStatus}");

            // =====================================================
            //  STORE LAST PAYMENT INFO (FOR VOID)
            //=====================
            _lastPayment = LastPaymentInfo(
              method: TextConstants.card,
              amount: amount,
              paymentId: data.paymentId?.toString(),

              sunmiTxnId: sunmi["transactionId"]?.toString(),
              sunmiOrderId: sunmi["orderId"]?.toString(),
              sunmiDeviceId: sunmi["deviceID"]?.toString(), //  FIX
            );

// Keep for API void usage
            paymentId = data.paymentId?.toString();

            // =====================================================
            //  SAVE TO HIVE (SURVIVES APP RESTART)
            // =====================================================
            try {
              final box = StorageProvider.offlineOrders;
              final key = (orderId ?? 0).toString();

              final hasKey = await box.containsKey(key);
              final raw = hasKey ? await box.get(key) : null;
              final existing = Map<String, dynamic>.from(raw is Map ? raw : {});

              existing["lastPayment"] = _lastPayment!.toJson();
              await box.put(key, existing);

              print("💾 LAST PAYMENT SAVED TO HIVE");
              print("   → method = ${_lastPayment!.method}");
              print("   → amount = ${_lastPayment!.amount}");
              print("   → sunmiTxn = ${_lastPayment!.sunmiTxnId}");
              print("   → paymentId = ${_lastPayment!.paymentId}");
            } catch (e) {
              print(" Failed saving last payment to Hive: $e");
            }

            // 🔹 FULL DATA DUMP
            try {
              print("📦 FULL DATA JSON ↓↓↓");
              print(jsonEncode(data.toJson()));
            } catch (e) {
              print("⚠ toJson() not available");
              print(data);
            }
          }

          print("===============================================================");
          subscription?.cancel();
        });
  }

  Future<void> updateOfflineOrderRedeem(
      String orderId,
      double redeemedValue,
      int redeemedPoints,
      int updatedAvailablePoints,
      ) async {
    final box = StorageProvider.offlineOrders;
    final existing = await box.get(orderId);

    if (existing == null) {
      print("[Hive] Cannot update redeem → Order not found: $orderId");
      return;
    }

    final updated = Map<String, dynamic>.from(existing);

    updated["redeemed_value"] = redeemedValue;
    updated["redeemed_points"] = redeemedPoints;
    updated["available_points_after_redeem"] = updatedAvailablePoints;

    await box.put(orderId, updated);

    print(
        " [Hive] Saved redeem → ID: $orderId | value: $redeemedValue | points: $redeemedPoints | left: $updatedAvailablePoints");
  }

  void _recalculateAfterPayment(double amount) {
    double remaining = balanceAmount;

    // 1 If paying by EBT
    if (selectedPaymentMethod == TextConstants.ebtText) {
      if (amount >= ebtTotal) {
        // Full EBT paid
        amount -= ebtTotal;
        remaining -= ebtTotal;
        ebtTotal = 0;
      } else {
        // Partial EBT payment
        ebtTotal -= amount;
        remaining -= amount;
        amount = 0;
      }
    }

    // 2 If paying by CASH or CARD etc.
    else {
      double nonEbtBalance =
          remaining - ebtTotal; // balance that cash CAN pay safely

      if (amount <= nonEbtBalance) {
        // Case 1 → cash does NOT affect EBT
        remaining -= amount;
      } else {
        // Case 2 → extra cash reduces EBT
        double extraCash = amount - nonEbtBalance;

        // Reduce EBT by that extra amount
        ebtTotal = (ebtTotal - extraCash).clamp(0, double.infinity);

        // New remaining balance becomes exactly new EBT
        remaining = ebtTotal;
      }
    }

    balanceAmount = remaining.clamp(0, double.infinity);

    setState(() {});
  }

  Future<void> removeOfflineOrderRedeem(String orderId) async {
    final box = StorageProvider.offlineOrders;
    final existing = await box.get(orderId);

    if (existing == null) return;

    final updated = Map<String, dynamic>.from(existing);

    updated.remove("redeemed_value");
    updated.remove("redeemed_points");
    updated.remove("available_points_after_redeem");

    await box.put(orderId, updated);

    if (kDebugMode) {
      print("🗑 [Hive] Redeem REMOVED → OrderId: $orderId");
    }
  }
  Future<void> _fetchPaymentsByOrderId() async {
    if (kDebugMode) print("###### _fetchPaymentsByOrderId");

    if (orderId == null) return;

    final box = StorageProvider.offlineOrders;
    final key = orderId.toString();

    // ================================
    //  RESTORE REDEEM
    // ================================
    try {
      if (await box.containsKey(key)) {
        final rawStored = await box.get(key);
        final stored =
        Map<String, dynamic>.from(rawStored is Map ? rawStored : {});
        redeemedValue = (stored["redeemed_value"] as num?)?.toDouble() ?? 0.0;
      }
    } catch (_) {
      redeemedValue = 0.0;
    }

    // ================================
    //  RESTORE REMAINING EBT (fallback: original)
    // ================================
    try {
      if (await box.containsKey(key)) {
        final rawStored = await box.get(key);
        final stored =
        Map<String, dynamic>.from(rawStored is Map ? rawStored : {});
        if (stored["remainingEbt"] != null) {
          ebtTotal = (stored["remainingEbt"] as num).toDouble();
        } else if (stored["originalEbt"] != null) {
          ebtTotal = (stored["originalEbt"] as num).toDouble();
        }
      }
    } catch (_) {}

    setState(() => isSummaryLoading = true);

    paymentBloc.getPaymentsByOrderId(orderId!);

    _paymentListSubscription?.cancel();
    _paymentListSubscription =
        paymentBloc.paymentsListStream.listen((response) async {
          if (response.status == Status.COMPLETED) {
            final data = response.data ?? [];
            if (data.isNotEmpty) {
              await _processPaymentList(data);
            } else {
              // API returned empty - use LocalPayment as source of truth
              // (fixes balance showing net payable when payments exist locally but not yet synced)
              await _calculateBalanceFromPaymentHistory();
            }
          }
          if (mounted) setState(() => isSummaryLoading = false);
        });
  }

  Future<void> _processPaymentList(List<PaymentListModel> payments) async {
    // When API returns empty but we may have local payments, prefer LocalPayment
    if (payments.isEmpty) {
      await _calculateBalanceFromPaymentHistory();
      return;
    }

    double cashTotal = 0.0;
    double otherTotal = 0.0;
    double ebtPaid = 0.0;

    // ===================================================
    // 1 ACCUMULATE NON-VOID PAYMENTS
    // ===================================================
    for (final payment in payments) {
      if (payment.voidStatus) continue;

      final amount = double.tryParse(payment.amount) ?? 0.0;

      if (payment.paymentMethod == TextConstants.ebtText) {
        ebtPaid += amount;
      } else if (payment.paymentMethod == TextConstants.cash) {
        cashTotal += amount;
      } else {
        otherTotal += amount;
      }
    }

    final box = StorageProvider.offlineOrders;
    final key = orderId.toString();

    final hasKey = await box.containsKey(key);
    final raw = hasKey ? await box.get(key) : null;
    final existing = Map<String, dynamic>.from(raw is Map ? raw : {});

    // ===================================================
    //  SINGLE SOURCE OF TRUTH
    // ===================================================
    final double basePayable = computedNetPayable;

    // ===================================================
    // LOCK ORIGINAL EBT
    // ===================================================
    final double originalEbt =
        (existing["originalEbt"] as num?)?.toDouble() ?? ebtTotal;

    existing["originalEbt"] ??= originalEbt;

    // ===================================================
    //  REMAINING EBT AFTER EBT PAYMENTS
    // ===================================================
    final double remainingEbt =
    originalEbt - ebtPaid < 0 ? 0.0 : originalEbt - ebtPaid;

    // ===================================================
    //  NON-EBT PORTION
    // ===================================================
    final double nonEbtOrderValue =
    basePayable - originalEbt < 0 ? 0.0 : basePayable - originalEbt;

    final double nonEbtPaid = cashTotal + otherTotal;

    // ===================================================
    //  CASH / CARD OVERFLOW REDUCES EBT
    // ===================================================
    final double overflowToEbt =
    nonEbtPaid > nonEbtOrderValue ? nonEbtPaid - nonEbtOrderValue : 0.0;

    final double finalRemainingEbt =
    remainingEbt - overflowToEbt < 0 ? 0.0 : remainingEbt - overflowToEbt;

    // ===================================================
    //  APPLY REDEEM (DISCOUNT ONLY)
    // ===================================================
    final double effectiveOrderTotal = basePayable - redeemedValue;

    // ===================================================
    //  TOTAL PAID
    // ===================================================
    final double totalPaid = cashTotal + otherTotal + ebtPaid;

    final double rawBalance = effectiveOrderTotal - totalPaid;

// Balance should NEVER be negative
    final double finalBalance = rawBalance > 0 ? rawBalance : 0.0;

// Change only if overpaid
    final double changeAmount = rawBalance < 0 ? rawBalance.abs() : 0.0;

    final Map<String, dynamic> couponResponse =
        (existing["coupon_response"] as Map?)?.cast<String, dynamic>() ?? {};

    // ===================================================
    //  UPDATE UI
    // ===================================================
    setState(() {
      payByCash = cashTotal;
      payByOther = otherTotal;
      payByEbt = ebtPaid;

      ebtTotal = finalRemainingEbt;
      tenderAmount = totalPaid;

      balanceAmount = finalBalance; //  never negative
      isPaymentStarted = totalPaid > 0;

      if (isPaymentStarted) {
        isRedeemActive = false;
      }

      _paymentDialogShown = false;
    });

    // ===================================================
    //  SAVE TO HIVE
    // ===================================================
    existing["remainingEbt"] = finalRemainingEbt;
    existing["redeemed_value"] = redeemedValue;
    existing["remainingBalance"] = finalBalance;

    await box.put(key, existing);

    if (kDebugMode) {
      print(" PAYMENT SUMMARY");
      print("Base Payable      = $basePayable");
      print("Redeem            = $redeemedValue");
      print("Cash              = $cashTotal");
      print("Other             = $otherTotal");
      print("EBT Paid          = $ebtPaid");
      print("Remaining EBT     = $finalRemainingEbt");
      print("Total Paid        = $totalPaid");
      print("Balance           = $finalBalance");
    }

    // ===================================================
// RESET SUCCESS POPUP AFTER VOID / PARTIAL PAYMENT
// ===================================================
    if (finalBalance > 0) {
      _successPopupShown = false;
    }

    // ===================================================
    //  PAYMENT COMPLETE (ZERO OR NEGATIVE)
    // ===================================================
    // if (payments.isNotEmpty && finalBalance <= 0) {
    //   WidgetsBinding.instance.addPostFrameCallback((_) {
    //     _showPaymentDialog(
    //       context,
    //       tenderAmount,
    //       changeAmount: changeAmount, //  negative allowed
    //       showChange: true,
    //       couponResponse: couponResponse,
    //     );
    //   });
    // }
  }

  void _toggleSummary() {
    setState(() {
      _showFullSummary = !_showFullSummary;
    });
  }

  void deleteItemFromOrder(dynamic itemId) async {
    // TODO: Implement actual deletion logic
    setState(() {
      orderItems.removeWhere((item) => item[AppDBConst.itemId] == itemId);
    });
  }

//   void _callCreatePaymentAPI() {
//     if (kDebugMode) {
//       print("###### _callCreatePaymentAPI called, balanceAmount: $balanceAmount");
//     }
//
//     // ------------------------------------------------------
//     //  RULE 0: Ensure user selected a payment method
//     // ------------------------------------------------------
//     if (selectedPaymentMethod == null || selectedPaymentMethod!.isEmpty) {
//       print("❌ ERROR: No payment method selected");
//       return;
//     }
//
//     final bool isCard = selectedPaymentMethod == TextConstants.card;
//
//     // ------------------------------------------------------
//     // ⭐ RULE 1: If method is NOT card, amount is required
//     // ------------------------------------------------------
//     if (!isCard && balanceAmount > 0 && amountController.text.isEmpty) {
//       print("❌ ERROR: Amount required for Cash / Wallet / EBT");
//       return;
//     }
//
//     // Clean amount
//     String cleanAmount = amountController.text
//         .replaceAll(TextConstants.currencySymbol, '')
//         .trim();
//
//     double amount = double.tryParse(cleanAmount) ?? 0.0;
//
//     // ------------------------------------------------------
//     // ⭐ RULE 2: CARD amount handled by Sunmi, ignore validation
//     // ------------------------------------------------------
//     if (isCard) {
//       print("💳 CARD PAYMENT → Skipping amount validation, Sunmi handles it.");
//       amount = amount > 0 ? amount : 0.0;
//     } else {
//       // ------------------------------------------------------
//       // ⭐ RULE 3: No negative amount
//       // ------------------------------------------------------
//       if (amount < 0) {
//         print("❌ ERROR: Negative amount");
//         return;
//       }
//
//       // ------------------------------------------------------
//       // ⭐ RULE 4: Amount cannot be zero IF balance > 0
//       // ------------------------------------------------------
//       if (amount == 0 && computedNetPayable > 0) {
//         setState(() => _amountErrorText = TextConstants.amountValidation);
//         return;
//       }
//     }
//
//     _amountErrorText = null;
//     double remainingBalance = balanceAmount;
//
//     setState(() {
//       _processingPaymentMethod = selectedPaymentMethod;
//       isLoading = true;
//     });
//     _showPaymentProgressDialog(context);
//
//     final String datetime =
//     DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
//
//     // ⭐ Important fix: Dynamic paymentMethod
//     final paymentRequest = PaymentRequestModel(
//       title: selectedPaymentMethod!,
//       orderId: orderId ?? 0,
//       amount: amount,
//       paymentMethod: selectedPaymentMethod!, // <-- correct method passed
//       shiftId: shiftId,
//       vendorId: vendorId,
//       userId: userId ?? 0,
//       serviceType: serviceType,
//       datetime: datetime,
//       notes: '',
//     );
//
//     if (kDebugMode) print("Creating payment with request: $paymentRequest");
//
//     paymentBloc.createPayment(paymentRequest);
//
//     StreamSubscription? subscription;
//     subscription = paymentBloc.createPaymentStream.listen(
//           (paymentResponse) async {
//
//
//         if (kDebugMode) {
//           print("Payment stream response: $paymentResponse");
//         }
//
//         if (paymentResponse.status == Status.ERROR) {
//           _hidePaymentProgressDialog();
//
//           setState(() {
//             _processingPaymentMethod = null;
//             isLoading = false;
//           });
//           subscription?.cancel();
//           return;
//         }
//
//         if (paymentResponse.status == Status.COMPLETED &&
//             paymentResponse.data != null &&
//             paymentResponse.data!.message == "Payment Created Successfully") {
//           setState(() {
//             isPaymentStarted = true;
//             _processingPaymentMethod = null;
//             isLoading = false;
//           });
//
//           final paymentData = paymentResponse.data!;
//           paidAmount = amount;
//           paymentId = paymentData.paymentId.toString();
//           orderStatus =
//               paymentData.orderStatus ?? TextConstants.processing;
//
//           try {
//             final box = StorageProvider.offlineOrders;
//             final key = (orderId ?? 0).toString();
//
//             final existing = box.containsKey(key)
//                 ? Map<String, dynamic>.from(box.get(key))
//                 : <String, dynamic>{};
//
//             existing["coupon_response"] = {
//               "available_coupons": paymentData.availableCoupons,
//               "coupons": paymentData.coupons
//                   ?.map((c) => c.toJson())
//                   .toList(),
//             };
//
//             await box.put(key, existing);
//
//             if (kDebugMode) {
//               print("🎁 FULL COUPON RESPONSE SAVED");
//               print(existing["coupon_response"]);
//             }
//           } catch (e) {
//             print("⚠ Coupon save failed: $e");
//           }
//
//           // ------------------------------------------
//           // OFFLINE DELETE (unchanged)
//           // ------------------------------------------
//           if (widget.isOfflineSynced && widget.offlineOrderId != null) {
//             try {
//               final offlineId = widget.offlineOrderId!;
//               final box = StorageProvider.offlineOrders;
//
//               if (await box.containsKey(offlineId.toString())) {
//                 await box.delete(offlineId.toString());
//               }
//
//               await orderHelper.deleteOrder(offlineId);
//             } catch (e) {
//               print("⚠ Failed deleting offline order: $e");
//             }
//           }
//
//           // =====================================================
// // ⭐ STORE LAST PAYMENT INFO (FOR VOID)
// // =====================================================
//           _lastPayment = LastPaymentInfo(
//             method: selectedPaymentMethod!,
//             amount: amount,
//             paymentId: paymentId,
//             sunmiTxnId: null, // ❗ only card has this
//           );
//
// // Save to Hive
//           try {
//             final box = StorageProvider.offlineOrders;
//             final key = (orderId ?? 0).toString();
//
//             final existing = box.containsKey(key)
//                 ? Map<String, dynamic>.from(box.get(key))
//                 : <String, dynamic>{};
//
//             existing["lastPayment"] = _lastPayment!.toJson();
//             await box.put(key, existing);
//
//             if (kDebugMode) {
//               print("💾 LAST PAYMENT SAVED (NON-CARD)");
//               print("   → method = ${_lastPayment!.method}");
//               print("   → amount = ${_lastPayment!.amount}");
//               print("   → paymentId = ${_lastPayment!.paymentId}");
//             }
//           } catch (e) {
//             print("⚠ Failed saving last payment to Hive: $e");
//           }
//
//
//           // ------------------------------------------
//           // BALANCE CALCULATION (unchanged)
//           // ------------------------------------------
//           final bool isExactPayment = (amount == remainingBalance);
//           final bool isOverPayment = (amount > remainingBalance);
//           final bool isPartialPayment = (amount < remainingBalance);
//
//           tenderAmount += amount;
//
//           if (isOverPayment) {
//             changeAmount = amount - remainingBalance;
//             balanceAmount = 0.0;
//           } else if (isExactPayment) {
//             changeAmount = 0.0;
//             balanceAmount = 0.0;
//           } else if (isPartialPayment) {
//             balanceAmount = remainingBalance - amount;
//             changeAmount = 0.0;
//           }
//
//           balanceAmount =
//               double.tryParse(balanceAmount.toStringAsFixed(2)) ?? 0.0;
//           if (changeAmount != null && changeAmount! > 0) {
//             final repo = PaymentRepository();
//             await repo.updatePaymentMeta(
//               paymentId: int.parse(paymentId!),
//               key: "_payment_remaining_change",
//               value: changeAmount!.toStringAsFixed(2),
//             );
//           }
//
//           _order["balanceAmount"] = balanceAmount;
//           _order["paidAmount"] = tenderAmount;
//           _order["tenderAmount"] = tenderAmount;
//
//           // ------------------------------------------------------
//           // ⭐ SAVE BALANCE + TENDER AMOUNT TO ORDER + HIVE
//           // ------------------------------------------------------
//           try {
//             final offlineBox = StorageProvider.offlineOrders;
//             final key = (orderId ?? 0).toString();
//
//             if (offlineBox.containsKey(key)) {
//               final updated = Map<String, dynamic>.from(offlineBox.get(key));
//
//               updated["balanceAmount"] = balanceAmount;
//               updated["paidAmount"] = tenderAmount;
//               updated["tenderAmount"] = tenderAmount;
//
//               // ⭐ Add this line to store EBT
//               updated["ebtTotal"] = ebtTotal;
//
//               offlineBox.put(key, updated);
//
//               print("✔ Hive updated → balance=$balanceAmount paid=$tenderAmount ebt=$ebtTotal");
//             } else {
//               // If order not in Hive yet, create it
//               offlineBox.put(key, {
//                 "balanceAmount": balanceAmount,
//                 "paidAmount": tenderAmount,
//                 "tenderAmount": tenderAmount,
//                 "payByCash": payByCash,
//                 "payByOther": payByOther,
//                 "ebtTotal": ebtTotal,   // ⭐ Add here too
//               });
//               print("✔ Hive created → balance=$balanceAmount paid=$tenderAmount ebt=$ebtTotal");
//             }
//           } catch (e) {
//             print("⚠ Hive update error: $e");
//           }
//           amountController.clear();
//
//           if (mounted) setState(() {});
//
//           // ------------------------------------------
//           // SHOW POPUPS (unchanged)
//           // ------------------------------------------
//           // if (isPartialPayment && balanceAmount > 0) {
//           //   _showPartialPaymentDialog(context, amount);
//           // } else {
//           //   _fetchPaymentsByOrderId();
//           //   // _showPaymentDialog(
//           //   //   context,
//           //   //   amount,
//           //   //   changeAmount: changeAmount,
//           //   //   showChange: changeAmount > 0,
//           //   // );
//           // }
//
//           // ------------------------------------------------------
// // ⭐ FINAL POPUP CONTROL (CREATE PAYMENT METHOD ONLY)
// // ------------------------------------------------------
//
//           _fetchPaymentsByOrderId(); // keep for UI refresh
//
//           final bool isPaymentComplete = balanceAmount <= 0;
//
//           if (isPaymentComplete && !_successPopupShown) {
//             _successPopupShown = true;
//             _hidePaymentProgressDialog();
//
//             final box = StorageProvider.offlineOrders;
//             final key = (orderId ?? 0).toString();
//
//             final couponResponse =
//                 (box.get(key)?["coupon_response"] as Map?)
//                     ?.cast<String, dynamic>() ??
//                     {};
//
//             _showPaymentDialog(
//               context,
//               tenderAmount,
//               changeAmount: changeAmount,
//               showChange: changeAmount != null && changeAmount! > 0,
//               couponResponse: couponResponse,
//             );
//           } else if (balanceAmount > 0) {
//             _hidePaymentProgressDialog();
//             _showPartialPaymentDialog(context, amount);
//           }
//
//
//           subscription?.cancel();
//         }
//       },
//     );
//   }

  Future<void> _callCreatePaymentAPI({bool skipPopup = false}) async {
    if (kDebugMode) {
      print(
          "###### _callCreatePaymentAPI called, balanceAmount: $balanceAmount, skipPopup: $skipPopup");
    }

    final now = DateTime.now();
    final String datetimeStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    // ────────────────────────────────────────────────
    //  Fake payment mode
    // ────────────────────────────────────────────────
    if (offline_PAYMENT_SUCCESS) {
      if (kDebugMode) print("⚡ FAKE PAYMENT SUCCESS MODE ACTIVE ⚡");

      double amount = double.tryParse(
        amountController.text
            .replaceAll(TextConstants.currencySymbol, '')
            .trim(),
      ) ??
          0.0;

      final double currentBalance = balanceAmount;
      final double newTender = tenderAmount + amount;

      double newBalance = currentBalance - amount;
      double newChange = 0.0;

      if (amount >= currentBalance) {
        newChange = amount - currentBalance;
        newBalance = 0.0;
      }

      newBalance = double.parse(newBalance.toStringAsFixed(2));
      newChange = double.parse(newChange.toStringAsFixed(2));

      final bool isFullPayment = newBalance <= 0;
      final bool isPartialPayment = !isFullPayment && amount > 0;

      // ─── Update UI state ───
      setState(() {
        isPaymentStarted = true;
        _processingPaymentMethod = null;
        isLoading = false;
        paidAmount = amount;
        paymentId = "fake_${now.millisecondsSinceEpoch}";
        orderStatus = TextConstants.completed;
        tenderAmount = newTender;
        balanceAmount = newBalance;
        changeAmount = newChange;

        _currentPaymentRemainingBalance = isPartialPayment ? newBalance : null;

        if (isPartialPayment) {
          // Update payment method totals
          if (selectedPaymentMethod == TextConstants.cash) payByCash += amount;
          if (selectedPaymentMethod == TextConstants.ebtText) {
            payByEbt += amount;
            ebtTotal = (ebtTotal - amount).clamp(0, double.infinity);
          }

          _lastPaymentDetails = {
            'amount': amount,
            'method': selectedPaymentMethod,
            'remainingBalance': newBalance,
            'previousBalance': currentBalance,
            'datetime': now.toIso8601String(),
            'paymentNumber': (_lastPaymentDetails?['paymentNumber'] ?? 0) + 1,
          };
        }
      });

      // ─── Show success popup only for full payment ───
      if (isFullPayment && !_successPopupShown) {
        // ✅ FULL PAYMENT
        _successPopupShown = true;

        final box = StorageProvider.offlineOrders;
        final key = (orderId ?? 0).toString();
        final d = await box.get(key);
        final cr = d is Map ? d["coupon_response"] : null;
        final couponResponse =
        cr is Map ? Map<String, dynamic>.from(cr) : <String, dynamic>{};

        // Update Hive order status
        // final box = StorageProvider.offlineOrders;
        // final key = (orderId ?? 0).toString();
        final raw = await box.get(key);
        if (raw != null) {
          final order = Map<String, dynamic>.from(raw);
          order['order_status'] = TextConstants.completed;
          await box.put(key, order);
        }

        _showPaymentDialog(
          context,
          amount,
          changeAmount: newChange,
          showChange: newChange > 0,
          couponResponse: couponResponse,
        );

// 🟡 PARTIAL PAYMENT — only if amount > 0 and balance remains
      } else if (!isFullPayment && amount > 0) {
        print("🟡 SHOWING PARTIAL PAYMENT DIALOG");
        _showPartialPaymentDialog(context, amount);
      }

      // ─── Save fake payment locally ───
      _lastPayment = LastPaymentInfo(
        method: selectedPaymentMethod ?? "Cash",
        amount: amount,
        paymentId: paymentId,
        sunmiTxnId: null,
      );

      final localPayment = LocalPayment(
        orderId: orderId ?? 0,
        title: selectedPaymentMethod ?? "Cash",
        amount: amount,
        paymentMethod: selectedPaymentMethod ?? "Cash",
        shiftId: shiftId,
        vendorId: vendorId,
        userId: userId ?? 0,
        serviceType: serviceType,
        datetime: datetimeStr,
        notes: "offline payment - ${now.toIso8601String()}",
        isSynced: false,
        createdAt: now,
        // status: isFullPayment ? PaymentDbStatus.completed : PaymentDbStatus.pending,
        status: PaymentDbStatus.pending,
        remainingBalance: newBalance,
      );

      try {
        final saved =
        await LocalPaymentDBHelper.instance.savePayment(localPayment);
        _lastPayment?.paymentId = "local_${saved.id}";
        _updateHivePaymentData(localPayment);

        if (kDebugMode) {
          print(
              " offline  payment saved → ID: ${saved.id}, Amount: $amount, New balance: $newBalance");
        }
      } catch (e) {
        print("✗ Failed to save fake payment: $e");
      }

      amountController.clear();
      return; // Skip real API
    }

    // ────────────────────────────────────────────────
    //  Real payment mode
    // ────────────────────────────────────────────────
    if (selectedPaymentMethod == null || selectedPaymentMethod!.isEmpty) {
      print("❌ ERROR: No payment method selected");
      return;
    }

    final bool isCard = selectedPaymentMethod == TextConstants.card;

    if (!isCard && balanceAmount > 0 && amountController.text.trim().isEmpty) {
      print("❌ ERROR: Amount required for Cash / Wallet / EBT");
      return;
    }

    double amount = double.tryParse(
      amountController.text
          .replaceAll(TextConstants.currencySymbol, '')
          .trim(),
    ) ??
        0.0;

    if (!isCard) {
      if (amount < 0) {
        print("❌ ERROR: Negative amount");
        return;
      }
      if (amount == 0 && computedNetPayable > 0) {
        setState(() => _amountErrorText = TextConstants.amountValidation);
        return;
      }
    } else {
      if (amount <= 0) amount = 0.0;
    }

    _amountErrorText = null;
    final double remainingBalance = balanceAmount;

    setState(() {
      _processingPaymentMethod = selectedPaymentMethod;
      isLoading = true;
    });

    if (!skipPopup) _showPaymentProgressDialog(context);

    final paymentRequest = PaymentRequestModel(
      title: selectedPaymentMethod!,
      orderId: orderId ?? 0,
      amount: amount,
      paymentMethod: selectedPaymentMethod!,
      shiftId: shiftId,
      vendorId: vendorId,
      userId: userId ?? 0,
      serviceType: serviceType,
      datetime: datetimeStr,
      notes: '',
    );

    // paymentBloc.createPayment(paymentRequest);

    StreamSubscription? subscription;
    subscription =
        paymentBloc.createPaymentStream.listen((paymentResponse) async {
          if (kDebugMode) print("Payment stream response: $paymentResponse");

          if (paymentResponse.status == Status.ERROR) {
            if (!skipPopup)
              _hidePaymentProgressDialog();
            else if (Navigator.canPop(context)) Navigator.pop(context);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Payment failed: ${paymentResponse.message}"),
                backgroundColor: Colors.red,
              ),
            );

            setState(() {
              _processingPaymentMethod = null;
              isLoading = false;
              _successPopupShown = false;
            });

            subscription?.cancel();
            return;
          }

          if (paymentResponse.status == Status.COMPLETED &&
              paymentResponse.data != null &&
              paymentResponse.data!.message == "Payment Created Successfully") {
            if (!skipPopup) _hidePaymentProgressDialog();

            final paymentData = paymentResponse.data!;
            paidAmount = amount;
            paymentId = paymentData.paymentId.toString();

            final bool isFullPayment = amount >= remainingBalance;
            final bool isPartialPayment = !isFullPayment && amount > 0;

            // Update balances
            tenderAmount += amount;
            final String paidMethod = selectedPaymentMethod!.toLowerCase().trim();
            if (paidMethod == TextConstants.cash.toLowerCase()) {
              payByCash += amount;
            } else if (paidMethod == TextConstants.card.toLowerCase()) {
              payByCard += amount;
            } else if (paidMethod == TextConstants.ebtText.toLowerCase()) {
              payByEbt += amount;
              ebtTotal = (ebtTotal - amount).clamp(0.0, double.infinity);
            } else {
              payByOther += amount;
            }
            if (isFullPayment) {
              balanceAmount = 0.0;
              changeAmount = amount - remainingBalance;
            } else {
              balanceAmount = remainingBalance - amount;
              changeAmount = 0.0;
            }
            balanceAmount = double.parse(balanceAmount.toStringAsFixed(2));

            // ─── Save last payment info ───
            _lastPayment = LastPaymentInfo(
              method: selectedPaymentMethod!,
              amount: amount,
              paymentId: paymentId,
              sunmiTxnId: null,
            );

            try {
              final box = StorageProvider.offlineOrders;
              final key = (orderId ?? 0).toString();
              final hasKey = await box.containsKey(key);
              final raw = hasKey ? await box.get(key) : null;
              final existing = Map<String, dynamic>.from(raw is Map ? raw : {});
              existing["lastPayment"] = _lastPayment!.toJson();
              existing["balanceAmount"] = balanceAmount;
              existing["paidAmount"] = tenderAmount;
              existing["tenderAmount"] = tenderAmount;
              existing["ebtTotal"] = ebtTotal;
              await box.put(key, existing);
            } catch (e) {
              print("⚠ Hive update error: $e");
            }

            if (mounted)
              setState(() {
                _processingPaymentMethod = null;
                isLoading = false;
                _currentPaymentRemainingBalance =
                isPartialPayment ? balanceAmount : null;
                _lastPaymentDetails = {
                  'amount': amount,
                  'method': selectedPaymentMethod!,
                  'remainingBalance': balanceAmount,
                  'previousBalance': remainingBalance,
                  'datetime': DateTime.now().toIso8601String(),
                };
              });

            // ─── Full: success receipt dialog | Partial: "next payment" dialog ───
            // Progress overlay was already closed above for both paths (!skipPopup).
            if (isFullPayment && !_successPopupShown) {
              _successPopupShown = true;

              final box = StorageProvider.offlineOrders;
              final key = (orderId ?? 0).toString();
              final rawBox = await box.get(key);
              final cr = rawBox is Map ? rawBox["coupon_response"] : null;
              final couponResponse =
              cr is Map ? Map<String, dynamic>.from(cr) : <String, dynamic>{};

              _showPaymentDialog(
                context,
                amount,
                changeAmount: changeAmount,
                showChange: changeAmount > 0,
                couponResponse: couponResponse,
              );
            } else if (isPartialPayment && amount > 0) {
              await _showPartialPaymentDialog(context, amount);
            }

            amountController.clear();
            _fetchPaymentsByOrderId();
            subscription?.cancel();
          }
        });
  }

  void _hidePaymentProgressDialog() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeHelper = Provider.of<ThemeNotifier>(context);
    ResponsiveLayout.init(context);

    return Scaffold(
      backgroundColor: themeHelper.themeMode == ThemeMode.dark
          ? ThemeNotifier.secondaryBackground
          : Color(0xFFF1F1F3),
      body: SafeArea(
        child: Column(
          children: [
            // Top Header with logo and user info
            // _buildHeader(),
            _buildNavigationBar(),

            // Main content area: split horizontally
            Expanded(
              child: Row(
                children: [
                  // Left Side: Navigation bar + Order Summary stacked vertically
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        Expanded(
                          child: _buildOrderSummary(),
                        ),
                      ],
                    ),
                  ),

                  // Right Side: Payment Section
                  Expanded(
                    flex: 4,
                    child: Column(
                      children: [
                        // Payment content takes remaining space
                        Expanded(
                          child: _buildPaymentSection(),
                        ),

                        Container(
                          margin: const EdgeInsets.only(
                            left: 0,
                            right: 8,
                            top: 0,
                            bottom: 8,
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 30, vertical: 8),
                          decoration: themeHelper.themeMode == ThemeMode.dark
                              ? ShapeDecoration(
                            color: const Color(
                                0xFF1F1D2B), // dark background
                            shape: RoundedRectangleBorder(
                              // side: BorderSide(
                              //   width: 0,
                              //   color: Colors.black.withOpacity(0.20),
                              // ),
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(
                                    ResponsiveLayout.getRadius(10)),
                                bottomRight: Radius.circular(
                                    ResponsiveLayout.getRadius(10)),
                              ),
                            ),
                          )
                              : BoxDecoration(
                            color: Colors.white, // light background
                            borderRadius: BorderRadius.only(
                              bottomLeft: Radius.circular(
                                  ResponsiveLayout.getRadius(10)),
                              bottomRight: Radius.circular(
                                  ResponsiveLayout.getRadius(10)),
                            ),
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: themeHelper.themeMode == ThemeMode.dark
                                  ? const Color(
                                  0xFF303136) // dark mode background
                                  : Colors.white, // light mode background
                              border: Border.all(
                                color: themeHelper.themeMode == ThemeMode.dark
                                    ? Color(
                                    0xFF303136) // optional darker border for dark mode
                                    : const Color(0xFFEDF2F9),
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: themeHelper.themeMode == ThemeMode.dark
                                      ? Colors.black.withOpacity(
                                      0.3) // subtle shadow in dark mode
                                      : Colors.white,
                                  blurRadius: 8,
                                  offset: const Offset(2, 4),
                                  spreadRadius: 0,
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _buildPaymentModeButton(
                                  TextConstants.cash,
                                  Image.asset(
                                    'assets/cash.png',
                                    width: ResponsiveLayout.getIconSize(24),
                                    height: ResponsiveLayout.getIconSize(24),
                                    fit: BoxFit.contain,
                                  ),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF9CCD7B),
                                      Color(0xFF9CCD7B)
                                    ],
                                  ),
                                  borderColor: const Color(0xFF9CCD7B),
                                  iconColor: Color(0xFF9CCD7B),
                                  isLoading: _processingPaymentMethod ==
                                      TextConstants.cash &&
                                      isLoading,
                                  isDisabled:
                                  _processingPaymentMethod != null &&
                                      _processingPaymentMethod !=
                                          TextConstants.cash,
                                  onTap: () async {
                                    _selectPaymentMethod(TextConstants.cash);
                                    // await CustomerService
                                    //     .publishProcessingPayment(
                                    //   orderId ?? 0,
                                    //   orderItems, // your list of items
                                    //   subtotal:
                                    //       grossTotal, // same as you send to display now
                                    //   tax: tax, // existing tax variable
                                    //   total:
                                    //       computedNetPayable, // or balanceAmount if you prefer
                                    // );
                                    _handlePay();
                                  },
                                ),
                                _buildPaymentModeButton(
                                  TextConstants.card,
                                  Image.asset(
                                    'assets/card.png',
                                    width: ResponsiveLayout.getIconSize(24),
                                    height: ResponsiveLayout.getIconSize(24),
                                    fit: BoxFit.contain,
                                  ),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFA484C8),
                                      Color(0xFFA484C8)
                                    ],
                                  ),
                                  borderColor: const Color(0xFFA484C8),
                                  iconColor: Color(0xFFA484C8),
                                  // isLoading: _processingPaymentMethod == TextConstants.card && isLoading,
                                  // isDisabled: _processingPaymentMethod != null && _processingPaymentMethod != TextConstants.card,

                                  isLoading: false,
                                  isDisabled: false,
                                  onTap: () async {
                                    _selectPaymentMethod(
                                      TextConstants.card,
                                      //autoFillAmount: true,
                                      maxAllowedAmount: balanceAmount,
                                    );
                                    _handlePay();


                                  },
                                ),
                                _buildPaymentModeButton(
                                  TextConstants.wallet,
                                  Image.asset(
                                    'assets/wallet.png',
                                    width: ResponsiveLayout.getIconSize(24),
                                    height: ResponsiveLayout.getIconSize(24),
                                    fit: BoxFit.contain,
                                  ),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFCCB985),
                                      Color(0xFFCCB985)
                                    ],
                                  ),
                                  borderColor: const Color(0xFFCCB985),
                                  iconColor: Color(0xFFCCB985),
                                  // isLoading: _processingPaymentMethod == TextConstants.wallet && isLoading,
                                  // isDisabled: _processingPaymentMethod != null && _processingPaymentMethod != TextConstants.wallet,
                                  // ❌ FORCE DISABLE
                                  isLoading: false,
                                  isDisabled: true,
                                  onTap: () {
                                    _selectPaymentMethod(
                                      TextConstants.wallet,
                                      //autoFillAmount: true,
                                      maxAllowedAmount: balanceAmount,
                                    );
                                    _handlePay();
                                  },
                                ),
                                //  Commented the code as part of boutique flow
                                // _buildPaymentModeButton(
                                //   TextConstants.ebtText,
                                //   Image.asset(
                                //     'assets/ebt.png',
                                //     width: ResponsiveLayout.getIconSize(24),
                                //     height: ResponsiveLayout.getIconSize(24),
                                //     fit: BoxFit.contain,
                                //   ),
                                //   gradient: const LinearGradient(
                                //     colors: [
                                //       Color(0xFF84A2CB),
                                //       Color(0xFF84A2CB)
                                //     ],
                                //   ),
                                //   borderColor: const Color(0xFF84A2CB),
                                //   iconColor: Colors.white,
                                //   isLoading: _processingPaymentMethod ==
                                //       TextConstants.ebtText &&
                                //       isLoading,
                                //   isDisabled:
                                //   _processingPaymentMethod != null &&
                                //       _processingPaymentMethod !=
                                //           TextConstants.ebtText,
                                //   onTap: () {
                                //     // 1️⃣ Check if there is any EBT left
                                //     if (ebtTotal <= 0) {
                                //       setState(() => _amountErrorText =
                                //       "No EBT balance available");
                                //       return;
                                //     }
                                //
                                //     // 2️⃣ Determine the maximum allowed amount
                                //     final allowedAmount =
                                //     balanceAmount.clamp(0.0, ebtTotal);
                                //
                                //     if (allowedAmount <= 0) {
                                //       setState(() => _amountErrorText =
                                //       "Cannot pay with EBT, balance is zero");
                                //       return;
                                //     }
                                //
                                //     // 3️⃣ Respect user-entered partial amount when present.
                                //     final enteredAmount = double.tryParse(
                                //       amountController.text
                                //           .replaceAll(
                                //           TextConstants.currencySymbol, '')
                                //           .trim(),
                                //     ) ??
                                //         0.0;
                                //
                                //     final amountToUse = enteredAmount > 0
                                //         ? enteredAmount.clamp(0.0, allowedAmount)
                                //         : allowedAmount;
                                //
                                //     if (amountToUse <= 0) {
                                //       setState(() => _amountErrorText =
                                //           TextConstants.amountValidation);
                                //       return;
                                //     }
                                //
                                //     // 4️⃣ Select EBT only (manual amount entry by user)
                                //     _selectPaymentMethod(
                                //       TextConstants.ebtText,
                                //     );
                                //
                                //     // If user already entered amount, submit like Cash flow.
                                //     if (enteredAmount > 0) {
                                //       final normalizedAmount = amountToUse;
                                //       setState(() {
                                //         _rawAmount = (normalizedAmount * 100).round();
                                //         amountController.text =
                                //         '${TextConstants.currencySymbol}${normalizedAmount.toStringAsFixed(2)}';
                                //         _isAmountEntered = true;
                                //         _amountErrorText = null;
                                //       });
                                //       _handlePay();
                                //       return;
                                //     }
                                //
                                //     // Otherwise keep EBT amount user-driven.
                                //     setState(() {
                                //       _rawAmount = 0;
                                //       amountController.text =
                                //       '${TextConstants.currencySymbol}0.00';
                                //       _isAmountEntered = false;
                                //       _amountErrorText = null;
                                //     });
                                //   },
                                // ),
                              ],
                            ),
                          ),
                        )
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPaymentProgressDialog(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    // THEME COLORS (same pattern as coupon popup)
    final Color dialogBg = isDark ? const Color(0xFF252837) : Colors.white;
    final Color textPrimary = isDark ? Colors.white : const Color(0xFF1F2937);
    final Color textSecondary =
    isDark ? Colors.white70 : const Color(0xFF6B7280);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return WillPopScope(
          onWillPop: () async => false,
          child: Dialog(
            elevation: 0,
            backgroundColor: Colors.transparent,
            child: Center(
              child: Container(
                width: 300,
                padding: const EdgeInsets.symmetric(
                  vertical: 28,
                  horizontal: 24,
                ),
                decoration: BoxDecoration(
                  color: dialogBg,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    if (!isDark)
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark
                              ? Colors.white70
                              : const Color(0xFF1BA672),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      "Payment in progress",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (_processingPaymentMethod != null)
                      Text(
                        "Processing ${_processingPaymentMethod!}",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Container(
      height: ResponsiveLayout.getHeight(60),
      color: themeHelper.themeMode == ThemeMode.dark
          ? ThemeNotifier.primaryBackground
          : Color(0xFFE4E4E4),
      padding: ResponsiveLayout.getResponsivePadding(
        horizontal: 16,
        vertical: 0,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Pinaka logo with triangle above it
          SvgPicture.asset(
            themeHelper.themeMode == ThemeMode.dark
                ? 'assets/svg/app_logo.svg'
                : 'assets/svg/app_icon.svg',
            height: ResponsiveLayout.getHeight(40),
            width: ResponsiveLayout.getWidth(40),
          ),

          // User profile section with container and notification bell
          Row(
            children: [
              Container(
                height: ResponsiveLayout.getHeight(45), //45
                margin: EdgeInsets.all(ResponsiveLayout.getPadding(10)),
                padding: EdgeInsets.symmetric(
                    horizontal: ResponsiveLayout.getPadding(16), vertical: 0),
                decoration: BoxDecoration(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.secondaryBackground
                      : Colors.white,
                  borderRadius:
                  BorderRadius.circular(ResponsiveLayout.getRadius(15)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: ResponsiveLayout.getRadius(18),
                      backgroundColor: Colors.deepPurple,
                      child: Text(
                        (userDisplayName ?? TextConstants.unknown).substring(
                            0, 1), //"A", /// use initial for the login user
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: ResponsiveLayout.getFontSize(14)),
                      ),
                    ),
                    SizedBox(width: ResponsiveLayout.getWidth(12)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          userDisplayName ??
                              "", //'A Raghav Kumar', /// use login user display name
                          style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: themeHelper.themeMode == ThemeMode.dark
                                  ? ThemeNotifier.textDark
                                  : ThemeNotifier.textLight,
                              fontSize: ResponsiveLayout.getFontSize(14)),
                        ),
                        Text(
                          userRole ??
                              TextConstants
                                  .unknown, //'I am Cashier', /// use user role
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: ResponsiveLayout.getWidth(16)),
              Container(
                decoration: BoxDecoration(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.secondaryBackground
                      : Colors.white,
                  shape: BoxShape.circle,
                ),
                padding: EdgeInsets.all(ResponsiveLayout.getPadding(10)),
                child: Icon(
                  Icons.notifications_outlined,
                  size: ResponsiveLayout.getIconSize(24),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showCouponAppliedSnackBar(
      BuildContext context,
      ) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            "Coupon already applied. Remove coupon to go back.",
          ),

          //  RED COLOR
          backgroundColor: Colors.red,

          duration: Duration(seconds: 3),

          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _showRedeemPointsSnackBar(BuildContext context) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "Loyalty applied, please remove and try again",
        ),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildNavigationBar() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final theme = Theme.of(context);

    // Determine the date and time to display
    _displayDate = widget.formattedDate;
    _displayTime = widget.formattedTime;

    final order = orderHelper.activeOrderId != null
        ? orderHelper.orders.firstWhere(
          (o) => o[AppDBConst.orderServerId] == orderHelper.activeOrderId,
      orElse: () => {},
    )
        : {};

    if (order.isNotEmpty && order[AppDBConst.orderDate] != null) {
      try {
        final DateTime createdDateTime =
        DateTime.parse(order[AppDBConst.orderDate].toString());
        _displayDate =
            DateFormat(TextConstants.dateFormat).format(createdDateTime);
        _displayTime =
            DateFormat(TextConstants.timeFormat).format(createdDateTime);
      } catch (e) {
        if (kDebugMode) {
          print("Error parsing order creation date: $e");
        }
        // Fallback to raw data or default if parsing fails
        _displayDate = order[AppDBConst.orderDate].toString().split(' ').first;
      }
    }

    bool isCustomerFieldDisabled = redeemedValue > 0;
    final bool isButtonDisabled = isPaymentDone ||
        redeemedValue > 0 ||
        isOrderPending ||
        (!(isPhoneValid || isEmailValid) && !showCustomerInput);

    return Container(
      height: ResponsiveLayout.getHeight(60),
      width: double.infinity,
      margin: EdgeInsets.all(ResponsiveLayout.getPadding(10)),
      padding: EdgeInsets.symmetric(horizontal: ResponsiveLayout.getPadding(6)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ResponsiveLayout.getRadius(10)),
        color: themeHelper.themeMode == ThemeMode.dark
            ? ThemeNotifier.appBarBackground
            : const Color(0xFFFFFFFF),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ////**88 */ Back button

          InkWell(
            borderRadius: BorderRadius.circular(ResponsiveLayout.getRadius(8)),
            onTap: () async {
              final box = StorageProvider.offlineOrders;

              final String orderKey = orderId?.toString() ??
                  widget.offlineOrderId?.toString() ??
                  "";

              final rawOrder = await box.get(orderKey);

              final latestOrder = Map<String, dynamic>.from(
                rawOrder is Map ? rawOrder : {},
              );

              print("LATEST ORDER -> $latestOrder");

              final bool couponExists = latestOrder["coupon_applied"] == true;

              print("coupon_applied: ${latestOrder["coupon_applied"]}");
              print("couponExists: $couponExists");

              // Get payments (defensive fallback across possible local/server IDs)
              // so back-flow still detects a void even when one ID path is empty.
              final Set<int> candidateIds = {
                if (orderId != null && orderId! > 0) orderId!,
                if (widget.orderId != null && widget.orderId! > 0) widget.orderId!,
                if (widget.offlineOrderId != null && widget.offlineOrderId! > 0)
                  widget.offlineOrderId!,
              };

              final List<LocalPayment> payments = [];
              final Set<int> seenPaymentIds = {};
              for (final id in candidateIds) {
                final rows =
                await LocalPaymentDBHelper.instance.getPaymentsByOrderId(id);
                for (final p in rows) {
                  if (seenPaymentIds.add(p.id)) {
                    payments.add(p);
                  }
                }
              }

              final bool hasAnyPaymentBeenMade = payments.isNotEmpty;

              double netAmount = payments.fold(0.0, (sum, p) => sum + p.amount);

              final bool hasNetPayment = netAmount.abs() > 0.01;

              // After a full void, net can be ~0 but unsynced void lines must still sync;
              // user should still get the exit confirmation.
              final bool hasUnsyncedPayments =
              payments.any((p) => !p.isSynced);

              final bool hasDiscount = discount > 0;

              final bool hasRedeemPoints = redeemedValue > 0;

              if (kDebugMode) {
                print("===== BACK BUTTON DEBUG =====");
                print("redeemedValue(UI): $redeemedValue");
                print("isRedeemAppliedFromApi: $isRedeemAppliedFromApi");
                print("hasRedeemPoints: $hasRedeemPoints");
                print("============================");
              }

              // Remaining balance
              final double effectiveRemaining =
              (_currentPaymentRemainingBalance != null &&
                  _currentPaymentRemainingBalance! > 0)
                  ? _currentPaymentRemainingBalance!
                  : balanceAmount;

// Always update customer display
              if (orderId != null) {
                await CustomerDisplayHelper.updateCustomerDisplay(
                  orderId!,
                  summaryEnabled: false,
                );
              }

// CASE 1: partial/full payment started
              if (hasAnyPaymentBeenMade || hasUnsyncedPayments) {
                _showExitPaymentConfirmation(context);
                return;
              }

// CASE 2: redeem applied but no payment
              if (hasRedeemPoints) {
                _showRedeemPointsSnackBar(context);
                return;
              }

              // ✅ CASE 2: Coupon applied but no payment yet
              // CASE 2: Coupon applied
              if (couponExists) {
                // ⭐ ISSUE COUPON → show exit confirmation popup
                if (isCouponActive) {
                  print("🎟 Issue coupon → showing exit confirmation");
                  _showExitPaymentConfirmation(context);
                  return;
                }

                // ⭐ GENERATED COUPON → show snackbar
                print("🚨 Generated coupon exists → showing snackbar");
                _showCouponAppliedSnackBar(context);
                return;
              }
              if (couponExists || isCouponAppliedFromApi) {
                print("🚨 Coupon already applied → showing snackbar");
                _showCouponAppliedSnackBar(context);
                return;
              }
              // ✅ CASE 3: Discount applied
              if (hasDiscount) {
                _showExitPaymentConfirmation(context);
                return;
              }

              // ✅ CASE 4: No payment and no coupon
              if (kDebugMode) {
                print("Back button → direct exit");
              }

              Navigator.of(context).pop();
            },
            child: Container(
              // height: 40,
              margin: EdgeInsets.only(left: 15.0, top: 10.0),
              width: MediaQuery.of(context).size.width * 0.075,
              height: MediaQuery.of(context).size.height * 0.05,
              decoration: BoxDecoration(
                color: Color(0xFF3B4259),
                borderRadius: BorderRadius.circular(6.0),
                border: Border.all(color: Color(0xFF3B4259)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(width: 10),
                  Container(
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.arrow_back,
                      size: 20,
                      weight: 10,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    TextConstants.back,
                    style: TextStyle(
                      fontSize: ResponsiveLayout.getFontSize(15),
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 70),

          const SizedBox(width: 160),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ---------------- CUSTOMER INPUT CONTAINER ----------------
                Expanded(
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.only(
                      top: 4,
                      left: 16,
                      right: 10,
                      bottom: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF40424F)
                          : const Color(0xFFE5EFFF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Customer :',
                          style: TextStyle(
                            color:
                            Theme.of(context).brightness == Brightness.dark
                                ? Colors.white70
                                : const Color(0xFF115ACD),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        //  Updated the field to support only mobile number entry as part of boutique app changes.
                        Expanded(
                          child: Container(
                            height: 40,
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            decoration: BoxDecoration(
                              color: Theme.of(context).brightness ==
                                  Brightness.dark
                                  ? const Color(0xFF2C2C2E)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                width: 1,
                                color: Theme.of(context).brightness ==
                                    Brightness.dark
                                    ? Colors.grey.shade700
                                    : Colors.black.withOpacity(0.20),
                              ),
                            ),
                            alignment: Alignment.centerLeft,
                            child: StatefulBuilder(
                              builder: (context, innerSetState) {
                                return TextField(
                                  controller: mobileController,
                                  enabled: !isCustomerFieldDisabled,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(10),
                                    TextInputFormatter.withFunction(
                                            (oldValue, newValue) {
                                          final text = newValue.text;

                                          // If input is only digits → Mobile number
                                          if (RegExp(r'^\d*$').hasMatch(text)) {
                                            if (text.length > 10) {
                                              return oldValue; // block extra digits
                                            }
                                          }
                                          // Otherwise → Email
                                          else {
                                            if (text.length > 50) {
                                              return oldValue; // block extra characters
                                            }
                                          }

                                          return newValue;
                                        }),
                                  ],
                                  onChanged: (value) {
                                    setState(() {
                                      isPhoneValid = RegExp(r'^[0-9]{10}$')
                                          .hasMatch(value);
                                      isEmailValid = RegExp(
                                        r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
                                      ).hasMatch(value);
                                    });
                                  },
                                  decoration: const InputDecoration(
                                    hintText: 'Add Mobile Number ',
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    counterText: '',
                                  ),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Theme.of(context).brightness ==
                                        Brightness.dark
                                        ? Colors.white
                                        : const Color(0xFF313131),
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

                const SizedBox(width: 18),

                // ---------------- ADD / CANCEL BUTTON (SAME LOGIC) ----------------
                InkWell(
                  onTap: isButtonDisabled
                      ? null
                      : () async {
                    // ---------- CANCEL ----------
                    if (showCustomerInput) {
                      // Only allow cancel if not disabled
                      if (isPaymentDone || redeemedValue > 0) return;

                      setState(() {
                        mobileController.clear();
                        showCustomerInput = false;
                        isPhoneValid = false;
                        isEmailValid = false;
                        isRedeemActive = false;
                      });

                      final offlineBox = StorageProvider.offlineOrders;
                      final localKey = widget.offlineOrderId?.toString();

                      if (localKey != null) {
                        final existing = await offlineBox.get(localKey);
                        if (existing != null) {
                          final d = Map<String, dynamic>.from(
                              existing is Map ? existing : {});
                          d["loyaltyContact"] = "";
                          await offlineBox.put(localKey, d);
                        }
                      }

                      final localOrderId = widget.offlineOrderId;
                      if (localOrderId != null) {
                        await CustomerDisplayHelper.updateCustomerDisplay(
                          localOrderId,
                          summaryEnabled: true,
                        );
                      }
                      return;
                    }

                    // ---------- ADD ----------
                    // ---------- ADD ----------
                    if (!(isPhoneValid || isEmailValid)) return;

                    setState(() => isAddLoading = true);

                    final contact = mobileController.text.trim();

                    try {

                      // ======================================
                      // 1️⃣ LOAD OFFLINE ORDER FROM HIVE
                      // ======================================
                      final offlineBox = StorageProvider.offlineOrders;

                      final localKey = widget.offlineOrderId?.toString();

                      if (localKey == null) {
                        throw Exception("Offline order not found");
                      }

                      final existing = await offlineBox.get(localKey);

                      if (existing == null) {
                        throw Exception("Order data missing");
                      }

                      final offlineOrder =
                      Map<String, dynamic>.from(existing);

                      print("🟡 OFFLINE ORDER LOADED");

                      // ======================================
                      // 2️⃣ SYNC ORDER WITH BACKEND
                      // ======================================
                      final syncResponse =
                      await orderBloc.syncSingleOfflineOrder(
                        offlineOrder,
                      );

                      print("✅ SYNC RESPONSE points: $syncResponse");

                      if (syncResponse == null) {
                        throw Exception("Sync failed");
                      }

                      // ======================================
                      // 3️⃣ GET WOO ORDER ID
                      // ======================================
                      final int syncedOrderId =
                          syncResponse["id"] ?? 0;

                      if (syncedOrderId == 0) {
                        throw Exception("Backend order id missing");
                      }

                      print("🟢 WOO ORDER ID lo: $syncedOrderId");

                      // ======================================
                      // 4️⃣ CALL CREATE CUSTOMER API
                      // ======================================
                      final rawResponse =
                      await orderBloc.addLoyaltyPoints(
                        orderId: syncedOrderId,
                        contact: contact,
                      );

                      print("🌐 CUSTOMER RESPONSE: $rawResponse");

                      final result = jsonDecode(rawResponse);

                      print("✅ FULL CUSTOMER RESULT: $result");

                      if (result == null) {
                        throw Exception("Empty customer response");
                      }

                      if (result["success"] == false) {
                        throw Exception(
                          result["message"] ?? "Customer API failed",
                        );
                      }

                      final data = result["data"] ?? {};

                      final pts = int.tryParse(
                        data["available_points"]?.toString() ?? "0",
                      ) ?? 0;
                      // ======================================
                      // 5️⃣ UPDATE UI
                      // ======================================
                      setState(() {
                        loyaltyData = data;
                        availablePoints = pts;
                        isRedeemActive = true;
                        showCustomerInput = true;
                      });

                      // ======================================
                      // 6️⃣ SAVE CONTACT LOCALLY
                      // ======================================
                      offlineOrder["loyaltyContact"] = contact;

                      await offlineBox.put(localKey, offlineOrder);

                      // ======================================
                      // 7️⃣ UPDATE CUSTOMER DISPLAY
                      // ======================================
                      // ======================================
// 7️⃣ DO NOT REFRESH CUSTOMER DISPLAY
// ======================================
                      try {
                        await const MethodChannel(
                          'com.example.flutter_customer_display/sunmi_display',
                        ).invokeMethod(
                          'showCustomerData',
                          {
                            'orderId': int.tryParse(localKey) ?? 0,
                            'items': List<Map<String, dynamic>>.from(
                              offlineOrder['products'] ?? [],
                            ),
                            'grossTotal':
                            (offlineOrder['gross_total'] as num?)?.toDouble() ?? 0.0,
                            'discount':
                            (offlineOrder['discount'] as num?)?.toDouble() ?? 0.0,
                            'merchantDiscount':
                            (offlineOrder['merchant_discount'] as num?)?.toDouble() ?? 0.0,
                            'netTotal':
                            (offlineOrder['net_total'] as num?)?.toDouble() ?? 0.0,
                            'tax':
                            (offlineOrder['order_tax'] as num?)?.toDouble() ?? 0.0,
                            'netPayable':
                            (offlineOrder['net_payable'] as num?)?.toDouble() ?? 0.0,
                            'orderDate': offlineOrder['order_date'] ?? '',
                            'orderTime': offlineOrder['order_time'] ?? '',
                            'cashbackFee':
                            (offlineOrder['cashback_fee'] as num?)?.toDouble() ?? 0.0,
                            'loyaltyContact': contact,
                            'availablePoints': pts,
                            'summaryEnabled': true,
                          },
                        );
                      } on PlatformException catch (e) {
                        if (e.code != 'NO_DISPLAY') {
                          rethrow;
                        }
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Customer Added Successfully!"),
                            backgroundColor: Colors.green,
                            duration: Duration(seconds: 1),
                          ),
                        );
                      }

                    } catch (e) {

                      print("❌ ERROR: $e");

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Failed: ${e.toString()}",
                            ),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }

                    } finally {

                      if (mounted) {
                        setState(() => isAddLoading = false);
                      }
                    }
                  },
                  child: Container(
                    height: 44,
                    width: 126,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isButtonDisabled
                          ? Colors.grey.shade400 // 🔒 Disabled / Pending
                          : showCustomerInput
                          ? Colors.red // ❌ Cancel
                          : const Color(0xFF3B4259), // ➕ Add
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: isAddLoading
                        ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                        : Text(
                      showCustomerInput ? '× Cancel' : '+ Add',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              ],
            ),
          ),
          const SizedBox(width: 90),
          // User profile section with container and notification bell
          Row(
            children: [
              Container(
                height: ResponsiveLayout.getHeight(45),
                margin: EdgeInsets.all(ResponsiveLayout.getPadding(10)),
                padding: EdgeInsets.symmetric(
                  horizontal: ResponsiveLayout.getPadding(16),
                  vertical: 0,
                ),
                decoration: BoxDecoration(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.secondaryBackground
                      : Colors.white,
                  borderRadius:
                  BorderRadius.circular(ResponsiveLayout.getRadius(15)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(
                        themeHelper.themeMode == ThemeMode.dark ? 0.3 : 0.12,
                      ),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: ResponsiveLayout.getRadius(18),
                      backgroundColor: Colors.deepPurple,
                      child: Text(
                        (userDisplayName ?? TextConstants.unknown)
                            .substring(0, 1),
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: ResponsiveLayout.getFontSize(14),
                        ),
                      ),
                    ),
                    SizedBox(width: ResponsiveLayout.getWidth(12)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          userDisplayName ?? "",
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: themeHelper.themeMode == ThemeMode.dark
                                ? ThemeNotifier.textDark
                                : ThemeNotifier.textLight,
                            fontSize: ResponsiveLayout.getFontSize(14),
                          ),
                        ),
                        Text(
                          userRole ?? TextConstants.unknown,
                          style:
                          const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: ResponsiveLayout.getWidth(16)),
              Container(
                decoration: BoxDecoration(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.secondaryBackground
                      : Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(
                        themeHelper.themeMode == ThemeMode.dark ? 0.3 : 0.15,
                      ),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                padding: EdgeInsets.all(ResponsiveLayout.getPadding(10)),
                child: Icon(
                  Icons.notifications_outlined,
                  size: ResponsiveLayout.getIconSize(24),
                ),
              ),
            ],
          ),

          const SizedBox(width: 18),
        ],
      ),
    );
  }

  Widget _buildOrderSummary() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final theme = Theme.of(context);

    int totalItems = orderItems.fold(0, (sum, item) {
      final name = item['item_name']?.toString().toLowerCase() ?? '';

      if (name == 'payout' || name == 'cashback') {
        return sum;
      }

      final qty = int.tryParse(item['items_count']?.toString() ?? '1') ?? 1;
      return sum + qty;
    });

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
            left: ResponsiveLayout.getPadding(10),
            right: ResponsiveLayout.getPadding(10),
            bottom: ResponsiveLayout.getPadding(10)),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ResponsiveLayout.getRadius(10)),
          color: themeHelper.themeMode == ThemeMode.dark
              ? ThemeNotifier.primaryBackground
              : Color(0xFFFFFFFF),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.1),
              spreadRadius: 1,
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.only(
              left: ResponsiveLayout.getPadding(12),
              right: ResponsiveLayout.getPadding(10),
              bottom: ResponsiveLayout.getPadding(15),
              top: ResponsiveLayout.getPadding(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  /// LEFT — Order ID
                  Row(
                    children: [
                      Text(
                        '${TextConstants.orderId}: ',
                        style: TextStyle(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white
                              : Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: ResponsiveLayout.getFontSize(16),
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            '# $orderId ',
                            style: TextStyle(
                              color: theme.brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: ResponsiveLayout.getFontSize(16),
                            ),
                          ),

                          // ─── Only show when there is a current partial/offline remaining balance ───
                          // if (_currentPaymentRemainingBalance != null && _currentPaymentRemainingBalance! > 0) ...[
                          //
                          //
                          //   const SizedBox(width: 16),
                          //   Container(
                          //     padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          //     decoration: BoxDecoration(
                          //       color: Colors.orange.withOpacity(0.18),
                          //       borderRadius: BorderRadius.circular(6),
                          //       border: Border.all(color: Colors.orange[700]!, width: 1.3),
                          //     ),
                          //     child: Row(
                          //       mainAxisSize: MainAxisSize.min,
                          //       children: [
                          //         Icon(
                          //           Icons.cloud_off_rounded,
                          //           size: 16,
                          //           color: Colors.orange[800],
                          //         ),
                          //         const SizedBox(width: 6),
                          //
                          //
                          //       Text(
                          //           "Offline balance: ${TextConstants.currencySymbol}${_currentPaymentRemainingBalance!.toStringAsFixed(2)}",
                          //           style: TextStyle(
                          //             color: Colors.orange[900],
                          //             fontWeight: FontWeight.w600,
                          //             fontSize: 13.5,
                          //           ),
                          //         ),
                          //
                          //       ],
                          //     ),
                          //   ),
                          // ],
                        ],
                      ),
                    ],
                  ),

                  /// PUSH RIGHT CONTENT TO END
                  const Spacer(),

                  /// RIGHT — Date + Time
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.calendar_month_rounded,
                        size: ResponsiveLayout.getIconSize(20),
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white // Dark mode color
                            : const Color(0xFF4C5F7D), // Light mode color
                      ),

                      const SizedBox(width: 6),
                      Text(
                        _displayDate,
                        style: TextStyle(
                          fontSize: ResponsiveLayout.getFontSize(13),
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.grey.shade800,
                          fontWeight: FontWeight.w500,
                        ),
                      ),

                      const SizedBox(width: 8),

                      /// Divider
                      Container(
                        height: ResponsiveLayout.getHeight(16),
                        width: 1,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white54 // slightly lighter for dark mode
                            : Colors.grey.shade400,
                      ),

                      const SizedBox(width: 8),

                      /// Time
                      Text(
                        _displayTime,
                        style: TextStyle(
                          fontSize: ResponsiveLayout.getFontSize(13),
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.grey.shade800,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                height: 30,
                margin: EdgeInsets.fromLTRB(
                  ResponsiveLayout.getPadding(2),
                  ResponsiveLayout.getPadding(5),
                  ResponsiveLayout.getPadding(2),
                  0,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFE6464),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Item Name
                    Expanded(
                      flex: 2,
                      child: Text(
                        "Item Name",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: ResponsiveLayout.getFontSize(14), // SAME
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.white,
                        ),
                        textAlign: TextAlign.left,
                      ),
                    ),

                    // Unit
                    Expanded(
                      flex: 1,
                      child: Text(
                        "Unit",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: ResponsiveLayout.getFontSize(14),
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.white,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),

                    // Price
                    Expanded(
                      flex: 2,
                      child: Text(
                        "Price",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: ResponsiveLayout.getFontSize(14), // SAME
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.white,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: ResponsiveLayout.getHeight(8)),
              Expanded(
                flex: 6,
                child: Container(
                    decoration: BoxDecoration(
                      borderRadius:
                      BorderRadius.circular(ResponsiveLayout.getRadius(10)),
                      color: themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.secondaryBackground
                          : Colors.white,
                      border: Border.all(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.borderColor
                              : Colors.grey.shade200),
                    ),
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.zero,
                      itemCount: orderItems.length,
                      itemBuilder: (context, index) {
                        return _buildOrderItem(index);
                      },
                    )),
              ),
              Container(
                decoration: BoxDecoration(
                  borderRadius:
                  BorderRadius.circular(ResponsiveLayout.getRadius(6)),
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.secondaryBackground
                      : Colors.white,
                ),
                margin: EdgeInsets.only(top: ResponsiveLayout.getPadding(10)),
                child: AnimatedSize(
                  duration: Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _showFullSummary
                      ? Container(
                    height: ResponsiveLayout.getHeight(205),
                    margin: EdgeInsets.only(
                      top: ResponsiveLayout.getPadding(0),
                      right: ResponsiveLayout.getPadding(1),
                      left: ResponsiveLayout.getPadding(1),
                      bottom: ResponsiveLayout.getPadding(3),
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.only(
                          topRight: Radius.circular(8),
                          topLeft: Radius.circular(8)),
                      color: themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.orderPanelSummary
                          : Colors.white,
                      boxShadow: [
                        // Shadow at the top
                        BoxShadow(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? Color(0xFFF0F0F0).withOpacity(
                              0.15) // dark mode top shadow
                              : Colors.black.withOpacity(
                              0.15), // light mode top shadow
                          // color: Colors.black.withOpacity(0.15),
                          offset: Offset(
                              0, -4), // 0 horizontal, -4 vertical (up)
                          blurRadius: 6,
                          spreadRadius: -0.5,
                        ),
                      ],
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: ResponsiveLayout.getPadding(8),
                    ),
                    child: isSummaryLoading
                        ? Center(child: CircularProgressIndicator())
                        : ScrollConfiguration(
                      behavior: NoScrollbarBehavior()
                          .copyWith(overscroll: false),
                      // thumbVisibility: true,
                      // radius: Radius.circular(10),
                      child: SingleChildScrollView(
                        physics: BouncingScrollPhysics(),
                        child: Column(
                          children: [
                            _buildOrderCalculation(
                              TextConstants.grossTotal,
                              grossTotal < 0
                                  ? '-${TextConstants.currencySymbol}${grossTotal.abs().toStringAsFixed(2)}'
                                  : '${TextConstants.currencySymbol}${grossTotal.toStringAsFixed(2)}',
                              isTotal: true,
                            ),

                            _buildOrderCalculation(
                                TextConstants.discountText,
                                '-${TextConstants.currencySymbol}${discount.abs().toStringAsFixed(2)}',
                                isDiscount: true),

                            ShaderMask(
                              shaderCallback: (Rect bounds) {
                                return LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: themeHelper.themeMode ==
                                      ThemeMode.dark
                                      ? [
                                    Colors.white
                                        .withOpacity(0.1),
                                    Colors.white
                                        .withOpacity(0.7),
                                    Colors.white
                                        .withOpacity(0.1),
                                  ]
                                      : [
                                    Colors.black
                                        .withOpacity(0.1),
                                    Colors.black
                                        .withOpacity(0.7),
                                    Colors.black
                                        .withOpacity(0.1),
                                  ],
                                  stops: const [0.0, 0.5, 1.0],
                                ).createShader(bounds);
                              },
                              blendMode: BlendMode.srcIn,
                              child: DottedLine(
                                dashLength: 6,
                                dashGapLength: 4,
                                lineThickness: 1,
                                direction: Axis.horizontal,
                                dashColor: themeHelper.themeMode ==
                                    ThemeMode.dark
                                    ? Colors.white
                                    : Colors
                                    .black, // ✅ ensures gradient works correctly
                              ),
                            ),
                            _buildOrderCalculation(
                              TextConstants.NetTotal,
                              NetTotal < 0
                                  ? '-${TextConstants.currencySymbol}${NetTotal.abs().toStringAsFixed(2)}'
                                  : '${TextConstants.currencySymbol}${NetTotal.toStringAsFixed(2)}',
                            ),

                            _buildOrderCalculation(
                                TextConstants.taxText,
                                '${TextConstants.currencySymbol}${tax.toStringAsFixed(2)}'),
                            if (merchantDiscount < 0)
                              _buildOrderCalculation(
                                TextConstants.merchantDiscount,
                                '-${TextConstants.currencySymbol}${merchantDiscount.abs().toStringAsFixed(2)}',
                              ),

                            if (cashbackFee > 0)
                              _buildOrderCalculation(
                                TextConstants.cashbackFee,
                                '${TextConstants.currencySymbol}${cashbackFee.toStringAsFixed(2)}',
                              ),

                            /// Service Charges
                            _buildOrderCalculation(
                                TextConstants.servicecharges,
                                '${TextConstants.currencySymbol}${servicecharges.toStringAsFixed(2)}'),

                            if (redeemedValue > 0)
                              _buildOrderCalculation(
                                "Redeemed Amount",
                                '-${TextConstants.currencySymbol}${redeemedValue.toStringAsFixed(2)}',
                              ),

                            ShaderMask(
                              shaderCallback: (Rect bounds) {
                                return LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: themeHelper.themeMode ==
                                      ThemeMode.dark
                                      ? [
                                    Colors.white
                                        .withOpacity(0.1),
                                    Colors.white
                                        .withOpacity(0.7),
                                    Colors.white
                                        .withOpacity(0.1),
                                  ]
                                      : [
                                    Colors.black
                                        .withOpacity(0.1),
                                    Colors.black
                                        .withOpacity(0.7),
                                    Colors.black
                                        .withOpacity(0.1),
                                  ],
                                  stops: const [0.0, 0.5, 1.0],
                                ).createShader(bounds);
                              },
                              blendMode: BlendMode.srcIn,
                              child: DottedLine(
                                dashLength: 6,
                                dashGapLength: 4,
                                lineThickness: 1,
                                direction: Axis.horizontal,
                                dashColor: themeHelper.themeMode ==
                                    ThemeMode.dark
                                    ? Colors.white
                                    : Colors
                                    .black, // ✅ ensures gradient works correctly
                              ),
                            ),

                            _buildOrderCalculation(
                              TextConstants.netPayable,
                              computedNetPayable < 0
                                  ? '-${TextConstants.currencySymbol}${computedNetPayable.abs().toStringAsFixed(2)}'
                                  : '${TextConstants.currencySymbol}${computedNetPayable.toStringAsFixed(2)}',
                              isTotal: true,
                            ),

                            // if (redeemedValue > 0)
                            //   _buildOrderCalculation(
                            //     "Redeemed Amount",
                            //     '-${TextConstants.currencySymbol}${redeemedValue.toStringAsFixed(2)}',
                            //   ),
                            _buildOrderCalculation(
                              "Pay by Card",
                              '${TextConstants.currencySymbol}${payByCard.toStringAsFixed(2)}',
                            ),

                            _buildOrderCalculation(
                                TextConstants.payByCash,
                                '${TextConstants.currencySymbol}${payByCash.toStringAsFixed(2)}'),
                            //  Commented because pay by ebt as a part of boutique flow
                            // _buildOrderCalculation(
                            //   "Pay by EBT",
                            //   '${TextConstants.currencySymbol}${payByEbt.toStringAsFixed(2)}',
                            // ),

                            _buildOrderCalculation(
                                TextConstants.payByOther,
                                '${TextConstants.currencySymbol}${payByOther.toStringAsFixed(2)}'),

                            _buildOrderCalculation(
                                TextConstants.tenderAmount,
                                '${TextConstants.currencySymbol}${tenderAmount.toStringAsFixed(2)}'),

                            _buildOrderCalculation(
                                TextConstants.change,
                                '${TextConstants.currencySymbol}${changeAmount.toStringAsFixed(2)}'),
                          ],
                        ),
                      ),
                    ),
                  )
                      : SizedBox.shrink(),
                ),
              ),
              GestureDetector(
                onTap: _toggleSummary,
                child: Container(
                  height: 32,
                  margin: EdgeInsets.only(
                    top: _showFullSummary
                        ? ResponsiveLayout.getPadding(0)
                        : ResponsiveLayout.getPadding(0),
                    right: ResponsiveLayout.getPadding(1),
                    left: ResponsiveLayout.getPadding(1),
                    bottom: ResponsiveLayout.getPadding(3),
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.only(
                      bottomRight:
                      Radius.circular(ResponsiveLayout.getRadius(6)),
                      bottomLeft:
                      Radius.circular(ResponsiveLayout.getRadius(6)),
                      topLeft: _showFullSummary
                          ? Radius.zero
                          : Radius.circular(ResponsiveLayout.getRadius(6)),
                      topRight: _showFullSummary
                          ? Radius.zero
                          : Radius.circular(ResponsiveLayout.getRadius(6)),
                    ),
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0xFF32343E)
                        : const Color(0xFFEAEDFE),

                    /// ⭐ ADD THIS SHADOW
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(
                            themeHelper.themeMode == ThemeMode.dark
                                ? 0.3
                                : 0.15),
                        offset: const Offset(0, 3),
                        blurRadius: 3,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  padding: EdgeInsets.symmetric(
                    horizontal: ResponsiveLayout.getPadding(18),
                    vertical: ResponsiveLayout.getPadding(0),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "${TextConstants.totalItemsText}: $totalItems",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            _showFullSummary
                                ? '${TextConstants.netPayable} : '
                                '${TextConstants.currencySymbol}${(computedNetPayable - redeemedValue).clamp(0.0, double.infinity).toStringAsFixed(2)}'
                                : '${TextConstants.netPayable} '
                                '${TextConstants.currencySymbol}${(computedNetPayable - redeemedValue).clamp(0.0, double.infinity).toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: themeHelper.themeMode == ThemeMode.dark
                                  ? ThemeNotifier.textDark
                                  : ThemeNotifier.textLight,
                            ),
                          ),
                          SizedBox(width: ResponsiveLayout.getPadding(8)),
                          Icon(
                            _showFullSummary
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_up,
                            color: themeHelper.themeMode == ThemeMode.dark
                                ? ThemeNotifier.textDark
                                : ThemeNotifier.textLight,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(flex: 0, child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }

  final OrderHelper orderHelper =
  OrderHelper(); // Helper instance to manage orders

  // Build #1.0.10: Fetches order items for the active order
  Future<void> fetchOrderItems() async {
    if (orderHelper.activeOrderId != null) {
      var orderData =
      await orderHelper.getOrderById(orderHelper.activeOrderId!);
      List<Map<String, dynamic>> items = await orderHelper
          .getOrderItems(orderData.first[AppDBConst.orderServerId]);

      //Build #1.0.29:  Fetch the orderServerId from the database

      if (orderData.isNotEmpty) {
        setState(() {
          orderId = orderData.first[AppDBConst.orderServerId] as int? ?? 0;
          orderDateTime =
          "${orderData.first[AppDBConst.orderDate]} ${orderData.first[AppDBConst.orderTime]}";
          discount =
              (orderData.first[AppDBConst.orderDiscount] as num?)?.toDouble() ??
                  0.0; // Fetch discount
          final dbMerchantDiscount =
              (orderData.first[AppDBConst.merchantDiscount] as num?)
                  ?.toDouble() ??
                  0.0;
          // Keep merchant discount algebraic (negative) for summary display/total logic.
          merchantDiscount = dbMerchantDiscount != 0
              ? -(dbMerchantDiscount.abs())
              : 0.0; // Build #1.0.80
          tax =
              (orderData.first[AppDBConst.orderTax] as num?)?.toDouble() ?? 0.0;
          orderTotal =
              (orderData.first[AppDBConst.orderTotal] as num?)?.toDouble() ??
                  0.0; // Build #1.0.80
          cashbackFee = (orderData.first[AppDBConst.orderCashbackFee] as num?)
              ?.toDouble() ??
              0.0;
          orderStatus = (orderData.first[AppDBConst.orderStatus] as String?) ??
              TextConstants.processing; // Build  #1.0.177
          if (kDebugMode) {
            print(
                "Fetched orderServerId: $orderId, Discount: $discount for activeOrderId: ${orderHelper.activeOrderId}, Time: $orderDateTime");
          }
        });
      } else {
        if (kDebugMode) {
          print(
              "No orderServerId found for activeOrderId: ${orderHelper.activeOrderId}");
        }
      }

      /// Call fetch payment details by order id API call after order id assigned here above, otherwise we get null order id
      _fetchPaymentsByOrderId();

      // Build #1.0.29: Calculate balance amount from order items
      for (var item in items) {
        double price = (item[AppDBConst.itemPrice] as num).toDouble();
        int count = item[AppDBConst.itemCount] as int;
        total += price * count;
      }

      if (kDebugMode) {
        print("##### fetchOrderItems :$items");
        print("Calculated balance amount: $total");
        print(
            "##### DEBUG 1001 orderTotal: $orderTotal, payByCash: $payByCash");
      }

      setState(() {
        orderItems = items;
        grossTotal = GlobalUtility.getGrossTotal(
            orderItems); // Build #1.0.138: GrossTotal calculation form global class for code re usability
        balanceAmount =
            orderTotal; // Build #1.0.138: using orderTotal from API value #No need our calculation here
        tenderAmount = 0.0; // Reset for new order
        changeAmount = 0.0; // Reset for new order
        paidAmount = 0.0; // Reset for new order
      });
    } else {
      setState(() {
        orderItems.clear();
        balanceAmount = 0.0;
        tenderAmount = 0.0; // Reset
        changeAmount = 0.0; // Reset
        paidAmount = 0.0; // Reset
        discount = 0.0; // Reset discount
      });
    }
  }

  Widget _buildOrderItem(int index) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final orderItem = orderItems[index];

    final String itemType =
        orderItem['item_type']?.toString().toLowerCase() ?? '';
    final String itemNameLower =
    (orderItem['item_name']?.toString() ?? '').toLowerCase();

    // Hide merchant discount line-items from the list (keep it in totals section).
    if (itemType.contains('discount') ||
        itemNameLower.contains('merchant discount')) {
      return const SizedBox.shrink();
    }

    final bool isPayout = itemType.contains(TextConstants.payoutText);
    final bool isCoupon = itemType.contains(TextConstants.couponText);
    final bool isCashback = itemType.contains("cashback");
    final bool isPayoutOrCoupon = isPayout || isCoupon || isCashback;

    // Parse variation_id: Woo/Hive use variation_id; SQLite uses item_variation_id.
    final int varId = _orderSummaryLineVariationId(orderItem);
    final bool hasVariationId = varId > 0;

    // Only show variant icon for actual product line items (not payout/coupon/custom/cashback)
    final bool isProductItem = !isPayoutOrCoupon;
    final bool isVariantFlag = orderItem['is_variant'] == true ||
        orderItem['is_variant'] == 1;
    // item_variation_custom_name is populated from API even for simple lines
    // (fallback is the full line-item name), so never treat name alone as variant.
    final bool isVariant = isProductItem &&
        (isVariantFlag ||
            (itemType == 'variant' || itemType == 'variation') ||
            hasVariationId);

    final bool isEbtEligible = _orderSummaryLineEbtEligible(orderItem);

    final String itemName = orderItem['item_name']?.toString() ?? '';
    final double itemPrice = (orderItem['item_price'] ?? 0).toDouble();
    final int itemCount = (orderItem['items_count'] ?? 0).toInt();

    final double originalTotal = (orderItem['item_sum_price'] ?? 0).toDouble();

    // --------------------------------------------------
    // ✅ DISCOUNT EXTRACTION
    // --------------------------------------------------
    // -----------------------------
// DISCOUNT EXTRACTION
// -----------------------------
    final String discountType =
        orderItem['discount_type']?.toString().toLowerCase() ?? '';

    double _num(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0.0;
    }

    // Pending/offline orders may use *_total or camelCase keys.
    double autoDiscount =
    _num(orderItem['auto_discount']) != 0
        ? _num(orderItem['auto_discount'])
        : _num(orderItem['auto_discount_total']) != 0
        ? _num(orderItem['auto_discount_total'])
        : _num(orderItem['autoDiscount']) != 0
        ? _num(orderItem['autoDiscount'])
        : _num(orderItem['autoDiscountTotal']) != 0
        ? _num(orderItem['autoDiscountTotal'])
        : _num(orderItem['display_auto_discount']);

    double comboDiscount = [
      orderItem['combo_discount_total'],
      orderItem['comboDiscountTotal'],
      orderItem['combo_discount'],
    ]
        .map((e) => _num(e))
        .firstWhere((v) => v != 0, orElse: () => 0);

    double mixMatchDiscount = [
      orderItem['mixmatch_discount_total'],
      orderItem['mixMatchDiscountTotal'],
      orderItem['mixmatch_discount'],
    ]
        .map((e) => _num(e))
        .firstWhere((v) => v != 0, orElse: () => 0);

    double multipackDiscount = [
      orderItem['multipack_discount_total'],
      orderItem['multipackDiscountTotal'],
      orderItem['multipack_discount'],
    ]
        .map((e) => _num(e))
        .firstWhere((v) => v != 0, orElse: () => 0);
    /// 🔥 FIX: backend sometimes moves discount into auto_discount
    if (discountType == 'mixmatch' &&
        autoDiscount > 0 &&
        mixMatchDiscount == 0) {
      mixMatchDiscount = autoDiscount;
      autoDiscount = 0;
    }

    if (discountType == 'combo' && autoDiscount > 0 && comboDiscount == 0) {
      comboDiscount = autoDiscount;
      autoDiscount = 0;
    }

    if (discountType == 'multipack' &&
        autoDiscount > 0 &&
        multipackDiscount == 0) {
      multipackDiscount = autoDiscount;
      autoDiscount = 0;
    }

    /// Flags
    final bool hasAutoDiscount = autoDiscount > 0;
    final bool isComboDiscount = comboDiscount > 0 || mixMatchDiscount > 0;
    final bool isMultipackDiscount = multipackDiscount > 0;

    /// Final price
    final double finalItemTotal = originalTotal -
        autoDiscount -
        comboDiscount -
        mixMatchDiscount -
        multipackDiscount;

    print(
      "SUMMARY ITEM -> ${orderItem['item_name']} "
          "TYPE:$discountType "
          "AUTO:$autoDiscount "
          "COMBO:$comboDiscount "
          "MIX:$mixMatchDiscount "
          "MULTIPACK:$multipackDiscount",
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: SizedBox(
            height: 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                /// LEFT + CENTER COLUMN
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      /// ROW 1 — NAME + QTY
                      SizedBox(
                        height: 16,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 150,
                              child: Text(
                                itemName.length > 30
                                    ? '${itemName.substring(0, 30)}...'
                                    : itemName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.0,
                                  fontWeight: FontWeight.bold,
                                  color: themeHelper.themeMode == ThemeMode.dark
                                      ? ThemeNotifier.textDark
                                      : ThemeNotifier.textLight,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (!isPayoutOrCoupon)
                              Text(
                                "${TextConstants.currencySymbol}${itemPrice.toStringAsFixed(2)} x $itemCount",
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.0,
                                  fontWeight: FontWeight.bold,
                                  color: themeHelper.themeMode == ThemeMode.dark
                                      ? ThemeNotifier.textDark
                                      : Colors.black87,
                                ),
                              ),
                          ],
                        ),
                      ),

                      /// ROW 2 — BADGES
                      /// ROW 2 — BADGES
                      if (isEbtEligible ||
                          isVariant ||
                          hasAutoDiscount ||
                          isComboDiscount ||
                          isMultipackDiscount)
                        SizedBox(
                          height: 12,
                          child: Row(
                            children: [
                              if (isEbtEligible)
                                Container(
                                  height: 14,
                                  padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: const Text(
                                    "EBT",
                                    style: TextStyle(
                                      fontSize: 8,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (isVariant) ...[
                                const SizedBox(width: 5),
                                SvgPicture.asset(
                                  SvgUtils.variationIcon,
                                  height: 8,
                                  width: 8,
                                ),
                              ],
                              if (hasAutoDiscount) ...[
                                const SizedBox(width: 5),
                                _discountBadge(
                                  "Autodiscount",
                                  Colors.red,
                                  amount: autoDiscount,
                                ),
                              ],
                              if (isComboDiscount) ...[
                                const SizedBox(width: 5),
                                _discountBadge(
                                  "combo discount",
                                  Colors.orange,
                                  amount: comboDiscount + mixMatchDiscount,
                                ),
                              ],
                              if (isMultipackDiscount) ...[
                                const SizedBox(width: 5),
                                _discountBadge(
                                  "Multipack",
                                  Colors.blue,
                                  amount: multipackDiscount,
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

                /// RIGHT PRICE COLUMN
                SizedBox(
                  //width: 55,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      /// FINAL PRICE
                      SizedBox(
                        height: 16,
                        child: Text(
                          isCoupon || isPayout
                              ? "-${TextConstants.currencySymbol}${originalTotal.abs().toStringAsFixed(2)}"
                              : "${TextConstants.currencySymbol}${finalItemTotal.toStringAsFixed(2)}",
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.0,
                            fontWeight: FontWeight.bold,
                            color: isCoupon || isPayout
                                ? Colors.red
                                : themeHelper.themeMode == ThemeMode.dark
                                ? ThemeNotifier.textDark
                                : ThemeNotifier.textLight,
                          ),
                        ),
                      ),

                      /// STRIKED ORIGINAL
                      SizedBox(
                        height: 12,
                        child: ((hasAutoDiscount ||
                            isComboDiscount ||
                            isMultipackDiscount) &&
                            !isPayoutOrCoupon)
                            ? Text(
                          "${TextConstants.currencySymbol}${originalTotal.toStringAsFixed(2)}",
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.0,
                            color: Colors.grey,
                            decoration: TextDecoration.lineThrough,
                          ),
                        )
                            : const SizedBox.shrink(),
                      ),

                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        /// ✅ DIVIDER — NOW IT WILL SHOW
        Divider(
          height: 1,
          thickness: 0.8,
          color: themeHelper.themeMode == ThemeMode.dark
              ? Colors.black26
              : Colors.grey.shade300,
        ),
      ],
    );
  }

  /// 🔹 Reusable badge widget
  /// 🔹 Reusable badge widget
  Widget _discountBadge(String text, Color color, {double? amount}) {
    final double? displayAmount =
    (amount != null && amount > 0) ? amount : null;
    return Text(
      displayAmount == null
          ? text
          : '$text  -${TextConstants.currencySymbol}${displayAmount.toStringAsFixed(2)}',
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.bold,
        color: color, // ✅ text color only
      ),
    );
  }

  FontWeight labelFontWeight = FontWeight.w500;
  FontWeight amountFontWeight = FontWeight.w600;

  Widget _buildOrderCalculation(String label, String amount,
      {bool isTotal = false, bool isDiscount = false}) {
    // //Build #1.0.34: Update the amount based on the label
    final themeHelper = Provider.of<ThemeNotifier>(context);
    if (label == TextConstants.tenderAmount) {
      amount =
      '${TextConstants.currencySymbol}${tenderAmount.toStringAsFixed(2)}';
    } else if (label == TextConstants.change) {
      amount =
      '${TextConstants.currencySymbol}${changeAmount.toStringAsFixed(2)}';
    } else if (label == TextConstants.total) {
      amount =
      '${TextConstants.currencySymbol}${(grossTotal - discount).toStringAsFixed(2)}'; // Adjust total with discount
    } else if (label == TextConstants.payByCash) {
      amount =
      '${TextConstants.currencySymbol}${payByCash.toStringAsFixed(2)}';
    } else if (label == TextConstants.payByOther) {
      amount =
      '${TextConstants.currencySymbol}${payByOther.toStringAsFixed(2)}';
    } else if (label == TextConstants.discountText) {
      amount =
      '-${TextConstants.currencySymbol}${discount.abs().toStringAsFixed(2)}'; // Display discount from DB
    }else if (label == TextConstants.netPayable) {
      amount =
      '${TextConstants.currencySymbol}${(computedNetPayable - redeemedValue).clamp(0.0, double.infinity).toStringAsFixed(2)}';
    }

    // Determine colors and icons based on label
    Color labelColor = themeHelper.themeMode == ThemeMode.dark
        ? ThemeNotifier.textDark
        : (isTotal ? Colors.black87 : Colors.grey[700]!);
    Color amountColor = themeHelper.themeMode == ThemeMode.dark
        ? ThemeNotifier.textDark
        : (isTotal ? Colors.black87 : Colors.grey[800]!);
    Widget? leadingIcon;

    if (isTotal) {
      amountColor = themeHelper.themeMode == ThemeMode.dark
          ? ThemeNotifier.textDark
          : Colors.black87;
    } else if (label == TextConstants.discountText || isDiscount) {
      labelColor = Colors.green[600]!;
      amountColor = Colors.green[600]!;
    } else if (label == TextConstants.merchantDiscount) {
      labelColor = Colors.blue[600]!;
      amountColor = Colors.blue[600]!;
    }
    // ---------------- CASHBACK ( #55CBCD ) ----------------
    else if (label == TextConstants.cashbackFee ||
        label.toLowerCase().contains("cashback")) {
      labelColor = const Color(0xFF55CBCD);
      amountColor = const Color(0xFF55CBCD);
      leadingIcon = SvgPicture.asset(
        'assets/cashicon.svg', // update your asset name if needed
        colorFilter: const ColorFilter.mode(Color(0xFF55CBCD), BlendMode.srcIn),
      );
    }

// ---------------- SERVICE CHARGE ( #0A122D ) ----------------
    else if (label == TextConstants.servicecharges ||
        label.toLowerCase().contains("service")) {
      labelColor = themeHelper.themeMode == ThemeMode.dark
          ? const Color(0xFFFFFFFF) // White for dark mode
          : const Color(0xFF0A122D); // Dark blue for light mode

      amountColor = themeHelper.themeMode == ThemeMode.dark
          ? const Color(0xFFFFFFFF) // White in dark mode
          : const Color(0xFF0A122D); // Dark blue in light mode

      leadingIcon = SvgPicture.asset(
        'assets/cashicon.svg', // update asset name
        colorFilter: const ColorFilter.mode(Color(0xFF0A122D), BlendMode.srcIn),
      );
    }
    // ---------------- NET TOTAL ( #373535 ) ----------------
    else if (label == TextConstants.NetTotal ||
        label.toLowerCase().contains("net total")) {
      labelColor = themeHelper.themeMode == ThemeMode.dark
          ? const Color(0xFFFFFFFF) // White in dark mode
          : const Color(0xFF373535); // Dark grey in light mode

      amountColor = themeHelper.themeMode == ThemeMode.dark
          ? const Color(0xFFFFFFFF) // White in dark mode
          : const Color(0xFF373535); // Dark blue in light mode

      // Make NET TOTAL bold
      labelFontWeight = FontWeight.w900;
      amountFontWeight = FontWeight.w900;

      leadingIcon = SvgPicture.asset(
        'assets/svg/net_total.svg',
        colorFilter: const ColorFilter.mode(Color(0xFF373535), BlendMode.srcIn),
      );
    }

    return Container(
      margin: EdgeInsets.symmetric(
          vertical: ResponsiveLayout.getPadding(
              2)), //ResponsiveLayout.getResponsiveMargin(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              if (leadingIcon != null) ...[
                leadingIcon,
              ],

              Text(
                label,
                style: TextStyle(
                  fontWeight: isTotal ? FontWeight.w600 : FontWeight.w500,
                  fontSize: ResponsiveLayout.getFontSize(isTotal ? 14 : 12),
                  color: labelColor,
                ),
              ),
              // ---------------- DELETE ICON FOR DISCOUNT ----------------
              if ((label == TextConstants.discountText || isDiscount) &&
                  discount.abs() > 0 &&
                  redeemedValue == 0)
                GestureDetector(
                  onTap: isPaymentStarted
                      ? null
                      : () async => await _removeAppliedCoupon(),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Icon(
                      Icons.delete_forever,
                      color: isPaymentStarted ? Colors.grey : Colors.red,
                      size: 20,
                    ),
                  ),
                ),

              if (label == "Redeemed Amount" && redeemedValue > 0)
                GestureDetector(
                  onTap: isPaymentStarted
                      ? null
                      : () async {
                    await _removeRedeemedAmount();
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Icon(
                      Icons.delete_forever,
                      color: isPaymentStarted ? Colors.grey : Colors.red,
                      size: 20,
                    ),
                  ),
                ),
            ],
          ),
          Row(
            children: [
              Text(
                amount,
                style: TextStyle(
                  fontWeight: isTotal ? FontWeight.w600 : FontWeight.w500,
                  fontSize: ResponsiveLayout.getFontSize(isTotal ? 14 : 12),
                  color: amountColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  Future<void> showRedeemSummary(double redeemedAmount) async {
    if (redeemedAmount <= 0) {
      print("❌ Redeem: Invalid amount $redeemedAmount");
      return;
    }

    print("🔄 Redeem Requested: $redeemedAmount | Current computedNetPayable: $computedNetPayable | Tendered: $tenderAmount");

    final double availableBalance = (computedNetPayable - tenderAmount).clamp(0.0, double.infinity);
    final double actualRedeem = redeemedAmount.clamp(0.0, availableBalance);

    setState(() {
      redeemedValue = actualRedeem;
      isRedeemAppliedFromApi = true;

      // 🔥 CORE CALCULATION - Apply redeem
      NetTotal = grossTotal + discount + merchantDiscount - actualRedeem;
      computedNetPayable = NetTotal + tax + cashbackFee;
      orderTotal = computedNetPayable;

      balanceAmount = (computedNetPayable - tenderAmount).clamp(0.0, double.infinity);

      // Reduce EBT if needed
      if (ebtTotal > 0) {
        ebtTotal = (ebtTotal - (redeemedAmount - actualRedeem)).clamp(0.0, double.infinity);
      }
    });

    // Persist to Hive
    try {
      final box = StorageProvider.offlineOrders;
      final key = (orderId ?? widget.offlineOrderId ?? 0).toString();

      if (await box.containsKey(key)) {
        final order = Map<String, dynamic>.from(await box.get(key));
        order['redeemed_value'] = actualRedeem;
        order['net_payable'] = computedNetPayable;
        order['balance_amount'] = balanceAmount;
        order['NetTotal'] = NetTotal;           // extra safety
        order['computedNetPayable'] = computedNetPayable;
        await box.put(key, order);
        print("💾 Redeem successfully saved to Hive → $actualRedeem");
      }
    } catch (e) {
      print("⚠️ Failed to save redeem to Hive: $e");
    }

    print("✅ REDEEM APPLIED SUCCESSFULLY!");
    print("   Redeemed     : -${actualRedeem.toStringAsFixed(2)}");
    print("   New NetTotal : ${NetTotal.toStringAsFixed(2)}");
    print("   New Payable  : ${computedNetPayable.toStringAsFixed(2)}");
    print("   New Balance  : ${balanceAmount.toStringAsFixed(2)}");

    // Force refresh UI
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _removeRedeemedAmount() async {

    // 🔴 Contact is mandatory
    if (mobileController.text.trim().isEmpty) {

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Customer contact not found."),
          backgroundColor: Colors.red,
        ),
      );

      return;
    }

    final String contact =
    mobileController.text.trim();

    // =====================================
// GET WOO ORDER ID FROM HIVE
// =====================================
    final offlineBox =
        StorageProvider.offlineOrders;

    final localKey =
    widget.offlineOrderId?.toString();

    if (localKey == null) {
      throw Exception("Offline order not found");
    }

    final existing =
    await offlineBox.get(localKey);

    if (existing == null) {
      throw Exception("Order data missing");
    }

    final offlineOrder =
    Map<String, dynamic>.from(
      existing is Map ? existing : {},
    );

// 🔥 GET WOO ORDER ID
    final int order =
        int.tryParse(
          offlineOrder["wooOrderId"]
              ?.toString() ?? "0",
        ) ??
            0;

    if (order == 0) {
      throw Exception("Woo Order ID missing");
    }

    print("🟢 USING WOO ORDER ID: $order");

    setState(() => isSummaryLoading = true);

    try {

      // =====================================
      // API CALL
      // =====================================
      final rawRes =
      await OrderRepository()
          .removeLoyaltyPoints(
        orderId: order,
        contact: contact,
      );

      // =====================================
      // SAFE RESPONSE
      // =====================================
      final result = rawRes is String
          ? jsonDecode(rawRes)
          : rawRes;

      print("🟢 REMOVE RESPONSE: $result");

      if (result["success"] != true) {

        throw Exception(
          result["message"] ??
              "Unable to remove points",
        );
      }

      final data = result["data"] ?? {};

      // =====================================
      // API VALUES
      // =====================================
      final double updatedOrderTotal =
          double.tryParse(
            data["order_total"]?.toString() ?? "0",
          ) ??
              widget.netPayable;
      final int updatedPoints =
          int.tryParse(
            data["available_points"]?.toString() ?? "0",
          ) ??
              availablePoints;

// UPDATE UI
      setState(() {
        redeemedValue = 0;
        isRedeemAppliedFromApi = false;
        isRedeemActive = false;
        loyaltyData = null;
        availablePoints = updatedPoints;
        computedNetPayable = updatedOrderTotal;
        balanceAmount = updatedOrderTotal - tenderAmount;
      });

// clear hive first
      // clear hive
      await removeOfflineOrderRedeem(localKey);

// tell android immediately
      await customerDisplayChannel.invokeMethod(
        "customerDisplayResult",
        {
          "success": true,
          "points": updatedPoints,
          "redeemedAmount": 0.0,
          "removeRedeem": true,
        },
      );

// then refresh full display
//       await CustomerDisplayHelper.updateCustomerDisplay(
//         widget.offlineOrderId!,
//         summaryEnabled: true,
//       );
      // =====================================
      // SUCCESS MESSAGE
      // =====================================
      if (mounted) {

        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              result["message"] ??
                  "Redeemed points removed successfully.",
            ),
            backgroundColor: Colors.green,
          ),
        );
      }

      print("🧹 Redeem removed successfully");

    } catch (e) {

      print("❌ Remove Loyalty Error: $e");

      if (mounted) {

        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              e.toString()
                  .replaceAll("Exception:", ""),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }

    } finally {

      if (mounted) {
        setState(
              () => isSummaryLoading = false,
        );
      }
    }
  }

  String _getPaymentHeader() {
    switch (selectedPaymentMethod) {
      case TextConstants.cash:
        return TextConstants.cashPayment;

      case TextConstants.card:
        return TextConstants.cardPayment;

      case TextConstants.wallet:
        return TextConstants.walletPayment;

      case TextConstants.ebtText:
        return TextConstants.ebtPayment;

      default:
        return TextConstants.cashPayment;
    }
  }

  void _resetAmount() {
    _rawAmount = 0;
    amountController.text = '${TextConstants.currencySymbol}0.00';
    _amountErrorText = null;
    _isAmountEntered = false;
  }

  Widget _buildPaymentSection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calculateBalanceFromPaymentHistory();
    });

    // ============================================
    // ⭐ PAYMENT PROGRESSION DISPLAY
    // ============================================
    // print("\n" + "📊" * 60);
    // print("📊 PAYMENT PROGRESSION - ORDER #$orderId");
    // print("📊" * 60);
    // print("💰 INITIAL NET PAYABLE: \$${computedNetPayable.toStringAsFixed(2)}");
    // print("💵 TOTAL TENDERED: \$${tenderAmount.toStringAsFixed(2)}");
    // print("📉 BALANCE REDUCED BY: \$${(computedNetPayable - balanceAmount).toStringAsFixed(2)}");
    // print("🔢 PAYMENTS MADE: ${_lastPaymentDetails?['paymentNumber'] ?? 0}");
    //
    // if (_lastPaymentDetails != null) {
    //   print("📈 LAST PAYMENT (#${_lastPaymentDetails!['paymentNumber']}):");
    //   print("   → Method: ${_lastPaymentDetails!['method']}");
    //   print("   → Amount: \$${_lastPaymentDetails!['amount']?.toStringAsFixed(2)}");
    //   print("   → Previous Balance: \$${_lastPaymentDetails!['previousBalance']?.toStringAsFixed(2)}");
    // }
    //
    // print("🎯 CURRENT STATUS:");
    // print("   → Balance Amount: \$${balanceAmount.toStringAsFixed(2)}");
    // print("   → Current Payment Remaining: ${_currentPaymentRemainingBalance != null ? '\$${_currentPaymentRemainingBalance!.toStringAsFixed(2)}' : 'None (Payment Complete)'}");
    // print("   → Payment Methods Used:");
    // print("      • Cash: \$${payByCash.toStringAsFixed(2)}");
    // print("      • Card: \$${payByCard.toStringAsFixed(2)}");
    // print("      • EBT: \$${payByEbt.toStringAsFixed(2)}");
    // print("      • Other: \$${payByOther.toStringAsFixed(2)}");
    // print("📊" * 60 + "\n");

    // Log payment history from database
    _printPaymentHistorySummary();

    final themeHelper = Provider.of<ThemeNotifier>(context);
    bool hasEbtItem =
    orderItems.any((item) => _orderSummaryLineEbtEligible(item));
    final bool hasOnlyCashbackOrPayoutItems = orderItems.isNotEmpty &&
        orderItems.every((item) {
          final type = (item['item_type'] ?? item['type'] ?? '')
              .toString()
              .toLowerCase();

          return type == 'cashback' || type == 'payout';
        });
    return Container(
      // Remove the fixed height constraint to let it match the left container
      margin: EdgeInsets.only(
        bottom: ResponsiveLayout.getPadding(0),
        right: ResponsiveLayout.getPadding(10),
        top: ResponsiveLayout.getPadding(2),
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(ResponsiveLayout.getRadius(10)),
          topRight: Radius.circular(ResponsiveLayout.getRadius(10)),
          bottomLeft: Radius.circular(ResponsiveLayout.getRadius(0)),
          bottomRight: Radius.circular(ResponsiveLayout.getRadius(0)),
        ),
        color: themeHelper.themeMode == ThemeMode.dark
            ? ThemeNotifier.primaryBackground
            : Color(0xFFFFFFFF),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: ResponsiveLayout.getPadding(18),
          right: ResponsiveLayout.getPadding(18),
          top: ResponsiveLayout.getPadding(15),
          bottom: ResponsiveLayout.getPadding(18), // Add bottom padding
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment:
          CrossAxisAlignment.start, // Changed to start for better alignment
          children: [
            Expanded(
              flex: 3,
              child: Column(
                // Remove SingleChildScrollView to avoid height issues
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment:
                MainAxisAlignment.start, // Changed from spaceEvenly
                children: [
                  SizedBox(height: ResponsiveLayout.getHeight(6)),

                  // Payment methods section
                  Expanded(
                    // Make this expand to fill available space
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Cash payment section - make it flexible
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                // Make the payment container expand to fill space
                                child: Container(
                                  width: double.infinity, // Take full width
                                  padding: EdgeInsets.only(
                                    left: ResponsiveLayout.getPadding(16),
                                    right: ResponsiveLayout.getPadding(16),
                                    top: ResponsiveLayout.getPadding(0),
                                    bottom: ResponsiveLayout.getPadding(8),
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                    themeHelper.themeMode == ThemeMode.dark
                                        ? Color(0xFF1F1D2B)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(
                                        ResponsiveLayout.getRadius(8)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                    children: [
                                      Column(
                                        crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            height:
                                            ResponsiveLayout.getHeight(60),
                                            padding: EdgeInsets.symmetric(
                                              horizontal:
                                              ResponsiveLayout.getPadding(
                                                  16),
                                            ),
                                            decoration: BoxDecoration(
                                              color: themeHelper.themeMode ==
                                                  ThemeMode.dark
                                                  ? const Color(0xFF40424F)
                                                  : const Color(0xFFF9FBFF),
                                              borderRadius:
                                              BorderRadius.circular(10),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Color(0x22000000),
                                                  blurRadius: 6,
                                                  offset: Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Row(
                                              children: [
                                                /// 🔵 LABEL
                                                Text(
                                                  "Tender Amount :",
                                                  style: TextStyle(
                                                    fontSize: ResponsiveLayout
                                                        .getFontSize(18),
                                                    fontWeight: FontWeight.w600,
                                                    color:
                                                    themeHelper.themeMode ==
                                                        ThemeMode.dark
                                                        ? Colors.white
                                                        : const Color(
                                                        0xFF0D47A1),
                                                  ),
                                                ),

                                                const SizedBox(width: 16),

                                                /// 🔹 AMOUNT FIELD
                                                Expanded(
                                                  child: Container(
                                                    height: ResponsiveLayout
                                                        .getHeight(44),
                                                    padding:
                                                    EdgeInsets.symmetric(
                                                      horizontal:
                                                      ResponsiveLayout
                                                          .getPadding(12),
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: themeHelper
                                                          .themeMode ==
                                                          ThemeMode.dark
                                                          ? const Color(
                                                          0xFF1F1D2B)
                                                          : Colors.white,
                                                      borderRadius:
                                                      BorderRadius.circular(
                                                          8),
                                                      border: Border.all(
                                                        color: _amountErrorText !=
                                                            null
                                                            ? Colors.red
                                                            : themeHelper
                                                            .themeMode ==
                                                            ThemeMode
                                                                .dark
                                                            ? Colors.white24
                                                            : const Color(
                                                            0xFFB6C6E3),
                                                        width:
                                                        _amountErrorText !=
                                                            null
                                                            ? 1.5
                                                            : 1.0,
                                                      ),
                                                      boxShadow: [
                                                        if (themeHelper
                                                            .themeMode !=
                                                            ThemeMode.dark)
                                                          BoxShadow(
                                                            color: Colors.black
                                                                .withOpacity(
                                                                0.05),
                                                            blurRadius: 4,
                                                            offset:
                                                            const Offset(
                                                                0, 2),
                                                          ),
                                                      ],
                                                    ),
                                                    alignment:
                                                    Alignment.centerRight,
                                                    child: TextField(
                                                      controller:
                                                      amountController,
                                                      keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                      textInputAction:
                                                      TextInputAction.done,
                                                      enabled: true,
                                                      readOnly: true,
                                                      textAlign:
                                                      TextAlign.right,
                                                      autofocus: false,
                                                      cursorColor: themeHelper
                                                          .themeMode ==
                                                          ThemeMode.dark
                                                          ? Colors.white
                                                          : const Color(
                                                          0xFF1F1D2B),
                                                      decoration:
                                                      InputDecoration(
                                                        border:
                                                        InputBorder.none,
                                                        isDense: true,
                                                        contentPadding:
                                                        EdgeInsets.zero,
                                                        hintText:
                                                        '${TextConstants.currencySymbol}0.00',
                                                        hintStyle: TextStyle(
                                                          color: themeHelper
                                                              .themeMode ==
                                                              ThemeMode.dark
                                                              ? Colors.white38
                                                              : Colors
                                                              .grey[400],
                                                          fontSize:
                                                          ResponsiveLayout
                                                              .getFontSize(
                                                              22),
                                                        ),

                                                        // errorText: _amountErrorText,
                                                        // errorStyle: TextStyle(
                                                        //   color: Colors.red,
                                                        //   fontSize: ResponsiveLayout.getFontSize(12),
                                                        // ),
                                                      ),
                                                      style: TextStyle(
                                                        fontSize:
                                                        ResponsiveLayout
                                                            .getFontSize(
                                                            22),
                                                        fontWeight:
                                                        FontWeight.bold,
                                                        color: themeHelper
                                                            .themeMode ==
                                                            ThemeMode.dark
                                                            ? const Color(
                                                            0xFFFFFFFF)
                                                            : const Color(
                                                            0xFF1F1D2B),
                                                      ),
                                                      inputFormatters: [
                                                        FilteringTextInputFormatter
                                                            .allow(RegExp(
                                                            r'^\d*\.?\d{0,2}')),
                                                      ],
                                                      onTap: () {
                                                        // Select all text when tapped (makes overwriting easy)
                                                        amountController
                                                            .selection =
                                                            TextSelection(
                                                              baseOffset: 0,
                                                              extentOffset:
                                                              amountController
                                                                  .text.length,
                                                            );
                                                      },
                                                      // ────────────────────────────────────────────────
                                                      // IMPORTANT: Detect real user typing
                                                      // ────────────────────────────────────────────────
                                                      onChanged: (value) {
                                                        // Mark that user is actively typing → prevent auto-fill later
                                                        _userManuallyEnteredAmount =
                                                        true;

                                                        // Optional: clean up pasted currency symbol
                                                        String clean = value
                                                            .replaceAll(
                                                            TextConstants
                                                                .currencySymbol,
                                                            '')
                                                            .trim();
                                                        if (clean != value) {
                                                          amountController
                                                              .value =
                                                              TextEditingValue(
                                                                text: clean,
                                                                selection: TextSelection
                                                                    .collapsed(
                                                                    offset: clean
                                                                        .length),
                                                              );
                                                        }
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                          // /// 🔴 ERROR TEXT BELOW FIELD
                                          // if (computedNetPayable > 0 && _amountErrorText != null)
                                          //   Padding(
                                          //     padding: EdgeInsets.only(
                                          //       top: ResponsiveLayout.getPadding(4),
                                          //       left: ResponsiveLayout.getPadding(12),
                                          //     ),
                                          //     child: Text(
                                          //       _amountErrorText!,
                                          //       style: TextStyle(
                                          //         color: Colors.red,
                                          //         fontSize: ResponsiveLayout.getFontSize(12),
                                          //       ),
                                          //     ),
                                          //   ),
                                        ],
                                      ),

                                      SizedBox(
                                          height:
                                          ResponsiveLayout.getHeight(8)),

                                      SizedBox(
                                          height:
                                          ResponsiveLayout.getHeight(12)),

// NUM PAD - FIXED LOGIC
                                      Expanded(
                                        child: Column(
                                          children: [
                                            // ✅ Display current payment remaining balance if available
                                            // if (_currentPaymentRemainingBalance != null && balanceAmount > 0)
                                            //   Container(
                                            //     margin: EdgeInsets.only(bottom: ResponsiveLayout.getHeight(8)),
                                            //     padding: EdgeInsets.symmetric(
                                            //       horizontal: ResponsiveLayout.getPadding(12),
                                            //       vertical: ResponsiveLayout.getPadding(6),
                                            //     ),
                                            //     decoration: BoxDecoration(
                                            //       color: themeHelper.themeMode == ThemeMode.dark
                                            //           ? Colors.orange.withOpacity(0.2)
                                            //           : Colors.orange.withOpacity(0.1),
                                            //       borderRadius: BorderRadius.circular(ResponsiveLayout.getRadius(6)),
                                            //       border: Border.all(
                                            //         color: Colors.orange.withOpacity(0.3),
                                            //         width: 1,
                                            //       ),
                                            //     ),
                                            //     child: Row(
                                            //       mainAxisAlignment: MainAxisAlignment.center,
                                            //       children: [
                                            //         Icon(
                                            //           Icons.info_outline,
                                            //           size: ResponsiveLayout.getIconSize(14),
                                            //           color: Colors.orange,
                                            //         ),
                                            //         // SizedBox(width: ResponsiveLayout.getWidth(6)),
                                            //         // Text(
                                            //         //   "Balance after last ${_lastPaymentDetails?['method'] ?? 'payment'}: ",
                                            //         //   style: TextStyle(
                                            //         //     fontSize: ResponsiveLayout.getFontSize(12),
                                            //         //     color: Colors.orange,
                                            //         //   ),
                                            //         // ),
                                            //         Text(
                                            //           '${TextConstants.currencySymbol}${_currentPaymentRemainingBalance!.toStringAsFixed(2)}',
                                            //           style: TextStyle(
                                            //             fontSize: ResponsiveLayout.getFontSize(12),
                                            //             fontWeight: FontWeight.bold,
                                            //             color: Colors.orange,
                                            //           ),
                                            //         ),
                                            //       ],
                                            //     ),
                                            //   ),

                                            // PaymentNumPad with modified logic
                                            Expanded(
                                              child: PaymentNumPad(
                                                numPadType:
                                                CustomTypeNumPad.payment,
                                                isDarkTheme:
                                                themeHelper.themeMode ==
                                                    ThemeMode.dark,
                                                getPaidAmount: () =>
                                                amountController.text,
                                                balanceAmount:
                                                selectedPaymentMethod ==
                                                    TextConstants
                                                        .ebtText
                                                    ? min(
                                                  ebtTotal,
                                                  _currentPaymentRemainingBalance ??
                                                      balanceAmount,
                                                )
                                                    : (_currentPaymentRemainingBalance ??
                                                    balanceAmount),
                                                onDigitPressed: (value) {
                                                  _userManuallyEnteredAmount =
                                                  true; // User touched → block future auto-fill

                                                  int digit = value == '00'
                                                      ? 0
                                                      : int.tryParse(value) ??
                                                      0;

                                                  int newAmount = value == '00'
                                                      ? _rawAmount * 100
                                                      : _rawAmount * 10 + digit;

                                                  int maxAmount;
                                                  double effectiveBalance =
                                                      _currentPaymentRemainingBalance ??
                                                          balanceAmount;

                                                  if (selectedPaymentMethod ==
                                                      TextConstants.ebtText) {
                                                    maxAmount = (min(ebtTotal,
                                                        effectiveBalance) *
                                                        100)
                                                        .toInt();
                                                  } else if (selectedPaymentMethod ==
                                                      TextConstants.card) {
                                                    maxAmount =
                                                        (effectiveBalance * 100)
                                                            .toInt();
                                                  } else {
                                                    maxAmount = 999999999;
                                                  }

                                                  if (newAmount > maxAmount)
                                                    return;

                                                  _rawAmount = newAmount;
                                                  double displayValue =
                                                      _rawAmount / 100.0;
                                                  amountController.text =
                                                  '${TextConstants.currencySymbol}${displayValue.toStringAsFixed(2)}';

                                                  setState(() {
                                                    _isAmountEntered =
                                                        _rawAmount != 0;
                                                  });
                                                },
                                                onClearPressed: () {
                                                  _userManuallyEnteredAmount =
                                                  true;

                                                  _rawAmount = 0;
                                                  amountController.text =
                                                  '${TextConstants.currencySymbol}0.00';
                                                  _amountErrorText = null;

                                                  setState(() {
                                                    _isAmountEntered = false;
                                                  });
                                                },
                                                onDeletePressed: () {
                                                  _userManuallyEnteredAmount =
                                                  true;

                                                  _rawAmount = _rawAmount ~/ 10;
                                                  double displayValue =
                                                      _rawAmount / 100.0;
                                                  amountController.text =
                                                  '${TextConstants.currencySymbol}${displayValue.toStringAsFixed(2)}';

                                                  setState(() {
                                                    _isAmountEntered =
                                                        _rawAmount != 0;
                                                  });
                                                },
                                                onQuickAmountSelected:
                                                    (double selectedAmount) {
                                                  _userManuallyEnteredAmount =
                                                  true;

                                                  double amountToUse =
                                                      selectedAmount;

                                                  if (selectedPaymentMethod ==
                                                      TextConstants.ebtText) {
                                                    amountToUse = min(
                                                        selectedAmount,
                                                        ebtTotal);
                                                  }
                                                  // For cash/card/wallet → allow full selectedAmount (even > balance)

                                                  _rawAmount =
                                                      (amountToUse * 100)
                                                          .round();
                                                  amountController.text =
                                                  '${TextConstants.currencySymbol}${amountToUse.toStringAsFixed(2)}';

                                                  setState(() {
                                                    _amountErrorText = null;
                                                    _isAmountEntered =
                                                        _rawAmount > 0;
                                                  });

                                                  print(
                                                      "Quick selected → $amountToUse (user picked $selectedAmount)");
                                                },
                                                onPayPressed: () async {
                                                  String cleanAmount =
                                                  amountController.text
                                                      .replaceAll(
                                                      TextConstants
                                                          .currencySymbol,
                                                      '')
                                                      .trim();

                                                  double amount =
                                                      double.tryParse(
                                                          cleanAmount) ??
                                                          0.0;

                                                  double effectiveBalance =
                                                      _currentPaymentRemainingBalance ??
                                                          balanceAmount;

                                                  _amountErrorText = null;

                                                  // Calculations (your existing logic)
                                                  double previousBalance =
                                                      effectiveBalance;
                                                  double newBalance =
                                                  (effectiveBalance -
                                                      amount)
                                                      .clamp(0,
                                                      double.infinity);
                                                  double newTenderAmount =
                                                      tenderAmount + amount;
                                                  double newChange = 0.0;

                                                  if (amount >
                                                      effectiveBalance) {
                                                    newChange = amount -
                                                        effectiveBalance;
                                                    newBalance = 0.0;
                                                  }

                                                  // Update UI
                                                  setState(() {
                                                    balanceAmount = newBalance;
                                                    tenderAmount =
                                                        newTenderAmount;
                                                    changeAmount = newChange;

                                                    if (selectedPaymentMethod ==
                                                        TextConstants.cash) {
                                                      payByCash += amount;
                                                    } else if (selectedPaymentMethod ==
                                                        TextConstants.ebtText) {
                                                      payByEbt += amount;
                                                      ebtTotal = (ebtTotal -
                                                          amount)
                                                          .clamp(0,
                                                          double.infinity);
                                                    }

                                                    isPaymentStarted = true;

                                                    int newPaymentNumber =
                                                        (_lastPaymentDetails?[
                                                        'paymentNumber'] ??
                                                            0) +
                                                            1;

                                                    if (newBalance > 0) {
                                                      _currentPaymentRemainingBalance =
                                                          newBalance;
                                                      _lastPaymentDetails = {
                                                        'amount': amount,
                                                        'method':
                                                        selectedPaymentMethod,
                                                        'remainingBalance':
                                                        newBalance,
                                                        'previousBalance':
                                                        previousBalance,
                                                        'datetime': DateTime
                                                            .now()
                                                            .toIso8601String(),
                                                        'paymentNumber':
                                                        newPaymentNumber,
                                                        'totalPaid':
                                                        newTenderAmount,
                                                      };
                                                    } else {
                                                      _currentPaymentRemainingBalance =
                                                      null;
                                                      _lastPaymentDetails =
                                                      null;
                                                    }
                                                  });

                                                  // ────────────────────────────────────────────────
                                                  // CRITICAL CHANGE: RESET TO 0.00 — BUT DO NOT AUTO-FILL
                                                  // ────────────────────────────────────────────────
                                                  _rawAmount = 0;
                                                  amountController.text =
                                                  '${TextConstants.currencySymbol}0.00';
                                                  _isAmountEntered = false;

                                                  // DO NOT call _autoFillRemainingBalance() here anymore!
                                                  // Only reset — let user decide next amount

                                                  // Show dialogs (your existing logic)
                                                  if (newBalance > 0) {
                                                    _showPartialPaymentDialog(
                                                        context, amount);
                                                  } else {
                                                    _successPopupShown = true;
                                                    final box = StorageProvider
                                                        .offlineOrders;
                                                    final key = (orderId ?? 0)
                                                        .toString();
                                                    final boxData =
                                                    await box.get(key);
                                                    final cr = boxData is Map
                                                        ? (boxData as Map)[
                                                    "coupon_response"]
                                                        : null;
                                                    final couponResponse = cr
                                                    is Map
                                                        ? Map<String,
                                                        dynamic>.from(
                                                        cr as Map)
                                                        : <String, dynamic>{};

                                                    _showPaymentDialog(
                                                      context,
                                                      newTenderAmount,
                                                      changeAmount: newChange,
                                                      showChange: newChange > 0,
                                                      couponResponse:
                                                      couponResponse,
                                                    );
                                                  }

                                                  // Background API
                                                  _callCreatePaymentAPI(
                                                      skipPopup: true);
                                                },
                                                isLoading: isLoading,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: ResponsiveLayout.getWidth(16)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Right side - Payment mode selection
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // SizedBox(height: ResponsiveLayout.getHeight(3)),

                  SizedBox(height: ResponsiveLayout.getHeight(3)),

                  // Payment mode buttons - make flexible
                  Expanded(
                    flex: 2,
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(ResponsiveLayout.getPadding(8)),
                      decoration: BoxDecoration(
                        color: themeHelper.themeMode == ThemeMode.dark
                            ? const Color(0xFF303136)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(
                          ResponsiveLayout.getRadius(8),
                        ),
                        border: Border.all(
                          color: const Color(0x2E4C5F7D), // #4C5F7D2E
                          width: 2, // adjust as needed
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: themeHelper.themeMode == ThemeMode.dark
                                ? Colors.black.withOpacity(0.3)
                                : Colors.black12,
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            // Net Payable
                            Container(
                              width: double.infinity,
                              padding: EdgeInsets.all(
                                  ResponsiveLayout.getPadding(8)),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  // Net Payable
                                  Container(
                                    height: ResponsiveLayout.getHeight(90),
                                    padding: const EdgeInsets.only(
                                      top: 6,
                                      right: 6,
                                      bottom: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: themeHelper.themeMode ==
                                          ThemeMode.dark
                                          ? const Color(
                                          0xFF091B34) // dark background
                                          : const Color(
                                          0xFFF4FCF7), // light mode background
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border(
                                        top: BorderSide(
                                          color: themeHelper.themeMode ==
                                              ThemeMode.dark
                                              ? const Color(0xFF091B34)
                                              : const Color(0xFF3EAE4C),
                                          width: 1,
                                        ),
                                        right: BorderSide(
                                          color: themeHelper.themeMode ==
                                              ThemeMode.dark
                                              ? const Color(0xFF091B34)
                                              : const Color(0xFF3EAE4C),
                                          width: 1,
                                        ),
                                        bottom: BorderSide(
                                          color: themeHelper.themeMode ==
                                              ThemeMode.dark
                                              ? const Color(0xFF091B34)
                                              : const Color(0xFF3EAE4C),
                                          width: 1,
                                        ),
                                        left: BorderSide
                                            .none, // 🚫 no left border
                                      ),
                                    ),
                                    child: _buildAmountDisplay(
                                      TextConstants.netPayable,
                                      '${TextConstants.currencySymbol}${(computedNetPayable - redeemedValue).clamp(0.0, double.infinity).toStringAsFixed(2)}',
                                      leftBarColor: const Color(0xFF3EAE4C),
                                      amountColor: themeHelper.themeMode == ThemeMode.dark
                                          ? Colors.white
                                          : Colors.black,
                                    ),
                                  ),

                                  SizedBox(
                                      height: ResponsiveLayout.getHeight(8)),

                                  // Balance Amount
// If there's a remaining payment balance, show only that
                                  if (_currentPaymentRemainingBalance != null &&
                                      _currentPaymentRemainingBalance! > 0)
                                    Column(
                                      children: [
                                        SizedBox(
                                            height:
                                            ResponsiveLayout.getHeight(10)),
                                        Container(
                                          height: ResponsiveLayout.getHeight(90),
                                          padding: const EdgeInsets.only(
                                            top: 6,
                                            right: 6,
                                            bottom: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: themeHelper.themeMode ==
                                                ThemeMode.dark
                                                ? const Color(0xFF091B34)
                                                : const Color(0xFFE6F3FF),
                                            borderRadius:
                                            BorderRadius.circular(6),
                                            border: Border(
                                              top: BorderSide(
                                                color: themeHelper.themeMode ==
                                                    ThemeMode.dark
                                                    ? const Color(0xFF091B34)
                                                    : const Color(0xFF3B7DDD),
                                                width: 1,
                                              ),
                                              right: BorderSide(
                                                color: themeHelper.themeMode ==
                                                    ThemeMode.dark
                                                    ? const Color(0xFF091B34)
                                                    : const Color(0xFF3B7DDD),
                                                width: 1,
                                              ),
                                              bottom: BorderSide(
                                                color: themeHelper.themeMode ==
                                                    ThemeMode.dark
                                                    ? const Color(0xFF091B34)
                                                    : const Color(0xFF3B7DDD),
                                                width: 1,
                                              ),
                                              left: BorderSide.none,
                                            ),
                                          ),
                                          child: _buildPaymentAmountDisplay(
                                            // "After ${_lastPaymentDetails?['method'] ?? 'Payment'}",
                                            "Balance Amount",

                                            '${TextConstants.currencySymbol}${_currentPaymentRemainingBalance!.toStringAsFixed(2)}',
                                            leftBarColor:
                                            const Color(0xFF3B7DDD),
                                            amountColor:
                                            themeHelper.themeMode ==
                                                ThemeMode.dark
                                                ? Colors.white
                                                : Colors.black,
                                            isPaymentBalance: true,
                                          ),
                                        ),
                                      ],
                                    )
// Otherwise show the main balance
                                  else
                                    Container(
                                      height: ResponsiveLayout.getHeight(90),
                                      padding: const EdgeInsets.only(
                                        top: 6,
                                        right: 6,
                                        bottom: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: themeHelper.themeMode ==
                                            ThemeMode.dark
                                            ? const Color(0xFF091B34)
                                            : const Color(0xFFFCF4F4),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border(
                                          top: BorderSide(
                                            color: themeHelper.themeMode ==
                                                ThemeMode.dark
                                                ? const Color(0xFF091B34)
                                                : const Color(0xFFE85C43),
                                            width: 1,
                                          ),
                                          right: BorderSide(
                                            color: themeHelper.themeMode ==
                                                ThemeMode.dark
                                                ? const Color(0xFF091B34)
                                                : const Color(0xFFE85C43),
                                            width: 1,
                                          ),
                                          bottom: BorderSide(
                                            color: themeHelper.themeMode ==
                                                ThemeMode.dark
                                                ? const Color(0xFF091B34)
                                                : const Color(0xFFE85C43),
                                            width: 1,
                                          ),
                                          left: BorderSide.none,
                                        ),
                                      ),
                                      child: _buildPaymentAmountDisplay(
                                        TextConstants.balanceAmount,
                                        balanceAmount < 0
                                            ? '-${TextConstants.currencySymbol}${balanceAmount.abs().toStringAsFixed(2)}'
                                            : '${TextConstants.currencySymbol}${balanceAmount.toStringAsFixed(2)}',
                                        leftBarColor: const Color(0xFFE85C43),
                                        amountColor: themeHelper.themeMode ==
                                            ThemeMode.dark
                                            ? Colors.white
                                            : Colors.black,
                                      ),
                                    ),

                                  SizedBox(
                                      height: ResponsiveLayout.getHeight(15)),

                                  SizedBox(
                                      height: ResponsiveLayout.getHeight(15)),

                                  // // EBT Amount Commented because ebt amount as a part of boutique flow
                                  // Container(
                                  //   padding: const EdgeInsets.only(
                                  //     top: 6,
                                  //     right: 6,
                                  //     bottom: 6,
                                  //   ),
                                  //   decoration: BoxDecoration(
                                  //     color: themeHelper.themeMode == ThemeMode.dark
                                  //         ? const Color(0xFF091B34)
                                  //         : const Color(0xFFF4F7FC),
                                  //     borderRadius: BorderRadius.circular(6),
                                  //     border: Border(
                                  //       top: BorderSide(
                                  //         color: themeHelper.themeMode == ThemeMode.dark
                                  //             ? const Color(0xFF091B34)
                                  //             : const Color(0xFF3B7DDD),
                                  //         width: 1,
                                  //       ),
                                  //       right: BorderSide(
                                  //         color: themeHelper.themeMode == ThemeMode.dark
                                  //             ? const Color(0xFF091B34)
                                  //             : const Color(0xFF3B7DDD),
                                  //         width: 1,
                                  //       ),
                                  //       bottom: BorderSide(
                                  //         color: themeHelper.themeMode == ThemeMode.dark
                                  //             ? const Color(0xFF091B34)
                                  //             : const Color(0xFF3B7DDD),
                                  //         width: 1,
                                  //       ),
                                  //       left: BorderSide.none, // 🚫 no left border
                                  //     ),
                                  //   ),
                                  //   child: _buildAmountDisplay(
                                  //     TextConstants.EBTAmount,
                                  //     ebtTotal < 0
                                  //         ? '-${TextConstants.currencySymbol}${ebtTotal.abs().toStringAsFixed(2)}'
                                  //         : '${TextConstants.currencySymbol}${ebtTotal.toStringAsFixed(2)}',
                                  //     leftBarColor: const Color(0xFF3B7DDD),
                                  //     amountColor: themeHelper.themeMode == ThemeMode.dark
                                  //         ? Colors.white
                                  //         : Colors.black,
                                  //   ),
                                  //
                                  // ),
                                ],
                              ),
                            )
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: ResponsiveLayout.getHeight(10)),

                  // Payment options - make flexible
                  Expanded(
                    flex: 2, // Give less space to payment options
                    child: Container(
                      width: double.infinity,
                      padding:
                      EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      decoration: BoxDecoration(
                        color: themeHelper.themeMode == ThemeMode.dark
                            ? const Color(0xFF303136)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(
                          ResponsiveLayout.getRadius(8),
                        ),
                        border: Border.all(
                          color: const Color(0x2E4C5F7D), // #4C5F7D2E
                          width: 1.5, // adjust as needed
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: themeHelper.themeMode == ThemeMode.dark
                                ? Colors.black.withOpacity(0.3)
                                : Colors.black12,
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              /// ⭐ Redeem Points
                              _buildPaymentOptionButton(
                                TextConstants.redeemPoints,
                                "assets/redeem.png",
                                isActive: redeemedValue == 0 &&
                                    availablePoints > 0 &&
                                    isRedeemActive &&
                                    !isPaymentStarted &&
                                    !hasEbtItem &&
                                    !isOrderPending,
                                onTap: () async {
                                  final bool isInPartialSession =
                                      _currentPaymentRemainingBalance != null &&
                                          _currentPaymentRemainingBalance! > 0;

                                  if (isInPartialSession || discount > 0) {
                                    _showExitPaymentConfirmation(context);
                                    return;
                                  }

                                  // Direct back in all other cases
                                  // Navigator.of(context).pop();
                                  if (hasEbtItem) return; // block redeem

                                  if (!isRedeemActive) return;
                                  if (isOrderPending) {
                                    print("⛔ Redeem blocked: Order is pending");
                                    return;
                                  }

                                  // ⭐ Block redeem when partial payment has started
                                  if (isPaymentStarted) {
                                    print(
                                        "⛔ Redeem blocked: Payment already started");
                                    return;
                                  }

                                  print("🔍 Current State Before Action:");
                                  print("➡ redeemedValue: $redeemedValue");
                                  print("➡ availablePoints: $availablePoints");
                                  print("➡ isMobileValid: $isMobileValid");
                                  print("➡ isEmailValid: $isEmailValid");

                                  if (redeemedValue > 0) {
                                    print(
                                        "⛔ Redeem blocked: Already redeemedValue > 0");
                                    return;
                                  }

                                  if (availablePoints == 0) {
                                    print(
                                        "⛔ Redeem blocked: No availablePoints");
                                    return;
                                  }

                                  if (!isMobileValid && !isEmailValid) {
                                    print(
                                        "⛔ Invalid Contact: Neither mobile nor email valid");
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            "Enter valid mobile number or email"),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                    return;
                                  }

                                  print("📨 Opening RedeemPointsDialog...");
                                  final result = await showDialog(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (_) => RedeemPointsDialog(
                                        apiData: loyaltyData!),
                                  );

                                  print("📨 Dialog Result: $result");

                                  if (result == null) {
                                    print(
                                        "⛔ Dialog closed manually (null result)");
                                    return;
                                  }

                                  // User removed redeem
                                  if (result["remove"] == true) {
                                    print("🗑 REMOVE REDEEM SELECTED");
                                    setState(() {
                                      redeemedValue = 0;
                                      computedNetPayable = NetTotal;
                                    });

                                    final String orderKey =
                                        widget.orderId?.toString() ??
                                            widget.offlineOrderId?.toString() ??
                                            "";

                                    print(
                                        "🗑 Removing redeem from Hive → OrderKey: $orderKey");

                                    if (orderKey.isNotEmpty) {
                                      await removeOfflineOrderRedeem(orderKey);
                                    }

                                    print("🧹 Redeem removed successfully.");
                                    return;
                                  }

                                  print("🟦 Processing API response...");

                                  final redeemApi =
                                  jsonDecode(result["apiResponse"]);
                                  print("📦 API Raw Response: $redeemApi");

                                  if (redeemApi == null) {
                                    print("❌ ERROR: Redeem API is null");
                                    return;
                                  }

                                  if (redeemApi["success"] != true) {
                                    print(
                                        "❌ API reported failure: ${redeemApi["message"]}");
                                    return;
                                  }

                                  final data = redeemApi["data"];
                                  print("📦 Parsed Data: $data");

                                  // Extract values
                                  final double newRedeemValue = double.tryParse(
                                      data["redeem_amount"].toString()) ??
                                      0.0;

                                  final int usedPoints = int.tryParse(
                                      data["redeem_points"].toString()) ??
                                      0;

                                  final int newAvailablePoints = int.tryParse(
                                      data["available_points"]
                                          .toString()) ??
                                      availablePoints;

                                  final double newBalanceAmount =
                                      double.tryParse(
                                          data["order_total"].toString()) ??
                                          computedNetPayable;

                                  print("🔢 Extracted API Values:");
                                  print("➡ newRedeemValue: $newRedeemValue");
                                  print("➡ usedPoints: $usedPoints");
                                  print(
                                      "➡ newAvailablePoints: $newAvailablePoints");
                                  print(
                                      "➡ newBalanceAmount: $newBalanceAmount");

                                  // Update UI
                                  setState(() {
                                    redeemedValue = newRedeemValue;
                                    availablePoints = newAvailablePoints;
                                    balanceAmount = newBalanceAmount;
                                    isRedeemAppliedFromApi = true;
                                  });

                                  print("🟩 UI Updated:");
                                  print("➡ redeemedValue: $redeemedValue");
                                  print("➡ availablePoints: $availablePoints");
                                  print("➡ balanceAmount: $balanceAmount");

                                  // Save to Hive
                                  final String orderKey =
                                      widget.orderId?.toString() ??
                                          widget.offlineOrderId?.toString() ??
                                          "";

                                  print(
                                      "💾 Saving redeem to Hive → OrderKey: $orderKey");

                                  if (orderKey.isNotEmpty) {
                                    await updateOfflineOrderRedeem(
                                      orderKey,
                                      newRedeemValue,
                                      usedPoints,
                                      newAvailablePoints,
                                    );
                                  }

                                  print("💾 Redeem successfully saved to Hive");
                                  print(
                                      "======== 🟩 REDEEM PROCESS COMPLETED 🟩 ========");
                                },
                              ),

                              const SizedBox(height: 10),
                              _buildCouponButton(
                                TextConstants.generatecoupon,
                                "assets/coupon.png",
                                isActive: redeemedValue == 0 &&
                                    !isPaymentStarted &&
                                    !isOrderPending &&
                                    !hasOnlyCashbackOrPayoutItems &&
                                    computedNetPayable > 0, // ✅ keep this
                                onTap: () {
                                  if (redeemedValue > 0 ||
                                      isPaymentStarted ||
                                      isOrderPending ||
                                      hasOnlyCashbackOrPayoutItems ||
                                      computedNetPayable <= 0) {
                                    return;
                                  }

                                  _openCouponPopup();
                                },
                              ),
                              const SizedBox(height: 10),
                              _buildRedeemCouponButton(
                                TextConstants.Issuecoupon,
                                "assets/coupon.png",

                                isActive:
                                !(offlineOrder?["coupon_applied"] == true ||
                                    isCouponActive||
                                    computedNetPayable < 0),

                                onTap: () async {
                                  if (offlineOrder == null) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content:
                                          Text("No offline order found")),
                                    );
                                    return;
                                  }
                                  await _syncAndShowCouponPopup();
                                  // Issue Coupon should not mark coupon as applied
                                  // to the current order.
                                  setState(() {
                                    isCouponActive = false;
                                  });
                                },
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool isGenerateCouponActive = false;

  Future<bool> _syncAndShowCouponPopup() async {
    if (_isProcessing) return false;

    setState(() => _isProcessing = true);
    bool loaderOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final response = await OrderRepository().CouponApply(offlineOrder!);

      if (loaderOpen) {
        Navigator.of(context).pop();
        loaderOpen = false;
      }

      if (response == null || response is! Map<String, dynamic>) {
        _showErrorPopup("Coupon applied but no response data received.");
        return false;
      }

      final coupons = response["coupons"] as List? ?? [];
      if (coupons.isEmpty) {
        _showErrorPopup("Coupon applied, but no coupon details returned.");
        return false;
      }

      final coupon = coupons.first;
      final double discountAmount = (coupon["amount"] as num?)?.toDouble() ?? 0.0;
      final String couponCode = coupon["code"]?.toString() ?? "";

      // Optional: Early minimum amount check (if backend provides it)
      final double minAmount = (coupon["min_amount"] as num?)?.toDouble() ?? 0.0;
      final double currentSubtotal = grossTotal; // or computed subtotal

      if (minAmount > 0 && currentSubtotal < minAmount) {
        _showErrorPopup("Coupon '$couponCode' requires minimum order of \$$minAmount");
        return false;
      }

      // Update UI temporarily
      setState(() {
        couponValue = discountAmount;
        ebtTotal = 0.0;
        cashbackFee = 0.0;
        isGenerateCouponActive = true;
      });

      // Show confirmation popup
      final bool confirmed = await _showCouponResponsePopup(response);

      if (!confirmed) {
        debugPrint("🔵 Coupon popup closed with X – not saving to Hive");
        setState(() => isGenerateCouponActive = false);
        return false;
      }

      // === Save to Hive only after user confirmation ===
      final box = StorageProvider.offlineOrders;
      final String key = offlineOrder?['id']?.toString() ??
          offlineOrder?['order_id']?.toString() ??
          offlineOrder?['local_order_id']?.toString() ?? "";

      if (key.isEmpty) return true;

      final hasKey = await box.containsKey(key);
      final raw = hasKey ? await box.get(key) : null;
      final Map<String, dynamic> existing = raw is Map
          ? Map<String, dynamic>.from(raw)
          : Map<String, dynamic>.from(offlineOrder!);

      // Prepare issued coupons
      final List<Map<String, dynamic>> issueCoupons = [];
      for (final c in response["coupons"] as List? ?? []) {
        if (c is! Map) continue;
        final m = Map<String, dynamic>.from(c);
        if (m["generate_type"] != true) {
          m["generate_type"] = false;
        }
        issueCoupons.add(m);
      }

      // Keep previous redeemed coupons
      final prevCoupons = <Map<String, dynamic>>[];
      final prevCr = existing["coupon_response"];
      if (prevCr is Map && prevCr["coupons"] is List) {
        for (final x in prevCr["coupons"] as List) {
          if (x is Map) prevCoupons.add(Map<String, dynamic>.from(x));
        }
      }

      final keptRedeems = prevCoupons.where((c) => _couponHiveEntryIsRedeem(c)).toList();

      final mergedResponse = Map<String, dynamic>.from(response);
      mergedResponse["coupons"] = [...issueCoupons, ...keptRedeems];

      existing["coupon_response"] = mergedResponse;
      existing["coupon_applied"] = true;
      existing["coupon_applied_at"] = DateTime.now().toIso8601String();
      existing["coupon_amount"] = discountAmount;

      await box.put(key, existing);
      offlineOrder = existing;

      debugPrint("✅ Generated Coupon saved in Hive for order $key");
      return true;

    } catch (e) {
      if (loaderOpen) {
        Navigator.of(context).pop();
        loaderOpen = false;
      }
      _showErrorPopup("Something went wrong while applying coupon.");
      debugPrint("❌ Coupon popup error: $e");
      return false;
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // Future<bool> _syncAndShowCouponPopup() async {
  //   if (_isProcessing) return false;
  //
  //   setState(() => _isProcessing = true);
  //
  //   bool loaderOpen = true;
  //
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (_) => const Center(child: CircularProgressIndicator()),
  //   );
  //
  //   try {
  //     final response = await OrderRepository().CouponApply(offlineOrder!);
  //
  //     if (loaderOpen) {
  //       Navigator.of(context).pop();
  //       loaderOpen = false;
  //     }
  //
  //     // 🔒 HARD GUARD
  //     if (response == null || response is! Map<String, dynamic>) {
  //       _showErrorPopup("Coupon applied but no response data received.");
  //       return false;
  //     }
  //
  //     final coupons = response["coupons"] as List? ?? [];
  //     if (coupons.isEmpty) {
  //       _showErrorPopup("Coupon applied, but no coupon details returned.");
  //       return false;
  //     }
  //
  //     final coupon = coupons.first;
  //     final double discountAmount =
  //         (coupon["amount"] as num?)?.toDouble() ?? 0.0;
  //
  //     // ✅ Only update UI state here; save to Hive only after user clicks OK
  //     setState(() {
  //       couponValue = discountAmount;
  //       ebtTotal = 0.0;
  //       cashbackFee = 0.0;
  //       isGenerateCouponActive = true;
  //     });
  //
  //     // ✅ Await popup result: true = OK (confirm), false = X (cancel)
  //     final bool confirmed = await _showCouponResponsePopup(response);
  //
  //     if (!confirmed) {
  //       // User closed with X – don't save to Hive, reset UI state so they can issue again
  //       debugPrint("🔵 Coupon popup closed with X – not saving to Hive");
  //       setState(() {
  //         isGenerateCouponActive = false;
  //       });
  //       return false;
  //     }
  //
  //     final box = StorageProvider.offlineOrders;
  //
  //     final String key = offlineOrder?['id']?.toString() ??
  //         offlineOrder?['order_id']?.toString() ??
  //         offlineOrder?['local_order_id']?.toString() ??
  //         "";
  //
  //     if (key.isEmpty) return true;
  //
  //     final hasKey = await box.containsKey(key);
  //     final raw = hasKey ? await box.get(key) : null;
  //     final Map<String, dynamic> existing = raw is Map
  //         ? Map<String, dynamic>.from(raw)
  //         : Map<String, dynamic>.from(offlineOrder!);
  //
  //     final List<Map<String, dynamic>> issueCoupons = [];
  //     for (final c in response["coupons"] as List? ?? []) {
  //       if (c is! Map) continue;
  //       final m = Map<String, dynamic>.from(c);
  //       if (m["generate_type"] != true) {
  //         m["generate_type"] = false;
  //       }
  //       issueCoupons.add(m);
  //     }
  //     final prevCoupons = <Map<String, dynamic>>[];
  //     final prevCr = existing["coupon_response"];
  //     if (prevCr is Map && prevCr["coupons"] is List) {
  //       for (final x in prevCr["coupons"] as List) {
  //         if (x is Map) prevCoupons.add(Map<String, dynamic>.from(x));
  //       }
  //     }
  //     final keptRedeems =
  //     prevCoupons.where((c) => _couponHiveEntryIsRedeem(c)).toList();
  //     final mergedResponse = Map<String, dynamic>.from(response);
  //     mergedResponse["coupons"] = [...issueCoupons, ...keptRedeems];
  //     existing["coupon_response"] = mergedResponse;
  //     existing["coupon_applied"] = true;
  //     existing["coupon_applied_at"] = DateTime.now().toIso8601String();
  //     existing["coupon_amount"] = discountAmount;
  //
  //     await box.put(key, existing);
  //     offlineOrder = existing;
  //
  //     debugPrint("✅ Coupon saved in Hive for order $key");
  //     return true;
  //   } catch (e) {
  //     if (loaderOpen) {
  //       Navigator.of(context).pop();
  //       loaderOpen = false;
  //     }
  //     _showErrorPopup("Something went wrong while applying coupon.");
  //     debugPrint("❌ Coupon popup error: $e");
  //     return false;
  //   } finally {
  //     setState(() => _isProcessing = false);
  //   }
  // }

  void _showErrorPopup(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Center(
          child: Text(
            "Error",
            style: TextStyle(
              color: Color(0xFFFE6464),      // 🔴 red color
              fontSize: 24,             // adjust if needed
              fontWeight: FontWeight.bold, // stronger emphasis
              fontFamily: "Inter",      // ✅ your custom font (change if needed)
            ),
          ),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center, // ✅ center message
        ),
        actionsAlignment: MainAxisAlignment.center, // ✅ center button
        actions: [
          SizedBox(
            width: 100,
            height: 40,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFFFE6464), // 🔴 button color
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                "OK",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _showCouponResponsePopup(Map<String, dynamic> response) async {
    final coupons = response["coupons"] as List? ?? [];
    final coupon = coupons.isNotEmpty ? coupons.first : null;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final dialogBg = isDark ? const Color(0xFF1A1C2A) : Colors.white;
    final cardBg = isDark ? const Color(0xFF2B2D3C) : const Color(0xFFF2F4F7);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final textSecondary = isDark ? Colors.white70 : Colors.grey;
    const success = Color(0xFF1ABC9C);

    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: dialogBg,
          insetPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      /// HEADER
                      Row(
                        children: [
                          const Icon(Icons.card_giftcard,
                              color: success, size: 30),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "Coupon Generated",
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: textPrimary),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 4),

                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "Can be redeemed after payment",
                          style: TextStyle(fontSize: 13, color: textSecondary),
                        ),
                      ),

                      const SizedBox(height: 18),

                      /// COUPON CARD
                      if (coupon != null)
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              /// CODE BOX
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12, horizontal: 14),
                                decoration: BoxDecoration(
                                  color: success.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.local_offer,
                                        color: success),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        coupon["code"].toString(),
                                        style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 1,
                                            color: textPrimary),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 14),

                              // _couponRow("Discount Amount",
                              //     "${coupon["amount"]}", textPrimary),
                              _couponRow(
                                "Discount Amount",
                                "\$${coupon["amount"]}",
                                textPrimary,
                              ),

                              _couponRow(
                                "Min Order Amount",
                                coupon["min_amount"] == null
                                    ? "No minimum"
                                    : "₹${coupon["min_amount"]}",
                                textPrimary,
                              ),

                              _couponRow(
                                "Max order Amount",
                                coupon["max_amount"] == null
                                    ? "No maximum"
                                    : "₹${coupon["max_amount"]}",
                                textPrimary,
                              ),
                            ],
                          ),
                        ),

                      const SizedBox(height: 18),

                      /// OK BUTTON → confirm (true)
                      SizedBox(
                        width: double.infinity,
                        height: 42,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                            Colors.red.shade400, // soft light red
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text(
                            "OK",
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                /// CLOSE (X) BUTTON → cancel (false)
                Positioned(
                  right: 12,
                  top: 12,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(dialogContext, false),
                    child: const CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.red,
                      child: Icon(Icons.close, color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return result ?? false;
  }

  Widget _couponRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(value),
        ],
      ),
    );
  }

  Widget _buildCouponButton(
      String title,
      String iconPath, {
        required VoidCallback onTap,
        bool isActive = true,
      }) {
    return InkWell(
      onTap: isActive ? onTap : null,
      child: Container(
        height: 50,
        width: 368,
        padding: const EdgeInsets.symmetric(horizontal: 24), // ✅ SAME PADDING
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? const Color(0xFFEB910E) : Colors.grey,
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x3F000000),
              blurRadius: 4,
              offset: Offset(2, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // 🔹 LEFT: TEXT
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: isActive ? const Color(0xFFEB910E) : Colors.grey,
                ),
              ),
            ),

            // 🔹 RIGHT: ICON (ALIGNED)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? const Color(0xFFEB910E) : Colors.grey,
                ),
                child: Image.asset(
                  iconPath,
                  width: 18,
                  height: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRedeemCouponButton(
      String title,
      String iconPath, {
        required VoidCallback onTap,
        bool isActive = true,
      }) {
    return InkWell(
      onTap: isActive ? onTap : null,
      child: Container(
        height: 50,
        width: 368,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        // ✅ SAME PADDING
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? const Color(0xFF1ABC9C) : Colors.grey,
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x3F000000),
              blurRadius: 4,
              offset: Offset(2, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // 🔹 LEFT: TEXT
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: isActive ? const Color(0xFF1ABC9C) : Colors.grey,
                ),
              ),
            ),

            // 🔹 RIGHT: ICON (ALIGNED)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? const Color(0xFF1ABC9C) : Colors.grey,
                ),
                child: Image.asset(
                  iconPath,
                  width: 18,
                  height: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  //
  // Future<void> _removeAppliedCoupon() async {
  //   if (widget.orderId == null || widget.orderId == 0) return;
  //
  //   final offlineBox = StorageProvider.offlineOrders;
  //   final localKey = widget.offlineOrderId?.toString(); // 🔥 LOCAL KEY ONLY
  //
  //   if (localKey == null) {
  //     print("❌ No offlineOrderId found");
  //     return;
  //   }
  //
  //   setState(() => isSummaryLoading = true);
  //
  //   try {
  //     // 🔥 Remove coupon from Woo
  //     await orderBloc.removeCooupon(
  //       orderId: widget.orderId!,
  //       couponCode: "",
  //     );
  //
  //     // 🔥 RESTORE ORIGINAL PAYABLE
  //     final double restoredPayable =
  //         grossTotal + oldTax - merchantDiscount + cashbackFee;
  //
  //     setState(() {
  //       discount = 0.0;
  //       discountValue = 0.0;
  //       couponDiscount = 0.0;
  //       NetTotal = grossTotal;
  //       computedNetPayable = restoredPayable;
  //       balanceAmount = restoredPayable - tenderAmount;
  //
  //       isCouponAppliedFromApi = false;
  //     });
  //
  //     // ----------------- UPDATE HIVE -----------------
  //     final existing = offlineBox.get(localKey);
  //     if (existing != null) {
  //       final data = Map<String, dynamic>.from(existing);
  //
  //       // 🧹 CLEAR COUPON DATA
  //       data.remove("appliedCoupon");
  //       data.remove("couponCode");
  //       data.remove("couponDiscount");
  //       data.remove("orderDiscount");
  //
  //       // 🔥 SINGLE SOURCE OF TRUTH
  //       data["basePayableAmount"] = restoredPayable;
  //       data["wooTax"] = oldTax;
  //       data["couponRemoved"] = true;
  //
  //       offlineBox.put(localKey, data);
  //
  //       print("🗑 Coupon removed | Base payable restored = $restoredPayable");
  //     }
  //
  //     await CustomerDisplayHelper.updateCustomerDisplay(
  //       widget.offlineOrderId!,
  //     );
  //
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       const SnackBar(
  //         content: Text("Coupon removed successfully"),
  //         backgroundColor: Colors.green,
  //       ),
  //     );
  //   } catch (e) {
  //     print("❌ Error removing coupon: $e");
  //   } finally {
  //     setState(() => isSummaryLoading = false);
  //   }
  // }
  Future<void> _removeAppliedCoupon() async {
    try {
      final box = StorageProvider.offlineOrders;

      final String orderKey = widget.orderId?.toString() ??
          widget.offlineOrderId?.toString() ??
          orderId?.toString() ??
          "";

      if (orderKey.isEmpty) return;

      final rawOrder = await box.get(orderKey);
      if (rawOrder == null) return;

      final offlineOrder = Map<String, dynamic>.from(rawOrder);

      if (mounted) {
        setState(() => isSummaryLoading = true);
      }

      final int safeOrderId =
          int.tryParse(orderKey) ?? widget.orderId ?? 0;

      final double restoredTax = widget.orderTax;

      setState(() {
        discount = 0.0;
        discountValue = 0.0;
        couponDiscount = 0.0;

        tax = restoredTax;
        grossTotal = widget.grossTotal;

        merchantDiscount = widget.merchantDiscount < 0
            ? widget.merchantDiscount
            : -widget.merchantDiscount.abs();

        NetTotal = grossTotal + merchantDiscount;
        computedNetPayable = NetTotal + tax + cashbackFee;
        orderTotal = computedNetPayable;
        balanceAmount = computedNetPayable - tenderAmount;

        isCouponAppliedFromApi = false;
      });

      // recalculate updated totals
      await _recalculateTaxOnDiscountedItems();

      if (!widget.itemPricesAlreadyAdjusted) {
        _recalculateGrossAndNetFromLineItemDiscounts();
      }

      // update Hive
      offlineOrder["coupon_response"] = {
        "coupons": [],
        "available_coupons": [],
      };

      offlineOrder["applied_coupons"] = [];
      offlineOrder["coupon_applied"] = false;
      offlineOrder["orderDiscount"] = discount;
      offlineOrder["tax_discount"] = tax;
      offlineOrder["grand_total"] = computedNetPayable;

      await box.put(orderKey, offlineOrder);

      // build items for customer display
      final customerItems = orderItems.map((item) {
        return {
          "name": item["item_name"] ?? "",
          "qty": item["items_count"] ?? 1,
          "price": item["item_price"] ?? 0.0,
          "image": item["item_image"] ?? "",
        };
      }).toList();

      // DIRECT customer display refresh
      await CustomerDisplayService.showCustomerData(
        orderId: safeOrderId,
        items: customerItems,
        grossTotal: grossTotal,
        discount: discount,
        merchantDiscount: merchantDiscount,
        netTotal: NetTotal,
        tax: tax,
        netPayable: computedNetPayable,
        cashbackFee: cashbackFee,
        redeemedAmount: redeemedValue.toDouble(),
        loyaltyContact: mobileController.text.trim(),
        summaryEnabled: true,
      );

      try {
        await OrderRepository().syncSingleOfflineOrder(offlineOrder);
      } catch (e) {
        print("Sync after coupon removal failed: $e");
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Coupon removed successfully"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print("Error removing coupon: $e");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to remove coupon: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => isSummaryLoading = false);
      }
    }
  }
  void _openCouponPopup() {
    ScannerGuard.isCouponPopupOpen = true;

    final TextEditingController _couponCtrl = TextEditingController();

    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    // THEME COLORS
    final Color dialogBg = isDark ? const Color(0xFF252837) : Colors.white;
    final Color borderColor =
    isDark ? const Color(0xFF3A3A3A) : Colors.grey.shade300;
    final Color textPrimary = isDark ? Colors.white : Colors.black87;
    final Color textSecondary = isDark ? Colors.white70 : Colors.black54;
    final Color hintColor = isDark ? Colors.white38 : Colors.grey;
    final Color redPrimary = const Color(0xFFFD6464);

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.10),
      builder: (context) {
        return Stack(
            children: [
              /// 🔹 WHITE BACKGROUND when keyboard opens
              if (MediaQuery.of(context).viewInsets.bottom > 0)
                Positioned.fill(
                  child: Container(
                    color: isDark
                        ? const Color(0xFF1F1D2B) // match your dark dialog bg
                        : Colors.white,
                  ),
                ),

              /// 🔹 YOUR EXISTING DIALOG
              Center(
                  child: WillPopScope(
                    onWillPop: () async {
                      ScannerGuard.isCouponPopupOpen = false;
                      return true;
                    },
                    child: BarcodeKeyboardListener(
                      bufferDuration: const Duration(milliseconds: 600),
                      onBarcodeScanned: (barcode) {
                        final code = barcode.trim();
                        print("🎯 Coupon QR/Barcode scanned → $code");

                        _couponCtrl.text = code; // ✅ Correct prefill
                      },
                      child: Dialog(
                        backgroundColor: dialogBg,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Container(
                          padding: const EdgeInsets.all(26),
                          width: MediaQuery.of(context).size.width * 0.30,
                          decoration: BoxDecoration(
                            color: dialogBg,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              if (!isDark)
                                BoxShadow(
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                  color: Colors.black.withOpacity(0.15),
                                ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: Text(
                                  "Apply Coupon",
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: redPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              TextField(
                                controller: _couponCtrl,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Enter Coupon Code",
                                  labelStyle: TextStyle(color: textSecondary),
                                  hintStyle: TextStyle(color: hintColor),
                                  filled: true,
                                  fillColor:
                                  isDark ? const Color(0xFF2C2C2C) : Colors.white,
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: redPrimary, width: 1),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderSide:
                                    BorderSide(color: borderColor, width: 1.0),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 25),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      foregroundColor: redPrimary,
                                      side: BorderSide(color: redPrimary, width: 1),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 10,
                                      ),
                                    ),
                                    onPressed: () {
                                      ScannerGuard.isCouponPopupOpen =
                                      false; // CLOSE FLAG
                                      Navigator.pop(context);
                                    },
                                    child: const Text(
                                      "Cancel",
                                      style: TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: redPrimary,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 12,
                                      ),
                                    ),
                                    onPressed: () async {
                                      final code = _couponCtrl.text.trim();

                                      if (code.isEmpty) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content:
                                            const Text("Please enter coupon code"),
                                            backgroundColor: Colors.redAccent,
                                          ),
                                        );
                                        return;
                                      }

                                      ScannerGuard.isCouponPopupOpen =
                                      false; // CLOSE FLAG
                                      Navigator.pop(context);
                                      await _applyCoupon(code);
                                    },
                                    child: const Text("Apply"),
                                  ),
                                ],
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                  ))
            ]);
      },
    ).then((_) {
      ScannerGuard.isCouponPopupOpen = false; // 🔓 Ensure scanner re-enables
    });
  }

  Future<void> _applyCoupon(String code) async {
    code = code.trim().toLowerCase();
    if (code.isEmpty) return;

    try {
      final box = StorageProvider.offlineOrders;
      final String orderKey = widget.orderId?.toString() ??
          widget.offlineOrderId?.toString() ??
          orderId?.toString() ??
          "";

      if (orderKey.isEmpty) return;

      final rawOrder = await box.get(orderKey);
      if (rawOrder == null) return;

      Map<String, dynamic> offlineOrder = Map<String, dynamic>.from(rawOrder);

      setState(() => isSummaryLoading = true);

      // ==================== SMART DUPLICATE CHECK ====================
      final dynamic cr = offlineOrder["coupon_response"];
      bool isAlreadyRedeemed = false;

      if (cr is Map) {
        final List<dynamic> coupons = cr["coupons"] as List? ?? [];

        for (final dynamic item in coupons) {
          if (item is! Map) continue;

          final Map<String, dynamic> couponMap = Map<String, dynamic>.from(item);
          final String existingCode = (couponMap["code"]?.toString() ?? "").trim().toLowerCase();

          if (existingCode == code) {
            // 🔥 ONLY block with "already applied" if it is ALREADY REDEEMED
            if (_couponHiveEntryIsRedeem(couponMap)) {
              isAlreadyRedeemed = true;
              break;
            }
            // If only issued → allow (for issuing or redeeming)
          }
        }
      }

      if (isAlreadyRedeemed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Coupon already applied"),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      // ============================================================

      // Backup
      final dynamic originalCouponResponse = offlineOrder["coupon_response"];

      // Merge redeem coupon
      offlineOrder["coupon_response"] =
          _mergeRedeemIntoCouponResponse(offlineOrder["coupon_response"], code);

      _cleanInvalidRedeemCoupons(offlineOrder, code);

      final int? localOrderId = int.tryParse(orderKey);
      if (localOrderId != null) {
        offlineOrder["id"] = localOrderId;
      }

      await box.put(orderKey, offlineOrder);

      // Sync to server
      final result = await OrderRepository().syncSingleOfflineOrder(offlineOrder);

      if (result == null || result is! Map<String, dynamic>) {
        offlineOrder["coupon_response"] = originalCouponResponse;
        await box.put(orderKey, offlineOrder);

        String errorMsg = "Invalid coupon or unable to apply";
        if (result is Map<String, dynamic> && result['code'] == 'invalid_coupon') {
          errorMsg = result['message']?.toString() ?? errorMsg;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMsg), backgroundColor: Colors.orange),
        );
        return;
      }

      // SUCCESS logic (unchanged)
      final double newDiscount = double.tryParse(result["discount_total"]?.toString() ?? "0") ?? 0.0;
      final double newTax = double.tryParse(result["tax"]?.toString() ?? "0") ?? tax;
      final double newTotal = double.tryParse(result["total"]?.toString() ?? "0") ?? 0.0;

      offlineOrder["orderDiscount"] = newDiscount;
      offlineOrder["tax_discount"] = newTax;
      offlineOrder["grand_total"] = newTotal;
      offlineOrder["coupon_applied"] = true;
      offlineOrder["applied_coupons"] = [{"code": code.toUpperCase(), "amount": newDiscount}];

      if (result.containsKey("id")) {
        offlineOrder["wooOrderId"] = result["id"];
        offlineOrder["wooStatus"] = result["status"]?.toString().toLowerCase() ?? '';
        offlineOrder["synced"] = true;
        offlineOrder["sync_at"] = DateTime.now().toIso8601String();
      }

      _enrichRedeemCouponIdsFromWoo(offlineOrder, result, code);
      await box.put(orderKey, offlineOrder);

      if (localOrderId != null) {
        await CustomerDisplayHelper.updateCustomerDisplay(localOrderId, summaryEnabled: true);
      }

      setState(() {
        discount = (newDiscount != 0) ? -newDiscount.abs() : 0.0;
        tax = newTax;
        NetTotal = grossTotal + discount + merchantDiscount;
        computedNetPayable = NetTotal + tax + cashbackFee;
        orderTotal = newTotal;
        balanceAmount = newTotal;
        isCouponAppliedFromApi = true;
      });

      await _recalculateTaxOnDiscountedItems();
      _recalculateGrossAndNetFromLineItemDiscounts();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Coupon applied successfully"), backgroundColor: Colors.green),
      );

    } catch (e) {
      print("❌ Apply coupon error: $e");
      // Restore logic (unchanged)
      try {
        final box = StorageProvider.offlineOrders;
        final String orderKey = widget.orderId?.toString() ?? widget.offlineOrderId?.toString() ?? "";
        if (orderKey.isNotEmpty) {
          final raw = await box.get(orderKey);
          if (raw is Map) {
            final order = Map<String, dynamic>.from(raw);
            final cr = order["coupon_response"];
            if (cr is Map) {
              final map = Map<String, dynamic>.from(cr);
              final coupons = (map['coupons'] as List?) ?? [];
              map['coupons'] = coupons.where((c) {
                if (c is! Map) return false;
                return !_couponHiveEntryIsRedeem(Map<String, dynamic>.from(c));
              }).toList();
              order["coupon_response"] = map;
              await box.put(orderKey, order);
            }
          }
        }
      } catch (_) {}

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to apply coupon"), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => isSummaryLoading = false);
    }
  }
  /// Remove previously failed/invalid redeem coupons before syncing
  void _cleanInvalidRedeemCoupons(Map<String, dynamic> offlineOrder, String currentCode) {
    final cr = offlineOrder['coupon_response'];
    if (cr is! Map) return;

    final map = Map<String, dynamic>.from(cr);
    final List<dynamic> coupons = map['coupons'] as List? ?? [];

    final cleaned = <Map<String, dynamic>>[];

    for (final dynamic c in coupons) {
      if (c is! Map) continue;
      final couponMap = Map<String, dynamic>.from(c);
      final isRedeem = _couponHiveEntryIsRedeem(couponMap);

      if (!isRedeem) {
        cleaned.add(couponMap);
      } else if (couponMap['code']?.toString().trim() == currentCode) {
        cleaned.add(couponMap); // keep only current one
      }
    }

    map['coupons'] = cleaned;
    offlineOrder['coupon_response'] = map;
  }
  // Future<void> _applyCoupon(String code) async {
  //   try {
  //     final box = StorageProvider.offlineOrders;
  //
  //     final String orderKey =
  //         widget.orderId?.toString() ?? widget.offlineOrderId?.toString() ?? "";
  //
  //     if (orderKey.isEmpty) return;
  //
  //     final rawOrder = await box.get(orderKey);
  //
  //     final offlineOrder = Map<String, dynamic>.from(
  //       rawOrder is Map ? rawOrder : {},
  //     );
  //
  //     if (offlineOrder.isEmpty) return;
  //
  //     // Store coupon locally (redeem: generate_type true; keep issued coupons if any)
  //
  //     offlineOrder["coupon_response"] =
  //         _mergeRedeemIntoCouponResponse(offlineOrder["coupon_response"], code);
  //
  //     // ✅ Use LOCAL order ID instead of Woo ID for syncing
  //
  //     final int? localOrderId = int.tryParse(orderKey);
  //
  //     if (localOrderId != null) {
  //       offlineOrder["id"] = localOrderId; // critical for local sync
  //     }
  //
  //     await box.put(orderKey, offlineOrder);
  //
  //     setState(() => isSummaryLoading = true);
  //
  //     // Send to repository with local ID
  //
  //     final result =
  //     await OrderRepository().syncSingleOfflineOrder(offlineOrder);
  //
  //     if (result == null || result is! Map) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         const SnackBar(
  //           content: Text("Invalid coupon or unable to apply"),
  //           backgroundColor: Colors.red,
  //         ),
  //       );
  //
  //       return;
  //     }
  //
  //     // ⭐ Extract values from repository response
  //
  //     final double newDiscount =
  //         double.tryParse(result["discount_total"]?.toString() ?? "0") ?? 0.0;
  //
  //     final double newTax =
  //         double.tryParse(result["tax"]?.toString() ?? "0") ?? tax;
  //
  //     final double newTotal =
  //         double.tryParse(result["total"]?.toString() ?? "0") ?? 0.0;
  //
  //     // Update offline order fields
  //
  //     offlineOrder["orderDiscount"] = newDiscount;
  //
  //     offlineOrder["tax_discount"] = newTax;
  //
  //     offlineOrder["grand_total"] = newTotal;
  //
  //     offlineOrder["coupon_applied"] = true;
  //
  //     offlineOrder["applied_coupons"] = [
  //       {"code": code, "amount": newDiscount}
  //     ];
  //
  //     // ✅ Store Woo info if returned, but do NOT send Woo ID next time
  //
  //     if (result.containsKey("id")) {
  //       offlineOrder["wooOrderId"] = result["id"];
  //
  //       offlineOrder["wooStatus"] =
  //           result["status"]?.toString().toLowerCase() ?? '';
  //
  //       offlineOrder["synced"] = true;
  //
  //       offlineOrder["sync_at"] = DateTime.now().toIso8601String();
  //     }
  //
  //     _enrichRedeemCouponIdsFromWoo(offlineOrder, result, code);
  //
  //     await box.put(orderKey, offlineOrder);
  //
  //     // 🔥 Update display
  //
  //     await CustomerDisplayHelper.updateCustomerDisplay(
  //       localOrderId!,
  //       summaryEnabled: true,
  //     );
  //
  //     setState(() {
  //       // Enforce negative sign for display consistency (-$5.00)
  //       discount = (newDiscount != 0) ? -(newDiscount.abs()) : 0.0;
  //       tax = newTax;
  //
  //       // Use algebraic sum
  //       NetTotal = grossTotal + discount + merchantDiscount;
  //       computedNetPayable = NetTotal + tax + cashbackFee;
  //       orderTotal = newTotal;
  //
  //       balanceAmount = newTotal;
  //
  //       isCouponAppliedFromApi = true;
  //     });
  //
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       const SnackBar(
  //         content: Text("Coupon applied successfully"),
  //         backgroundColor: Colors.green,
  //       ),
  //     );
  //
  //     print(
  //         "✅ Coupon Applied (local ID $localOrderId): Discount $newDiscount, Tax $newTax, Total $newTotal");
  //   } catch (e) {
  //     print("❌ Apply coupon error: $e");
  //   } finally {
  //     setState(() => isSummaryLoading = false);
  //   }
  // }

  Widget _buildAmountDisplay(
      String label,
      String amount, {
        required Color leftBarColor,
        Color? amountColor = Colors.black,
      }) {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Container(
      width: MediaQuery.of(context).size.width * 0.240, // fixed width
      height: ResponsiveLayout.getHeight(40), // fixed height
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 🔴 LEFT INDICATOR BAR (VERTICALLY CENTERED)
          Container(
            width: 4,
            height: ResponsiveLayout.getHeight(
                40), // slightly taller for visual effect
            decoration: BoxDecoration(
              color: leftBarColor,
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              boxShadow: [
                BoxShadow(
                  color: leftBarColor.withOpacity(0.45),
                  blurRadius: 8,
                  offset: const Offset(1, 2),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          // 📄 TEXT CONTENT
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: ResponsiveLayout.getFontSize(11),
                  fontWeight: FontWeight.w500,
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? Colors.white
                      : const Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                amount,
                style: TextStyle(
                  fontSize: ResponsiveLayout.getFontSize(12),
                  fontWeight: FontWeight.w700,
                  color: amountColor ??
                      (themeHelper.themeMode == ThemeMode.dark
                          ? Colors.white
                          : const Color(0xFF222222)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAmountButton(String amount) {
    // Build #1.0.29: updated
    return GestureDetector(
      onTap: () {
        // Remove '$' and ensure the value is numeric
        String cleanAmount =
        amount.replaceAll(TextConstants.currencySymbol, '');
        double numericValue = double.parse(cleanAmount);
        amountController.text =
        '${TextConstants.currencySymbol} ${numericValue.toStringAsFixed(2)}';
        setState(() {});
      },
      child: Container(
        height: ResponsiveLayout.getHeight(43),
        width: ResponsiveLayout.getWidth(100),
        alignment: Alignment.center,
        padding: EdgeInsets.all(ResponsiveLayout.getPadding(5.0)),
        decoration: BoxDecoration(
          color: Color(0xFFE1F8DC),
          borderRadius: BorderRadius.circular(ResponsiveLayout.getRadius(5)),
        ),
        child: Text(
          amount,
          style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: ResponsiveLayout.getFontSize(16),
              color: Color(0xFF518C3A)),
        ),
      ),
    );
  }

  // Helper method to generate exactly 5 unique quick amounts
  List<double> _generateQuickAmounts(double balanceAmount) {
    Set<double> amounts = {};

    // 1. Exact balance amount
    amounts.add(balanceAmount);

    // 2. Round up to next whole number
    amounts.add(balanceAmount.ceilToDouble());

    // 3. Round up to next 5
    double nextFive = ((balanceAmount / 5).ceil() * 5).toDouble();
    amounts.add(nextFive);

    // 4. Round up to next 10
    double nextTen = ((balanceAmount / 10).ceil() * 10).toDouble();
    amounts.add(nextTen);

    // Keep adding logical amounts until we have at least 5
    List<double> additionalAmounts = [];

    if (balanceAmount < 20) {
      additionalAmounts = [20.0, 25.0, 50.0, 100.0];
    } else if (balanceAmount < 50) {
      additionalAmounts = [50.0, 75.0, 100.0, 150.0];
    } else if (balanceAmount < 100) {
      additionalAmounts = [100.0, 150.0, 200.0, 250.0];
    } else if (balanceAmount < 500) {
      additionalAmounts = [
        ((balanceAmount / 50).ceil() * 50).toDouble(),
        ((balanceAmount / 100).ceil() * 100).toDouble(),
        ((balanceAmount / 100).ceil() * 100 + 100).toDouble(),
        ((balanceAmount / 100).ceil() * 100 + 200).toDouble(),
      ];
    } else {
      additionalAmounts = [
        ((balanceAmount / 100).ceil() * 100).toDouble(),
        ((balanceAmount / 500).ceil() * 500).toDouble(),
        ((balanceAmount / 1000).ceil() * 1000).toDouble(),
        ((balanceAmount / 1000).ceil() * 1000 + 500).toDouble(),
      ];
    }

    // Add additional amounts to ensure we have enough
    for (double amount in additionalAmounts) {
      amounts.add(amount);
      if (amounts.length >= 7) break; // Get more than 5 to have options
    }

    // Convert to sorted list and take exactly 5 unique values
    List<double> sortedAmounts = amounts.toList()..sort();

    // Ensure we always return exactly 5 amounts
    if (sortedAmounts.length >= 5) {
      return sortedAmounts.take(5).toList();
    } else {
      // If somehow we don't have 5, pad with increments
      while (sortedAmounts.length < 5) {
        double lastAmount = sortedAmounts.last;
        double increment = lastAmount < 100 ? 25 : 100;
        sortedAmounts.add(lastAmount + increment);
      }
      return sortedAmounts.take(5).toList();
    }
  }

  Widget _buildPaymentModeButton(
      String label,
      Widget iconWidget, {
        required LinearGradient gradient,
        required Color borderColor,
        Color? iconColor, // optional
        VoidCallback? onTap,
        bool isLoading = false,
        bool isDisabled = false,
      }) {
    double _scale = 1.0;
    final bool isEnabled = !isDisabled && !isLoading && onTap != null;

    return StatefulBuilder(
      builder: (context, setState) {
        return GestureDetector(
          onTapDown: isEnabled
              ? (_) {
            setState(() {
              _scale = 0.95; // press effect
            });
          }
              : null,
          onTapUp: isEnabled
              ? (_) {
            setState(() {
              _scale = 1.0;
            });
            if (onTap != null) onTap();
          }
              : null,
          onTapCancel: isEnabled
              ? () {
            setState(() {
              _scale = 1.0;
            });
          }
              : null,
          child: AnimatedScale(
            scale: _scale,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeInOut,
            child: Opacity(
              opacity: isEnabled ? 1.0 : 0.5,
              child: Container(
                width: ResponsiveLayout.getWidth(240),
                height: ResponsiveLayout.getHeight(54),
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius:
                  BorderRadius.circular(ResponsiveLayout.getRadius(8)),
                  border: Border.all(color: borderColor),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x3F000000),
                      blurRadius: 4,
                      offset: Offset(2, 4),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius:
                    BorderRadius.circular(ResponsiveLayout.getRadius(8)),
                    onTap: isEnabled ? onTap : null,
                    splashColor: Colors.white24,
                    highlightColor: Colors.transparent,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Icon inside circle or loading indicator
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                          child: isLoading
                              ? SizedBox(
                            width: ResponsiveLayout.getIconSize(24),
                            height: ResponsiveLayout.getIconSize(24),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  borderColor),
                            ),
                          )
                              : iconWidget,
                        ),
                        SizedBox(width: ResponsiveLayout.getWidth(12)),
                        Text(
                          label,
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.bold,
                            fontSize: ResponsiveLayout.getFontSize(18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPaymentOptionButton(
      String title,
      String iconPath, {
        required bool isActive,
        required VoidCallback onTap,
      }) {
    return InkWell(
      onTap: isActive ? onTap : null,
      child: Container(
        height: 50,
        width: 368,
        padding: const EdgeInsets.symmetric(horizontal: 24), // ✅ SAME PADDING
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? const Color(0xFF817ACC) : Colors.grey,
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x3F000000),
              blurRadius: 4,
              offset: Offset(2, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // 🔹 LEFT: TEXT
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: isActive ? const Color(0xFF817ACC) : Colors.grey,
                ),
              ),
            ),

            // 🔹 RIGHT: ICON (ALIGNED)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? const Color(0xFF817ACC) : Colors.grey,
                ),
                child: Image.asset(
                  iconPath,
                  width: 18,
                  height: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build #1.0.175: Modified _handleVoidPayment for partial void with API call

  Future<void> _handleVoidPayment(BuildContext context,
      {required bool isPartial}) async {
    // ────────────────────────────────────────────────
    //  0. Early validation
    // ────────────────────────────────────────────────
    if (_lastPayment == null || _lastPayment!.amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No valid payment to void")),
      );
      Navigator.of(context).pop(); // close confirmation dialog
      return;
    }

    final voidedAmount = _lastPayment!.amount;
    final method = _lastPayment!.method;

    print(
        "VOID INITIATED → reversing \$${voidedAmount.toStringAsFixed(2)} ($method) | isPartial: $isPartial");

    final now = DateTime.now();
    final String voidDateTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    // ────────────────────────────────────────────────
    //  1. Create NEGATIVE payment record
    // ────────────────────────────────────────────────
    final negativePayment = LocalPayment(
      orderId: orderId ?? 0,
      title: "Void ($method)",
      amount: -voidedAmount,
      // IMPORTANT: use the original payment method so per-method totals (Pay by Cash)
      // correctly subtract the negative void amount.
      paymentMethod: method,
      shiftId: shiftId,
      vendorId: vendorId,
      userId: userId ?? 0,
      serviceType: serviceType,
      datetime: voidDateTime,
      notes:
      "Local void of ${method} payment – original ID: ${_lastPayment?.paymentId ?? 'local'}",
      isSynced: false,
      createdAt: now,
      remainingBalance:
      (balanceAmount + voidedAmount).clamp(0.0, double.infinity),
      status: PaymentDbStatus.voided,
      serverPaymentId: int.tryParse(_lastPayment?.paymentId ?? "0"),
    );

    try {
      // ────────────────────────────────────────────────
      //  2. Save void payment (Isar + Hive mirroring)
      // ────────────────────────────────────────────────
      final savedVoid =
      await LocalPaymentDBHelper.instance.savePayment(negativePayment);
      print(
          "Void saved in Isar → ID: ${savedVoid.id} | amount: -${voidedAmount.toStringAsFixed(2)}");

      await _savePaymentToHive(
        amount: -voidedAmount,
        paymentMethod: method,
        transactionId: "void_${savedVoid.id}",
        localPayment: savedVoid,
      );

      await _saveLocalPaymentToHive(savedVoid);

      // ────────────────────────────────────────────────
      //  3. Refresh balances from full payment history
      //     (this should now include the -amount entry)
      // ────────────────────────────────────────────────
      await _calculateBalanceFromPaymentHistory();
      await _printPaymentHistorySummary();

      // ────────────────────────────────────────────────
      //  4. CRITICAL: Force-reset "payment completed" flags
      //     Especially important when isPartial == false (full void)
      // ────────────────────────────────────────────────
      setState(() {
        // Always clear last payment reference
        _lastPayment = null;
        _lastPaymentDetails = null;

        // If this was a FULL payment void → make sure we allow new full payment
        if (!isPartial) {
          // Most important resets for full void
          _currentPaymentRemainingBalance =
          null; // no longer "in partial session"
          _successPopupShown = false; // allow success dialog again
          isPaymentStarted = false; // visually reset "payment in progress"
        }

        // Clear the input + payment-method highlight so we don't remain in "EBT zone"
        // when the user voids and continues paying.
        selectedPaymentMethod = TextConstants.cash;

        // Always update main UI flags based on new calculated balance
        isPaymentStarted = tenderAmount > 0;
      });

      // Reset keypad input (amount field) after void.
      // (Do it outside setState so it also updates controller text.)
      _resetAmountAfterPay();

      // ────────────────────────────────────────────────
      //  5. Optional: Show feedback (non-intrusive)
      // ────────────────────────────────────────────────
      String message = isPartial
          ? "Partial payment of \$${voidedAmount.toStringAsFixed(2)} voided"
          : "Full payment of \$${voidedAmount.toStringAsFixed(2)} voided. Ready for new payment.";

      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(
      //     content: Text(message),
      //     backgroundColor: Colors.orange[800],
      //     duration: const Duration(seconds: 4),
      //   ),
      // );
    } catch (e, stack) {
      print("VOID FAILED: $e");
      print(stack);

      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(
      //     content: Text("Failed to void payment: $e"),
      //     backgroundColor: Colors.red,
      //   ),
      // );
    }

    // Push void + updated balances to Woo while Hive still holds wooOrderId
    if (mounted) {
      Future.microtask(() async {
        try {
          await _syncCurrentOfflineOrder();
        } catch (e) {
          print("❌ Post-void sync failed: $e");
        }
      });
    }

    // Always close the confirmation dialog at the end
    // if (Navigator.canPop(context)) {
    //   Navigator.of(context).pop();
    // }
  }

  // Build #1.0.175: New method for void order API call
  void _handleVoidOrder(BuildContext context) {
    if (orderId == null || orderId == 0) {
      if (kDebugMode) {
        print(
            "_handleVoidOrder -> Invalid order ID: $orderId. Cannot void order.");
      }
      Navigator.of(context).pop(); // Close the dialog
      return;
    }

    // DEBUG: Log the void order attempt
    if (kDebugMode) {
      print("_handleVoidOrder -> Attempting to void order ID: $orderId");
    }

    paymentBloc.voidOrder(orderId!);
    StreamSubscription? subscription;
    subscription = paymentBloc.voidOrderStream.listen((response) {
      if (!mounted) {
        if (kDebugMode) {
          print("_handleVoidOrder -> Widget not mounted, skipping UI updates");
        }
        subscription?.cancel();
        return;
      }

      if (response.status == Status.COMPLETED) {
        if (kDebugMode) {
          print(
              "_handleVoidOrder -> Void order successful: ${response.data!.message}");
        }

        // Reset UI values after voiding order
        setState(() {
          payByCash = 0.0;
          payByOther = 0.0;
          tenderAmount = 0.0;
          changeAmount = 0.0;
          balanceAmount = orderTotal; // Reset to original order total
          if (kDebugMode) {
            print(
                "_handleVoidOrder -> Balance reset to original order total: $balanceAmount");
          }
        });

        if (Misc.showDebugSnackBar) {
          // Build #1.0.254
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                response.data!.message ?? TextConstants.voidSuccess,
                style: const TextStyle(color: Colors.white),
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }

        // Build #1.0.175
        Navigator.of(context).pop(); // Close void confirmation dialog
        Navigator.of(context).pop(); // Close payment dialog
        // Navigator.of(context).pop(TextConstants.refresh); // Navigate back to previous screen
        if (kDebugMode) {
          print("_handleVoidOrder -> 2: ${response.data!.message}");
        }

        ///This is for voiding completed payment
        OrderHelper.isOrderPanelLoaded = false;

        ///Update! on 9-Sep-25: asked by Shravan, void button click will result in cancelling of payment only, no need to change order status to cancelled now. If balance amount is changed then order will be pending else it will be processing
        // Navigator.pushReplacement(result: TextConstants.refresh,
        //   context,
        //   MaterialPageRoute(builder: (_) => POSHomeScreen()),
        // );
      } else if (response.status == Status.ERROR) {
        if (kDebugMode) {
          print(
              "_handleVoidOrder -> Void order failed: ${response.data!.message}");
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              response.data!.message ?? '',
              style: const TextStyle(color: Colors.red),
            ),
            backgroundColor: Colors.white,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pop(); // Close the dialog
      }
      subscription?.cancel();
    });
  }

  // --------------------

  Future<void> _showPartialPaymentDialog(BuildContext context, double amount,
      {bool isVoidDisabled = false}) async {
    if (_isShowingPartialDialog) {
      print("Partial dialog already showing → skipping duplicate call");
      return;
    }
    _isShowingPartialDialog = true;

    final double remainingToShow =
        _currentPaymentRemainingBalance ?? balanceAmount;
    print(
        "Showing Partial Payment Dialog → amount: $amount | remaining: $remainingToShow");

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => PaymentDialog(
        status: PaymentStatus.partial,
        mode: _currentDialogPaymentMode(),
        amount: amount,
        remainingBalance: remainingToShow,
        isVoidDisabled: isVoidDisabled,
        onVoid: () async {
          print("Void tapped from partial dialog");
          // 1. Close the partial dialog cleanly first
          Navigator.of(dialogCtx).pop();

          // 2. Show void confirmation
          if (!_isShowingPartialDialog) {
            showVoidExitConfirmation(context, false); // false = not partial
          }
          await _showVoidConfirmation(context, isPartial: true);
        },
        onNextPayment: () async {
          // try {
          //   await CustomerDisplayService.showThankYou();
          // } catch (e) {
          //   print(">>> Error showing Thank You screen: $e");
          // }

          print("Next Payment tapped → closing partial dialog cleanly");

          Navigator.of(dialogCtx).pop();

          if (mounted) {
            setState(() {
              selectedPaymentMethod = TextConstants.cash;
            });
            _resetAmountAfterPay();
          }
        },
      ),
    );

    // Reset guard after dialog is fully closed
    _isShowingPartialDialog = false;
    print("Partial dialog closed → guard reset");
  }

  Future<void> _showVoidConfirmation(BuildContext context,
      {required bool isPartial}) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => PaymentDialog.voidConfirmation(
        onVoidCancel: () async {
          print("❌ VOID CANCELED ByyyY USER");

          // ⚠️ This will mark all pending payments as completed – use with extreme caution
          if (orderId != null && orderId! > 0) {
            int retries = 3;
            while (retries > 0) {
              final payments = await LocalPaymentDBHelper.instance
                  .getPaymentsByOrderId(orderId!);
              final pendingPayments = payments
                  .where((p) =>
              p.amount > 0 && p.status == PaymentDbStatus.pending)
                  .toList();
              if (pendingPayments.isNotEmpty) {
                for (final p in pendingPayments) {
                  await LocalPaymentDBHelper.instance.updateStatus(
                    p.id,
                    PaymentDbStatus.pending,
                  );
                }
                print(
                    "✅ Marked ${pendingPayments.length} payments as completed");
                break;
              } else {
                retries--;
                if (retries > 0) {
                  print(
                      " No pending payments found, retrying... ($retries left)");
                  await Future.delayed(const Duration(milliseconds: 200));
                }
              }
            }
          }

          Navigator.of(dialogCtx, rootNavigator: false).pop();
          _isVoiding = false;
        },
        onVoidConfirm: () async {
          // try {
          //   await CustomerDisplayService.showThankYou();
          // } catch (e) {
          //   print(">>> Error showing Thank You screen: $e");
          // }
          Navigator.of(dialogCtx).pop();

          if (_lastPayment == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("No payment to void")),
            );
            return;
          }

          final method = _lastPayment!.method.toLowerCase();

          if (method == TextConstants.card.toLowerCase() &&
              _lastPayment!.sunmiTxnId != null &&
              _lastPayment!.sunmiOrderId != null) {
            await _openSunmiVoidScreen(
              amount: _lastPayment!.amount,
              orderId: _lastPayment!.sunmiOrderId!,
              originTransactionId: _lastPayment!.sunmiTxnId!,
            );
          } else {
            await _handleVoidPayment(context, isPartial: isPartial);
          }

          // 🔁 STAY ON SCREEN (no Navigator.pop)
          print("Void completed – staying on OrderSummaryScreen");

          if (mounted) {
            setState(() {});
          }
        },
      ),
    );
  }

  ////////

  // void _showPaymentDialog(
  //     BuildContext context,
  //     double amount, {
  //       double? changeAmount,
  //       required bool showChange,
  //       Map<String, dynamic>? couponResponse,
  //     }) async {
  //   if (kDebugMode) {
  //     print(
  //         "Showing Payment Dialog: amount=$amount, showChange=$showChange, changeAmount=$changeAmount");
  //   }
  //
  //   final storeInfo = PinakaPreferences.getLoggedInStore();
  //
  //   Future<void> _updateCustomerDisplayWelcome(
  //       Map<String, String?> storeInfo) async {
  //     if (storeInfo.isNotEmpty) {
  //       if (kDebugMode) {
  //         print(">>> Updating Customer Display with store info:");
  //         print("Store ID: ${storeInfo['storeId']}");
  //         print("Store Name: ${storeInfo['storeName']}");
  //         print("Store Logo URL: ${storeInfo['storeLogoUrl']}");
  //         print("Store Base URL: ${storeInfo['storeBaseUrl']}");
  //       }
  //
  //       await CustomerDisplayHelper.updateWelcomeWithStore(
  //         storeInfo['storeId'] ?? '0',
  //         storeInfo['storeName'] ?? 'Store',
  //         storeLogoUrl: storeInfo['storeLogoUrl'] ?? '',
  //         storeBaseUrl: storeInfo['storeBaseUrl'] ?? '',
  //       );
  //     } else {
  //       if (kDebugMode) {
  //         print(">>> No store info found, showing default welcome screen");
  //       }
  //       await CustomerDisplayService.showWelcome();
  //     }
  //   }
  //
  //   try {
  //     if (kDebugMode) print(">>> Showing THANK YOU screen before receipt options");
  //     await CustomerDisplayService.showThankYou();
  //   } catch (e) {
  //     if (kDebugMode) print(">>> Error showing Thank You screen: $e");
  //   }
  //
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (dialogCtx) => PaymentDialog(
  //       status: PaymentStatus.successful,
  //       mode: PaymentMode.cash,
  //       amount: amount,
  //       changeAmount: showChange ? changeAmount : null,
  //       couponResponse: couponResponse,
  //
  //       // ────────────────────────────────────────────────
  //       // UPDATED: Void button now navigates back instantly after confirmation
  //       // ────────────────────────────────────────────────
  //       onVoid: () {
  //         print("Void tapped from FULL payment success dialog");
  //
  //         // Close the success dialog first (clean stack)
  //         Navigator.of(dialogCtx).pop();
  //
  //         // Show confirmation → and let it handle instant navigation on success/fail
  //         showVoidExitConfirmation(context, false); // false = not partial
  //       },
  //
  //       onNoReceipt: () async {
  //         if (kDebugMode) print(">>> NoReceipt pressed");
  //         await _updateCustomerDisplayWelcome(storeInfo);
  //         changeStatusToCompletedAndExit(false);
  //       },
  //
  //       onDone: (selectedOption, {String? email}) async {
  //         if (kDebugMode) {
  //           print("DEBUG 0011 : $selectedOption, $email, ${email?.isNotEmpty}");
  //         }
  //
  //         if (selectedOption == TextConstants.email &&
  //             email != null &&
  //             email.isNotEmpty) {
  //           if (orderId == null || orderId == 0) {
  //             ScaffoldMessenger.of(context).showSnackBar(
  //               SnackBar(
  //                 content: Text(TextConstants.canNotSendEmail),
  //                 backgroundColor: Colors.red,
  //                 duration: const Duration(seconds: 3),
  //               ),
  //             );
  //             return;
  //           }
  //
  //           paymentBloc.sendOrderDetails(orderId!, email);
  //           StreamSubscription? subscription;
  //           subscription = paymentBloc.sendOrderDetailsStream.listen((response) async {
  //             subscription?.cancel();
  //             if (kDebugMode) print(">>> Email sent, updating customer display");
  //             await _updateCustomerDisplayWelcome(storeInfo);
  //             changeStatusToCompletedAndExit(true, selectedOption: selectedOption);
  //           });
  //           return;
  //         }
  //
  //         if (selectedOption == TextConstants.print && !Misc.disablePrinter) {
  //           if (kDebugMode) print(">>> Printing receipt");
  //           await _preparePrintTicket();
  //           await _printTicket(manual: true);
  //         }
  //
  //         if (kDebugMode) print(">>> Returning to Welcome after Thank You");
  //         await _updateCustomerDisplayWelcome(storeInfo);
  //         changeStatusToCompletedAndExit(true, selectedOption: selectedOption);
  //       },
  //     ),
  //   );
  // }

  Future<void> _updatePaymentStatusInHive(
      int localOrderId, int paymentLocalId, String newStatus) async {
    try {
      final box = StorageProvider.offlineOrders;
      final String hiveKey =
      localOrderId.toString(); // key is the local order ID

      if (!(await box.containsKey(hiveKey))) return;

      final raw = await box.get(hiveKey);
      final order = Map<String, dynamic>.from(raw is Map ? raw : {});

      final List<dynamic> payments = order['payments'] ?? [];
      bool updated = false;

      for (int i = 0; i < payments.length; i++) {
        final p = payments[i] as Map<String, dynamic>;
        if (p['local_id'] == paymentLocalId) {
          p['status'] = newStatus;
          updated = true;
          break;
        }
      }

      if (updated) {
        order['payments'] = payments;
        await box.put(hiveKey, order);
        print("✅ Hive payment #$paymentLocalId status updated to '$newStatus'");
      }
    } catch (e) {
      print("❌ Error updating Hive payment status: $e");
    }
  }

  Future<void> _markHiveOrderCompleted(int localOrderId) async {
    try {
      final box = StorageProvider.offlineOrders;
      final String key = localOrderId.toString();

      if (!(await box.containsKey(key))) return;

      final raw = await box.get(key);
      final order = Map<String, dynamic>.from(raw is Map ? raw : {});

      order['order_status'] = 'processing';
      order['updated_at'] = DateTime.now().toIso8601String();

      await box.put(key, order);
      print("✅ Hive order #$localOrderId marked as processing");
    } catch (e) {
      print("❌ _markHiveOrderCompleted error: $e");
    }
  }

  Future<void> _syncCurrentOfflineOrder() async {
    final String orderKey = widget.orderId?.toString() ??
        widget.offlineOrderId?.toString() ??
        orderId?.toString() ?? "";

    if (orderKey.isEmpty) return;

    if (_isOrderSyncInProgress && _activeSyncOrderKey == orderKey) return;

    _isOrderSyncInProgress = true;
    _activeSyncOrderKey = orderKey;

    try {
      final box = StorageProvider.offlineOrders;
      final raw = await box.get(orderKey);
      if (raw is! Map<String, dynamic>) return;

      var order = Map<String, dynamic>.from(raw);

      // === CRITICAL: Handle coupon validation failures ===
      bool syncSuccess = false;
      int retryCount = 0;
      const maxRetries = 3;

      while (!syncSuccess && retryCount < maxRetries) {
        retryCount++;

        final result = await OrderRepository().syncSingleOfflineOrder(order);

        if (result != null && result is Map) {
          // Success
          syncSuccess = true;
          final woo = Map<String, dynamic>.from(result);
          final wooOrderId = woo['id'] ?? 0;
          final wooStatus = woo['status']?.toString().toLowerCase() ?? '';

          // Mark payments synced
          final localOrderId = int.tryParse(orderKey);
          if (localOrderId != null) {
            final payments = await LocalPaymentDBHelper.instance
                .getPaymentsByOrderId(localOrderId);
            for (final p in payments.where((p) => !p.isSynced)) {
              await LocalPaymentDBHelper.instance.markAsSynced(p.id, wooOrderId);
            }
          }

          // Clean up Hive
          if (wooStatus == 'completed') {
            await box.delete(orderKey);
            print("✅ Order $orderKey synced & deleted (completed)");
          } else {
            order['wooOrderId'] = wooOrderId;
            order['wooStatus'] = wooStatus;
            order['synced'] = true;
            order['sync_at'] = DateTime.now().toIso8601String();
            await box.put(orderKey, order);
          }

        } else if (retryCount < maxRetries) {
          // === HANDLE COUPON FAILURE GRACEFULLY ===
          print("⚠️ Sync attempt $retryCount failed. Checking for coupon issues...");

          // Remove problematic coupons from this attempt and retry
          if (order['coupon_response'] is Map) {
            final cr = Map<String, dynamic>.from(order['coupon_response']);
            final coupons = (cr['coupons'] as List?) ?? [];

            // Keep only "issued" coupons (generate_type: false), remove redeem ones that failed
            final keptCoupons = coupons.where((c) {
              if (c is Map) {
                final isRedeem = c['generate_type'] == true ||
                    (c['code']?.toString().contains("2026") ?? false);
                return !isRedeem;
              }
              return true;
            }).toList();

            cr['coupons'] = keptCoupons;
            order['coupon_response'] = cr;
            order['coupon_lines'] = []; // clear for next attempt
            order['coupon_applied'] = keptCoupons.isNotEmpty;

            print("🔄 Removed failing coupons. Retrying sync...");
            await box.put(orderKey, order); // save cleaned version
          }
        } else {
          print("❌ All retry attempts failed for order $orderKey");
          // Optional: mark as partially synced or show user notification
        }
      }

    } catch (e, stack) {
      print("❌ _syncCurrentOfflineOrder error: $e");
      print(stack);
    } finally {
      _isOrderSyncInProgress = false;
      _activeSyncOrderKey = null;
      _lastSyncedOrderKey = orderKey;
      _lastOrderSyncAt = DateTime.now();
    }
  }

  void _showPaymentDialog(
      BuildContext context,
      double amount, {
        double? changeAmount,
        required bool showChange,
        Map<String, dynamic>? couponResponse,
        bool isVoidDisabled = false,
      }) async {
    if (_isShowingPaymentDialog) {
      print("Payment dialog already showing → skipping duplicate call");
      return;
    }

    _isShowingPaymentDialog = true;

    final storeInfo = PinakaPreferences.getLoggedInStore();

    // ── Helper: update customer display ──────────────────────
    Future<void> updateCustomerDisplayWelcome() async {
      try {
        if (storeInfo.isNotEmpty) {
          await CustomerDisplayHelper.updateWelcomeWithStore(
            storeInfo['storeId'] ?? '0',
            storeInfo['storeName'] ?? 'Store',
            storeLogoUrl: storeInfo['storeLogoUrl'] ?? '',
            storeBaseUrl: storeInfo['storeBaseUrl'] ?? '',
          );
        } else {
          await CustomerDisplayService.showWelcome();
        }
      } catch (e) {
        print(">>> Error updating customer display: $e");
      }
    }

    // ── Check if this is a negative/payout order ─────────────
    final bool isNegativeOrder = computedNetPayable <= 0;

    // ── Helper: mark order completed in Hive ─────────────────
    Future<void> forceMarkHiveOrderCompleted() async {
      try {
        final box = StorageProvider.offlineOrders;
        final String key = (orderId ?? 0).toString();
        if (!(await box.containsKey(key))) return;

        final raw = await box.get(key);
        final order = Map<String, dynamic>.from(raw is Map ? raw : {});

        order['order_status'] = 'completed'; // force completed
        order['updated_at'] = DateTime.now().toIso8601String();

        await box.put(key, order);
        print("✅ Hive order #$orderId force-marked as completed");
      } catch (e) {
        print("❌ forceMarkHiveOrderCompleted error: $e");
      }
    }

    // ── Helper: background work (non-blocking) ───────────────
    void doBackgroundWork() {
      Future(() async {
        if (orderId != null && orderId! > 0) {
          final allPayments = await LocalPaymentDBHelper.instance
              .getPaymentsByOrderId(orderId!);

          final bool isNegativeOrder = computedNetPayable <= 0;

          for (final p in allPayments) {
            if (p.status == PaymentDbStatus.pending) {
              if (p.amount > 0 || isNegativeOrder) {
                await LocalPaymentDBHelper.instance
                    .updateStatus(p.id, PaymentDbStatus.completed);
                print(" Completed payment ID ${p.id} "
                    "amount:\$${p.amount} isNegativeOrder:$isNegativeOrder");
              }
            }
          }
        }

        // Sync to backend (your original unchanged _syncCurrentOfflineOrder)
        try {
          await _syncCurrentOfflineOrder();
          print("✅ doBackgroundWork: sync done");
        } catch (e) {
          print("❌ doBackgroundWork: sync failed: $e");
        }

        // Update customer display
        try {
          final storeInfo = PinakaPreferences.getLoggedInStore();
          if (storeInfo.isNotEmpty) {
            await CustomerDisplayHelper.updateWelcomeWithStore(
              storeInfo['storeId'] ?? '0',
              storeInfo['storeName'] ?? 'Store',
              storeLogoUrl: storeInfo['storeLogoUrl'] ?? '',
              storeBaseUrl: storeInfo['storeBaseUrl'] ?? '',
            );
          } else {
            await CustomerDisplayService.showWelcome();
          }
        } catch (e) {
          print(">>> customer display error: $e");
        }
      });
    }

    // try {
    //   await CustomerDisplayService.showThankYou();
    // } catch (e) {
    //   print(">>> Error showing Thank You screen: $e");
    // }

    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (dialogCtx) => PaymentDialog(
        status: PaymentStatus.successful,
        mode: _currentDialogPaymentMode(),
        amount: amount,
        changeAmount: showChange ? changeAmount : null,
        couponResponse: couponResponse,
        isVoidDisabled: isVoidDisabled,

        // ── VOID ─────────────────────────────────────────────
        onVoid: () async {


          Navigator.of(dialogCtx, rootNavigator: false).pop();

          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!_isShowingPartialDialog) {
              showVoidExitConfirmation(context, false);
            }
          });
        },
        // ── NO RECEIPT ───────────────────────────────────────
        onNoReceipt: () async {
          try {
            await CustomerDisplayService.showThankYou();
          } catch (e) {
            print(">>> Error showing Thank You screen: $e");
          }

          Navigator.of(dialogCtx, rootNavigator: false).pop();

          doBackgroundWork();

          OrderHelper.isOrderPanelLoaded = false;
          OrderHelper.notifyOrderPanelToRefresh();

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => POSHomeScreen()),
            result: TextConstants.refresh,
          );
        },

        // ── DONE (Print / Email / SMS) ────────────────────────
        onDone: (selectedOption, {String? email}) async {
          try {
            await CustomerDisplayService.showThankYou();
          } catch (e) {
            print(">>> Error showing Thank You screen: $e");
          }

          print("onDone → $selectedOption, email=$email");

          // ── EMAIL ────────────────────────────────────────────
          if (selectedOption == TextConstants.email &&
              email != null &&
              email.isNotEmpty) {

            Navigator.of(dialogCtx, rootNavigator: false).pop();

            if (orderId == null || orderId == 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(TextConstants.canNotSendEmail),
                  backgroundColor: Colors.red,
                  duration: const Duration(milliseconds: 1500),
                ),
              );
            } else {
              paymentBloc.sendOrderDetails(orderId!, email);

              StreamSubscription? subscription;
              subscription =
                  paymentBloc.sendOrderDetailsStream.listen((response) {
                    subscription?.cancel();
                    print(">>> Email sent");
                  });
            }

            doBackgroundWork();

            OrderHelper.isOrderPanelLoaded = false;
            OrderHelper.notifyOrderPanelToRefresh();

            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => POSHomeScreen()),
              result: TextConstants.refresh,
            );
            return;
          }

          // ── PRINT ─────────────────────────────────────────────
          Navigator.of(dialogCtx, rootNavigator: false).pop();

          if (selectedOption == TextConstants.print && !Misc.disablePrinter) {
            Future(() async {
              await _preparePrintTicket();
              await _printTicket(manual: true);
            });
          }

          doBackgroundWork();

          OrderHelper.isOrderPanelLoaded = false;
          OrderHelper.notifyOrderPanelToRefresh();

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => POSHomeScreen()),
            result: TextConstants.refresh,
          );
        },
      ),
    ).then((_) {
      _isShowingPaymentDialog = false;
      print("Payment dialog closed → guard reset");
    });
  }

// ============================================================
// ALSO REPLACE _showPartialPaymentDialog with immediate close on Next Payment
// ============================================================

  // Future<void> _showPartialPaymentDialog(BuildContext context, double amount) async {
  //   if (_isShowingPartialDialog) {
  //     print("Partial dialog already showing → skipping duplicate call");
  //     return;
  //   }
  //   _isShowingPartialDialog = true;
  //
  //   final double remainingToShow = _currentPaymentRemainingBalance ?? balanceAmount;
  //   print("Showing Partial Payment Dialog → amount: $amount | remaining: $remainingToShow");
  //
  //   await showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (dialogCtx) => PaymentDialog(
  //       status: PaymentStatus.partial,
  //       mode: PaymentMode.cash,
  //       amount: amount,
  //       remainingBalance: remainingToShow,
  //
  //       onVoid: () async {
  //         // ✅ Close immediately
  //         Navigator.of(dialogCtx, rootNavigator: false).pop();
  //         _isShowingPartialDialog = false;
  //
  //         await _showVoidConfirmation(context, isPartial: true);
  //       },
  //
  //       onNextPayment: () {
  //         // ✅ Close immediately — no async work needed
  //         Navigator.of(dialogCtx, rootNavigator: false).pop();
  //         print("Next Payment tapped → partial dialog closed");
  //       },
  //     ),
  //   );
  //
  //   _isShowingPartialDialog = false;
  //   print("Partial dialog closed → guard reset");
  // }

/////impo

  // void showVoidExitConfirmation(BuildContext context, bool isPartial) {
  //   print("showVoidExitConfirmation → isPartial: $isPartial");
  //
  //   if (_isVoiding) {
  //     print("Void already in progress → skipping");
  //     return;
  //   }
  //   _isVoiding = true;
  //
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     useRootNavigator: false,
  //     builder: (dialogCtx) => PaymentDialog.voidConfirmation(
  //
  //       onVoidCancel: () {
  //         // ✅ Close dialog IMMEDIATELY
  //         Navigator.of(dialogCtx, rootNavigator: false).pop();
  //         _isVoiding = false;
  //
  //         // Do background work (mark payments completed + sync) without blocking
  //         Future(() async {
  //           if (orderId != null && orderId! > 0) {
  //             int retries = 3;
  //             while (retries > 0) {
  //               final payments = await LocalPaymentDBHelper.instance
  //                   .getPaymentsByOrderId(orderId!);
  //               final pendingPayments = payments
  //                   .where((p) => p.amount > 0 && p.status == PaymentDbStatus.pending)
  //                   .toList();
  //               if (pendingPayments.isNotEmpty) {
  //                 for (final p in pendingPayments) {
  //                   await LocalPaymentDBHelper.instance.updateStatus(
  //                     p.id,
  //                     PaymentDbStatus.completed,
  //                   );
  //                 }
  //                 print("✅ Background: Marked ${pendingPayments.length} payments as completed");
  //
  //                 // Sync after marking complete
  //                 try {
  //                   await _syncCurrentOfflineOrder();
  //                 } catch (e) {
  //                   print("❌ Background sync failed: $e");
  //                 }
  //
  //                 if (mounted) {
  //                   OrderHelper.isOrderPanelLoaded = false;
  //                   OrderHelper.notifyOrderPanelToRefresh();
  //                   Navigator.pushReplacement(
  //                     context,
  //                     MaterialPageRoute(builder: (_) => POSHomeScreen()),
  //                     result: TextConstants.refresh,
  //                   );
  //                 }
  //                 return;
  //               }
  //               retries--;
  //               if (retries > 0) await Future.delayed(const Duration(milliseconds: 200));
  //             }
  //           }
  //         });
  //       },
  //
  //       onVoidConfirm: () async {
  //         // ✅ Close dialog IMMEDIATELY
  //         Navigator.of(dialogCtx, rootNavigator: false).pop();
  //         _isVoiding = false;
  //
  //         if (_lastPayment == null) {
  //           ScaffoldMessenger.of(context).showSnackBar(
  //             const SnackBar(content: Text("No payment to void")),
  //           );
  //           return;
  //         }
  //
  //         final method = _lastPayment!.method.toLowerCase();
  //
  //         if (method == TextConstants.card.toLowerCase() &&
  //             _lastPayment!.sunmiTxnId != null &&
  //             _lastPayment!.sunmiOrderId != null) {
  //           await _openSunmiVoidScreen(
  //             amount: _lastPayment!.amount,
  //             orderId: _lastPayment!.sunmiOrderId!,
  //             originTransactionId: _lastPayment!.sunmiTxnId!,
  //           );
  //         } else {
  //           await _handleVoidPayment(context, isPartial: isPartial);
  //         }
  //
  //         print("Void completed – staying on OrderSummaryScreen");
  //         if (mounted) setState(() {});
  //       },
  //     ),
  //   );
  // }

////

  void showVoidExitConfirmation(BuildContext context, bool isPartial) {
    print("showVoidExitConfirmation → isPartial: $isPartial");

    if (_isVoiding) {
      print("Void already in progress → skipping");
      return;
    }
    _isVoiding = true;

    // ✅ CAPTURE these BEFORE showing dialog (dialog context won't have them)
    final double capturedAmount = tenderAmount;
    final double capturedChange = changeAmount;
    final bool capturedShowChange = changeAmount > 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (dialogCtx) => PaymentDialog.voidConfirmation(
        onVoidCancel: () {
          // ✅ STEP 1: Close void confirmation dialog IMMEDIATELY
          Navigator.of(dialogCtx, rootNavigator: false).pop();
          _isVoiding = false;

          // ✅ STEP 2: Re-show the payment success dialog
          // Small delay to let void dialog fully close first
          Future.delayed(const Duration(milliseconds: 100), () async {
            if (!mounted) return;

            // Get coupon response from Hive
            final box = StorageProvider.offlineOrders;
            final key = (orderId ?? 0).toString();
            final raw = await box.get(key);
            final cr = raw is Map ? raw["coupon_response"] : null;
            final couponResponse =
            cr is Map ? Map<String, dynamic>.from(cr) : <String, dynamic>{};

            // ✅ Re-show payment success popup
            _showPaymentDialog(
              context,
              capturedAmount,
              changeAmount: capturedChange,
              showChange: capturedShowChange,
              couponResponse: couponResponse,
              isVoidDisabled: true, // Disable void button when returning
            );
          });

          // ✅ STEP 3: Background sync only (NO navigation)
          Future(() async {
            if (orderId != null && orderId! > 0) {
              int retries = 3;
              while (retries > 0) {
                final payments = await LocalPaymentDBHelper.instance
                    .getPaymentsByOrderId(orderId!);

                final bool isNegativeOrder = computedNetPayable <= 0;

                final pendingPayments = payments
                    .where((p) =>
                p.status == PaymentDbStatus.pending &&
                    (p.amount > 0 || isNegativeOrder))
                    .toList();

                if (pendingPayments.isNotEmpty) {
                  for (final p in pendingPayments) {
                    await LocalPaymentDBHelper.instance
                        .updateStatus(p.id, PaymentDbStatus.completed);
                  }
                  print(
                      "✅ Background: Marked ${pendingPayments.length} payments completed");
                  break;
                }
                retries--;
                if (retries > 0) {
                  await Future.delayed(const Duration(milliseconds: 200));
                }
              }
            }
            try {
              await _syncCurrentOfflineOrder();
              print("✅ Background: Sync done after void cancel");
            } catch (e) {
              print("❌ Background sync failed: $e");
            }
          });
        },
        onVoidConfirm: () async {
          //  Close dialog IMMEDIATELY
          Navigator.of(dialogCtx, rootNavigator: false).pop();
          _isVoiding = false;

          if (_lastPayment == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("No payment to void")),
            );
            return;
          }

          final method = _lastPayment!.method.toLowerCase();

          if (method == TextConstants.card.toLowerCase() &&
              _lastPayment!.sunmiTxnId != null &&
              _lastPayment!.sunmiOrderId != null) {
            await _openSunmiVoidScreen(
              amount: _lastPayment!.amount,
              orderId: _lastPayment!.sunmiOrderId!,
              originTransactionId: _lastPayment!.sunmiTxnId!,
            );
          } else {
            await _handleVoidPayment(context, isPartial: isPartial);
          }

          print("Void completed – staying on OrderSummaryScreen");
          if (mounted) setState(() {});
        },
      ),
    ).then((_) {
      if (mounted) _isVoiding = false;
    });
  }

  // void showVoidExitConfirmation(BuildContext context, bool isPartial) {
  //   print("showVoidExitConfirmation → isPartial: $isPartial, orderId: $orderId");
  //
  //   if (_isVoiding) {
  //     print("Void already in progress → skipping");
  //     return;
  //   }
  //   _isVoiding = true;
  //
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     useRootNavigator: false,
  //     builder: (dialogCtx) => PaymentDialog.voidConfirmation(
  //
  //       onVoidCancel: () async {
  //         print("❌ VOID CANCELED BY USEeeeR");
  //
  //         bool updatedAny = false;
  //
  //         // --- 1. Mark all pending payments as completed locally ---
  //         if (orderId != null && orderId! > 0) {
  //           int retries = 3;
  //           while (retries > 0) {
  //             final payments = await LocalPaymentDBHelper.instance
  //                 .getPaymentsByOrderId(orderId!);
  //             final pendingPayments = payments
  //                 .where((p) => p.amount > 0 && p.status == PaymentDbStatus.pending)
  //                 .toList();
  //
  //             if (pendingPayments.isNotEmpty) {
  //               for (final p in pendingPayments) {
  //                 await LocalPaymentDBHelper.instance.updateStatus(
  //                   p.id,
  //                   PaymentDbStatus.completed,
  //                 );
  //               }
  //               print("✅ Marked ${pendingPayments.length} payments as completed");
  //               updatedAny = true;
  //               break;
  //             } else {
  //               retries--;
  //               if (retries > 0) {
  //                 print("⏳ No pending payments found, retrying... ($retries left)");
  //                 await Future.delayed(const Duration(milliseconds: 200));
  //               }
  //             }
  //           }
  //
  //         }
  //
  //         // --- 2. Sync the updated order to the backend ---
  //         if (updatedAny && mounted) {
  //           try {
  //             await _syncCurrentOfflineOrder(); // This sends the order and completed payments to Woo
  //             print("✅ Order synced to backend after completing pending payments");
  //           } catch (e) {
  //             print("❌ Failed to sync order: $e");
  //             ScaffoldMessenger.of(context).showSnackBar(
  //               SnackBar(
  //                 content: Text("Order completed locally but sync failed: $e"),
  //                 backgroundColor: Colors.orange,
  //               ),
  //             );
  //           }
  //         }
  //
  //
  //         // --- 3. Close the confirmation dialog (after all async work) ---
  //         // Navigator.of(dialogCtx, rootNavigator: false).pop();
  //         _isVoiding = false;
  //
  //         // --- 4. Navigate to home screen only if payments were updated ---
  //         if (updatedAny && mounted) {
  //           OrderHelper.isOrderPanelLoaded = false;
  //           OrderHelper.notifyOrderPanelToRefresh();
  //           Navigator.pop(context);
  //
  //           Navigator.pushReplacement(
  //             context,
  //             MaterialPageRoute(builder: (_) => POSHomeScreen()),
  //             result: TextConstants.refresh,
  //           );
  //
  //           ScaffoldMessenger.of(context).showSnackBar(
  //             const SnackBar(
  //               content: Text("Payments completed and order finalized"),
  //               backgroundColor: Colors.green,
  //               duration: Duration(seconds: 2),
  //             ),
  //           );
  //         }
  //       },
  //
  //       onVoidConfirm: () async {
  //         // (unchanged – handles actual void)
  //         print("✅ VOID CONFIRMED");
  //         Navigator.of(dialogCtx, rootNavigator: false).pop();
  //
  //         if (_lastPayment == null) {
  //           ScaffoldMessenger.of(context).showSnackBar(
  //             const SnackBar(content: Text("No payment to void")),
  //           );
  //           _isVoiding = false;
  //           return;
  //         }
  //
  //         final method = _lastPayment!.method.toLowerCase();
  //
  //         if (method == TextConstants.card.toLowerCase() &&
  //             _lastPayment!.sunmiTxnId != null &&
  //             _lastPayment!.sunmiOrderId != null) {
  //           await _openSunmiVoidScreen(
  //             amount: _lastPayment!.amount,
  //             orderId: _lastPayment!.sunmiOrderId!,
  //             originTransactionId: _lastPayment!.sunmiTxnId!,
  //           );
  //         } else {
  //           await _handleVoidPayment(context, isPartial: isPartial);
  //         }
  //
  //         print("${isPartial ? 'Partial' : 'Full'} payment voided → staying on OrderSummaryScreen");
  //
  //         if (mounted) {
  //           setState(() {});
  //         }
  //
  //         _isVoiding = false;
  //       },
  //     ),
  //   );
  // }

  // ============================================================
// REPLACE your _showExitPaymentConfirmation method with this
// KEY FIX: Navigate IMMEDIATELY, sync in background
// ============================================================

  void _showExitPaymentConfirmation(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (dialogCtx) => PaymentDialog(
        status: PaymentStatus.exitConfirmation,

        onExitCancel: () {
          if (Navigator.of(dialogCtx).canPop()) {
            Navigator.of(dialogCtx).pop();
          }
        },

        onExitConfirm: () async {
          // Close popup
          if (Navigator.of(dialogCtx).canPop()) {
            Navigator.of(dialogCtx).pop();
          }

          // Customer display
          try {
            await CustomerDisplayService.showThankYou();
          } catch (e) {
            print(">>> Error updating customer display: $e");
          }

          // Refresh order panel
          OrderHelper.isOrderPanelLoaded = false;
          OrderHelper.notifyOrderPanelToRefresh();

          // Navigate safely
          if (context.mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => POSHomeScreen(),
              ),
            );
          }

          // Background sync
          Future(() async {
            try {
              await _syncCurrentOfflineOrder();
              print("✅ Background: Exit sync completed");
            } catch (e) {
              print("❌ Background: Exit sync failed: $e");
            }
          });
        },
      ),
    );
  }

  Future<Map<String, dynamic>?> loadPrinterData() async {
    var printerDB = await PrinterDBHelper().getPrinterFromDB();
    if (printerDB.isEmpty) {
      if (kDebugMode) {
        print(">>>>> OrderSummaryScreen : printerDB is empty");
      }
      return null;
    }
    return printerDB.first;
  }

  Future _preparePrintTicket() async {
    if (kDebugMode) {
      print("OrderSummaryScreen _preparePrintTicket call print receipt");
    }

    var printerData = await loadPrinterData();
    var header = printerData?[AppDBConst.receiptHeaderText] ?? "";
    var footer = printerData?[AppDBConst.receiptFooterText] ?? "";
    var logo = printerData?[AppDBConst.receiptIconPath] ?? "";

    bytes = [];
    final ticket = await _printerSettings.getTicket();

    // -------------------------------
    // LOGO (unchanged)
    // -------------------------------
    final ByteData data;
    if (logo != "") {
      data = await GlobalUtility.fileToByteData(File(logo)) ??
          await rootBundle.load('assets/Bubbas_logo.png');
    } else {
      data = await rootBundle.load('assets/Bubbas_logo.png');
    }

    if (data.lengthInBytes > 0) {
      final Uint8List imageBytes = data.buffer.asUint8List();
      final decodedImage = img.decodeImage(imageBytes)!;
      img.Image thumbnail = img.copyResize(decodedImage, height: 280);
      img.Image originalImg =
      img.copyResize(decodedImage, width: 470, height: 280);
      img.fill(originalImg, color: img.ColorRgb8(255, 255, 255));
      var padding = (originalImg.width - thumbnail.width) / 2;
      drawImage(originalImg, thumbnail, dstX: padding.toInt());
      var grayscaleImage = img.grayscale(originalImg);
      // bytes += ticket.imageRaster(grayscaleImage, align: PosAlign.center);
    }

    // -------------------------------
    // HEADER & STORE INFO (unchanged)
    // -------------------------------
    var merchantDetails = await StoreDbHelper.instance.getStoreValidationData();
    var storeId = "${merchantDetails?[AppDBConst.storeId]}";
    var storePhone = "${merchantDetails?[AppDBConst.storePhone]}";

    var storeDetails = await AssetDBHelper.instance.getStoreDetails();
    var storeName = "${storeDetails?.name}";
    var address = "${storeDetails?.address},";
    var cityStateZip =
        "${storeDetails?.city},${storeDetails?.state}-${storeDetails?.zipCode}";
    var orderIdToPrint = '$orderId';

    final userData = await UserDbHelper().getUserData();
    var cashierName =
        "${userData?[AppDBConst.userDisplayName] ?? "Unknown Name"}";
    var cashierRole = "${userData?[AppDBConst.userRole] ?? "Unknown Role"}";

    if (header != "") {
      bytes += ticket.row([
        PosColumn(
            text: header, width: 12, styles: PosStyles(align: PosAlign.center)),
      ]);
    }

    bytes += ticket.row([
      PosColumn(
        text: "***** CUST-INVOICE *****",
        width: 12,
        styles: PosStyles(align: PosAlign.center, bold: true),
      ),
    ]);

    bytes += ticket.feed(1);

    bytes += ticket.row([
      PosColumn(
        text: storeName,
        width: 12,
        styles: PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    ]);

    bytes += ticket.feed(1);

    bytes += ticket.row([
      PosColumn(
          text: address, width: 12, styles: PosStyles(align: PosAlign.center))
    ]);
    bytes += ticket.row([
      PosColumn(
          text: cityStateZip,
          width: 12,
          styles: PosStyles(align: PosAlign.center))
    ]);
    bytes += ticket.row([
      PosColumn(
          text: "Phone: $storePhone",
          width: 12,
          styles: PosStyles(align: PosAlign.center)),
    ]);

    bytes += ticket.feed(1);
    bytes += ticket.row([
      PosColumn(
          text: "-----------------------------------------------", width: 12),
    ]);

    bytes += ticket.feed(1);

    bytes += ticket.row([
      PosColumn(text: "Date: $_displayDate", width: 7),
      PosColumn(text: "Time: $_displayTime", width: 5),
    ]);

    bytes += ticket.row([
      PosColumn(text: "Cashier: $cashierName", width: 7),
      PosColumn(text: "StoreID: $storeId", width: 5),
    ]);

    bytes += ticket.row([
      PosColumn(text: "Role: $cashierRole", width: 7),
      PosColumn(text: "OrderID: $orderIdToPrint", width: 5),
    ]);

    bytes += ticket.feed(1);
    bytes += ticket.row([
      PosColumn(
          text: "-----------------------------------------------", width: 12),
    ]);

    bytes += ticket.feed(1);

    // -------------------------------
    // ITEM HEADER
    // -------------------------------
    bytes += ticket.row([
      PosColumn(text: "#", width: 1, styles: PosStyles(bold: true)),
      PosColumn(text: "Description", width: 5, styles: PosStyles(bold: true)),
      PosColumn(
          text: "Qty",
          width: 1,
          styles: PosStyles(align: PosAlign.center, bold: true)),
      PosColumn(
          text: "Rate",
          width: 2,
          styles: PosStyles(align: PosAlign.right, bold: true)),
      PosColumn(
          text: "Amt",
          width: 3,
          styles: PosStyles(align: PosAlign.right, bold: true)),
    ]);

    bytes += ticket.feed(1);

    String formatCurrency(double amount) {
      if (amount < 0) {
        return "-${TextConstants.currencySymbol}${amount.abs().toStringAsFixed(2)}";
      } else {
        return "${TextConstants.currencySymbol}${amount.toStringAsFixed(2)}";
      }
    }

    // -------------------------------
    // ITEMS LOOP (with Combo Discount added)
    // -------------------------------
    for (int i = 0; i < orderItems.length; i++) {
      var item = orderItems[i];

      String itemName = item['item_name'] ?? '';
      double unitPrice = (item['item_price'] ?? 0).toDouble();
      int qty = (item['items_count'] ?? 0).toInt();
      double lineTotal = (item['item_sum_price'] ?? 0).toDouble();
      String type = item['item_type']?.toString().toLowerCase() ?? '';

      // Hide merchant discount/discount line-items from print item list
      final nameLower = itemName.toLowerCase();
      if (type.contains('discount') ||
          nameLower.contains('merchant discount')) {
        continue;
      }

      bool isPayout = type.contains(TextConstants.payoutText);
      bool isCoupon = type.contains(TextConstants.couponText);
      bool isCashback = type.contains("cashback");
      bool isPayoutOrCoupon = isPayout || isCoupon || isCashback;

      String formattedRate = formatCurrency(unitPrice);
      String formattedTotal = formatCurrency(lineTotal);

      bytes += ticket.row([
        PosColumn(text: "${i + 1}", width: 1),
        PosColumn(text: itemName, width: 5),
        PosColumn(
            text: "$qty", width: 1, styles: PosStyles(align: PosAlign.center)),
        PosColumn(
            text: formattedRate,
            width: 2,
            styles: PosStyles(align: PosAlign.right)),
        PosColumn(
            text: formattedTotal,
            width: 3,
            styles: PosStyles(align: PosAlign.right)),
      ]);

      // ────────────────────────────────────────────────
      // DISCOUNT EXTRACTION & PRINTING
      // ────────────────────────────────────────────────
      String discountType = item['discount_type']?.toString() ?? '';

      double autoDiscount = (discountType.isEmpty || discountType == 'auto')
          ? (item['auto_discount'] ?? 0).toDouble()
          : 0.0;

      double multipackDiscount = (discountType == 'multipack')
          ? (item['auto_discount'] ?? 0).toDouble()
          : 0.0;

      double comboDiscount =
      (discountType == 'combo' || discountType == 'mixmatch')
          ? (item['auto_discount'] ?? 0).toDouble()
          : 0.0;

      // Auto Discount
      if (autoDiscount > 0 && !isPayoutOrCoupon) {
        bytes += ticket.row([
          PosColumn(text: "Auto Discount", width: 9),
          PosColumn(
            text: "-${formatCurrency(autoDiscount).replaceAll('-', '')}",
            width: 3,
            styles: PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      // Combo / Mix & Match Discount
      if (comboDiscount > 0 && !isPayoutOrCoupon) {
        bytes += ticket.row([
          PosColumn(text: "Combo Discount", width: 9),
          PosColumn(
            text: "-${formatCurrency(comboDiscount).replaceAll('-', '')}",
            width: 3,
            styles: PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      // Multipack Discount
      if (multipackDiscount > 0 && !isPayoutOrCoupon) {
        bytes += ticket.row([
          PosColumn(text: "Multipack Discount", width: 9),
          PosColumn(
            text: "-${formatCurrency(multipackDiscount).replaceAll('-', '')}",
            width: 3,
            styles: PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      bytes += ticket.emptyLines(1);
    }

    // Prefer discount coming from GetOrderModel/API (json['discount']) for printing.
    // Falls back to passed-in discountValue (offline) and finally the screen's discount.
    final double discount = () {
      final raw = _order["discount"] ?? _order["order_discount"] ?? _order["discount_amount"];
      final parsed = raw == null ? null : double.tryParse(raw.toString());
      final fromGetOrder = parsed ?? (discountValue != 0 ? discountValue : null);
      if (fromGetOrder == null) return this.discount;
      return fromGetOrder != 0 ? -(fromGetOrder.abs()) : 0.0;
    }();

    // -------------------------------
    // TOTALS (unchanged from your version)
    // -------------------------------
    bytes += ticket.feed(1);
    bytes += ticket.row([
      PosColumn(
          text: "-----------------------------------------------", width: 12),
    ]);

    bytes += ticket.row([
      PosColumn(text: TextConstants.grossTotal, width: 8),
      PosColumn(
        text: formatCurrency(grossTotal),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    // Show Coupon (standardized negative display)
    bytes += ticket.row([
      PosColumn(text: TextConstants.discountText, width: 8),
      PosColumn(
        text: discount != 0 ? formatCurrency(discount) : formatCurrency(0.0),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(text: TextConstants.taxText, width: 8),
      PosColumn(
        text: formatCurrency(tax),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(text: TextConstants.merchantDiscount, width: 8),
      PosColumn(
        text: merchantDiscount != 0
            ? formatCurrency(merchantDiscount)
            : formatCurrency(0.0),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    if (cashbackFee > 0) {
      bytes += ticket.row([
        PosColumn(text: TextConstants.cashbackFee, width: 8),
        PosColumn(
          text: formatCurrency(cashbackFee),
          width: 4,
          styles: PosStyles(align: PosAlign.right),
        ),
      ]);
    }

    bytes += ticket.row([
      PosColumn(text: TextConstants.servicecharges, width: 8),
      PosColumn(
        text: formatCurrency(servicecharges),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(
          text: "-----------------------------------------------", width: 12),
    ]);

    bytes += ticket.feed(1);

    // Final Net Payable logic matching the summary screen precisely
    double printNetPayable = grossTotal +
        discount +
        merchantDiscount +
        tax +
        servicecharges +
        cashbackFee;
    if (printNetPayable < 0) printNetPayable = 0.0;

    bytes += ticket.row([
      PosColumn(text: TextConstants.netPayable, width: 8),
      PosColumn(
        text: formatCurrency(printNetPayable),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    if (redeemedValue > 0) {
      bytes += ticket.row([
        PosColumn(text: "Redeemed Amount", width: 8),
        PosColumn(
          text: "-${formatCurrency(redeemedValue).replaceAll('-', '')}",
          width: 4,
          styles: PosStyles(align: PosAlign.right),
        ),
      ]);
    }

    bytes += ticket.row([
      PosColumn(text: TextConstants.payByCash, width: 8),
      PosColumn(
        text: formatCurrency(payByCash),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(text: "Pay by EBT", width: 8),
      PosColumn(
        text: formatCurrency(payByEbt),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(text: TextConstants.payByOther, width: 8),
      PosColumn(
        text: formatCurrency(payByOther),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(text: TextConstants.tenderAmount, width: 8),
      PosColumn(
        text: formatCurrency(tenderAmount),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(text: TextConstants.change, width: 8),
      PosColumn(
        text: formatCurrency(changeAmount),
        width: 4,
        styles: PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += ticket.row([
      PosColumn(
          text: "-----------------------------------------------", width: 12),
    ]);

    if (footer != "") {
      bytes += ticket.feed(1);
      bytes += ticket.row([
        PosColumn(
            text: footer, width: 12, styles: PosStyles(align: PosAlign.center)),
      ]);
    }
  }

//////

  Future _printTicket({bool manual = false}) async {
    final ticket = await _printerSettings.getTicket();
    final result = await _printerSettings.printTicket(bytes, ticket);

    if (kDebugMode) {
      print(">>>> PrintTicket result $result");
    }

    switch (result) {
      case Ok<BluetoothPrinter>():
        break;
      case Error<BluetoothPrinter>():
        if (manual) return;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.error.getMessage,
                style: const TextStyle(color: Colors.red),
              ),
              backgroundColor: Colors.black,
              duration: const Duration(seconds: 3),
            ),
          );

          Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PrinterSetup(),
              )).then((result) {
            if (result == TextConstants.refresh) {
              _printerSettings.loadPrinter();
              setState(() {
                if (!Misc.disablePrinter) {
                  _printTicket(); // retry only when NOT manual
                }
              });
            } else {
              if (mounted) {
                _showReceiptDialog(context, paidAmount);
              }
            }
          });
        });
        break;
    }
  }

  Future _printCustomTest() async {
    if (kDebugMode) {
      print("OrderSummaryScreen _printCustomTest call print reciept");
    }
    List<int> bytes = [];

    final ticket = await _printerSettings.getTicket();
    bytes += ticket.row([
      PosColumn(text: "#", width: 1),
      PosColumn(text: "Description", width: 5),
      PosColumn(text: "Qty", width: 1),
      PosColumn(text: "Rate", width: 2),
      PosColumn(text: "Dis", width: 1),
      PosColumn(text: "Amt", width: 2),
    ]);
    bytes += ticket.feed(1);
    bytes += ticket.row([
      PosColumn(text: "1", width: 1),
      PosColumn(text: "Shan Haleem Masala Mix", width: 5),
      PosColumn(text: "1.0", width: 1),
      PosColumn(text: "420.0", width: 2),
      PosColumn(text: "0.0", width: 1),
      PosColumn(text: "420.0", width: 2),
    ]);
    bytes += ticket.row([
      PosColumn(
          text: "sfgasa sdfasdfasdf asdfasdfasdfsdfasdfasdf adfasdfasdfasdf",
          width: 12),
    ]);
    final result = await _printerSettings.printTicket(bytes, ticket);

    if (kDebugMode) {
      print(">>>> PrintTicket result $result");
    }
    switch (result) {
      case Ok<BluetoothPrinter>():
      // BluetoothPrinter printer = result.value;
        break;
      case Error<BluetoothPrinter>():
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Build #1.0.16
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.error.getMessage,
                style: const TextStyle(color: Colors.red),
              ),
              backgroundColor: Colors.black, // ✅ Black background
              duration: const Duration(seconds: 3),
            ),
          );

          /// call printer setup screen
          if (kDebugMode) {
            print("call printer setup screen");
          }
          Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PrinterSetup(),
              )).then((result) {
            if (result == TextConstants.refresh) {
              // Build #1.0.175: added TextConstants
              _printerSettings.loadPrinter();
              setState(() {
                // Update state to refresh the UI
                if (kDebugMode) {
                  print(
                      "SettingScreen - printer setup is done, connected printer is ${_printerSettings.selectedPrinter?.deviceName}");
                }
                if (!Misc.disablePrinter) {
                  _printTicket();
                }
              });
            }
          });
        });
        break;
    }
  }

  void _showReceiptDialog(BuildContext context, double amount) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PaymentDialog(
        status: PaymentStatus.receipt,
        mode: _currentDialogPaymentMode(),
        amount: amount,
        onPrint: () {
          if (kDebugMode) {
            print("Printing receipt for amount: $amount");
          }
        },
        onEmail: (email) {
          if (kDebugMode) {
            print("Email option selected with email: $email");
          }
        },
        onSMS: (phone) {},
        onNoReceipt: () async {
          // await CustomerService.publishPaymentSuccess(
          //   orderId ?? 0,
          //   orderItems,
          //   subtotal: grossTotal,
          //   tax: tax,
          //   total: computedNetPayable,
          // );
          print("Email option selected with data");

          await Future.delayed(const Duration(milliseconds: 300));
          if (orderId != null && orderId! > 0) {
            int retries = 3;
            while (retries > 0) {
              final payments = await LocalPaymentDBHelper.instance
                  .getPaymentsByOrderId(orderId!);
              final pendingPayments = payments
                  .where((p) =>
              p.amount > 0 && p.status == PaymentDbStatus.pending)
                  .toList();
              if (pendingPayments.isNotEmpty) {
                for (final p in pendingPayments) {
                  await LocalPaymentDBHelper.instance.updateStatus(
                    p.id,
                    PaymentDbStatus.completed,
                  );
                }
                print(
                    "✅ Marked ${pendingPayments.length} payments as completed");
                break;
              } else {
                retries--;
                if (retries > 0) {
                  print(
                      "⏳ No pending payments found, retrying... ($retries left)");
                  await Future.delayed(const Duration(milliseconds: 200));
                }
              }
            }
          }
          changeStatusToCompletedAndExit(false);
        },
        onDone: (selectedOption, {String? email}) async {
          // Build #1.0.159: Integrated Send Email Order Details API
          print("onDone → $selectedOption, email=$email");

          // ✅ KEY FIX: mark completed FIRST — same inline pattern as onNoReceipt
          await Future.delayed(const Duration(milliseconds: 300));
          if (orderId != null && orderId! > 0) {
            int retries = 3;
            while (retries > 0) {
              final payments = await LocalPaymentDBHelper.instance
                  .getPaymentsByOrderId(orderId!);
              final pendingPayments = payments
                  .where((p) =>
              p.amount > 0 && p.status == PaymentDbStatus.pending)
                  .toList();
              if (pendingPayments.isNotEmpty) {
                for (final p in pendingPayments) {
                  await LocalPaymentDBHelper.instance.updateStatus(
                    p.id,
                    PaymentDbStatus.completed,
                  );
                }
                print(
                    "✅ Marked ${pendingPayments.length} payments as completed");
                break;
              } else {
                retries--;
                if (retries > 0) {
                  print(
                      "⏳ No pending payments found, retrying... ($retries left)");
                  await Future.delayed(const Duration(milliseconds: 200));
                }
              }
            }
          }

          // ✅ NOW close dialog (triggers .then() → _syncCurrentOfflineOrder)
          // Isar already updated above so sync will see "completed"
          // Navigator.of(dialogCtx, rootNavigator: false).pop();
          if (kDebugMode) {
            print("DEBUG 0011 : $selectedOption, $email, ${email?.isNotEmpty}");
          }
          // Call API only if email option is selected and an email is provided
          if (selectedOption == TextConstants.email &&
              email != null &&
              email.isNotEmpty) {
            if (orderId == null || orderId == 0) {
              if (kDebugMode) {
                print("Invalid order ID: $orderId. Cannot send email.");
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(TextConstants.canNotSendEmail),
                  backgroundColor: Colors.red,
                  duration: const Duration(seconds: 3),
                ),
              );
              return;
            }

            if (kDebugMode) {
              print(
                  "Sending receipt to email: $email for order ID: $orderId on Done button click");
            }

            paymentBloc.sendOrderDetails(orderId!, email);
            StreamSubscription? subscription;
            subscription =
                paymentBloc.sendOrderDetailsStream.listen((response) {
                  if (response.status == Status.COMPLETED) {
                    if (kDebugMode) {
                      print("Email sent successfully: ${response.data!.message}");
                    }
                    if (Misc.showDebugSnackBar) {
                      // Build #1.0.254
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(response.data!.message),
                          backgroundColor: Colors.green,
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    }
                  } else if (response.status == Status.ERROR) {
                    if (kDebugMode) {
                      print("Failed to send email: ${response.message}");
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(TextConstants.failedSendEmail),
                        backgroundColor: Colors.red,
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  }
                  subscription?.cancel();
                  // Proceed to complete the order after email API response
                  changeStatusToCompletedAndExit(true,
                      selectedOption: selectedOption);
                });
          } else {
            // For non-email options, proceed directly to complete the order
            changeStatusToCompletedAndExit(true,
                selectedOption: selectedOption);
          }
        },
      ),
    );
  }

  ///Use this function to change status to complete the order after payment
  ///it is used called by no receipt and print receipt on order payment completed - print button tap
  void changeStatusToCompletedAndExit(bool isReceipt,
      {String selectedOption = TextConstants.print}) {
    /// Build #1.0.168: Fixed Issue - Change is showing as zero only
    /// No need here to reset changeAmount,balanceAmount or tenderAmount
    /// Every time comes to this screen we are already resetting initially in fetchOrderItems method

    if (kDebugMode) {
      print(
          "OrderSummaryScreen _showReceiptDialog Done call print receipt = $isReceipt");
    }

    if (kDebugMode) {
      print(
          "changeStatusToCompletedAndExit called with isReceipt=$isReceipt, selectedOption=$selectedOption");
    } else if (selectedOption == TextConstants.sms) {
      // SMS receipt
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(TextConstants.smsConfiguration),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
    }

    // If user navigates back to this screen later, make sure we don't keep
    // the keypad/EBT highlight from the previous payment flow.
    selectedPaymentMethod = TextConstants.cash;
    _rawAmount = 0;
    amountController.text = '${TextConstants.currencySymbol}0.00';
    _isAmountEntered = false;
    _amountErrorText = null;

    ///ToDO: Change the status of order to 'completed' here
    // Build #1.0.49: Added Call Order Status Update API code

    /// Build #1.0.175: No need change status to completed API call
    /// It was handling from backend
    Navigator.of(context).pop(); // Dismiss the receipt dialog
    // Navigator.of(context).pop(TextConstants.refresh); // Dismiss back to the previous screen with a refresh signal
    if (kDebugMode) {
      print("changeStatusToCompletedAndExit -> 3:");
    }

    ///Completed order
    OrderHelper.isOrderPanelLoaded = false;
    OrderHelper.notifyOrderPanelToRefresh();
    Navigator.pushReplacement(
      result: TextConstants.refresh,
      context,
      MaterialPageRoute(builder: (_) => POSHomeScreen()),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          TextConstants.orderCompleted,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.green, // Build #1.0.104: updated to green
        duration: const Duration(seconds: 1),
      ),
    );
  }

  // void showVoidExitConfirmation(BuildContext context, bool isPartial) {
  //   if (kDebugMode) {
  //     print(
  //       "showVoidExitConfirmation → isPartial: $isPartial, orderId: $orderId",
  //     );
  //   }
  //
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (dialogContext) => PaymentDialog.voidConfirmation(
  //       onVoidCancel: () {
  //         if (kDebugMode) {
  //           print("❌ VOID CANCELED BY USER");
  //         }
  //         Navigator.of(dialogContext).pop(); // Just close dialog
  //       },
  //
  //       onVoidConfirm: () async {
  //         // 1. Close confirmation dialog first
  //         Navigator.of(dialogContext).pop();
  //
  //         if (_lastPayment == null) {
  //           ScaffoldMessenger.of(context).showSnackBar(
  //             const SnackBar(content: Text("No payment to void")),
  //           );
  //           return;
  //         }
  //
  //         final method = _lastPayment!.method.toLowerCase();
  //
  //         // CARD → SUNMI VOID
  //         if (method == TextConstants.card.toLowerCase() &&
  //             _lastPayment!.sunmiTxnId != null &&
  //             _lastPayment!.sunmiOrderId != null) {
  //
  //           if (kDebugMode) {
  //             print("🔁 VOID CONFIRM → CARD → SUNMI HARDWARE VOID");
  //           }
  //
  //           await _openSunmiVoidScreen(
  //             amount: _lastPayment!.amount,
  //             orderId: _lastPayment!.sunmiOrderId!,
  //             originTransactionId: _lastPayment!.sunmiTxnId!,
  //           );
  //         }
  //         // Other methods → local void
  //         else {
  //           if (kDebugMode) {
  //             print("🔁 VOID CONFIRM → $method → LOCAL VOID");
  //           }
  //
  //           await _handleVoidPayment(context, isPartial: isPartial);
  //         }
  //
  //         // ────────────────────────────────────────────────
  //         // SAME NAVIGATION FOR BOTH PARTIAL AND FULL VOID
  //         // ────────────────────────────────────────────────
  //         if (kDebugMode) {
  //           print("${isPartial ? 'Partial' : 'Full'} payment voided → simple pop (back one screen)");
  //         }
  //
  //         // Just go back one screen (same behavior for both cases)
  //         Navigator.of(context).pop();
  //
  //         // Optional feedback (shows for both partial & full)
  //         // ScaffoldMessenger.of(context).showSnackBar(
  //         //   SnackBar(
  //         //     content: Text(
  //         //       "Void successful – ${isPartial ? 'partial' : 'full'} payment reversed",
  //         //     ),
  //         //     backgroundColor: Colors.orange[800],
  //         //   ),
  //         // );
  //       },
  //     ),
  //   );
  // }

  // void _showExitPaymentConfirmation(BuildContext context) {
  //   // No need for orderStatus check here anymore
  //
  //   if (kDebugMode) {
  //     print("_showExitPaymentConfirmation called → will show dialog because caller already checked balance");
  //     print("   payByCash: $payByCash | payByOther: $payByOther");
  //     print("   balanceAmount: $balanceAmount | orderTotal: $orderTotal");
  //     print("   orderStatus: $orderStatus | tenderAmount: $tenderAmount");
  //   }
  //
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (dialogContext) => PaymentDialog(
  //       status: PaymentStatus.exitConfirmation,
  //       onExitCancel: () {
  //         if (kDebugMode) {
  //           print("_showExitPaymentConfirmation → User canceled exit");
  //         }
  //         Navigator.of(dialogContext).pop();
  //       },
  //       onExitConfirm: () {
  //         if (kDebugMode) {
  //           print("_showExitPaymentConfirmation → User confirmed exit → navigating back");
  //         }
  //         Navigator.of(dialogContext).pop();
  //
  //         OrderHelper.isOrderPanelLoaded = false;
  //
  //         Navigator.pushReplacement(
  //           context,
  //           MaterialPageRoute(builder: (_) => POSHomeScreen()),
  //           result: TextConstants.refresh,
  //         );
  //
  //       },
  //     ),
  //   );
  // }

  Widget _buildPaymentAmountDisplay(
      String label,
      String amount, {
        required Color leftBarColor,
        Color? amountColor = Colors.black,
        bool isPaymentBalance = false, // NEW: Add this flag
      }) {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Container(
      width: MediaQuery.of(context).size.width * 0.240,
      height: ResponsiveLayout.getHeight(40),
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 🔴 LEFT INDICATOR BAR
          Container(
            width: 4,
            height: ResponsiveLayout.getHeight(45),
            decoration: BoxDecoration(
              color: leftBarColor,
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              boxShadow: [
                BoxShadow(
                  color: leftBarColor.withOpacity(0.45),
                  blurRadius: 8,
                  offset: const Offset(1, 2),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          // 📄 TEXT CONTENT
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: ResponsiveLayout.getFontSize(11),
                  fontWeight: FontWeight.w500,
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? Colors.white
                      : const Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                amount,
                style: TextStyle(
                  fontSize: ResponsiveLayout.getFontSize(12),
                  fontWeight: FontWeight.w700,
                  color: amountColor ??
                      (themeHelper.themeMode == ThemeMode.dark
                          ? Colors.white
                          : const Color(0xFF222222)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
