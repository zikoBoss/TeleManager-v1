import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Renders the QR login code for the second device to scan.
///
/// The link is a login token: it is rendered as a QR image only, never
/// shown as text, never logged, and never copied. The widget shows
/// nothing when [link] is null.
class QrDisplay extends StatelessWidget {
  const QrDisplay({super.key, required this.link});

  /// The Telegram login link (in-memory only).
  final String? link;

  @override
  Widget build(BuildContext context) {
    final link = this.link;
    if (link == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Scan with Telegram on a second device',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        QrImageView(
          data: link,
          version: QrVersions.auto,
          size: 220,
          backgroundColor: Colors.white,
        ),
        const SizedBox(height: 8),
        const Text(
          'Do not share this code. It is a login token.',
          style: TextStyle(color: Colors.red),
        ),
      ],
    );
  }
}
