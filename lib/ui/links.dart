import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

abstract final class ShifterUrls {
  static const panel = 'https://shifter.io/panel';
  static const apiKey = 'https://shifter.io/user/profile';
  static const register = 'https://shifter.io/login';
  static const order = 'https://shifter.io/order/residential-proxies';
  static const support = 'https://shifter.io/contact';
  static String renew(String membershipId) => 'https://shifter.io/panel/membership/$membershipId';
}

/// Opens [url] in the default browser; says where it would go if that fails.
Future<void> openExternal(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text("Couldn't open $url"), duration: const Duration(seconds: 3)));
  }
}
