import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/svg.dart';
import 'package:intl/intl.dart';
// import 'package:pinaka_pos/Screens/Home/refund_screen.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_datepicker/datepicker.dart';

// import '../../Blocs/Orders/refund_order_list_bloc.dart';
import '../../Constants/text.dart';
import '../../Helper/Extentions/theme_notifier.dart';
// import '../../Models/Orders/refund_order_list.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../../Widgets/widget_order_screen_panel.dart';
import '../../Widgets/widget_topbar.dart';
import '../Blocs/Orders/refund_orderlist_bloc.dart';
import '../Blocs/Orders/refund_validation_bloc.dart';
import '../Database/db_helper.dart';
import '../Database/user_db_helper.dart';
import '../Helper/Extentions/nav_layout_manager.dart';
import '../Models/Orders/refund_orderlist_model.dart';
import '../Repositories/Orders/refund_validation_repository.dart';
import '../Widgets/refund_checkin_popup.dart';

enum SidebarPosition { left, right, bottom }

enum OrderPanelPosition { left, right }

List<String> allData = List.generate(27, (i) => "Item ${i + 1}");

class CompletedOrdersScreen extends StatefulWidget {
  const CompletedOrdersScreen({super.key, required int lastSelectedIndex});

  @override
  State<CompletedOrdersScreen> createState() => _CompletedOrdersScreenState();
}

class _CompletedOrdersScreenState extends State<CompletedOrdersScreen> with WidgetsBindingObserver, LayoutSelectionMixin{
  int _selectedSidebarIndex = 4;
  int _currentPage = 1;

