import 'dart:convert';

import 'package:dotted_line/dotted_line.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pinaka_pos/Screens/Home/total_orders_screen.dart';
import 'package:pinaka_pos/Widgets/widget_topbar.dart';
// Fix import path to match your project (e.g. widget_navigation_bar.dart):
import 'package:pinaka_pos/Widgets/widget_navigation_bar.dart';
import 'package:pinaka_pos/Widgets/widget_navigation_bar.dart' as custom;
import 'package:provider/provider.dart';

import '../../Constants/text.dart';
import '../../Database/db_helper.dart';
import '../../Database/order_panel_db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Models/Orders/refund_orderlist_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Orders/Full_order_RefundOrderRepository.dart';
import '../../Repositories/Orders/Refund_orderlist_repository.dart' show CompletedOrdersRepository;
import '../../Repositories/Orders/partial_order_reund_repository.dart';
import '../../Widgets/cash_refund.dart';
import '../../Widgets/verify_item_status.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
enum SidebarPosition { left, right, bottom }
enum OrderPanelPosition { left, right }
class RefundScreen extends StatefulWidget {
  final CompletedOrder order;

  const RefundScreen({
    super.key,
    required this.order,
  });

  @override
  State<RefundScreen> createState() => _RefundScreenState();
}

class _RefundScreenState extends State<RefundScreen> {

  String? selectedReason;
  String? selectedPayment; // instead of "Cash"
  int _selectedSidebarIndex = 5; // Refund index
  bool isExpanded = false;
  bool isConfirmEnabled = false;
// Add this at the top of your State class
  List<Map<String, dynamic>> selectedItems = [];
  late CompletedOrder selectedOrder;
  bool _showFullSummary = true;
  double? editedRefundAmount;
  String? _disabledPaymentType;
  bool _isProcessingPayment = false;
  bool _isRefundCompleted = false;
  // double merchantDiscount = 0;
  void _toggleSummary() {
    setState(() {
      _showFullSummary = !_showFullSummary;
    });
  }

  bool get isReasonEnabled =>
      selectedItems.isNotEmpty && selectedPayment != null;
  double get grossTotal => selectedOrder.amount;

  double get taxTotal => selectedOrder.tax;

  double get netTotal => grossTotal + taxTotal;

  double get merchantDiscount {
    double discount = 0;

    for (var item in selectedOrder.items) {
      if (item.name.toLowerCase().contains("discount")) {
        discount += item.total.abs(); // discount usually negative
      }
    }

    return discount;
  }

  double get totalNetPayable => selectedOrder.total;

// Refund calculation (only selected items)
  double get refundGross {
    double sum = 0;
    for (var item in selectedItems) {
      sum += (item['unit_price'] * item['qty']);
    }
    return sum;
  }

  double get refundTax {
    double sum = 0;
    for (var item in selectedItems) {
      sum += item['tax'];
    }
    return sum;
  }

  double get refundNetTotal => refundGross + refundTax;

  double get refundDiscount {
    if (grossTotal == 0) return 0;
    return (refundGross / grossTotal) * merchantDiscount;
  }
  double get totalRefund {
    if (selectedItems.isEmpty) return 0;

    final refundableItems = selectedOrder.items.where((item) {
      final name = item.name.toLowerCase().trim();

      return name != "discount" &&
          name != "payout" &&
          name != "cashback";
    }).toList();

    int totalItemCount = refundableItems.length;

    if (totalItemCount == 0) return 0;

    double discountPerItem = merchantDiscount / totalItemCount;

    double refund = 0;

    for (var item in selectedItems) {
      double itemAmount = item['amount'];
      refund += (itemAmount - discountPerItem);
    }

    return refund;
  }
  double get couponTotal {
    double total = 0;

    for (var coupon in selectedOrder.coupons) {
      total += coupon.discount;
    }

    return total;
  }
  @override
  void initState() {
    super.initState();
    selectedOrder = widget.order;
  }

  bool get _hasUnsavedRefundChanges {
    return selectedItems.isNotEmpty ||
        selectedPayment != null ||
        selectedReason != null ||
        editedRefundAmount != null ||
        isConfirmEnabled ||
        isReasonEnabled;
  }

  bool _lineItemSelectableForRefund(LineItem item) {
    final String itemName = item.name.toLowerCase();
    if (itemName.contains("discount")) return false;
    final normalized = itemName.trim();
    if (normalized == "payout" || normalized == "cashback") return false;
    return true;
  }

  int _selectableRefundCount(List<LineItem> visibleItems) {
    int count = 0;
    for (final item in visibleItems) {
      if (_lineItemSelectableForRefund(item)) count++;
    }
    return count;
  }

  int _selectedSelectableCount(List<LineItem> visibleItems) {
    int count = 0;
    for (final item in visibleItems) {
      if (!_lineItemSelectableForRefund(item)) continue;
      if (selectedItems.any((selected) => selected['order_item_id'] == item.id)) {
        count++;
      }
    }
    return count;
  }

  Future<bool> _confirmDiscardChangesIfNeeded() async {
    if (!_hasUnsavedRefundChanges) return true;

    final shouldDiscard = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Center(
          child: SizedBox(
            width: 480, // 👈 reduce popup width here (try 300–340)
            child: Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 🔺 Warning Icon
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red.withOpacity(0.1),
                      ),
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.red,
                        size: 50,
                      ),
                    ),

                    const SizedBox(height: 20),

                    const Text(
                      "Discard Changes?",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),

