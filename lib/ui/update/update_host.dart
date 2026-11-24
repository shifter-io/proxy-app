import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../proxy/proxy_engine.dart';
import '../../proxy/tunnel_proxy_engine.dart';
import '../../state/app_controller.dart';
import '../../theme/tokens.dart';
import '../../update/adapters/desktop_velopack.dart';
import '../../update/adapters/update_adapter.dart';
import '../../update/update_config.dart';
import '../../update/update_coordinator.dart';
import '../../update/update_models.dart';
import '../../update/update_repository.dart';
import '../../update/update_store.dart';
import 'update_panel.dart';

class UpdateScope extends InheritedWidget {
  const UpdateScope({
    super.key,
    required this.coordinator,
    required this.open,
    required this.problem,
    required this.modalOpen,
    required this.close,
    required super.child,
  });
  final UpdateCoordinator? coordinator;
  final VoidCallback open, close;
  final bool modalOpen;
  final String? problem;
  static UpdateScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>();
  @override
  bool updateShouldNotify(UpdateScope oldWidget) =>
      coordinator != oldWidget.coordinator ||
      problem != oldWidget.problem ||
      modalOpen != oldWidget.modalOpen;
}

/// Above the Navigator: auth resets and route pops cannot remove the modal.
class UpdateHost extends StatefulWidget {
  const UpdateHost({
    super.key,
    required this.app,
    required this.enabled,
    required this.navigatorKey,
    required this.child,
    this.initialCoordinator,
  });
  final AppController app;
  final bool enabled;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final UpdateCoordinator? initialCoordinator;
  @override
  State<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends State<UpdateHost> {
  UpdateCoordinator? _updates;
  String? _problem;
  bool _open = false;
  FocusNode? _previousFocus;
  final _dialogFocus = FocusScopeNode(
    debugLabel: 'App updates',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  AppLifecycleListener? _lifecycle;
  String? _route;
  Timer? _policyPoll;
  bool _required = false;
  bool get _modalOpen => _open || _required;
  bool _foreground = true;
  bool _initialized = false;
  @override
  void initState() {
    super.initState();
    widget.app.addListener(_appChanged);
    if (widget.initialCoordinator != null) {
      _updates = widget.initialCoordinator;
      _updates!.addListener(_changed);
      _initialized = true;
      if (_updates!.requiredVersion != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
      }
    } else if (widget.enabled) {
      unawaited(_initialize());
    } else {
      _problem = 'Updates are available in installed Shifter releases.';
    }
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _foreground = true;
        if (_initialized) unawaited(_updates?.check(automatic: true));
      },
      onHide: () {
        _foreground = false;
      },
      onPause: () {
        _foreground = false;
      },
    );
  }

  String _proxy() {
    final app = widget.app;
    if (app.phase == AuthPhase.booting ||
        app.isConnecting ||
        app.connection.status == ConnectionStatus.error) {
      throw const UpdateFailure(
        'Wait for the connection to settle before checking for updates.',
      );
    }
    if (!app.isConnected) return 'DIRECT';
    final engine = app.engine;
    final port = engine is LocalProxyEngine
        ? engine.port
        : engine is TunnelProxyEngine
        ? engine.port
        : null;
    if (port == null) {
      throw const UpdateFailure(
        'The active proxy is unavailable. Retry after disconnecting.',
      );
    }
    return 'PROXY 127.0.0.1:$port';
  }

  Future<void> _initialize() async {
    try {
      final config = UpdateConfig.production();
      final UpdateAdapter adapter = DesktopVelopackAdapter();
      final identity = await adapter.identity();
      final capabilities = await adapter.capabilities();
      final store = await UpdateStore.open();
      final updates = UpdateCoordinator(
        store: store,
        adapter: adapter,
        identity: identity,
        capabilities: capabilities,
        repository: config == null
            ? null
            : UpdateRepository(config, identity, store, proxy: _proxy),
        prepareConnection: widget.app.prepareForUpdate,
        prepareAutomaticConnection: (handoff) =>
            widget.app.prepareForUpdate(handoff, automatic: true),
        canAutomaticallyInstall: () =>
            mounted &&
            _foreground &&
            !_open &&
            widget.app.phase != AuthPhase.booting &&
            widget.app.connection.status == ConnectionStatus.disconnected &&
            !widget.app.updatePreparing &&
            !(widget.navigatorKey.currentState?.canPop() ?? true),
        canPrompt: () =>
            mounted &&
            _foreground &&
            !_open &&
            widget.app.phase != AuthPhase.booting &&
            widget.app.connection.status == ConnectionStatus.disconnected &&
            !widget.app.updatePreparing &&
            !(widget.navigatorKey.currentState?.canPop() ?? true),
      );
      if (!mounted) {
        updates.dispose();
        return;
      }
      setState(() {
        _updates = updates;
      });
      updates.addListener(_changed);
      _changed();
      _initializeWhenReady();
      if (config != null) {
        _policyPoll = Timer.periodic(const Duration(minutes: 5), (_) {
          if (_initialized) unawaited(updates.check(automatic: true));
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _problem = 'Update information is unavailable for this build.';
        });
      }
    }
  }

