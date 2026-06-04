import 'package:pinaka_pos/Constants/text.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import '../Models/Assets/asset_model.dart';
import 'db_helper.dart';

class AssetDBHelper { //Build #1.0.54: added
  // Singleton instance to ensure only one instance of AssetDBHelper
  static final AssetDBHelper instance = AssetDBHelper._init();
  AssetDBHelper._init();

  Future<Database> get database async {
    if (kDebugMode) print("#### AssetDBHelper: Accessing database via DBHelper");
    return await DBHelper.instance.database;
  }

  // // Getter for the database instance
  // Future<Database> get database async {
  //   if (_database != null) {
  //     if (kDebugMode) {
  //       print("#### AssetDBHelper: Reusing existing database instance");
  //     }
  //     return _database!;
  //   }
  //   _database = await _initDB(AppDBConst.dbName);
  //   return _database!;
  // }

  // Initialize the database with the specified file path
  // Future<Database> _initDB(String filePath) async {
  //   final dbPath = await getDatabasesPath();
  //   final path = join(dbPath, filePath);
  //   if (kDebugMode) {
  //     print("#### AssetDBHelper: Initializing database at path: $path");
  //   }
  //   return await openDatabase(path, version: 1);
  // }

  // Save asset response to database within a transaction
  Future<void> saveAssets(AssetResponse assetResponse) async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Starting to save assets to database");
    }
    final db = await database;
    await db.transaction((txn) async {
      try {
        final existingAsset = await txn.query(AppDBConst.assetTable, limit: 1);
        int assetId = 1;

        if (existingAsset.isNotEmpty) { // Build #1.0.69 : updated code , check assets data exist or not
          await txn.update(
            AppDBConst.assetTable,
            {
              AppDBConst.baseUrl: assetResponse.baseUrl,
              AppDBConst.currency: assetResponse.currency,
              AppDBConst.currencySymbol: assetResponse.currencySymbol,
              AppDBConst.maxTubesCount: assetResponse.maxTubesCount,
              AppDBConst.safeDropAmount: assetResponse.safeDropAmount,
              AppDBConst.drawerAmount: assetResponse.drawerAmount,
            },
            where: '${AppDBConst.assetId} = ?',
            whereArgs: [assetId],
          );
          if (kDebugMode) {
            print("#### AssetDBHelper: Updated asset with ID: $assetId");
          }
        } else {
          await txn.insert(AppDBConst.assetTable, {
            AppDBConst.assetId: assetId,
            AppDBConst.baseUrl: assetResponse.baseUrl,
            AppDBConst.currency: assetResponse.currency,
            AppDBConst.currencySymbol: assetResponse.currencySymbol,
            AppDBConst.maxTubesCount: assetResponse.maxTubesCount,
            AppDBConst.safeDropAmount: assetResponse.safeDropAmount,
            AppDBConst.drawerAmount: assetResponse.drawerAmount,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted asset with ID: $assetId");
          }
        }

        TextConstants.currencySymbol = assetResponse.currencySymbol;

        // Build #1.0.163: No need save media from assets api, updated to saving from image assets api
       // await txn.delete(AppDBConst.mediaTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.taxTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.couponTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.orderStatusTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.roleTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.subscriptionPlanTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.storeDetailsTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.notesDenomTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.coinDenomTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.safeDenomTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.tubesDenomTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.vendorTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.vendorPaymentTypesTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.vendorPaymentPurposeTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.employeesTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);
        await txn.delete(AppDBConst.orderTypeTable, where: '${AppDBConst.assetId} = ?', whereArgs: [assetId]);

        // Build #1.0.163: No need save media from assets api, updated to saving from image assets api
        // for (var media in assetResponse.media) {
        //   await txn.insert(AppDBConst.mediaTable, {
        //     ...media.toMap(),
        //     AppDBConst.assetId: assetId,
        //   });
        //   if (kDebugMode) {
        //     print("#### AssetDBHelper: Inserted media with ID: ${media.id}");
        //   }
        // }

        for (var tax in assetResponse.taxes) {
          await txn.insert(
            AppDBConst.taxTable,
            {
              ...tax.toMap(),
              AppDBConst.assetId: assetId,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted tax with slug: ${tax.slug}");
          }
        }

        for (var coupon in assetResponse.coupons) {
          await txn.insert(AppDBConst.couponTable, {
            ...coupon.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted coupon with ID: ${coupon.id}");
          }
        }

        for (var status in assetResponse.orderStatuses) {
          await txn.insert(AppDBConst.orderStatusTable, {
            ...status.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted order status with slug: ${status.slug}");
          }
        }

        for (var role in assetResponse.roles) {
          await txn.insert(AppDBConst.roleTable, {
            ...role.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted role with slug: ${role.slug}");
          }
        }

        await txn.insert(AppDBConst.subscriptionPlanTable, {
          ...assetResponse.subscriptionPlans.toMap(),
          AppDBConst.assetId: assetId,
        });
        if (kDebugMode) {
          print("#### AssetDBHelper: Inserted subscription plan");
        }

        await txn.insert(AppDBConst.storeDetailsTable, {
          ...assetResponse.storeDetails.toMap(),
          AppDBConst.assetId: assetId,
        });
        if (kDebugMode) {
          print("#### AssetDBHelper: Inserted store details");
        }

        for (var denom in assetResponse.notesDenom) {
          await txn.insert(AppDBConst.notesDenomTable, {
            ...denom.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted notes denom: ${denom.denom}");
          }
        }

        for (var denom in assetResponse.coinDenom) {
          await txn.insert(AppDBConst.coinDenomTable, {
            ...denom.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted coin denom: ${denom.denom}");
          }
        }

        for (var denom in assetResponse.safeDenom) {
          await txn.insert(AppDBConst.safeDenomTable, {
            ...denom.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted safe denom: ${denom.denom}");
          }
        }

        for (var denom in assetResponse.tubesDenom) {
          await txn.insert(AppDBConst.tubesDenomTable, {
            ...denom.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted tubes denom: ${denom.denom}");
          }
        }

        for (var vendor in assetResponse.vendors) {  //Build #1.0.74: Naveen Added
          if (vendor.id == 0) {
            if (kDebugMode) print("#### AssetDBHelper: Skipping vendor with invalid ID: ${vendor.vendorName}");
            continue;
          }
          await txn.insert(AppDBConst.vendorTable, {
            AppDBConst.vendorId: vendor.id,
            AppDBConst.vendorName: vendor.vendorName,
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted vendor with ID: ${vendor.id}");
          }
        }

        for (var paymentType in assetResponse.vendorPaymentTypes) {
          await txn.insert(AppDBConst.vendorPaymentTypesTable, {
            AppDBConst.paymentType: paymentType,
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted payment type: $paymentType");
          }
        }

        for (var paymentPurpose in assetResponse.vendorPaymentPurpose) {
          await txn.insert(AppDBConst.vendorPaymentPurposeTable, {
            AppDBConst.paymentPurpose: paymentPurpose,
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted payment purpose: $paymentPurpose");
          }
        }

        for (var employee in assetResponse.employees) {
          await txn.insert(AppDBConst.employeesTable, {
            AppDBConst.employeeId: employee.iD,
            AppDBConst.employeeDisplayName: employee.displayName,
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted Employee: $employee");
          }
        }

        for (var orderType in assetResponse.orderTypes) {
          await txn.insert(AppDBConst.orderTypeTable, {
            ...orderType.toMap(),
            AppDBConst.assetId: assetId,
          });
          if (kDebugMode) {
            print("#### AssetDBHelper: Inserted orderType with slug: ${orderType.slug}");
          }
        }

      } catch (e) {
        if (kDebugMode) print("#### AssetDBHelper: Error saving assets: $e");
        rethrow;
      }
    });
  }

  // Retrieve the currency from the asset table
  Future<List<String?>?> getCurrency() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching base URL");
    }
    final db = await database;
    final result = await db.query(AppDBConst.assetTable,
        columns: [AppDBConst.currency, AppDBConst.currencySymbol], limit: 1);
    if (kDebugMode) {
      print("#### AssetDBHelper: Base URL query result: $result");
    }
    return result.isNotEmpty ? [result.first[AppDBConst.currency] as String?,result.first[AppDBConst.currencySymbol] as String?] : null;
  }

  // Retrieve the base URL from the asset table
  Future<String?> getAppBaseUrl() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching base URL");
    }
    final db = await database;
    final result = await db.query(AppDBConst.assetTable,
        columns: [AppDBConst.baseUrl], limit: 1);
    if (kDebugMode) {
      print("#### AssetDBHelper: Base URL query result: $result");
    }
    return result.isNotEmpty ? result.first[AppDBConst.baseUrl] as String? : null;
  }

  // Retrieve list of order statuses
  Future<List<OrderStatus>> getOrderStatusList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching order status list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.orderStatusTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} order statuses");
    }
    return result.map((map) => OrderStatus.fromJson(map)).toList();
  }

  // Retrieve list of media
  Future<List<Media>> getMediaList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching media list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.mediaTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} media items");
    }
    return result.map((map) => Media.fromJson(map)).toList();
  }

  // In AssetDBHelper, update getTaxList with detailed logging
  Future<List<Tax>> getTaxList() async {
    try {
      final db = await database;
      final result = await db.query(AppDBConst.taxTable);
      debugPrint("========== TAX TABLE ==========");
      if (kDebugMode) print("#### AssetDBHelper: Retrieved ${result.length} taxes: ${result.toString()}}");
      return result.map((map) => Tax.fromJson(map)).toList();
    } catch (e) {
      if (kDebugMode) print("#### AssetDBHelper: Error fetching tax list: $e}");
      debugPrint("Tax error: $e");
      return [];
    }
  }

  // Retrieve list of coupons
  Future<List<Coupon>> getCouponList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching coupon list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.couponTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} coupons");
    }
    return result.map((map) => Coupon.fromJson(map)).toList();
  }

  // Retrieve list of roles
  Future<List<Role>> getRoleList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching role list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.roleTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} roles");
    }
    return result.map((map) => Role.fromJson(map)).toList();
  }

  // Retrieve subscription plan
  Future<SubscriptionPlan?> getSubscriptionPlan() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching subscription plan");
    }
    final db = await database;
    final result = await db.query(AppDBConst.subscriptionPlanTable, limit: 1);
    if (kDebugMode) {
      print("#### AssetDBHelper: Subscription plan query result: $result");
    }
    return result.isNotEmpty ? SubscriptionPlan.fromJson(result.first) : null;
  }

  // Retrieve store details
  Future<StoreDetails?> getStoreDetails() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching store details");
    }
    final db = await database;
    final result = await db.query(AppDBConst.storeDetailsTable, limit: 1);
    if (kDebugMode) {
      print("#### AssetDBHelper: Store details query result: $result");
    }
    return result.isNotEmpty ? StoreDetails.fromJson(result.first) : null;
  }

  // Build #1.0.69 : added new functions based on new response of assets api
  Future<List<Denom>> getNotesDenomList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching notes denom list");
    }
    final db = await database;
    final result = await db.query(
      AppDBConst.notesDenomTable,
      orderBy: 'CAST(denom AS REAL) DESC', // Build #1.0.70 - Sort by numeric value in descending order
    );
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} notes denom in descending order: ${result.map((e) => e['denom']).toList()}");
    }
    return result.map((map) => Denom.fromJson(map)).toList();
  }

  Future<List<Denom>> getCoinDenomList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching coin denom list");
    }
    final db = await database;
    final result = await db.query(
      AppDBConst.coinDenomTable,
      orderBy: 'CAST(denom AS REAL) DESC', // Build #1.0.70 - Sort by numeric value in descending order
    );
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} coin denom in descending order: ${result.map((e) => e['denom']).toList()}");
    }
    return result.map((map) => Denom.fromJson(map)).toList();
  }

  Future<List<Denom>> getSafeDenomList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching safe denom list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.safeDenomTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} safe denom");
    }
    return result.map((map) => Denom.fromJson(map)).toList();
  }

  Future<List<Denom>> getTubesDenomList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching tubes denom list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.tubesDenomTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} tubes denom");
    }
    return result.map((map) => Denom.fromJson(map)).toList();
  }

  //Build #1.0.74: Naveen Added
  Future<List<Vendor>> getVendorList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching vendor list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.vendorTable);
    if (kDebugMode) print("#### AssetDBHelper: Retrieved ${result.length} vendors: ${result.map((v) => 'ID: ${v[AppDBConst.vendorId]}, Name: ${v[AppDBConst.vendorName]}').toList()}");
    return result.map((map) => Vendor.fromJson({
      'id': map[AppDBConst.vendorId],
      'vendor_name': map[AppDBConst.vendorName],
    })).toList();
  }

  Future<List<String>> getVendorPaymentTypesList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching vendor payment types list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.vendorPaymentTypesTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} payment types");
    }
    return result.map((map) => map[AppDBConst.paymentType] as String).toList();
  }

  Future<List<String>> getVendorPaymentPurposeList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching vendor payment purpose list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.vendorPaymentPurposeTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} payment purposes");
    }
    return result.map((map) => map[AppDBConst.paymentPurpose] as String).toList();
  }

  Future<List<Employees>> getEmployeeList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching employee list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.employeesTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} employees");
    }
    return result.map((map) => Employees.fromJson({
      'ID': map[AppDBConst.employeeId],
      'display_name': map[AppDBConst.employeeDisplayName],
    })).toList();
  }

  // Retrieve list of orderType
  Future<List<OrderType>> getOrderTypeList() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Fetching order type list");
    }
    final db = await database;
    final result = await db.query(AppDBConst.orderTypeTable);
    if (kDebugMode) {
      print("#### AssetDBHelper: Retrieved ${result.length} order types");
    }
    return result.map((map) => OrderType.fromJson(map)).toList();
  }

  // Close the database connection
  Future<void> close() async {
    if (kDebugMode) {
      print("#### AssetDBHelper: Closing database connection");
    }
    final db = await database;
    await db.close();
    if (kDebugMode) {
      print("#### AssetDBHelper: Database connection closed!");
    }
  }
}