                    const SizedBox(height: 12),

                    const Text(
                      "You have unsaved changes. Are you sure you want to go back?",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, color: Colors.grey),
                    ),

                    const SizedBox(height: 24),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 130,
                          child: OutlinedButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.red, width: 2),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text(
                              "Cancel",
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 130,
                          child: ElevatedButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text("Confirm",style: TextStyle(color: Colors.white),),
                          ),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    return shouldDiscard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    final bool isFullRefund =
        selectedItems.length == selectedOrder.items.length &&
            selectedItems.isNotEmpty;

    final bool isPartialRefund =
        selectedItems.isNotEmpty &&
            selectedItems.length < selectedOrder.items.length;
    final visibleItems = selectedOrder.items
        .where((item) => !item.name.toLowerCase().contains("discount"))
        .toList();
    final int selectableRefundCount = _selectableRefundCount(visibleItems);
    final int selectedSelectableCount = _selectedSelectableCount(visibleItems);
    final bool headerAllSelected = selectableRefundCount > 0 &&
        selectedSelectableCount == selectableRefundCount;
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final layout = PinakaPreferences.layoutSelectionNotifier.value;

// Defaults
    SidebarPosition sidebarPosition = SidebarPosition.left;
    OrderPanelPosition orderPanelPosition = OrderPanelPosition.right;

