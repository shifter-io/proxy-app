import 'package:flutter/widgets.dart';

/// FutureBuilder that only re-runs [load] when [cacheKey] changes, so
/// rebuilds (typing in search, app notifications) don't refetch.
class AsyncValue<T> extends StatefulWidget {
  const AsyncValue({super.key, required this.cacheKey, required this.load, required this.builder});
  final Object cacheKey;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T? data, bool loading) builder;

  @override
  State<AsyncValue<T>> createState() => _AsyncValueState<T>();
}

class _AsyncValueState<T> extends State<AsyncValue<T>> {
  late Future<T> _future = widget.load();

  @override
  void didUpdateWidget(covariant AsyncValue<T> old) {
    super.didUpdateWidget(old);
    if (old.cacheKey != widget.cacheKey) _future = widget.load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) => widget.builder(context, snap.data, snap.connectionState != ConnectionState.done),
    );
  }
}
