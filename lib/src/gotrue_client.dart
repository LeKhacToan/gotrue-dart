import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:gotrue/gotrue.dart';
import 'package:gotrue/src/constants.dart';
import 'package:gotrue/src/fetch.dart';
import 'package:gotrue/src/types/auth_response.dart';
import 'package:gotrue/src/types/fetch_options.dart';
import 'package:http/http.dart';
import 'package:universal_io/io.dart';

class GoTrueClient {
  /// Namespace for the GoTrue API methods.
  /// These can be used for example to get a user from a JWT in a server environment or reset a user's password.
  late GoTrueAdminApi admin;

  /// The currently logged in user or null.
  User? _currentUser;

  /// The session object for the currently logged in user or null.
  Session? _currentSession;

  final String _url;
  final Map<String, String> _headers;
  final Client? _httpClient;
  late final GotrueFetch _fetch = GotrueFetch(_httpClient);

  late bool _autoRefreshToken;

  Timer? _refreshTokenTimer;

  int _refreshTokenRetryCount = 0;

  final _onAuthStateChangeController = StreamController<AuthState>.broadcast();
  // Receive a notification every time an auth event happens.
  Stream<AuthState> get onAuthStateChange =>
      _onAuthStateChangeController.stream;

  GoTrueClient({
    String? url,
    Map<String, String>? headers,
    bool? autoRefreshToken,
    Client? httpClient,
  })  : _url = url ?? Constants.defaultGotrueUrl,
        _headers = headers ?? {},
        _httpClient = httpClient {
    _autoRefreshToken = autoRefreshToken ?? true;

    final gotrueUrl = url ?? Constants.defaultGotrueUrl;
    final gotrueHeader = {
      ...Constants.defaultHeaders,
      if (headers != null) ...headers,
    };
    admin = GoTrueAdminApi(
      gotrueUrl,
      headers: gotrueHeader,
      httpClient: httpClient,
    );
  }

  /// Returns the current logged in user, if any;
  User? get currentUser => _currentUser;

  /// Returns the current session, if any;
  Session? get currentSession => _currentSession;

  /// Creates a new user.
  ///
  /// [email] is the user's email address
  ///
  /// [phone] is the user's phone number WITH international prefix
  ///
  /// [password] is the password of the user
  ///
  /// [data] sets [User.userMetadata] without an extra call to [updateUser]
  Future<AuthResponse> signUp({
    String? email,
    String? phone,
    required String password,
    String? emailRedirectTo,
    Map<String, dynamic>? data,
    String? captchaToken,
  }) async {
    assert((email != null && phone == null) || (email == null && phone != null),
        'You must provide either an email or phone number');

    _removeSession();

    late final Map<String, dynamic> response;

    if (email != null) {
      final urlParams = <String, String>{};

      response = await _fetch.request(
        '$_url/signup',
        RequestMethodType.post,
        options: GotrueRequestOptions(
          headers: _headers,
          redirectTo: emailRedirectTo,
          body: {
            'email': email,
            'password': password,
            'data': data,
            'gotrue_meta_security': {'captcha_token': captchaToken},
          },
          query: urlParams,
        ),
      );
    } else if (phone != null) {
      final body = {
        'phone': phone,
        'password': password,
        'data': data,
        'gotrue_meta_security': {'captcha_token': captchaToken},
      };
      final fetchOptions = GotrueRequestOptions(headers: _headers, body: body);
      response = await _fetch.request('$_url/signup', RequestMethodType.post,
          options: fetchOptions) as Map<String, dynamic>;
    } else {
      throw AuthException(
          'You must provide either an email or phone number and a password');
    }

    final authResponse = AuthResponse.fromJson(response);

    final session = authResponse.session;
    if (session != null) {
      _saveSession(session);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }

    return authResponse;
  }

  /// Log in an existing user with an email and password or phone and password.
  Future<AuthResponse> signInWithPassword({
    String? email,
    String? phone,
    required String password,
    String? captchaToken,
  }) async {
    _removeSession();

    late final Map<String, dynamic> response;

    if (email != null) {
      response = await _fetch.request(
        '$_url/token',
        RequestMethodType.post,
        options: GotrueRequestOptions(
          headers: _headers,
          body: {'email': email, 'password': password},
          query: {'grant_type': 'password'},
        ),
      );
    } else if (phone != null) {
      response = await _fetch.request(
        '$_url/token',
        RequestMethodType.post,
        options: GotrueRequestOptions(
          headers: _headers,
          body: {'phone': phone, 'password': password},
          query: {'grant_type': 'password'},
        ),
      );
    } else {
      throw AuthException(
        'You must provide either an email, phone number, a third-party provider or OpenID Connect.',
      );
    }

    final authResponse = AuthResponse.fromJson(response);

    if (authResponse.session?.accessToken != null) {
      _saveSession(authResponse.session!);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }
    return authResponse;
  }

