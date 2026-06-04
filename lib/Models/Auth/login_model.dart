class LoginResponse {
  bool? success;
  int? statusCode;
  String? code;
  String? message;
  String? token;
  int? id;
  String? email;
  String? nicename;
  String? firstName;
  String? lastName;
  String? displayName;
  String? role; //Build #1.0.122: Updated
  String? avatar;
  int? shiftId; // Build #1.0.149: Added shift_id from API response
  String? safeEnable;
  String? safeEnableDrop;
  bool? payoutEnable;
  bool? cashbackEnable;
  LoginResponse({
    this.success,
    this.statusCode,
    this.code,
    this.message,
    this.token,
    this.id,
    this.email,
    this.nicename,
    this.firstName,
    this.lastName,
    this.displayName,
    this.role,
    this.avatar,
    this.shiftId, // Build #1.0.149: added
    this.safeEnable,
    this.safeEnableDrop,
    this.payoutEnable,
    this.cashbackEnable,
  });

  LoginResponse.fromJson(Map<String, dynamic> json) {
    success = json['success'];
    statusCode = json['statusCode'];
    code = json['code'];
    message = json['message'];
    token = json['data']?['token'];
    id = json['data']?['id'];
    email = json['data']?['email'];
    nicename = json['data']?['nicename'];
    firstName = json['data']?['firstName'];
    lastName = json['data']?['lastName'];
    displayName = json['data']?['displayName'];
    role = json['data']?['role'];
    avatar = json['data']?['avatar'];
    shiftId = json['data']?['shift_id']; // Build #1.0.149: added
    safeEnable = json['data']?['safe_enable']; // ✅ HERE
    safeEnableDrop = json['data']?['safe_enable_drop']; // ✅ HERE
    payoutEnable = json['data']?['payout_enable'] == "yes";
    // Inside fromJson()
    cashbackEnable = json['data']?['cashback_enable'] == "yes";
  }

  Map<String, dynamic> toJson() {
    return {
      'success': success,
      'statusCode': statusCode,
      'code': code,
      'message': message,
      'data': {
        'token': token,
        'id': id,
        'email': email,
        'nicename': nicename,
        'firstName': firstName,
        'lastName': lastName,
        'displayName': displayName,
        'role': role,
        'avatar': avatar,
        'shift_id': shiftId, // Build #1.0.149: added
        'safe_enable':safeEnable,
        'safe_enable_drop': safeEnableDrop, // ✅ added
        'payout_enable': payoutEnable,
        // Inside toJson()
        'cashback_enable': cashbackEnable,
      }
    };
  }
}

class LoginRequest { // Build #1.0.13: Updated login request
  String _empLoginPin;

  set empLoginPin(String value) {
    _empLoginPin = value;
  }

  LoginRequest(this._empLoginPin);

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['emp_login_pin'] = _empLoginPin;
    return data;
  }
}