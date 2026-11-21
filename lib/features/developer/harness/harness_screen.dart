import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'credentials_form.dart';
import 'harness_controller.dart';
import 'qr_display.dart';

/// Temporary developer Test Harness screen (Task 05, D1–D5).
///
/// Shows the real provider's auth state, `my_id`, last error,
/// pending/unresolved indicators, send counts, and the sanitized
/// event log, and offers the Harness actions (authenticate, sign out,
/// dispose, create a new provider, reset the test session) plus the
/// debug-only reply-delay controls.
///
/// Temporary: removed after D1–D5 (with the delay hook and the send
/// counter). The screen never shows credentials, codes, passwords,
/// QR links as text, or the database encryption key.
final class HarnessScreen extends StatelessWidget {
  const HarnessScreen({super.key, required this.controller});

  final HarnessController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return Scaffold(
          appBar: AppBar(
            title: const Text('TeleManager Test Harness (Task 05)'),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section('State', [
                  Text('Auth: ${c.authState.runtimeType}'),
                  if (c.myId != null)
                    Text(
                      'my_id: ${c.myId} '
                      '(matches expected: ${c.myIdMatchesExpected ? 'yes' : 'no'})',
                    ),
                  if (c.lastError != null)
                    Text('Last error: ${c.lastError!.code}'),
                  Text(
                    'Provider: ${c.providerInitialized ? 'initialized' : 'not initialized'}',
                  ),
                  Text('Database key: ${c.keyStatus}'),
                  Text('Database: ${c.databaseDirectoryLabel}'),
                  Text(
                    'Credentials: ${c.credentialsSaved ? 'saved' : 'not saved'}',
                  ),
                ]),
                _section('Pending requests', [
                  Text(
                    'setTdlibParameters: pending '
                    '${c.pendingSetTdlibParameters ? 'yes' : 'no'}, '
                    'unresolved ${c.unresolvedSetTdlibParameters ? 'yes' : 'no'}',
                  ),
                  Text(
                    'logOut: pending ${c.pendingLogOut ? 'yes' : 'no'}, '
                    'unresolved ${c.unresolvedLogOut ? 'yes' : 'no'}',
                  ),
                  Text(
                    'Send counts: ${c.sendCounts.isEmpty ? 'none' : c.sendCounts.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
                  ),
                ]),
                if (c.lastActionResult != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Last action: ${c.lastActionResult}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                _section('Actions', [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: c.busy ? null : c.authenticate,
                        child: const Text('Authenticate'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy ? null : c.signOut,
                        child: const Text('Sign Out'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy ? null : c.disposeProvider,
                        child: const Text('Dispose Provider'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy ? null : c.createNewProvider,
                        child: const Text('Create New Provider'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy ? null : c.resetTestSession,
                        child: const Text('Reset Test Session'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy ? null : c.refreshPending,
                        child: const Text('Refresh'),
                      ),
                    ],
                  ),
                ]),
                _section('Reply delay (debug only)', [
                  const Text(
                    'D1: arm setTdlibParameters 15000ms. '
                    'D3: arm logOut 35000ms. Clear before D2/D4/D5.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: c.busy
                            ? null
                            : () =>
                                  c.setReplyDelay('setTdlibParameters', 15000),
                        child: const Text('Arm D1 (15s)'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy
                            ? null
                            : () => c.setReplyDelay('logOut', 35000),
                        child: const Text('Arm D3 (35s)'),
                      ),
                      ElevatedButton(
                        onPressed: c.busy ? null : c.clearReplyDelays,
                        child: const Text('Clear delays'),
                      ),
                    ],
                  ),
                ]),
                if (c.qrLink != null) ...[
                  const SizedBox(height: 12),
                  QrDisplay(link: c.qrLink),
                ],
                const SizedBox(height: 12),
                CredentialsForm(
                  credentialsSaved: c.credentialsSaved,
                  onSave: c.saveCredentials,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text(
                      'Event log',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: c.eventLog.toText()),
                        );
                      },
                      child: const Text('Copy log'),
                    ),
                    TextButton(
                      onPressed: c.clearLog,
                      child: const Text('Clear log'),
                    ),
                  ],
                ),
                Container(
                  height: 220,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: ListView.builder(
                    itemCount: c.eventLog.entries.length,
                    itemBuilder: (context, index) {
                      final entry = c.eventLog.entries[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Text(
                          entry.toString(),
                          style: const TextStyle(fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}