  /// Log in an existing user via a third-party provider.
  Future<OAuthResponse> getOAuthSignInUrl({
    required Provider provider,
    String? redirectTo,
    String? scopes,
    Map<String, String>? queryParams,
  }) async {
    _removeSession();
    return _handleProviderSignIn(provider,
        redirectTo: redirectTo, scopes: scopes, queryParams: queryParams);
  }

  /// Log in a user using magiclink or a one-time password (OTP).
  ///
  /// If the `{{ .ConfirmationURL }}` variable is specified in the email template, a magiclink will be sent.
  ///
  /// If the `{{ .Token }}` variable is specified in the email template, an OTP will be sent.
  ///
  /// If you're using phone sign-ins, only an OTP will be sent. You won't be able to send a magiclink for phone sign-ins.
  ///
  /// If [shouldCreateUser] is set to false, this method will not create a new user. Defaults to true.
  ///
  /// [emailRedirectTo] can be used to specify the redirect URL embedded in the email link
  ///
  /// [data] can be used to set the user's metadata, which maps to the `auth.users.user_metadata` column.
  ///
  /// [captchaToken] Verification token received when the user completes the captcha on the site.
  Future<void> signInWithOtp({
    String? email,
    String? phone,
    String? emailRedirectTo,
    bool? shouldCreateUser,
    Map<String, dynamic>? data,
    String? captchaToken,
  }) async {
    _removeSession();

    if (email != null) {
      await _fetch.request(
        '$_url/otp',
        RequestMethodType.post,
        options: GotrueRequestOptions(
          headers: _headers,
          redirectTo: emailRedirectTo,
          body: {
            'email': email,
            'data': data ?? {},
            'create_user': shouldCreateUser ?? true,
            'gotrue_meta_security': {'captcha_token': captchaToken},
          },
        ),
      );
      return;
    }
    if (phone != null) {
      final body = {
        'phone': phone,
        'data': data ?? {},
        'create_user': shouldCreateUser ?? true,
        'gotrue_meta_security': {'captcha_token': captchaToken},
      };
      final fetchOptions = GotrueRequestOptions(headers: _headers, body: body);

      await _fetch.request(
        '$_url/otp',
        RequestMethodType.post,
        options: fetchOptions,
      );
      return;
    }
    throw AuthException(
      'You must provide either an email, phone number, a third-party provider or OpenID Connect.',
    );
  }

  /// Log in a user given a User supplied OTP received via mobile.
  ///
  /// [phone] is the user's phone number WITH international prefix
  ///
  /// [token] is the token that user was sent to their mobile phone
  Future<AuthResponse> verifyOTP({
    String? email,
    String? phone,
    required String token,
    required OtpType type,
    String? redirectTo,
    String? captchaToken,
  }) async {
    assert((email != null && phone == null) || (email == null && phone != null),
        '`email` or `phone` needs to be specified.');

    _removeSession();

    final body = {
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      'token': token,
      'type': type.snakeCase,
      'redirect_to': redirectTo,
      'gotrue_meta_security': {'captchaToken': captchaToken},
    };
    final fetchOptions = GotrueRequestOptions(headers: _headers, body: body);
    final response = await _fetch
        .request('$_url/verify', RequestMethodType.post, options: fetchOptions);

    final authResponse = AuthResponse.fromJson(response);

    if (authResponse.session == null) {
      throw AuthException(
        'An error occurred on token verification.',
      );
    }

    _saveSession(authResponse.session!);
    _notifyAllSubscribers(AuthChangeEvent.signedIn);

    return authResponse;
  }

  /// Force refreshes the session including the user data in case it was updated
  /// in a different session.
  Future<AuthResponse> refreshSession() async {
    final refreshCompleter = Completer<AuthResponse>();
    if (currentSession?.accessToken == null) {
      throw AuthException('Not logged in.');
    }

    return _callRefreshToken(refreshCompleter);
  }

  /// Updates user data, if there is a logged in user.
  Future<UserResponse> updateUser(UserAttributes attributes) async {
    final accessToken = currentSession?.accessToken;
    if (accessToken == null) {
      throw AuthException('Not logged in.');
    }

    final body = attributes.toJson();
    final options = GotrueRequestOptions(
      headers: _headers,
      body: body,
      jwt: accessToken,
    );
    final response = await _fetch.request('$_url/user', RequestMethodType.put,
        options: options);
    final userResponse = UserResponse.fromJson(response);

    _currentUser = userResponse.user;
    _currentSession = currentSession?.copyWith(user: userResponse.user);
    _notifyAllSubscribers(AuthChangeEvent.userUpdated);

    return userResponse;
  }