  void _initializeWhenReady() {
    if (!_initialized &&
        _updates != null &&
        !widget.app.isConnecting &&
        widget.app.phase != AuthPhase.booting) {
      _initialized = true;
      unawaited(_updates!.initialize());
    }
  }

  void _appChanged() {
    _initializeWhenReady();
    String next;
    try {
      next = _proxy();
    } catch (_) {
      next = 'unavailable';
    }
    if (_route != next) {
      _route = next;
      _updates?.routeChanged();
    }
    if (mounted) {
      setState(() {});
      unawaited(_updates?.considerPrompt());
    }
  }

  void _changed() {
    if (!mounted) return;
    final wasOpen = _modalOpen;
    _required = _updates?.requiredVersion != null;
    widget.app.setUpdateRequired(_required);
    if (_required && !wasOpen) _focusDialog();
    if (wasOpen && !_modalOpen) _restoreFocus();
    if (_updates?.promptRequested == true) {
      _updates!.consumePrompt();
      _show();
    }
    setState(() {});
  }

  void _show() {
    if (_modalOpen) return;
    setState(() {
      _open = true;
    });
    _focusDialog();
  }

  void _focusDialog() {
    _previousFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _modalOpen) _dialogFocus.requestFocus();
    });
  }

  void _restoreFocus() {
    if (_previousFocus?.context != null) _previousFocus?.requestFocus();
  }

  void _close() {
    if (_required || _updates?.phase == UpdatePhase.preparingInstall) return;
    unawaited(_updates?.later());
    setState(() {
      _open = false;
    });
    _restoreFocus();
  }

  @override
  Widget build(BuildContext context) => UpdateScope(
    coordinator: _updates,
    open: _show,
    problem: _problem,
    modalOpen: _modalOpen,
    close: _close,
    child: Stack(
      children: [
        ExcludeFocus(
          excluding: _modalOpen,
          child: ExcludeSemantics(excluding: _modalOpen, child: widget.child),
        ),
        if (_modalOpen) ...[
          ModalBarrier(
            color: Colors.black.withValues(alpha: .7),
            dismissible:
                !_required && _updates?.phase != UpdatePhase.preparingInstall,
            onDismiss: _required ? null : _close,
            semanticsLabel: _required ? null : 'Close app updates',
          ),
          SafeArea(
            child: Center(
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                },
                child: Actions(
                  actions: {
                    DismissIntent: CallbackAction<DismissIntent>(
                      onInvoke: (_) {
                        _close();
                        return null;
                      },
                    ),
                  },
                  child: FocusScope(
                    node: _dialogFocus,
                    autofocus: true,
                    child: Semantics(
                      scopesRoute: true,
                      namesRoute: true,
                      label: _required ? 'Update required' : 'App updates',
                      explicitChildNodes: true,
                      child: Dialog(
                        backgroundColor: Sf.bgElevated,
                        insetPadding: const EdgeInsets.all(20),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 500),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: _required
                                  ? RequiredUpdatePanel(updates: _updates!)
                                  : UpdatePanel(onClose: _close),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
  @override
  void dispose() {
    _policyPoll?.cancel();
    _lifecycle?.dispose();
    widget.app.removeListener(_appChanged);
    _updates?.removeListener(_changed);
    _updates?.dispose();
    _dialogFocus.dispose();
    super.dispose();
  }
}

/// Put this inside each route that exposes updates. System Back closes the
/// app-wide modal while its operation continues outside Navigator ownership.
class UpdateBackGuard extends StatelessWidget {
  const UpdateBackGuard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scope = UpdateScope.of(context);
    return PopScope(
      canPop: scope?.modalOpen != true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && scope?.modalOpen == true) scope!.close();
      },
      child: child,
    );
  }
}
