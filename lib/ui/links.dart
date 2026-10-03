import 'package:flutter/material.dart';

abstract final class ShifterUrls {
  static const panel = 'https://shifter.io/panel';
  static const apiKey = 'https://shifter.io/user/profile';
  static const register = 'https://shifter.io/login';
  static const order = 'https://shifter.io/order/residential-proxies';
  static const support = 'https://shifter.io/contact';
  static String renew(String membershipId) => 'https://shifter.io/panel/membership/$membershipId';
}

/// UI phase: external links are not wired to the OS browser yet (that needs
/// the url_launcher plugin), so show where the link would go.
void openExternal(BuildContext context, String url) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('Opens $url'), duration: const Duration(seconds: 2)));
}