// 🔥 SAME LOGIC AS OrdersScreen
    if (layout == SharedPreferenceTextConstants.navRightOrderLeft) {
      sidebarPosition = SidebarPosition.right;
      orderPanelPosition = OrderPanelPosition.left;
    } else if (layout == SharedPreferenceTextConstants.navBottomOrderLeft) {
      sidebarPosition = SidebarPosition.bottom;
      orderPanelPosition = OrderPanelPosition.left;
    } else if (layout == SharedPreferenceTextConstants.navBottomOrderRight) {
      sidebarPosition = SidebarPosition.bottom;
      orderPanelPosition = OrderPanelPosition.right;
    } else {
      sidebarPosition = SidebarPosition.left;
      orderPanelPosition = OrderPanelPosition.right;
    }

    return WillPopScope(
      onWillPop: _confirmDiscardChangesIfNeeded,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Padding(
          padding: const EdgeInsets.only(
            left: 0,
            right: 0,
            top: 0,
            bottom: 10,
          ),
          child: Column(
            children: [
              TopBar(
                  screen: Screen.ORDERS,
                  onModeChanged: () async {
                    String newLayout;

                    switch (layout) {
                      case SharedPreferenceTextConstants.navLeftOrderRight:
                        newLayout = SharedPreferenceTextConstants.navRightOrderLeft;
                        break;

                      case SharedPreferenceTextConstants.navRightOrderLeft:
                        newLayout = SharedPreferenceTextConstants.navBottomOrderLeft;
                        break;

                      case SharedPreferenceTextConstants.navBottomOrderLeft:
                        newLayout = SharedPreferenceTextConstants.navBottomOrderRight;
                        break;

                      case SharedPreferenceTextConstants.navBottomOrderRight:
                        newLayout = SharedPreferenceTextConstants.navLeftOrderRight;
                        break;

                      default:
                        newLayout = SharedPreferenceTextConstants.navLeftOrderRight;
                    }

                    PinakaPreferences.layoutSelectionNotifier.value = newLayout;

                    await UserDbHelper().saveUserSettings(
                      {AppDBConst.layoutSelection: newLayout},
                      modeChange: true,
                    );

                    setState(() {});
                  }
              ),
              // const SizedBox(height: 10),
              // const Divider(
              //   color: Colors.grey,
              //   thickness: 0.4,
              //   height: 4,
              // ),

              /// ================= MAIN SECTION: SIDEBAR + CONTENT =================
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    /// ================= LEFT SIDEBAR (NavigationBar) =================
                    if (sidebarPosition == SidebarPosition.left)
                      custom_widgets.NavigationBar(
                        selectedSidebarIndex: _selectedSidebarIndex,
                        isVertical: true,
                        onWillNavigate: (_) => _confirmDiscardChangesIfNeeded(),
                        onSidebarItemSelected: (index) {
                          setState(() => _selectedSidebarIndex = index);
                        },
                      ),
                    const SizedBox(width: 10),

                    /// ================= REFUND CONTENT (Products + Summary) =================
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // LEFT: Products list + Reason
                          Expanded(
                            flex: 3,
                            child: Column(
                              children: [
                                Expanded(
                                  child: Container(
                                    margin: const EdgeInsets.only(top: 10),
                                    padding: const EdgeInsets.all(16),
                                    decoration: _boxDecoration(),
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            GestureDetector(
                                              onTap: () async {
                                                final canLeave = await _confirmDiscardChangesIfNeeded();
                                                if (!mounted || !canLeave) return;
                                                Navigator.pop(context);
                                              },
                                              child: Icon(
                                                Icons.arrow_back,
                                                size: 20,
                                                color: isDark ? Colors.white : Colors.black,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            const Text(
                                              "Products List",
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 16),
                                        // Table header
                                        Container(
                                          height: 50,
                                          decoration: BoxDecoration(
                                            color: isDark
                                                ? const Color(0xFF293142)
                                                : const Color(0xFF989292),
                                            borderRadius: const BorderRadius.only(
                                              topLeft: Radius.circular(7),
                                              topRight: Radius.circular(7),
                                            ),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 20),
                                          child: Row(
                                            children:  [
                                              SizedBox(width: 0),

                                              GestureDetector(
                                                onTap: _isRefundCompleted
                                                    ? null
                                                    : () {
                                                  setState(() {
                                                    final bool allSelected = selectableRefundCount > 0 &&
                                                        selectedSelectableCount == selectableRefundCount;
                                                    if (allSelected) {
                                                      // Unselect all
                                                      selectedItems.clear();
                                                    } else {
                                                      selectedItems.clear();

                                                      for (var item in visibleItems) {
                                                        if (!_lineItemSelectableForRefund(item)) {
                                                          continue;
                                                        }

                                                        final double unitPrice = item.total / item.quantity;

                                                        selectedItems.add({
                                                          'order_item_id': item.id,
                                                          'name': item.name,
                                                          'unit_price': unitPrice,
                                                          'qty': item.quantity,
                                                          'tax': item.totalTax,
                                                          'amount': item.total + item.totalTax,
                                                        });
                                                      }
                                                    }
                                                    /// 🔥 ADD THIS
                                                    if (selectedItems.isEmpty) {
                                                      selectedPayment = null;
                                                      selectedReason = null; // 🔥 important
                                                    }
                                                  });
                                                },
                                                child: Container(
                                                  width: 17,
                                                  height: 17,
                                                  decoration: BoxDecoration(
                                                    color: headerAllSelected ? Colors.red : Colors.transparent,
                                                    borderRadius: BorderRadius.circular(4), // border radius added
                                                    border: Border.all(
                                                      color: const Color(0xFFFBFBFC),
                                                      width: 1,
                                                    ),
                                                  ),
                                                  child: headerAllSelected
                                                      ? const Icon(
                                                    Icons.check,
                                                    size: 16,
                                                    color: Colors.white,
                                                  )
                                                      : null,
                                                ),
                                              ),
                                              SizedBox(width: 14),
                                              // if (!item.name.toLowerCase().contains("discount"))
                                              Expanded(
                                                flex: 5,
                                                child: const Text(
                                                  "Item Name",
                                                  style: TextStyle(color: Colors.white),
                                                ),
                                              ),
                                              Expanded(
                                                  flex: 3,
                                                  child: Text("Unit Price",
                                                      style: TextStyle(
                                                          color: Colors.white))),
                                              Expanded(
                                                  flex: 3,
                                                  child: Text("Tax",
                                                      style: TextStyle(
                                                          color: Colors.white))),
                                              Expanded(
                                                  flex: 2,
                                                  child: Text("Quantity",
                                                      style: TextStyle(
                                                          color: Colors.white))),


                                              Expanded(
                                                  flex: 2,
                                                  child: Text("Amount",
                                                      textAlign: TextAlign.right,
                                                      style: TextStyle(
                                                          color: Colors.white))),
                                            ],
                                          ),
                                        ),

// BODY
                                        Expanded(
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius:
                                              const BorderRadius.only(
                                                bottomLeft: Radius.circular(7),
                                                bottomRight: Radius.circular(7),
                                              ),
                                              border: Border(
                                                left: BorderSide(
                                                  color: isDark ? const Color(0xFF4D4E63) : Colors.grey.shade200,
                                                ),
                                                right: BorderSide(
                                                  color: isDark ? const Color(0xFF4D4E63) : Colors.grey.shade200,
                                                ),
                                                bottom: BorderSide(
                                                  color: isDark ? const Color(0xFF4D4E63) : Colors.grey.shade200,
                                                ),
                                              ),
                                            ),
                                            child: ListView.builder(
                                              padding: EdgeInsets.zero,
                                              itemCount: visibleItems.length,
                                              itemBuilder: (context, index) {

                                                final item = visibleItems[index];

                                                final String itemName = item.name.toLowerCase();


                                                final bool isDiscount = itemName.contains("discount");
                                                final bool isPayoutOrCashback =
                                                    itemName.trim() == "payout" || itemName.trim() == "cashback";
                                                final double unitPrice = item.total / item.quantity;

                                                return Opacity(
                                                  opacity: isPayoutOrCashback ? 0.4 : 1,
                                                  child: IgnorePointer(
                                                    ignoring: isDiscount || isPayoutOrCashback || _isRefundCompleted,
                                                    child: InkWell(
                                                      onTap: () {
                                                        setState(() {
                                                          final existingIndex = selectedItems.indexWhere(
                                                                  (e) => e['order_item_id'] == item.id);

                                                          if (existingIndex != -1) {
                                                            // Remove if already selected
                                                            selectedItems.removeAt(existingIndex);
                                                          } else {
                                                            // Add if not selected
                                                            final double unitPrice = item.total / item.quantity;

                                                            selectedItems.add({
                                                              'order_item_id': item.id,
                                                              'name': item.name,
                                                              'unit_price': unitPrice,
                                                              'qty': item.quantity,
                                                              'tax': item.totalTax,
                                                              'amount': item.total + item.totalTax,
                                                            });
                                                          }
                                                          /// 🔥 ADD THIS
                                                          if (selectedItems.isEmpty) {
                                                            selectedPayment = null;
                                                            selectedReason = null; // 🔥 important
                                                          }
                                                        });
                                                      },
                                                      child: _refundRow(
                                                        isDark,
                                                        item.id,
                                                        item.name,
                                                        '${unitPrice < 0 ? '-' : ''}\$${unitPrice.abs().toStringAsFixed(2)} ×${item.quantity}',
                                                        '${item.totalTax < 0 ? '-' : ''}\$${item.totalTax.abs().toStringAsFixed(2)}',
                                                        item.quantity,
                                                        '${(item.total + item.totalTax) < 0 ? '-' : ''}\$${(item.total + item.totalTax).abs().toStringAsFixed(2)}',
                                                        hasDiscount: item.isItemsHasDiscount == "Yes",
                                                        discountType: item.itemDiscountType,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),

                                        // const SizedBox(height: 8),
                                        // const Expanded(
                                        //   child: SizedBox(),
                                        // ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Enter Reason
                                Container(
                                  height: 65,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: isReasonEnabled
                                        ? Theme.of(context).colorScheme.surface
                                        : Theme.of(context).colorScheme.surfaceContainerHighest, // ✅ disabled bg
                                    borderRadius: BorderRadius.circular(10),
                                    // border: Border.all(
                                    //   color: Theme.of(context).colorScheme.outline, // ✅ adaptive border
                                    // ),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        "Enter Reason :",
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: isReasonEnabled
                                              ? Theme.of(context).colorScheme.onSurface
                                              : Theme.of(context).colorScheme.onSurface.withOpacity(0.5), // ✅ disabled text
                                        ),
                                      ),
                                      const SizedBox(width: 16),

                                      SizedBox(
                                        width: MediaQuery.of(context).size.width * 0.40,
                                        child: DropdownButtonFormField<String>(
                                          value: selectedReason,
                                          hint: Text(
                                            "Select Reason",
                                            style: TextStyle(
                                              color: isDark
                                                  ? const Color(0xFF9CA3AF) // 🔥 dark hint (soft grey)
                                                  : const Color(0xFF6B7280), // 🔥 light hint
                                            ),
                                          ),
                                          style: TextStyle(
                                            color: isDark
                                                ? const Color(0xFFFFFFFF) // 🔥 white text
                                                : const Color(0xFF111827), // 🔥 near black
                                          ),
                                          dropdownColor: isDark
                                              ? const Color(0xFF1F2937) // 🔥 dark dropdown bg
                                              : const Color(0xFFFFFFFF), // 🔥 white dropdown
                                          iconEnabledColor: isDark
                                              ? const Color(0xFFFFFFFF)
                                              : const Color(0xFF111827),

                                          decoration: InputDecoration(
                                            isDense: true,
                                            contentPadding:
                                            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),

                                            filled: true,
                                            fillColor: isReasonEnabled
                                                ? (isDark
                                                ? const Color(0xFF1F2937) // 🔥 enabled dark
                                                : const Color(0xFFFFFFFF)) // 🔥 enabled light
                                                : (isDark
                                                ? const Color(0xFF2F3241) // 🔥 disabled dark
                                                : const Color(0xFFE5E7EB)), // 🔥 disabled light

                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(10),
                                            ),

                                            enabledBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(10),
                                              borderSide: BorderSide(
                                                color: isDark
                                                    ? const Color(0xFF374151) // 🔥 dark border
                                                    : const Color(0xFFD1D5DB), // 🔥 light border
                                                width: 1,
                                              ),
                                            ),

                                            focusedBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(10),
                                              borderSide: BorderSide(
                                                color: isDark
                                                    ? const Color(0xFF60A5FA) // 🔥 blue focus dark
                                                    : const Color(0xFF2563EB), // 🔥 blue focus light
                                                width: 1.5,
                                              ),
                                            ),
                                          ),

                                          items: [
                                            "Customer changed Opinion",
                                            "Product Expired"
                                          ]
                                              .map((e) => DropdownMenuItem(
                                            value: e,
                                            child: Text(e),
                                          ))
                                              .toList(),

                                          onChanged: isReasonEnabled
                                              ? (val) => setState(() => selectedReason = val)
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),


                          /// RIGHT: Refund Summary Panel
                          Expanded(
                            flex: 2,
                            child: Container(
                              margin: const EdgeInsets.only(top: 10, right: 10),
                              height: MediaQuery.of(context).size.height * 0.99,
                              padding: const EdgeInsets.all(8),
                              decoration: _boxDecoration(),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      // Left: Order ID
                                      RichText(
                                        text: TextSpan(
                                          children: [
                                            TextSpan(
                                              text: "Order ID: ",
                                              style: TextStyle(
                                                fontWeight: FontWeight.normal,
                                                fontSize: 14,
                                                color: isDark
                                                    ? const Color(0xFFB0B3B8)   // light grey for dark mode
                                                    : const Color(0xFF83868C), // Color for "Order ID:"
                                              ),
                                            ),
                                            TextSpan(
                                              text: "#${selectedOrder.orderId}",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                                color: isDark
                                                    ? Colors.white
                                                    : const Color(0xFF4C5F7D), // Color for the order number
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Right: Calendar + Date + Divider + Time
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.calendar_today,
                                            size: 16,
                                            color: isDark ? Colors.white : Colors.black,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            DateFormat('dd MMM yyyy')
                                                .format(selectedOrder.completedAt.toLocal()),
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: isDark ? Colors.white : Colors.black,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            width: 1,
                                            height: 14,
                                            color: isDark ? Colors.white : Colors.black,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            DateFormat('hh:mm a')
                                                .format(selectedOrder.completedAt.toLocal()),
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: isDark ? Colors.white : Colors.black,
                                            ),
                                          ),
                                        ],
                                      )
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  // Locate the Stack inside the Summary Panel (around line 348)
                                  Flexible(
                                    child: Container(
                                      width: double.infinity,
                                      clipBehavior: Clip.antiAlias,
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? const Color(0xFF252525)
                                            : const Color(0xFFF1F1F3),
                                        borderRadius: BorderRadius.circular(7),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x26000000),
                                            blurRadius: 15,
                                            offset: Offset(0, 2),
                                          )
                                        ],
                                      ),
                                      child: Column(
                                        children: [
                                          /// HEADER
                                          Container(
                                            height: 35,
                                            color: isDark
                                                ? const Color(0xFF293142)
                                                : const Color(0xFF989292),
                                            padding: const EdgeInsets.symmetric(horizontal: 10),
                                            child: Row(
                                              children: const [
                                                Expanded(
                                                  flex: 3,
                                                  child: Align(
                                                    alignment: Alignment.centerLeft,
                                                    child: Text(
                                                      "Item Name",
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 2,
                                                  child: Align(
                                                    alignment: Alignment.centerLeft,
                                                    child: Text(
                                                      "Price/Qty",
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 1,
                                                  child: Align(
                                                    alignment: Alignment.centerLeft,
                                                    child: Text(
                                                      "Tax",
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 1,
                                                  child: Align(
                                                    alignment: Alignment.centerRight,
                                                    child: Text(
                                                      "Amount",
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                          /// LIST (auto adjusts now)
                                          Expanded(
                                            child: selectedItems.isEmpty
                                                ? const Center(
                                              child: Text(
                                                "No Item Selected",
                                                style: TextStyle(
                                                  color: Color(0xFF9A9A9A),
                                                  fontSize: 12,
                                                ),
                                              ),
                                            )
                                                : ListView.builder(
                                              itemCount: selectedItems.length,
                                              itemBuilder: (context, index) {
                                                final item = selectedItems[index];

                                                return Container(
                                                  padding: const EdgeInsets.symmetric(
                                                      horizontal: 10, vertical: 8),
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(context).brightness == Brightness.dark
                                                        ? const Color(0xFF121212)
                                                        : const Color(0xFFFFFFFF),
                                                    border: Border(
                                                      bottom: BorderSide(color: Colors.grey.shade800),
                                                    ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        flex: 3,
                                                        child: Text(
                                                          item['name'],
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            color: isDark ? Colors.white : Colors.black,
                                                          ),
                                                        ),
                                                      ),
                                                      Expanded(
                                                        flex: 2,
                                                        child: Text(
                                                          '${item['unit_price'] < 0 ? '-' : ''}\$${item['unit_price'].abs().toStringAsFixed(2)} ×${item['qty']}',
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            color: isDark ? Colors.white : Colors.black,
                                                          ),
                                                        ),
                                                      ),
                                                      Expanded(
                                                        flex: 1,
                                                        child: Text(
                                                          '${item['tax'] < 0 ? '-' : ''}\$${item['tax'].abs().toStringAsFixed(2)}',
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            color: isDark ? Colors.white : Colors.black,
                                                          ),
                                                        ),
                                                      ),

                                                      Expanded(
                                                        flex: 1,
                                                        child: Text(
                                                          '${item['amount'] < 0 ? '-' : ''}\$${item['amount'].abs().toStringAsFixed(2)}',
                                                          textAlign: TextAlign.right,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            color: isDark ? Colors.white : Colors.black,
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
                                  ),
                                  const SizedBox(height: 10),

                                  Row(
                                    mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      const Text(
                                        "Select Payment Type",
                                        style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      Expanded(
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            '*Refund will be issued to the only original payment method.',
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              color: isDark
                                                  ? const Color(0xFF96DBF3) // 🔥 lighter blue for dark mode
                                                  : const Color(0xFF0753C5), // 🔥 your original light mode blue
                                              fontSize: 10,
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      _paymentButton("Cash"),
                                      const SizedBox(width: 10),
                                      _paymentButton("Card"),
                                      const SizedBox(width: 10),
                                      _paymentButton("Wallet"),
                                    ],
                                  ),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        margin: const EdgeInsets.only(top: 4, right: 6),
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? const Color(0xFFFFB74D) // 🔥 softer orange for dark
                                              : const Color(0xFFD97D00), // 🔥 original for light
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          'Refund amount is calculated after discount application',
                                          style: TextStyle(
                                            color: isDark
                                                ? const Color(0xFFD1AA76) // 🔥 readable in dark
                                                : const Color(0xFFD97D00),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 6),

                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        margin: const EdgeInsets.only(top: 4, right: 6),
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? const Color(0xFFEF5350) // 🔥 softer red for dark
                                              : const Color(0xFFBF3333),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          'For card payments, only the exact paid amount can be refunded. '
                                              'Partial or excess refunds are not allowed.',
                                          style: TextStyle(
                                            color: isDark
                                                ? const Color(0xFFCE8383)
                                                : const Color(0xFFBF3333),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            height: 1.4,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      // 🔥 Make whole header clickable
                                      GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            isExpanded = !isExpanded;
                                          });
                                        },
                                        child: Container(
                                          width: double.infinity,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).brightness == Brightness.dark
                                                ? const Color(0xFF5D7EB2) // dark bluish tone
                                                : const Color(0xFFE5EFFF),
                                            borderRadius: const BorderRadius.only(
                                              bottomLeft: Radius.circular(8),
                                              bottomRight: Radius.circular(8),
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Theme.of(context).brightness == Brightness.dark
                                                    ? Colors.black.withOpacity(0.6)
                                                    : const Color(0x26000000),
                                                blurRadius: 6,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            children: [
                                              const SizedBox(width: 15),
                                              Expanded(
                                                child: Text(
                                                  'Payment Summary',
                                                  style: TextStyle(
                                                    color: Theme.of(context).colorScheme.onSurface, // ✅ adaptive text
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.only(right: 10),
                                                child: Icon(
                                                  isExpanded
                                                      ? Icons.keyboard_arrow_up
                                                      : Icons.keyboard_arrow_down,
                                                  color: Theme.of(context).colorScheme.onSurface, // ✅ adaptive icon
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),


                                      // 🔥 Expand UPWARD
                                      if (isExpanded)

                                        Positioned(
                                          bottom: 40,
                                          left: 0,
                                          right: 0,
                                          child: AnimatedSize(
                                            duration: const Duration(milliseconds: 300),
                                            curve: Curves.easeInOut,
                                            alignment: Alignment.bottomCenter,
                                            child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                    horizontal: 15, vertical: 10),
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context).colorScheme.surface,
                                                  borderRadius: const BorderRadius.only(
                                                    topLeft: Radius.circular(8),
                                                    topRight: Radius.circular(8),
                                                  ),
                                                  boxShadow: const [
                                                    BoxShadow(
                                                      color: Color(0x26000000),
                                                      blurRadius: 10,
                                                      offset: Offset(0, -2),
                                                    )
                                                  ],
                                                ),
                                                child: Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [

                                                    /// ===== ORIGINAL ORDER =====
                                                    _buildRow("Gross Total", "\$${grossTotal.toStringAsFixed(2)}"),
                                                    // _buildRow("Tax", "\$${taxTotal.toStringAsFixed(2)}"),

                                                    if (couponTotal > 0)
                                                      _buildRow(
                                                        "Coupons",
                                                        "-\$${couponTotal.toStringAsFixed(2)}",
                                                        valueColor: Colors.green,
                                                      ),
                                                    _buildRow(
                                                      "Tax",
                                                      '${taxTotal < 0 ? '-' : ''}\$${taxTotal.abs().toStringAsFixed(2)}',
                                                    ),
                                                    ShaderMask(
                                                      shaderCallback: (Rect bounds) {
                                                        final isDark =
                                                            Theme.of(context).brightness == Brightness.dark;

                                                        return LinearGradient(
                                                          begin: Alignment.centerLeft,
                                                          end: Alignment.centerRight,
                                                          colors: isDark
                                                              ? [
                                                            Colors.white.withOpacity(0.1),
                                                            Colors.white.withOpacity(0.7),
                                                            Colors.white.withOpacity(0.1),
                                                          ]
                                                              : [
                                                            Colors.black.withOpacity(0.1),
                                                            Colors.black.withOpacity(0.7),
                                                            Colors.black.withOpacity(0.1),
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
                                                        dashColor:
                                                        Theme.of(context).brightness == Brightness.dark
                                                            ? Colors.white
                                                            : Colors.black,
                                                      ),
                                                    ),
                                                    _buildRow(
                                                      "Net Total",
                                                      '${netTotal < 0 ? '-' : ''}\$${netTotal.abs().toStringAsFixed(2)}',
                                                    ),
                                                    if (merchantDiscount > 0)
                                                      _buildRow(
                                                        "Merchant Discount",
                                                        "-\$${merchantDiscount.toStringAsFixed(2)}",
                                                        valueColor: Colors.blue,
                                                      ),

                                                    ShaderMask(
                                                      shaderCallback: (Rect bounds) {
                                                        final isDark =
                                                            Theme.of(context).brightness == Brightness.dark;

                                                        return LinearGradient(
                                                          begin: Alignment.centerLeft,
                                                          end: Alignment.centerRight,
                                                          colors: isDark
                                                              ? [
                                                            Colors.white.withOpacity(0.1),
                                                            Colors.white.withOpacity(0.7),
                                                            Colors.white.withOpacity(0.1),
                                                          ]
                                                              : [
                                                            Colors.black.withOpacity(0.1),
                                                            Colors.black.withOpacity(0.7),
                                                            Colors.black.withOpacity(0.1),
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
                                                        dashColor:
                                                        Theme.of(context).brightness == Brightness.dark
                                                            ? Colors.white
                                                            : Colors.black,
                                                      ),
                                                    ),

                                                    _buildRow(
                                                      "Total Net Payable",
                                                      "${totalNetPayable < 0 ? "-" : ""}\$${totalNetPayable.abs().toStringAsFixed(2)}",
                                                      isBold: true,
                                                    ),

                                                    // const SizedBox(height: 15),

                                                    /// ===== REFUND SECTION =====
                                                    if (isPartialRefund) ...[
                                                      const SizedBox(height: 8),


                                                      // Align(
                                                      //   alignment: Alignment.centerLeft,
                                                      //   child: const Text(
                                                      //     "Refund Summary",
                                                      //     style: TextStyle(
                                                      //       fontWeight: FontWeight.w600,
                                                      //       fontSize: 13,
                                                      //     ),
                                                      //   ),
                                                      // ),

                                                      const SizedBox(height: 8),

                                                      // _buildRow(
                                                      //     "Refund Gross Total", "₹${refundGross.toStringAsFixed(2)}"),
                                                      // _buildRow("Tax", "₹${refundTax.toStringAsFixed(2)}"),
                                                      //
                                                      // _buildDottedDivider(context),
                                                      //
                                                      // _buildRow(
                                                      //     "Net Total", "₹${refundNetTotal.toStringAsFixed(2)}"),
                                                      //
                                                      // _buildRow(
                                                      //   "Merchant Discount",
                                                      //   "- ₹${refundDiscount.toStringAsFixed(2)}",
                                                      //   valueColor: Colors.blue,
                                                      // ),

                                                      // _buildDottedDivider(context),

                                                      _buildRow(
                                                        "Refund Amount",
                                                        '${(editedRefundAmount ?? totalRefund) < 0 ? '-' : ''}\$${(editedRefundAmount ?? totalRefund).abs().toStringAsFixed(2)}',
                                                        isBold: true,
                                                      ),
                                                    ],
                                                  ],
                                                )
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),

                                  const SizedBox(height: 15),
                                  GestureDetector(
                                    onTap: () async {
                                      if (selectedItems.isEmpty) {
                                        // ⚠️ No items selected
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text("No items selected for refund"),
                                            backgroundColor: Colors.red,
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      } else if (selectedReason == null) {
                                        // ⚠️ Reason not selected
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text("Please select a reason before confirming refund"),
                                            backgroundColor: Colors.red,
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      } else {
                                        // ✅ Items & reason selected → show dialog
                                        // await showDialog(
                                        //   context: context,
                                        //   barrierDismissible: false,
                                        //   builder: (_) => VerifyItemStatusDialog(
                                        //     order: selectedOrder,
                                        //     selectedItems: selectedItems,
                                        //   ),
                                        // );
                                        try {

                                          final fullRepo = RefundOrderRepository(
                                            baseUrl: "https://merchantretail.alektasolutions.com",
                                          );

                                          final partialRepo = PartialRefundRepository(
                                            baseUrl: "https://merchantretail.alektasolutions.com",
                                          );

                                          final isFullRefund =
                                              selectedItems.length == selectedOrder.items.length;

                                          // Default values
                                          final itemsReusableValue = "yes";
                                          final reason = selectedReason ?? "refund";

                                          bool success = false;

                                          if (isFullRefund) {

                                            success = await fullRepo.fullOrderRefund(
                                              orderId: selectedOrder.orderId,
                                              amount: selectedOrder.total.toDouble(),
                                              reason: reason,
                                              itemsReusable: itemsReusableValue,
                                            );

                                          } else {

                                            final itemsToRefund =
                                            selectedItems.map((item) {

                                              final rawAmount =
                                                  item['amount']?.toString() ?? "0";

                                              final amount = double.tryParse(
                                                rawAmount.replaceAll(
                                                  RegExp(r'[^0-9.]'),
                                                  '',
                                                ),
                                              ) ?? 0.0;

                                              return {
                                                "order_item_id": item['order_item_id'],
                                                "qty": item['qty'],
                                                "refundable_amount": amount,
                                              };

                                            }).toList();

                                            success = await partialRepo.partialOrderRefund(
                                              orderId: selectedOrder.orderId,
                                              reason: reason,
                                              itemsReusable: itemsReusableValue,
                                              items: itemsToRefund,
                                            );
                                          }

                                          if (!mounted) return;

                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                success
                                                    ? "Refund Successful"
                                                    : "Refund Failed",
                                              ),
                                              backgroundColor:
                                              success ? Colors.green : Colors.red,
                                            ),
                                          );

                                          if (success) {

                                            Navigator.pushAndRemoveUntil(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                const TotalOrdersScreen(),
                                              ),
                                                  (route) => false,
                                            );

                                          }

                                        } catch (e) {

                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text("Error: $e"),
                                              backgroundColor: Colors.red,
                                            ),
                                          );

                                        }
                                      }
                                    },
                                    child: Container(
                                      width: double.infinity,
                                      height: 45,
                                      decoration: BoxDecoration(
                                        color: (selectedItems.isNotEmpty && selectedReason != null)
                                            ? Colors.red
                                            : Colors.grey.shade400,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Center(
                                        child: Text(
                                          "Confirm Refund",
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                ],
                              ),
                            ),
                          ),
                          if (sidebarPosition == SidebarPosition.right)
                            const SizedBox(width: 10),

                          if (sidebarPosition == SidebarPosition.right)
                            custom_widgets.NavigationBar(
                              selectedSidebarIndex: _selectedSidebarIndex,
                              isVertical: true,
                              onWillNavigate: (_) => _confirmDiscardChangesIfNeeded(),
                              onSidebarItemSelected: (index) {
                                setState(() => _selectedSidebarIndex = index);
                              },
                            ),

                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (sidebarPosition == SidebarPosition.bottom)
                custom_widgets.NavigationBar(
                  selectedSidebarIndex: _selectedSidebarIndex,
                  isVertical: false,
                  onWillNavigate: (_) => _confirmDiscardChangesIfNeeded(),
                  onSidebarItemSelected: (index) {
                    setState(() => _selectedSidebarIndex = index);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildDottedDivider(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: isDark
              ? [
            Colors.white.withOpacity(0.1),
            Colors.white.withOpacity(0.7),
            Colors.white.withOpacity(0.1),
          ]
              : [
            Colors.black.withOpacity(0.1),
            Colors.black.withOpacity(0.7),
            Colors.black.withOpacity(0.1),
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
        dashColor: isDark ? Colors.white : Colors.black,
      ),
    );
  }
  Widget _buildRow(String title, String value,
      {bool isBold = false, Color? valueColor}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w400,
              color: valueColor ?? (isDark ? Colors.white : Colors.black),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w400,
              color: valueColor ?? (isDark ? Colors.white : Colors.black),
            ),
          ),
        ],
      ),
    );
  }
  Widget _refundRow(
      bool isDark,
      int orderItemId,
      String itemName,
      String unitPrice,
      String tax,
      int qty,
      String amount, {
        bool hasDiscount = false,
        String discountType = "",
      }) {
    // Check if this specific item is already in the selected list
    bool isChecked = selectedItems.any(
            (item) => item['order_item_id'] == orderItemId
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF4D4E63) : Colors.grey.shade200,
          ),
        ),
      ),
      child: Row(
        children: [
          // Real Checkbox
          SizedBox(
              width: 24,
              height: 24,
              child:Checkbox(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                fillColor: WidgetStateProperty.resolveWith<Color>((states) {
                  if (states.contains(WidgetState.selected)) {
                    return Colors.red; // checked color
                  }
                  return isDark ? const Color(0xFF2A2A2A) : Colors.white; // background
                }),
                checkColor: Colors.white,
                side: BorderSide(
                  color: isDark ? const Color(0xFFD0D0D0) : Colors.grey.shade400,
                  width: 1,
                ),
                value: isChecked,
                onChanged: _isRefundCompleted
                    ? null
                    : (bool? value) {
                  setState(() {
                    if (value == true) {
                      selectedItems.add({
                        'order_item_id': orderItemId,
                        'name': itemName,
                        'unit_price': double.parse(
                            unitPrice.split("×")[0].replaceAll("\$", "")),
                        'qty': qty,
                        'tax': double.parse(tax.replaceAll("\$", "")),
                        'amount': double.parse(amount.replaceAll("\$", "")),
                      });
                    } else {
                      selectedItems.removeWhere(
                              (item) => item['order_item_id'] == orderItemId);
                    }
                  });
                },
              )
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(itemName, style: const TextStyle(fontSize: 13)),
                if (hasDiscount)
                  Text(
                    "Discount: $discountType",
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.red,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(flex: 3, child: Text(unitPrice, style: const TextStyle(fontSize: 13))),
          Expanded(flex: 3, child: Text(tax, style: const TextStyle(fontSize: 13))),
          Expanded(
            flex: 2,
            child: Row(
              children: [
                _qtyButton("-", isDark),
                Container(width: 30, alignment: Alignment.center, child: Text(qty.toString())),

                _qtyButton("+", isDark),
              ],
            ),
          ),
          Expanded(flex: 2, child: Text(amount, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
  Widget _qtyButton(String symbol, bool isDark) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        symbol,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white : Colors.black,
        ),
      ),
    );
  }

// Define colors for each payment type
  final Map<String, Color> paymentColors = {
    "Cash": Color(0xFF84BB60),
    "Card": Color(0xFF7F5AA6),
    "Wallet": Color(0xFF978349),
  };

  Widget _paymentButton(String type) {
    final bool isSelected = selectedPayment == type;
    final bool isDisabled = _disabledPaymentType == type;
    final Color color = paymentColors[type] ?? Colors.green;

    return Expanded(
      child: GestureDetector(
        onTap: isDisabled
            ? null
            : () async {
          try {
            if (type == "Cash") {
              if (selectedItems.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Please select at least one product to refund.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              setState(() {
                selectedPayment = type;
              });

              final bool isFullRefund =
                  selectedItems.length == selectedOrder.items.length;

              final bool isPartialRefund = !isFullRefund;

              List<RefundItem>? refundItems;

              if (isPartialRefund) {
                refundItems = selectedItems.map((item) {
                  final lineItem = selectedOrder.items.firstWhere(
                        (e) => e.id == item['order_item_id'],
                  );

                  return RefundItem(
                    orderItemId: lineItem.id,
                    orderItemAmount: double.parse(
                      (lineItem.total + lineItem.totalTax)
                          .toStringAsFixed(2),
                    ),
                  );
                }).toList();
              }

              final refundType = isFullRefund ? "Full" : "Partial";

              final refundRequest = RefundRequestModel(
                orderId: selectedOrder.orderId,
                refundType: refundType,
                items: refundItems,
              );

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
              );

              final result =
              await CompletedOrdersRepository(baseUrl: '').refundOrder(
                orderId: selectedOrder.orderId,
                refundType: refundType,
                items: refundItems?.map((e) => e.toJson()).toList(),
              );

              Navigator.of(context, rootNavigator: true).pop();

              if (result["success"] == false) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      result["message"] ?? "Refund not allowed",
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

// Directly show payment success
              setState(() {
                _disabledPaymentType = type;
              });

              await showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => PaymentSuccessDialog(
                  amount: totalRefund,
                ),
              );

              setState(() {
                editedRefundAmount = totalRefund;
                isConfirmEnabled = true;
                _isRefundCompleted = true;
              });
            }
          } catch (e) {
            print("Refund error: $e");
          }
        },
        child: Opacity(
          opacity: isDisabled ? 0.6 : 1,
          child: Container(
            height: 45,
            decoration: BoxDecoration(
              color: isSelected ? color : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDisabled ? Colors.grey : color,
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(
                type, // always show Cash/Card/Wallet
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : color,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  BoxDecoration _boxDecoration() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BoxDecoration(
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color:
          isDark ? Colors.black.withOpacity(0.4) : const Color(0x14000000),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
}