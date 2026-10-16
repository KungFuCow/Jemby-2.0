import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/repositories/server_repository.dart';
import '../../../auth/repositories/session_repository.dart';
import '../../../auth/store/authentication_preferences.dart';
import '../../../auth/store/credential_store.dart';
import '../../../data/services/connectivity_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../util/pin_code_util.dart';
import '../../../preference/preference_constants.dart';
import '../../navigation/destinations.dart';
import '../../widgets/adaptive/adaptive_dialog.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/pin_entry_dialog.dart';
import '../../widgets/focus/request_initial_focus.dart';

class StartupScreen extends StatefulWidget {
  final bool bootstrapActiveSession;

  const StartupScreen({
    super.key,
    this.bootstrapActiveSession = false,
  });

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;
  List<String> _posterUrls = const [];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    _fadeController.forward();
    _initialize();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  /// On a cold boot the app can win the race against Wi-Fi association and
  /// see the device as offline for a few seconds. Waiting here keeps the
  /// splash up briefly instead of bouncing the user to the offline fallback.
  /// Once online, also settle server reachability (the boot-time check runs
  /// before a client exists) so home loads in the right online/offline mode.
  Future<void> _waitForNetworkSettle() async {
    final connectivity = GetIt.instance<ConnectivityService>();
    if (!connectivity.isOnline) {
      await connectivity.waitForOnline(const Duration(seconds: 5));
    }
    if (connectivity.isOnline &&
        GetIt.instance.isRegistered<MediaServerClient>()) {
      try {
        await connectivity.recheckNow();
      } catch (_) {}
    }
  }

