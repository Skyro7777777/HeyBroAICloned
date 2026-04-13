import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'puter_client.dart';
import 'secure_storage.dart';
import 'screens/puter_auth_screen.dart';

/// Settings screen for Puter.js AI configuration.
/// Since Puter.js handles auth internally via JS SDK, this just shows
/// connection status and provides a sign-in/sign-out button.
class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  final PuterClient _puterClient = PuterClient();
  final SecureStorage _secureStorage = SecureStorage();

  bool _isSignedIn = false;
  bool _isTesting = false;
  String _statusMessage = '';
  Color _statusColor = Colors.grey;

  // Automation Settings
  String _automationMode = 'vision_a11y';
  bool _a11yOverlayEnabled = false;
  bool _hasOverlayPermission = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
    _checkOverlayPermission();
    _loadAutomationSettings();
  }

  Future<void> _checkStatus() async {
    await _secureStorage.initialize();
    final auth = await _secureStorage.getPuterAuthToken();
    setState(() {
      _isSignedIn = auth != null && auth.isNotEmpty;
    });
  }

  Future<void> _checkOverlayPermission() async {
    const channel = MethodChannel('com.vibeagent.dude/agent');
    try {
      final hasPermission =
          await channel.invokeMethod<bool>('checkOverlayPermission');
      setState(() {
        _hasOverlayPermission = hasPermission ?? false;
      });
    } catch (e) {
      debugPrint('Error checking overlay permission: $e');
    }
  }

  Future<void> _requestOverlayPermission() async {
    const channel = MethodChannel('com.vibeagent.dude/agent');
    try {
      await channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      _setStatus('Error requesting permission: $e', Colors.red);
    }
  }

  Future<void> _loadAutomationSettings() async {
    _automationMode = await _secureStorage.getAutomationMode();
    _a11yOverlayEnabled = await _secureStorage.isA11yOverlayEnabled();
    setState(() {});
  }

  void _setStatus(String message, Color color) {
    setState(() {
      _statusMessage = message;
      _statusColor = color;
    });
  }

  Future<void> _signIn() async {
    // Navigate to Puter auth screen (full browser) so user can sign in on puter.com
    _setStatus('Opening Puter sign-in page...', Colors.blue);

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (context) => const PuterAuthScreen()),
    );

    if (result == true) {
      // User completed sign-in in the browser, now refresh the hidden WebView
      _setStatus('Refreshing auth session...', Colors.orange);

      final authOk = await _puterClient.refreshAuth();
      if (authOk) {
        await _secureStorage.savePuterAuthToken('puter_js_authenticated');
        setState(() => _isSignedIn = true);
        _setStatus('Connected to Puter!', const Color(0xFF4CAF50));
      } else {
        _setStatus('Auth refresh failed. Try signing in again.', Colors.orange);
      }
    } else {
      _setStatus('Sign-in cancelled.', Colors.grey);
    }
  }

  Future<void> _signOut() async {
    await _puterClient.signOut();
    await _secureStorage.clearPuterConfiguration();
    setState(() => _isSignedIn = false);
    _setStatus('Signed out from Puter', Colors.orange);
  }

  Future<void> _testConnection() async {
    setState(() => _isTesting = true);
    _setStatus('Testing connection with gpt-5.4-nano...', Colors.blue);

    try {
      final success = await _puterClient.testConnection();
      if (success) {
        _setStatus('Connection successful! gpt-5.4-nano is ready.',
            const Color(0xFF4CAF50));
      } else {
        _setStatus('Test failed - AI did not respond correctly.', Colors.red);
      }
    } catch (e) {
      _setStatus('Test error: $e', Colors.red);
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _saveAutomationSettings() async {
    try {
      await _secureStorage.saveAutomationMode(_automationMode);
      await _secureStorage.saveA11yOverlayEnabled(_a11yOverlayEnabled);
      _setStatus('Automation settings saved!', const Color(0xFF4CAF50));
    } catch (e) {
      _setStatus('Error saving: $e', Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Color(0xFF2E7D32)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'AI Settings',
          style: TextStyle(
            color: Color(0xFF2E7D32),
            fontWeight: FontWeight.w700,
            fontSize: 24,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(isTablet ? 32 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Puter.js - Free AI',
              style: TextStyle(
                fontSize: isTablet ? 28 : 24,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1B5E20),
              ),
            ),
            SizedBox(height: isTablet ? 8 : 6),
            Text(
              'Uses gpt-5.4-nano via Puter.js. No API key needed.',
              style: TextStyle(
                fontSize: isTablet ? 16 : 14,
                color: Colors.grey[600],
              ),
            ),
            SizedBox(height: isTablet ? 40 : 32),

            // Auth Status Card
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _isSignedIn ? const Color(0xFF4CAF50) : Colors.orange,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
                color: _isSignedIn
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFFFF3E0),
              ),
              padding: EdgeInsets.all(isTablet ? 20 : 16),
              child: Row(
                children: [
                  Icon(
                    _isSignedIn ? Icons.check_circle : Icons.info_outline,
                    color:
                        _isSignedIn ? const Color(0xFF4CAF50) : Colors.orange,
                    size: isTablet ? 32 : 28,
                  ),
                  SizedBox(width: isTablet ? 16 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isSignedIn ? 'Connected to Puter' : 'Not signed in',
                          style: TextStyle(
                            fontSize: isTablet ? 18 : 16,
                            fontWeight: FontWeight.w600,
                            color: _isSignedIn
                                ? const Color(0xFF2E7D32)
                                : Colors.orange[800],
                          ),
                        ),
                        Text(
                          _isSignedIn
                              ? 'Model: gpt-5.4-nano (vision + text)'
                              : 'Tap below to sign in with Puter',
                          style: TextStyle(
                            fontSize: isTablet ? 14 : 13,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isSignedIn)
                    IconButton(
                      icon: const Icon(Icons.logout, color: Colors.red),
                      onPressed: _signOut,
                      tooltip: 'Sign out',
                    ),
                ],
              ),
            ),

            SizedBox(height: isTablet ? 16 : 12),

            // Sign In / Test buttons
            Row(
              children: [
                if (!_isSignedIn)
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _signIn,
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in to Puter'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: isTablet ? 24 : 16,
                          vertical: isTablet ? 16 : 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                if (_isSignedIn) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isTesting ? null : _testConnection,
                      icon: _isTesting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF4CAF50),
                              ),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label:
                          Text(_isTesting ? 'Testing...' : 'Test Connection'),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: const Color(0xFF4CAF50),
                        padding: EdgeInsets.symmetric(
                          horizontal: isTablet ? 24 : 16,
                          vertical: isTablet ? 16 : 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: const BorderSide(color: Color(0xFF4CAF50)),
                      ),
                    ),
                  ),
                ],
              ],
            ),

            SizedBox(height: isTablet ? 40 : 32),

            // Automation Settings
            Text(
              'Automation Settings',
              style: TextStyle(
                fontSize: isTablet ? 18 : 16,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF2E7D32),
              ),
            ),
            SizedBox(height: isTablet ? 12 : 8),

            DropdownButtonFormField<String>(
              value: _automationMode,
              decoration: InputDecoration(
                labelText: 'Automation Mode',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: isTablet ? 20 : 16,
                  vertical: isTablet ? 20 : 16,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'vision_a11y',
                  child: Text('Vision + Accessibility (Recommended)'),
                ),
                DropdownMenuItem(
                  value: 'a11y_only',
                  child: Text('Accessibility Only (Faster, No Vision)'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _automationMode = value);
                }
              },
            ),
            SizedBox(height: isTablet ? 16 : 12),

            Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE0E0E0)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text('Show Accessibility Overlay'),
                subtitle: Text(
                  _hasOverlayPermission
                      ? 'Draw boxes over detected elements'
                      : 'Requires "Display over other apps" permission',
                  style: TextStyle(
                    fontSize: 12,
                    color: _hasOverlayPermission ? null : Colors.orange,
                  ),
                ),
                value: _a11yOverlayEnabled,
                onChanged: (value) {
                  if (value && !_hasOverlayPermission) {
                    _requestOverlayPermission();
                  }
                  setState(() => _a11yOverlayEnabled = value);
                },
                activeTrackColor: const Color(0xFF4CAF50),
              ),
            ),

            SizedBox(height: isTablet ? 16 : 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saveAutomationSettings,
                icon: const Icon(Icons.save),
                label: const Text('Save Automation Settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(
                    horizontal: isTablet ? 24 : 16,
                    vertical: isTablet ? 16 : 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

            SizedBox(height: isTablet ? 32 : 24),

            // Status
            if (_statusMessage.isNotEmpty)
              Container(
                padding: EdgeInsets.all(isTablet ? 16 : 12),
                decoration: BoxDecoration(
                  color: _statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _statusColor.withOpacity(0.3)),
                ),
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _statusColor,
                    fontWeight: FontWeight.w500,
                    fontSize: isTablet ? 16 : 14,
                  ),
                ),
              ),

            SizedBox(height: isTablet ? 32 : 24),

            // Info
            Text(
              'About Puter.js',
              style: TextStyle(
                fontSize: isTablet ? 20 : 18,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1B5E20),
              ),
            ),
            SizedBox(height: isTablet ? 12 : 8),
            Text(
              'Puter.js provides free AI access through a JavaScript SDK loaded in a WebView. '
              'It uses gpt-5.4-nano which supports both text and vision (screenshots). '
              'No API keys needed - usage is billed to your free Puter account. '
              'Images are resized to 1080x1920 before sending to the AI.',
              style: TextStyle(
                fontSize: isTablet ? 14 : 13,
                color: Colors.grey[600],
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