  /// Sets the session data from refresh_token and returns the current session.
  Future<AuthResponse> setSession(String refreshToken) async {
    final refreshCompleter = Completer<AuthResponse>();
    if (refreshToken.isEmpty) {
      throw AuthException('No current session.');
    }
    return _callRefreshToken(refreshCompleter, refreshToken: refreshToken);
  }

  /// Gets the session data from a oauth2 callback URL
  Future<AuthSessionUrlResponse> getSessionFromUrl(
    Uri originUrl, {
    bool storeSession = true,
  }) async {
    var url = originUrl;
    if (originUrl.hasQuery) {
      final decoded = originUrl.toString().replaceAll('#', '&');
      url = Uri.parse(decoded);
    } else {
      final decoded = originUrl.toString().replaceAll('#', '?');
      url = Uri.parse(decoded);
    }

    final errorDescription = url.queryParameters['error_description'];
    if (errorDescription != null) {
      throw AuthException(errorDescription);
    }

    final accessToken = url.queryParameters['access_token'];
    final expiresIn = url.queryParameters['expires_in'];
    final refreshToken = url.queryParameters['refresh_token'];
    final tokenType = url.queryParameters['token_type'];
    final providerToken = url.queryParameters['provider_token'];

    if (accessToken == null) {
      throw AuthException('No access_token detected.');
    }
    if (expiresIn == null) {
      throw AuthException('No expires_in detected.');
    }
    if (refreshToken == null) {
      throw AuthException('No refresh_token detected.');
    }
    if (tokenType == null) {
      throw AuthException('No token_type detected.');
    }

    final headers = {..._headers};
    headers['Authorization'] = 'Bearer $accessToken';
    final options = GotrueRequestOptions(headers: headers);
    final response = await _fetch.request('$_url/user', RequestMethodType.get,
        options: options);
    final user = UserResponse.fromJson(response).user;
    if (user == null) {
      throw AuthException('No user found. ');
    }

    final session = Session(
      providerToken: providerToken,
      accessToken: accessToken,
      expiresIn: int.parse(expiresIn),
      refreshToken: refreshToken,
      tokenType: tokenType,
      user: user,
    );

    final redirectType = url.queryParameters['type'];

    if (storeSession == true) {
      _saveSession(session);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
      if (redirectType == 'recovery') {
        _notifyAllSubscribers(AuthChangeEvent.passwordRecovery);
      }
    }

    return AuthSessionUrlResponse(session: session, redirectType: redirectType);
  }

  /// Signs out the current user, if there is a logged in user.
  Future<void> signOut() async {
    final accessToken = currentSession?.accessToken;
    _removeSession();
    _notifyAllSubscribers(AuthChangeEvent.signedOut);
    if (accessToken != null) {
      return admin.signOut(accessToken);
    }
  }

  /// Sends a reset request to an email address.
  Future<void> resetPasswordForEmail(
    String email, {
    String? redirectTo,
    String? captchaToken,
  }) async {
    final body = {
      'email': email,
      'gotrue_meta_security': {'captcha_token': captchaToken},
    };
    final urlParams = <String, String>{};
    if (redirectTo != null) {
      final encodedRedirectTo = Uri.encodeComponent(redirectTo);
      urlParams['redirect_to'] = encodedRedirectTo;
    }

    final fetchOptions =
        GotrueRequestOptions(headers: _headers, body: body, query: urlParams);
    await _fetch.request(
      '$_url/recover',
      RequestMethodType.post,
      options: fetchOptions,
    );
  }

  /// Recover session from persisted session json string.
  /// Persisted session json has the format { currentSession, expiresAt }
  ///
  /// currentSession: session json object, expiresAt: timestamp in seconds
  Future<AuthResponse> recoverSession(String jsonStr) async {
    final refreshCompleter = Completer<AuthResponse>();
    final persistedData = json.decode(jsonStr) as Map<String, dynamic>;
    final currentSession =
        persistedData['currentSession'] as Map<String, dynamic>?;
    final expiresAt = persistedData['expiresAt'] as int?;
    if (currentSession == null) {
      throw AuthException('Missing currentSession.');
    }
    if (expiresAt == null) {
      throw AuthException('Missing expiresAt.');
    }

    final session = Session.fromJson(currentSession);
    if (session == null) {
      throw AuthException('Current session is missing data.');
    }

    final timeNow = (DateTime.now().millisecondsSinceEpoch / 1000).round();
    if (expiresAt < (timeNow - Constants.expiryMargin.inSeconds)) {
      if (_autoRefreshToken && session.refreshToken != null) {
        final response = await _callRefreshToken(
          refreshCompleter,
          refreshToken: session.refreshToken,
          accessToken: session.accessToken,
        );
        return response;
      } else {
        throw AuthException('Session expired.');
      }
    } else {
      _saveSession(session);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
      return AuthResponse(session: session);
    }
  }

