import 'local_proxy.dart';

/// The login for full-device mode: the plan's own gateway login (host, port,
/// and the username carrying targeting and session).
Map<String, Object> socksLogin(GatewayEndpoint endpoint) =>
    {'host': endpoint.host, 'port': endpoint.port, 'username': endpoint.username, 'password': endpoint.password};