  int itemsPerPage = 10;
  final List<int> _rowsPerPageOptions = [10, 20, 50, 100];
  int _rowsPerPage = 10;
  DateTime? selectedDate;
  // final int _rowsPerPage = 10;
  List<int> quantities = [];
  DateTime? _startDate;
  DateTime? _endDate;
  bool _isDateRangeApplied = false;
// int _currentPage = 1;
  List<CompletedOrder> _allOrders = [];
  List<CompletedOrder> filteredOrders = [];
// List<CompletedOrder> _allOrders = [];
  List<CompletedOrder> _pagedOrders = [];
  List<CompletedOrder> _visibleOrders = [];
  // final int _rowsPerPage = 10;
  // int _currentPage = 1;
  int _totalPages = 1;
  TextEditingController searchController = TextEditingController();
  String selectedStatus = 'Completed';
  String? selectedTransactionId;
  List<String> transactionIds = [];
  Map<int, String?> selectedTxnPerOrder = {};
  List<String> transactionIdOptions = [];
  double _lastBottomInset = 0;
  final _searchFocusNode = FocusNode();
  List<CompletedOrder> _orders = [];
  // int _totalPages = 1;
  String _todayStart() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 0, 0, 0);
    return start.toIso8601String();
  }

  String _todayEnd() {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return end.toIso8601String();
  }

  void _paginate() {
    final startIndex = (_currentPage - 1) * _rowsPerPage;
    final endIndex = startIndex + _rowsPerPage;

    _pagedOrders = _allOrders.sublist(
      startIndex,
      endIndex > _allOrders.length ? _allOrders.length : endIndex,
    );
  }

  void _loadPage(int page) {
    setState(() {
      _currentPage = page;
      _paginate();
    });
  }

  void _updatePagination() {
    final startIndex = (_currentPage - 1) * itemsPerPage;
    final endIndex = startIndex + itemsPerPage;

    setState(() {
      _pagedOrders = filteredOrders.sublist(
        startIndex,
        endIndex > filteredOrders.length ? filteredOrders.length : endIndex,
      );
    });
  }

  // @override
  @override
  void initState() {
    super.initState();
    // _allOrders = widget.orders; // or loaded data
    WidgetsBinding.instance.addObserver(this);
    filteredOrders = _allOrders;

    context.read<CompletedOrdersBloc>().add(
      FetchCompletedOrders(
        page: 1,
        perPage: 100, // ✅ required
      ),
    );
  }
  @override
  void didChangeMetrics() {
    final bottomInset = WidgetsBinding.instance.window.viewInsets.bottom;

    // Detect ONLY when keyboard goes from OPEN → CLOSED
    if (_lastBottomInset > 0 && bottomInset == 0) {
      if (_searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
      }
    }

    _lastBottomInset = bottomInset;
  }
  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }
  Widget build(BuildContext context) {
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

    return Scaffold(
      body: Column(
        children: [
          /// 🔹 TOP BAR (same as Orders screen)
          TopBar(
            screen: Screen.ORDERS,
            onModeChanged: () async {
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

              // Update notifier
              PinakaPreferences.layoutSelectionNotifier.value = newLayout;

              // Save to DB
              await UserDbHelper().saveUserSettings(
                {AppDBConst.layoutSelection: newLayout},
                modeChange: true,
              );

              // Refresh UI
              if (mounted) {
                setState(() {});
              }
            },
          ),

          const Divider(height: 1, thickness: 0.4),

          /// 🔹 MAIN CONTENT
          Expanded(
            child: Row(
              children: [
                /// 🔹 LEFT SIDEBAR
                if (sidebarPosition == SidebarPosition.left)
                  custom_widgets.NavigationBar(
                    selectedSidebarIndex: _selectedSidebarIndex,
                    isVertical: true,
                    onSidebarItemSelected: (index) {
                      setState(() => _selectedSidebarIndex = index);
                    },
                  ),

                /// 🔹 CENTER CONTENT (Completed Orders Table)
                Expanded(
                  child:
                  BlocConsumer<CompletedOrdersBloc, CompletedOrdersState>(
                    listener: (context, state) {
                      if (state is CompletedOrdersLoaded) {
                        setState(() {
                          _allOrders = state.orders;

                          // ✅ collect unique transaction IDs
                          transactionIds = _allOrders
                              .map((o) => o.transactionId)
                              .where((id) => id.isNotEmpty)
                              .toSet()
                              .toList();

                          filteredOrders = _allOrders;
                          _currentPage = 1;
                          _totalPages =
                              (_allOrders.length / _rowsPerPage).ceil();
                          _paginate();
                        });
                      }
                    },
                    builder: (context, state) {
                      if (state is CompletedOrdersLoading) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (state is CompletedOrdersError) {
                        return Center(
                          child: Text(
                            state.message,
                            style: const TextStyle(color: Colors.red),
                          ),
                        );
                      }

                      // Loaded / Initial
                      return Container(
                        margin: const EdgeInsets.all(12),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.primaryBackground
                              : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 6,
                            )
                          ],
                        ),
                        child: Column(
                          children: [
                            /// 🔹 HEADER
                            _buildHeader(),

                            const SizedBox(height: 12),

                            /// 🔹 TABLE
                            Expanded(child: _buildOrderTable(themeHelper)),

                            /// 🔹 PAGINATION
                            const SizedBox(height: 8),
                            _buildPagination(),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                /// 🔹 RIGHT ORDER PANEL (same behavior as Orders)
                // if (sidebarPosition != SidebarPosition.right)
                //   OrderScreenPanel(
                //     fetchOrders: true,
                //     formattedDate: '',
                //     formattedTime: '',
                //     quantities: quantities,
                //     activeOrderId: null,
                //     refreshOrderList: () {},
                //   ),

                /// 🔹 RIGHT SIDEBAR
                if (sidebarPosition == SidebarPosition.right)
                  custom_widgets.NavigationBar(
                    selectedSidebarIndex: _selectedSidebarIndex,
                    isVertical: true,
                    onSidebarItemSelected: (index) {
                      setState(() => _selectedSidebarIndex = index);
                    },
                  ),
              ],
            ),
          ),

          /// 🔹 BOTTOM SIDEBAR
          if (sidebarPosition == SidebarPosition.bottom)
            custom_widgets.NavigationBar(
              selectedSidebarIndex: _selectedSidebarIndex,
              isVertical: false,
              onSidebarItemSelected: (index) {
                setState(() => _selectedSidebarIndex = index);
              },
            ),
        ],
      ),
    );
  }

  // ================= HEADER =================

  Widget _buildHeader() {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        const Text(
          "Completed Order List",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Container(
          width: 200,
          height: 35,
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF29313F) // 🌙 your dark mode color
                : Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 6,
                spreadRadius: 1,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: TextField(
            controller: searchController,
            focusNode: _searchFocusNode,
            textAlignVertical:
            TextAlignVertical.center,
            keyboardType: TextInputType.number, // ✅ numeric keyboard
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly, // ✅ only digits allowed
            ],// ⭐ centers hint & text vertically
            onSubmitted: (_) {
              FocusScope.of(context).unfocus();
            },

            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
            },
            onChanged: (value) {
              setState(() {
                if (value.isEmpty) {
                  filteredOrders = _allOrders;
                } else {
                  filteredOrders = _allOrders.where((order) {
                    return order.orderId
                        .toString()
                        .toLowerCase()
                        .contains(value.toLowerCase());
                  }).toList();
                }

                _currentPage = 1;
                _updatePagination();
              });
            },
            decoration: InputDecoration(
              hintText: "Search Order ID",
              hintStyle: TextStyle(
                fontFamily: "Inter",
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: isDark ? Colors.white : const Color(0xFF999393),
              ),

              prefixIcon: Icon(
                Icons.search,
                color: isDark ? Colors.white : const Color(0xFF999393),
                size: 18,
              ),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                icon: Icon(
                  Icons.close,
                  color: isDark
                      ? Colors.white
                      : const Color(0xFF6B7280), // ⭐ close icon color
                  size: 18,
                ),
                onPressed: () {
                  searchController.clear();
                  setState(() {
                    filteredOrders = _allOrders;
                    _currentPage = 1;
                    _updatePagination();
                  });
                },
              )
                  : null,

              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,

              contentPadding: const EdgeInsets.symmetric(
                  vertical: 0), // ⭐ keeps text centered
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 18),
        Row(
          children: [
            // STATUS DROPDOWN
            // DropdownButtonHideUnderline(
            //   child: Container(
            //     padding:
            //     const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            //     decoration: BoxDecoration(
            //       border: Border.all(
            //         color: isDark
            //             ? const Color(0xFF4D4E63)
            //             : const Color(0xFFCCCCCC),
            //       ),
            //       borderRadius: BorderRadius.circular(6),
            //       color: isDark ? const Color(0xFF29313F) : Colors.white,
            //     ),
            //     child: DropdownButton<String>(
            //       value: selectedStatus,
            //       isDense: true,
            //       icon: Icon(
            //         Icons.keyboard_arrow_down,
            //         size: 18,
            //         color: isDark ? Colors.white : Colors.black,
            //       ),
            //       dropdownColor:
            //       isDark ? const Color(0xFF29313F) : Colors.white,
            //       style: TextStyle(
            //         color: isDark ? Colors.white : Colors.black,
            //         fontSize: 13,
            //       ),
            //       onChanged: (value) {
            //         if (value == null) return;
            //
            //         setState(() {
            //           selectedStatus = value;
            //
            //           filteredOrders = value == "Completed"
            //               ? _allOrders
            //               .where((o) =>
            //           (o.status ?? '').toLowerCase() ==
            //               'completed')
            //               .toList()
            //               : _allOrders
            //               .where((o) {
            //             final s = (o.status ?? '').toLowerCase();
            //             return s == 'refunded' ||
            //                 s == 'partial-refund';
            //           })
            //               .toList();
            //
            //           _currentPage = 1;
            //           _updatePagination();
            //         });
            //       },
            //       items: const [
            //         DropdownMenuItem(
            //           value: "Completed",
            //           child: Text("Completed"),
            //         ),
            //         DropdownMenuItem(
            //           value: "Refund",
            //           child: Text("Refund"),
            //         ),
            //       ],
            //     ),
            //   ),
            // ),

            const SizedBox(width: 8),

            // CALENDAR ICON FILTER
            InkWell(
              onTap: _openDateRangePickerDialog,
              child: Container(
                padding: const EdgeInsets.all(7),
                child: SvgPicture.asset(
                  'assets/svg/filter_calendar.svg',
                  width: 32,
                  height: 32,
                  colorFilter: ColorFilter.mode(
                    _isDateRangeApplied
                        ? Colors.redAccent
                        : Theme.of(context).colorScheme.onSurface,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ],
        )
      ],
    );
  }
  void _openDateRangePickerDialog() {
    final themeHelper = Provider.of<ThemeNotifier>(context, listen: false);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: themeHelper.themeMode == ThemeMode.dark
              ? ThemeNotifier.secondaryBackground
              : null,
          title: const Text("Select Date Range"),
          content: SizedBox(
            height: 400,
            width: 350,
            child: SfDateRangePicker(
              selectionMode: DateRangePickerSelectionMode.range,
              showActionButtons: true,
              onSelectionChanged: _onDateRangeSelectionChanged,
              initialSelectedRange: _startDate != null && _endDate != null
                  ? PickerDateRange(_startDate, _endDate)
                  : null,
              onSubmit: (value) => Navigator.pop(context),
              onCancel: () => Navigator.pop(context),
            ),
          ),
        );
      },
    );
  }
  void _onDateRangeSelectionChanged(
      DateRangePickerSelectionChangedArgs args) {
    if (args.value is PickerDateRange) {
      final range = args.value as PickerDateRange;

      setState(() {
        _startDate = range.startDate;
        _endDate = range.endDate ?? range.startDate;

        _isDateRangeApplied = _startDate != null && _endDate != null;

        _applyDateFilter(); // 👈 important
      });
    }
  }
  void _applyDateFilter() {
    if (!_isDateRangeApplied || _startDate == null || _endDate == null) {
      filteredOrders = _allOrders;
    } else {
      filteredOrders = _allOrders.where((order) {
        final orderDate = order.completedAt;

        final dateOnly =
        DateTime(orderDate.year, orderDate.month, orderDate.day);

        final start =
        DateTime(_startDate!.year, _startDate!.month, _startDate!.day);

        final end =
        DateTime(_endDate!.year, _endDate!.month, _endDate!.day);

        return dateOnly.isAfter(start.subtract(const Duration(days: 1))) &&
            dateOnly.isBefore(end.add(const Duration(days: 1)));
      }).toList();
    }

    _currentPage = 1;
    _updatePagination();
  }
  // ================= TABLE =================

  Widget _buildOrderTable(ThemeNotifier themeHelper) { bool isDark = Theme.of(context).brightness == Brightness.dark;

  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: themeHelper.themeMode == ThemeMode.dark
          ? const Color(0xFF201F29)
          : const Color(0xFFF9F9F9),
    ),
    child: Column(
      children: [
        /// 🔹 TABLE HEADER
        Container(
          padding: const EdgeInsets.only(
            left: 8,
            right: 0,
            top: 14,
            bottom: 14,
          ),
          decoration: BoxDecoration(
            color: themeHelper.themeMode == ThemeMode.dark
                ? const Color(0xFF29313F)
                : const Color(0xFF6F6F70),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Row(
            children: const [
              SizedBox(width: 10),

              _HeaderCell("Order ID"),
              _HeaderCell("Order Type"),
              _HeaderCell("Date"),
              _HeaderCell("Transaction ID"),
              // SizedBox(width: 10),
              _HeaderCell("Payment Type"),
              _HeaderCell("Amount"),
              _HeaderCell("Item Tax"),
              _HeaderCell("Discount"),
              _HeaderCell("Total"),
              _HeaderCell("Status"),
            ],
          ),
        ),

        /// 🔹 TABLE BODY
        Expanded(
          child: ListView.builder(
            itemCount: _pagedOrders.length,
            itemBuilder: (context, index) {
              final order = _pagedOrders[index];

              return InkWell(
                onTap: () {
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (dialogContext) {
                      return BlocProvider(
                        create: (_) => RefundValidationBloc(
                          repository: RefundValidationRepository(
                            baseUrl:
                            "https://merchantretail.alektasolutions.com",
                          ),
                        ),
                        child: PinCheckInDialog(order: order),
                      );
                    },
                  );
                },
                child: Container(
                  padding: const EdgeInsets.only(
                    left: 10,
                    right: 10,
                    top: 10,
                    bottom: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF212231) : Colors.white,
                    border: Border(
                      bottom: BorderSide(
                        color: isDark
                            ? const Color(0xFF4D4E63)   // dark mode border
                            : const Color(0xFFD8D7D7),  // light mode border
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      _DataCell("#${order.orderId}"),
                      _DataCell(order.orderType),
                      _DataCell(
                        DateFormat('dd-MM-yyyy').format(order.completedAt),
                      ),
                      // _DataCell(order.transactionId),
                      const SizedBox(width:10),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {},
                          behavior: HitTestBehavior.opaque,
                          child: DropdownButtonHideUnderline(
                            child: Builder(
                              builder: (context) {
                                final List<String> itemsList = [
                                  order.transactionId.toString(),
                                  ...transactionIdOptions
                                      .map((e) => e.toString()),
                                ].toSet().toList();

                                // ✅ Show only first 2 IDs in display
                                String displayText = "";

                                if (itemsList.length == 1) {
                                  displayText = itemsList[0];
                                } else if (itemsList.length == 2) {
                                  displayText =
                                  "${itemsList[0]}, ${itemsList[1]}";
                                } else if (itemsList.length > 2) {
                                  displayText =
                                  "${itemsList[0]}, ${itemsList[1]}...";
                                }
                                return DropdownButton<String>(
                                  value: itemsList.first,
                                  isDense: true,
                                  isExpanded: true,
                                  icon: const SizedBox.shrink(),
                                  onChanged: (value) {
                                    setState(() {
                                      selectedTxnPerOrder[order.orderId] =
                                      value!;
                                    });
                                  },
                                  selectedItemBuilder: (context) {
                                    return itemsList.map((e) {
                                      return Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          displayText,
                                          style:
                                          const TextStyle(fontSize: 14),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      );
                                    }).toList();
                                  },
                                  items: itemsList.map((txn) {
                                    return DropdownMenuItem<String>(
                                      value: txn,
                                      child: Text(
                                        txn,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      // const SizedBox(width:5),
                      _DataCell(order.paymentMethod),
                      _DataCell('${order.amount < 0 ? '-' : ''}\$${order.amount.abs().toStringAsFixed(2)}'),
                      _DataCell('${order.tax < 0 ? '-' : ''}\$${order.tax.abs().toStringAsFixed(2)}'),
                      _DataCell('${order.discount < 0 ? '-' : ''}\$${order.discount.abs().toStringAsFixed(2)}'),
                      _DataCell('${order.total < 0 ? '-' : ''}\$${order.total.abs().toStringAsFixed(2)}'),
                      const _StatusCell(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
  }

  // ================= PAGINATION =================
  Widget _buildPagination() {
    final int totalItems = _allOrders.length; // make sure you have this
    final int totalPages = _totalPages;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const Text("Rows per page:"),
          const SizedBox(width: 8),

          // ---------------- ROWS PER PAGE ----------------
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.0),
              border: Border.all(color: Colors.grey.shade400),
            ),
            child: DropdownButton<int>(
              value: _rowsPerPage,
              underline: const SizedBox.shrink(),
              items: _rowsPerPageOptions.map((int value) {
                return DropdownMenuItem<int>(
                  value: value,
                  child: Text(value.toString()),
                );
              }).toList(),
              onChanged: (int? newValue) {
                if (newValue != null) {
                  setState(() {
                    _rowsPerPage = newValue;
                    _currentPage = 1;
                    _loadPage(1);
                  });
                }
              },
            ),
          ),

          const SizedBox(width: 24),

          // ---------------- PAGE INFO ----------------
          Text(
            totalItems == 0
                ? '0-0 of 0'
                : '${(_currentPage - 1) * _rowsPerPage + 1}'
                '-${(_currentPage * _rowsPerPage) > totalItems ? totalItems : (_currentPage * _rowsPerPage)}'
                ' of $totalItems',
          ),

          const SizedBox(width: 24),

          // ---------------- FIRST PAGE ----------------
          IconButton(
            icon: const Icon(Icons.first_page),
            onPressed: _currentPage == 1 || totalItems == 0
                ? null
                : () => _loadPage(1),
          ),

          // ---------------- PREVIOUS PAGE ----------------
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _currentPage == 1 || totalItems == 0
                ? null
                : () => _loadPage(_currentPage - 1),
          ),

          // ---------------- NEXT PAGE ----------------
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _currentPage == totalPages || totalItems == 0
                ? null
                : () => _loadPage(_currentPage + 1),
          ),

          // ---------------- LAST PAGE ----------------
          IconButton(
            icon: const Icon(Icons.last_page),
            onPressed: _currentPage == totalPages || totalItems == 0
                ? null
                : () => _loadPage(totalPages),
          ),
        ],
      ),
    );
  }

  Widget _pageButton(int page) {
    final bool selected = _currentPage == page;

    return InkWell(
      onTap: () {
        setState(() {
          _currentPage = page;
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.red : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.red),
        ),
        child: Text(
          page.toString(),
          style: TextStyle(
            color: selected ? Colors.white : Colors.red,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// ================= SHARED CELLS =================

class _HeaderCell extends StatelessWidget {
  final String text;
  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Text(
        text,
        style:
        const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _DataCell extends StatelessWidget {
  final String text;
  const _DataCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Text(text));
  }
}

class _StatusCell extends StatelessWidget {
  const _StatusCell();

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          "Completed",
          style: TextStyle(color: Colors.green),
        ),
      ),
    );
  }
}