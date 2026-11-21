import 'package:material_ui/material_ui.dart';

import '../../../providers/provider_error.dart';
import 'harness_controller.dart';
import 'harness_screen.dart';

/// Entry page for the temporary Test Harness (Task 05, D1–D5).
///
/// Creates the real [HarnessController] asynchronously (it reads the
/// no-backup directory and initializes the provider), shows a loading
/// indicator meanwhile, and disposes the controller when popped.
/// Only reachable in debug builds (see the kDebugMode entry in
/// main.dart). Temporary: removed with the Harness.
///
/// The failure message shows only an error code/type, never a secret.
class HarnessEntryPage extends StatefulWidget {
  const HarnessEntryPage({super.key});

  @override
  State<HarnessEntryPage> createState() => _HarnessEntryPageState();
}

class _HarnessEntryPageState extends State<HarnessEntryPage> {
  HarnessController? _controller;
  String? _errorLabel;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    try {
      final controller = await HarnessController.create();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorLabel = e is ProviderError
            ? e.code
            : e.runtimeType.toString(),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_errorLabel != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Test Harness')),
        body: Center(child: Text('Failed to start the Harness: $_errorLabel')),
      );
    }
    if (controller == null) {
      // No `const`: AppBar is not a const constructor in Flutter 3.50.
      return Scaffold(
        appBar: AppBar(title: Text('Test Harness')),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return HarnessScreen(controller: controller);
  }
}