  /// return provider url only
  OAuthResponse _handleProviderSignIn(
    Provider provider, {
    required String? scopes,
    required String? redirectTo,
    required Map<String, String>? queryParams,
  }) {
    // final url = admin.getUrlForProvider(provider, options);
    final urlParams = {'provider': provider.name};
    if (scopes != null) {
      urlParams['scopes'] = scopes;
    }
    if (redirectTo != null) {
      final encodedRedirectTo = Uri.encodeComponent(redirectTo);
      urlParams['redirect_to'] = encodedRedirectTo;
    }
    if (queryParams != null) {
      urlParams.addAll(queryParams);
    }
    final url = '$_url/authorize?${Uri(queryParameters: urlParams).query}';

    return OAuthResponse(provider: provider, url: url);
  }

  void _saveSession(Session session) {
    final refreshCompleter = Completer<AuthResponse>();
    _currentSession = session;
    _currentUser = session.user;
    final expiresAt = session.expiresAt;

    if (_autoRefreshToken && expiresAt != null) {
      _refreshTokenTimer?.cancel();

      final timeNow = (DateTime.now().millisecondsSinceEpoch / 1000).round();
      final expiresIn = expiresAt - timeNow;
      final refreshDurationBeforeExpires = expiresIn > 60 ? 60 : 1;
      final nextDuration = expiresIn - refreshDurationBeforeExpires;
      if (nextDuration > 0) {
        final timerDuration = Duration(seconds: nextDuration);
        _setTokenRefreshTimer(timerDuration, refreshCompleter);
      } else {
        _callRefreshToken(refreshCompleter);
      }
    }
  }

  void _setTokenRefreshTimer(
    Duration timerDuration,
    Completer<AuthResponse> completer, {
    String? refreshToken,
    String? accessToken,
  }) {
    _refreshTokenTimer?.cancel();
    _refreshTokenRetryCount++;
    if (_refreshTokenRetryCount < Constants.maxRetryCount) {
      _refreshTokenTimer = Timer(timerDuration, () {
        _callRefreshToken(
          completer,
          refreshToken: refreshToken,
          accessToken: accessToken,
        );
      });
    } else {
      final error = AuthException('Access token refresh retry limit exceeded.');
      completer.completeError(error, StackTrace.current);
    }
  }

  void _removeSession() {
    _currentSession = null;
    _currentUser = null;
    _refreshTokenRetryCount = 0;

    _refreshTokenTimer?.cancel();
  }

  /// Generates a new JWT.
  Future<AuthResponse> _callRefreshToken(
    Completer<AuthResponse> completer, {
    String? refreshToken,
    String? accessToken,
  }) async {
    final token = refreshToken ?? currentSession?.refreshToken;
    if (token == null) {
      final error = AuthException('No current session.');
      completer.completeError(error, StackTrace.current);
      throw error;
    }

    final jwt = accessToken ?? currentSession?.accessToken;

    try {
      final body = {'refresh_token': token};
      if (jwt != null) {
        _headers['Authorization'] = 'Bearer $jwt';
      }
      final options = GotrueRequestOptions(
          headers: _headers,
          body: body,
          query: {'grant_type': 'refresh_token'});
      final response = await _fetch
          .request('$_url/token', RequestMethodType.post, options: options);
      final authResponse = AuthResponse.fromJson(response);

      if (authResponse.session == null) {
        final error = AuthException('Invalid session data.');
        completer.completeError(error, StackTrace.current);
        throw error;
      }
      _refreshTokenRetryCount = 0;

      _saveSession(authResponse.session!);
      _notifyAllSubscribers(AuthChangeEvent.tokenRefreshed);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);

      completer.complete(authResponse);
      return completer.future;
    } on SocketException {
      _setTokenRefreshTimer(
        Constants.retryInterval * pow(2, _refreshTokenRetryCount),
        completer,
        refreshToken: token,
        accessToken: accessToken,
      );
      return completer.future;
    } catch (error, stack) {
      completer.completeError(error, stack);
      return completer.future;
    }
  }

  void _notifyAllSubscribers(AuthChangeEvent event) {
    _onAuthStateChangeController.add(AuthState(event, currentSession));
  }
}