  /// Preserve J'Emby 1.0's personalized poster collage, without holding
  /// startup hostage if the Emby server is slow or temporarily unreachable.
  Future<void> _loadJembySplashArt() async {
    if (!GetIt.instance.isRegistered<MediaServerClient>()) return;
    try {
      final client = GetIt.instance<MediaServerClient>();
      final data = await client.itemsApi.getItems(
        recursive: true,
        includeItemTypes: const ['Movie', 'Series'],
        sortBy: 'DateCreated',
        sortOrder: 'Descending',
        limit: 60,
      ).timeout(const Duration(seconds: 3));
      final items = (data['Items'] as List?) ?? const [];
      final ids = items
          .whereType<Map>()
          .map((e) => e['Id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      final others = ids.skip(8).toList()..shuffle();
      final selection = <String>[
        ...ids.take(6),
        ...others.take(6),
      ];
      if (!mounted || selection.isEmpty) return;
      setState(() {
        _posterUrls = selection
            .map((id) => client.imageApi.getPrimaryImageUrl(id, maxWidth: 350))
            .toList();
      });
      // Allow cached or locally served artwork a brief chance to paint.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    } catch (_) {
      // Keep the colorful offline tile fallback on failed connections.
    }
  }

  Future<void> _initialize() async {
    final session = GetIt.instance<SessionRepository>();
    final serverRepo = GetIt.instance<ServerRepository>();
    final credentialStore = GetIt.instance<CredentialStore>();
    final authPrefs = GetIt.instance<AuthenticationPreferences>();

    if (session.state != SessionState.ready) {
      // Never wait here forever. A session that cannot finish restoring would
      // otherwise hold the splash with nothing on screen to say why.
      await session.stateStream
          .firstWhere((s) => s == SessionState.ready)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => SessionState.ready,
          );
    }

    await serverRepo.loadStoredServers();

    if (widget.bootstrapActiveSession && session.activeUserId != null) {
      await _waitForNetworkSettle();
      await _loadJembySplashArt();
      if (mounted) context.go(Destinations.home);
      return;
    }

    final behavior = authPrefs.loginBehavior;
    String? targetUserId;

    // Always start with the last-used server as a universal fallback so that
    // any edge case where a behavior-specific ID is not set still lands on
    // the correct server's user-select page rather than the Add Server screen.
    String? targetServerId = authPrefs.savedLastServerId.isNotEmpty
        ? authPrefs.savedLastServerId
        : null;

    if (behavior == UserSelectBehavior.lastUser) {
      targetUserId = authPrefs.savedLastUserId;
    } else if (behavior == UserSelectBehavior.currentUser) {
      final autoServerId = authPrefs.savedAutoLoginServerId;
      if (autoServerId.isNotEmpty) targetServerId = autoServerId;
      targetUserId = authPrefs.savedAutoLoginUserId;
    }

    bool pinEnabledForAutoLoginUser = false;
    if (targetUserId != null && targetUserId.isNotEmpty) {
      final store = GetIt.instance<PreferenceStore>();
      final pinUtil = PinCodeUtil(store, targetUserId);
      pinEnabledForAutoLoginUser = pinUtil.isPinEnabled;
    }

    final restored = (authPrefs.shouldAlwaysAuthenticate || pinEnabledForAutoLoginUser)
        ? false
        : await session.restoreSession();

    if (!mounted) return;

    // Read the flag either way so a one-off failure doesn't carry over to the
    // next launch, but only warn when it cost the user something. A session
    // that came back has the token it needs and the warning is just noise.
    final storageFailed = credentialStore.consumeSecureStorageUnavailable();
    if (storageFailed && !(restored && session.activeUserId != null)) {
      await _showSecureStorageWarning();
      if (!mounted) return;
    }

    if (restored && session.activeUserId != null) {
      final store = GetIt.instance<PreferenceStore>();
      final pinUtil = PinCodeUtil(store, session.activeUserId!);

      if (pinUtil.isPinEnabled) {
        final verified = await PinEntryDialog.show(
          context,
          mode: PinEntryMode.verify,
          onVerify: pinUtil.verifyPin,
          onForgotPin: () {
            if (mounted) context.go(Destinations.serverSelect);
          },
        );

        if (!verified) {
          if (mounted) context.go(Destinations.serverSelect);
          return;
        }
      }

      await _waitForNetworkSettle();
      await _loadJembySplashArt();
      if (mounted) context.go(Destinations.home);
    } else {
      if (mounted) {
        if (targetServerId != null && targetServerId.isNotEmpty) {
          // A previously-used server is known — go straight to user selection
          // for that server rather than the Add Server page.
          context.go('${Destinations.server}?serverId=$targetServerId');
        } else {
          context.go(Destinations.serverSelect);
        }
      }
    }
  }

  Future<void> _showSecureStorageWarning() async {
    final l10n = AppLocalizations.of(context);
    await showFocusRestoringDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.secureStorageUnavailable),
        content: Text(
          l10n.secureStorageUnavailableMessage,
        ),
        actions: [
          adaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  bool get _isLargeScreen {
    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows;
  }

  @override
  Widget build(BuildContext context) =>
      RequestInitialFocus(child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    // Same poster-mosaic splash and tagline as the original J'Emby client.
    const tints = [
      Color(0xFF274763),
      Color(0xFF31546C),
      Color(0xFF172F48),
      Color(0xFF466079),
      Color(0xFF1F4356),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 720;

    return Scaffold(
      backgroundColor: const Color(0xFF03070E),
      body: Stack(
        fit: StackFit.expand,
        children: [
          GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              childAspectRatio: 1.34,
            ),
            itemCount: 12,
            itemBuilder: (context, index) {
              final fallback = ColoredBox(color: tints[index % tints.length]);
              if (_posterUrls.isEmpty) return fallback;
              final url = _posterUrls[index % _posterUrls.length];
              return Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              );
            },
          ),
          const ColoredBox(color: Color(0x99000000)),
          Center(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset(
                    'assets/images/jemby_logo.svg',
                    width: wide ? 104 : 76,
                    height: wide ? 104 : 76,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "J'Emby",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: wide ? 58 : 38,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your Media. Your Way.',
                    style: TextStyle(
                      fontSize: wide ? 22 : 16,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 22),
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFF50B4F6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
