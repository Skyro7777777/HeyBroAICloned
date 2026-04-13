import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../secure_storage.dart';

/// Puter authentication screen with built-in multi-tab browser.
/// Handles Puter.js sign-in flow and captures the auth token.
class PuterAuthScreen extends StatefulWidget {
  final VoidCallback? onAuthSuccess;

  const PuterAuthScreen({super.key, this.onAuthSuccess});

  @override
  State<PuterAuthScreen> createState() => _PuterAuthScreenState();
}

class _PuterAuthScreenState extends State<PuterAuthScreen>
    with TickerProviderStateMixin {
  late WebViewController _webViewController;
  final SecureStorage _secureStorage = SecureStorage();
  final List<_BrowserTab> _tabs = [];
  int _activeTabIndex = 0;
  bool _isLoading = true;
  String? _errorMessage;
  bool _authSuccess = false;
  String _url = '';
  bool _canGoBack = false;
  bool _canGoForward = false;

  // Progress controller for URL bar
  double _loadingProgress = 0;

  @override
  void initState() {
    super.initState();
    _initBrowser();
  }

  void _initBrowser() {
    // Create initial auth tab
    _tabs.add(_BrowserTab(
      title: 'Puter Sign In',
      url: 'https://puter.com',
      controller:
          _createWebViewController('https://puter.com', isAuthTab: true),
    ));

    // Set up Chrome-specific settings for better compatibility
    if (Platform.isAndroid) {
      AndroidWebViewController.enableDebugging(false);
    }

    _activeTabIndex = 0;
    _webViewController = _tabs.first.controller;
  }

  WebViewController _createWebViewController(String initialUrl,
      {bool isAuthTab = false}) {
    late final WebViewController controller;

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'PuterAuthChannel',
        onMessageReceived: (message) {
          try {
            final data = jsonDecode(message.message);
            if (data['type'] == 'auth_token' && data['token'] != null) {
              _handleAuthToken(
                data['token'] as String,
                source: data['source'] as String? ?? '',
              );
            }
          } catch (e) {
            print('[PuterAuth] Failed to parse JS message: $e');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            setState(() {
              _loadingProgress = progress / 100.0;
            });
          },
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              _url = url;
              _errorMessage = null;
            });
            _updateTabTitle(url);
          },
          onPageFinished: (url) async {
            setState(() {
              _isLoading = false;
              _loadingProgress = 1.0;
              _url = url;
            });

            // Check navigation state
            final canGoBack = await controller.canGoBack();
            final canGoForward = await controller.canGoForward();
            setState(() {
              _canGoBack = canGoBack;
              _canGoForward = canGoForward;
            });

            // On auth tab, inject JS to listen for Puter auth token
            if (isAuthTab) {
              _injectAuthListener(controller);
            }
          },
          onWebResourceError: (error) {
            setState(() {
              _isLoading = false;
              _errorMessage = 'Failed to load: ${error.description}';
            });
          },
          onNavigationRequest: (navigation) {
            return NavigationDecision.navigate;
          },
        ),
      )
      ..setBackgroundColor(const Color(0x00000000))
      ..loadRequest(Uri.parse(initialUrl));

    // Enable DOM storage and cookies for session persistence
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController)
          .setOnShowFileSelector((params) async => []);
    }

    return controller;
  }

  /// Inject JavaScript to intercept Puter auth token.
  /// Puter.js uses window.postMessage() after sign-in to pass the token.
  void _injectAuthListener(WebViewController controller) {
    // This JS listens for Puter's auth postMessage and calls our Dart channel
    controller.runJavaScript('''
      (function() {
        // Listen for Puter auth messages
        window.addEventListener('message', function(event) {
          if (event.data && event.data.token && event.data.success) {
            // Send token to Flutter via PuterAuthChannel
            if (window.PuterAuthChannel) {
              window.PuterAuthChannel.postMessage(JSON.stringify({
                type: 'auth_token',
                token: event.data.token,
                username: event.data.username || ''
              }));
            }
          }
        });

        // Also intercept XHR to capture auth token from API responses
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          if (name.toLowerCase() === 'authorization' && value.startsWith('Bearer ')) {
            if (window.PuterAuthChannel) {
              window.PuterAuthChannel.postMessage(JSON.stringify({
                type: 'auth_token',
                token: value.substring(7),
                source: 'xhr_header'
              }));
            }
          }
          return originalSetRequestHeader.call(this, name, value);
        };

        // Intercept fetch to capture auth tokens
        const originalFetch = window.fetch;
        window.fetch = function(input, init) {
          if (init && init.headers) {
            const headers = init.headers;
            if (headers['Authorization'] && headers['Authorization'].startsWith('Bearer ')) {
              if (window.PuterAuthChannel) {
                window.PuterAuthChannel.postMessage(JSON.stringify({
                  type: 'auth_token',
                  token: headers['Authorization'].substring(7),
                  source: 'fetch_header'
                }));
              }
            }
          }
          return originalFetch.apply(this, arguments);
        };

        // Check if puter.js is already loaded and user is already signed in
        setTimeout(function() {
          try {
            if (window.puter && window.puter.authToken) {
              if (window.PuterAuthChannel) {
                window.PuterAuthChannel.postMessage(JSON.stringify({
                  type: 'auth_token',
                  token: window.puter.authToken,
                  source: 'existing_session'
                }));
              }
            }
          } catch(e) {}
          // Also check localStorage/sessionStorage for Puter tokens
          try {
            var token = localStorage.getItem('puter-auth-token') ||
                        sessionStorage.getItem('puter-auth-token');
            if (token && window.PuterAuthChannel) {
              window.PuterAuthChannel.postMessage(JSON.stringify({
                type: 'auth_token',
                token: token,
                source: 'storage'
              }));
            }
          } catch(e) {}
        }, 3000);
      })();
    ''');
  }

  void _updateTabTitle(String url) {
    if (_activeTabIndex < _tabs.length) {
      String title = url;
      try {
        final uri = Uri.parse(url);
        title = uri.host;
        if (uri.path.isNotEmpty && uri.path != '/') {
          title += uri.path;
        }
      } catch (_) {}
      setState(() {
        _tabs[_activeTabIndex].title = title;
        _tabs[_activeTabIndex].url = url;
      });
    }
  }

  Future<void> _handleAuthToken(String token, {String source = ''}) async {
    if (_authSuccess || token.isEmpty) return;

    print('[PuterAuth] Token received (source: $source)');

    // Verify token by calling Puter /whoami endpoint
    try {
      final response = await http.get(
        Uri.parse('https://api.puter.com/whoami'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final userData = jsonDecode(response.body);
        final username = userData['username'] ?? 'unknown';
        print('[PuterAuth] Token verified for user: $username');

        // Save token to secure storage (as marker)
        await _secureStorage.savePuterAuthToken(token);
        setState(() {
          _authSuccess = true;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Puter authenticated as $username!'),
              backgroundColor: const Color(0xFF4CAF50),
            ),
          );

          // Wait a moment then navigate back
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) {
              widget.onAuthSuccess?.call();
              Navigator.of(context).pop(true);
            }
          });
        }
      } else {
        print('[PuterAuth] Token verification failed: ${response.statusCode}');
      }
    } catch (e) {
      print('[PuterAuth] Token verification error: $e');
    }
  }

  void _addNewTab() {
    final controller = _createWebViewController('https://www.google.com');
    setState(() {
      _tabs.add(_BrowserTab(
        title: 'New Tab',
        url: 'https://www.google.com',
        controller: controller,
      ));
      _activeTabIndex = _tabs.length - 1;
      _webViewController = controller;
    });
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) return; // Keep at least one tab
    setState(() {
      _tabs[index].dispose();
      _tabs.removeAt(index);
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      }
      if (_activeTabIndex == index && _activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      }
      _webViewController = _tabs[_activeTabIndex].controller;
    });
  }

  void _switchToTab(int index) {
    if (index == _activeTabIndex || index >= _tabs.length) return;
    setState(() {
      _activeTabIndex = index;
      _webViewController = _tabs[index].controller;
      _url = _tabs[index].url;
    });
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Puter Authentication',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        actions: [
          // Navigation buttons
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: _canGoBack ? () => _webViewController.goBack() : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios, size: 18),
            onPressed:
                _canGoForward ? () => _webViewController.goForward() : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () => _webViewController.reload(),
          ),
          const SizedBox(width: 8),
        ],
        bottom: _buildTabBar(),
      ),
      body: Column(
        children: [
          // URL bar
          _buildUrlBar(),
          // Loading progress
          if (_isLoading && _loadingProgress < 1.0)
            LinearProgressIndicator(
              value: _loadingProgress,
              backgroundColor: Colors.grey[800],
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
            ),
          // Auth success indicator
          if (_authSuccess)
            Container(
              color: const Color(0xFF4CAF50),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Authenticated successfully!',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          // WebView
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _webViewController),
                if (_errorMessage != null) _buildErrorOverlay(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildTabBar() {
    if (_tabs.length <= 1)
      return const PreferredSize(
          preferredSize: Size.zero, child: SizedBox.shrink());

    return PreferredSize(
      preferredSize: const Size.fromHeight(40),
      child: Container(
        height: 40,
        color: const Color(0xFF16213E),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          itemCount: _tabs.length + 1, // +1 for new tab button
          itemBuilder: (context, index) {
            if (index == _tabs.length) {
              // New tab button
              return InkWell(
                onTap: _addNewTab,
                child: Container(
                  width: 36,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.add, color: Colors.white70, size: 18),
                ),
              );
            }

            final tab = _tabs[index];
            final isActive = index == _activeTabIndex;

            return InkWell(
              onTap: () => _switchToTab(index),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: isActive ? const Color(0xFF1A1A2E) : Colors.grey[800],
                  borderRadius: BorderRadius.circular(6),
                  border: isActive
                      ? Border.all(color: const Color(0xFF4CAF50), width: 1)
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.public,
                      size: 14,
                      color:
                          isActive ? const Color(0xFF4CAF50) : Colors.white54,
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        tab.title,
                        style: TextStyle(
                          fontSize: 12,
                          color: isActive ? Colors.white : Colors.white70,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_tabs.length > 1) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => _closeTab(index),
                        child: const Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildUrlBar() {
    return Container(
      color: const Color(0xFF0F3460),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            _isLoading ? Icons.hourglass_empty : Icons.lock,
            size: 16,
            color: Colors.white54,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _url,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              setState(() => _errorMessage = null);
              _webViewController.reload();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      color: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Sign in to Puter to use free AI models. Your usage is billed to your Puter account.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () {
              // Navigate to Puter sign-in page
              _webViewController.loadRequest(
                Uri.parse('https://puter.com?action=sign-in'),
              );
            },
            icon: const Icon(Icons.login, size: 16),
            label: const Text('Sign In', style: TextStyle(fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4CAF50),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

/// Simple browser tab model
class _BrowserTab {
  String title;
  String url;
  final WebViewController controller;

  _BrowserTab({
    required this.title,
    required this.url,
    required this.controller,
  });

  void dispose() {
    // WebViewController doesn't have a dispose method in webview_flutter 4.x
    // The platform handles cleanup
  }
}
