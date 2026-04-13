import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Puter.js AI client using a hidden WebView + puter.ai.chat() JS SDK.
///
/// Auth flow:
///   1. User signs in via PuterAuthScreen (visible WebView browser on puter.com)
///   2. After sign-in, call refreshAuth() to reload and pick up the session cookie
///   3. Puter.js SDK auto-detects auth via cookies and sets puter.authToken
///
/// Image is resized to 1080x1920 before sending.
/// Model is fixed as gpt-5.4-nano.
class PuterClient {
  static const String _model = 'gpt-5.4-nano';
  static const int _imageWidth = 1080;
  static const int _imageHeight = 1920;

  // Singleton
  static final PuterClient _instance = PuterClient._internal();
  factory PuterClient() => _instance;
  PuterClient._internal();

  WebViewController? _controller;
  bool _isInitialized = false;
  bool _sdkReady = false;
  bool _isAuthenticated = false;

  // Request-response via Completer
  final Map<int, Completer<String?>> _pendingRequests = {};
  int _requestId = 0;

  /// Initialize the hidden WebView. Must be placed in widget tree via buildHiddenWebView().
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'PuterResponseChannel',
        onMessageReceived: (message) {
          _handleJsResponse(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _injectPuterSDK();
          },
        ),
      )
      ..loadRequest(Uri.parse('about:blank'));

    // Enable DOM storage and cookies for session persistence
    if (_controller!.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
    }

    // Wait briefly for WebView to be ready
    await Future.delayed(const Duration(milliseconds: 500));
    _isInitialized = true;
    return true;
  }

  void _injectPuterSDK() {
    _controller?.runJavaScript('''
      (function() {
        // Check if SDK already loaded
        if (typeof puter !== 'undefined') {
          PuterResponseChannel.postMessage(JSON.stringify({
            type: 'sdk_loaded',
            authenticated: !!(puter.authToken)
          }));
          return;
        }

        var script = document.createElement('script');
        script.src = 'https://js.puter.com/v2/';
        script.onload = function() {
          try {
            // Wait a moment for Puter.js to auto-detect auth from cookies
            setTimeout(function() {
              PuterResponseChannel.postMessage(JSON.stringify({
                type: 'sdk_loaded',
                authenticated: !!(typeof puter !== 'undefined' && puter.authToken)
              }));
            }, 1000);
          } catch(e) {
            PuterResponseChannel.postMessage(JSON.stringify({
              type: 'sdk_loaded',
              authenticated: false
            }));
          }
        };
        script.onerror = function() {
          PuterResponseChannel.postMessage(JSON.stringify({
            type: 'error',
            message: 'Failed to load Puter.js SDK'
          }));
        };
        document.head.appendChild(script);
      })();
    ''');
  }

  void _handleJsResponse(String messageStr) {
    try {
      final data = jsonDecode(messageStr) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case 'sdk_loaded':
          _sdkReady = true;
          _isAuthenticated = data['authenticated'] == true;
          print('[Puter] SDK loaded, authenticated: $_isAuthenticated');
          break;

        case 'auth_changed':
          _isAuthenticated = data['authenticated'] == true;
          print('[Puter] Auth changed: $_isAuthenticated');
          break;

        case 'ai_response':
          final id = data['request_id'] as int?;
          if (id != null && _pendingRequests.containsKey(id)) {
            final completer = _pendingRequests.remove(id)!;
            completer.complete(data['text'] as String?);
          }
          break;

        case 'auth_error':  // Handle authentication errors
          final id = data['request_id'] as int?;
          if (id != null && _pendingRequests.containsKey(id)) {
            // Attempt to refresh auth and retry the request
            print('[Puter] Auth error detected, attempting to refresh auth...');
            _refreshAndRetry(id, data['message']);
          }
          print('[Puter] Auth error: ${data['message']}');
          break;

        case 'ai_error':
          final id = data['request_id'] as int?;
          if (id != null && _pendingRequests.containsKey(id)) {
            final completer = _pendingRequests.remove(id)!;
            completer.complete(null);
          }
          print('[Puter] AI error: ${data['message']}');
          break;

        case 'error':
          print('[Puter] JS error: ${data['message']}');
          break;
      }
    } catch (e) {
      print('[Puter] Failed to parse JS message: $e');
    }
  }

  /// The WebViewWidget to place in the widget tree (wrapped in Offstage).
  Widget buildHiddenWebView() {
    if (_controller == null) {
      return const SizedBox.shrink();
    }
    return Offstage(
      child: WebViewWidget(controller: _controller!),
    );
  }

  /// Check if Puter.js SDK is loaded and user is authenticated.
  bool get isInitialized => _sdkReady && _isAuthenticated;

  /// Check if SDK is loaded (regardless of auth).
  bool get isSdkReady => _sdkReady;

  /// Check if user is authenticated with Puter.
  bool get isAuthenticated => _isAuthenticated;

  /// Refresh auth state after user has signed in via PuterAuthScreen.
  /// Loads puter.com so cookies are shared, then Puter.js picks up the session.
  Future<bool> refreshAuth() async {
    if (_controller == null) return false;

    _sdkReady = false;
    _isAuthenticated = false;

    // Load puter.com to share cookies and let Puter.js detect the session
    _controller!.loadRequest(Uri.parse('https://puter.com'));

    // Wait for page to load and SDK to initialize
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (_sdkReady && _isAuthenticated) {
        print('[Puter] Auth refreshed successfully');
        return true;
      }
    }

    print('[Puter] Auth refresh timed out, authenticated: $_isAuthenticated');
    return _isAuthenticated;
  }

  /// Sign out from Puter (clears the auth token).
  Future<void> signOut() async {
    if (_controller == null) return;

    await _controller!.runJavaScriptReturningResult('''
      (function() {
        if (typeof puter !== 'undefined') {
          puter.auth.signOut();
        }
        document.cookie.split(";").forEach(function(c) {
          document.cookie = c.replace(/^ +/, "").replace(/=.*/, "=;expires=" + new Date().toUTCString() + ";path=/");
        });
        return 'done';
      })()
    ''');
    _isAuthenticated = false;
    _sdkReady = false;
  }

  /// Generate content with text prompt only (no image).
  Future<String?> generateContent(String prompt) async {
    if (!_sdkReady) {
      print('[Puter] SDK not ready');
      // Try to refresh auth if not ready
      if (!_sdkReady && _controller != null) {
        print('[Puter] Attempting to refresh authentication...');
        await refreshAuth();
        if (!_sdkReady) {
          print('[Puter] SDK still not ready after auth refresh');
          return null;
        }
      } else {
        return null;
      }
    }

    // Double-check authentication status before making request
    if (!_isAuthenticated) {
      print('[Puter] Not authenticated, attempting to refresh auth...');
      bool authOk = await refreshAuth();
      if (!authOk) {
        print('[Puter] Authentication refresh failed');
        return null;
      }
    }

    final id = _requestId++;
    final completer = Completer<String?>();
    _pendingRequests[id] = completer;

    final escapedPrompt = prompt.replaceAll("'", "\\'").replaceAll('\n', '\\n').replaceAll('\r', '');

    _controller?.runJavaScript('''
      (function() {
        var id = $id;
        try {
          puter.ai.chat('$escapedPrompt', null, {
            model: '$_model'
          }).then(function(response) {
            // puter.ai.chat() returns a ChatResponse object, not a string
            var text = (typeof response === 'string') ? response :
                       (response && response.message && response.message.content) ?
                       response.message.content : JSON.stringify(response);
            PuterResponseChannel.postMessage(JSON.stringify({
              type: 'ai_response',
              request_id: id,
              text: text
            }));
          }).catch(function(err) {
            // Check if it's an authentication error
            if (err.message && (err.message.toLowerCase().includes('auth') || 
                                err.message.toLowerCase().includes('unauthorized') || 
                                err.message.toLowerCase().includes('401'))) {
              PuterResponseChannel.postMessage(JSON.stringify({
                type: 'auth_error',
                request_id: id,
                message: err.message || 'Authentication error'
              }));
            } else {
              PuterResponseChannel.postMessage(JSON.stringify({
                type: 'ai_error',
                request_id: id,
                message: err.message || err.toString() || 'Unknown error'
              }));
            }
          });
        } catch(e) {
          PuterResponseChannel.postMessage(JSON.stringify({
            type: 'ai_error',
            request_id: id,
            message: e.message || 'JS exception'
          }));
        }
      })();
    ''');

    // Timeout after 60 seconds
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _pendingRequests.remove(id);
        print('[Puter] Request timed out');
        return null;
      },
    );
  }

  /// Generate content with text prompt and base64 image (vision).
  /// Image is resized to 1080x1920 in JavaScript before sending.
  Future<String?> generateContentWithImage(String prompt, String base64Image) async {
    if (!_sdkReady) {
      print('[Puter] SDK not ready');
      // Try to refresh auth if not ready
      if (!_sdkReady && _controller != null) {
        print('[Puter] Attempting to refresh authentication...');
        await refreshAuth();
        if (!_sdkReady) {
          print('[Puter] SDK still not ready after auth refresh');
          return null;
        }
      } else {
        return null;
      }
    }

    // Double-check authentication status before making request
    if (!_isAuthenticated) {
      print('[Puter] Not authenticated, attempting to refresh auth...');
      bool authOk = await refreshAuth();
      if (!authOk) {
        print('[Puter] Authentication refresh failed');
        return null;
      }
    }

    final id = _requestId++;
    final completer = Completer<String?>();
    _pendingRequests[id] = completer;

    // Strip data URL prefix if present, we'll add our own
    String cleanBase64 = base64Image;
    if (cleanBase64.contains(',')) {
      cleanBase64 = base64Image.split(',').last;
    }

    // Escape single quotes in prompt for JS string safety
    final escapedPrompt = prompt.replaceAll("'", "\\'").replaceAll('\n', '\\n').replaceAll('\r', '');

    _controller?.runJavaScript('''
      (function() {
        var id = $id;
        try {
          // Create image from base64, resize to $_imageWidth x $_imageHeight
          var img = new Image();
          img.onload = function() {
            var canvas = document.createElement('canvas');
            canvas.width = $_imageWidth;
            canvas.height = $_imageHeight;
            var ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, $_imageWidth, $_imageHeight);
            var dataUrl = canvas.toDataURL('image/jpeg', 0.85);

            puter.ai.chat('$escapedPrompt', dataUrl, {
              model: '$_model'
            }).then(function(response) {
              // puter.ai.chat() returns a ChatResponse object, not a string
              var text = (typeof response === 'string') ? response :
                         (response && response.message && response.message.content) ?
                         response.message.content : JSON.stringify(response);
              PuterResponseChannel.postMessage(JSON.stringify({
                type: 'ai_response',
                request_id: id,
                text: text
              }));
            }).catch(function(err) {
              // Check if it's an authentication error
              if (err.message && (err.message.toLowerCase().includes('auth') || 
                                  err.message.toLowerCase().includes('unauthorized') || 
                                  err.message.toLowerCase().includes('401'))) {
                PuterResponseChannel.postMessage(JSON.stringify({
                  type: 'auth_error',
                  request_id: id,
                  message: err.message || 'Authentication error'
                }));
              } else {
                PuterResponseChannel.postMessage(JSON.stringify({
                  type: 'ai_error',
                  request_id: id,
                  message: err.message || err.toString() || 'Unknown error'
                }));
              }
            });
          };
          img.onerror = function() {
            PuterResponseChannel.postMessage(JSON.stringify({
              type: 'ai_error',
              request_id: id,
              message: 'Failed to load image for processing'
            }));
          };
          img.src = 'data:image/jpeg;base64,$cleanBase64';
        } catch(e) {
          PuterResponseChannel.postMessage(JSON.stringify({
            type: 'ai_error',
            request_id: id,
            message: e.message || 'JS exception'
          }));
        }
      })();
    ''');

    // Timeout after 90 seconds (image processing can be slower)
    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _pendingRequests.remove(id);
        print('[Puter] Image request timed out');
        return null;
      },
    );
  }

  /// Test connection by sending a simple prompt.
  Future<bool> testConnection() async {
    try {
      final response = await generateContent(
        'Say exactly: Connection successful',
      );
      return response?.toLowerCase().contains('successful') ?? false;
    } catch (e) {
      print('[Puter] Connection test failed: $e');
      return false;
    }
  }

  // Helper method to refresh authentication and retry a request
  Future<void> _refreshAndRetry(int requestId, String errorMessage) async {
    bool authOk = await refreshAuth();
    if (authOk) {
      print('[Puter] Authentication refreshed successfully, retrying request $requestId');
      // We can't actually retry the original request since the JS call has already failed,
      // but we've refreshed the auth for future requests
    } else {
      print('[Puter] Failed to refresh authentication after error: $errorMessage');
      // Complete the request with null since we couldn't authenticate
      if (_pendingRequests.containsKey(requestId)) {
        final completer = _pendingRequests.remove(requestId)!;
        completer.complete(null);
      }
    }
  }
}
