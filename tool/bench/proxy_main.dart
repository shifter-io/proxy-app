// The app's LocalProxy on its own, for benchmarks:
//   dart compile exe tool/bench/proxy_main.dart -o /tmp/bench_proxy
//   /tmp/bench_proxy <gatewayPort>   -> prints "proxy <port>"
import 'dart:io';

import 'package:shifter_app/proxy/local_proxy.dart';

Future<void> main(List<String> args) async {
  final proxy = LocalProxy(onRejected: () => stderr.writeln('rejected'));
  final port = await proxy.start();
  proxy.setEndpoint(GatewayEndpoint(
    host: '127.0.0.1',
    port: int.parse(args.first),
    username: 'customer-bench-country-us-sid-abc123-ttl-600',
    password: 'bench',
  ));
  stdout.writeln('proxy $port');
}
