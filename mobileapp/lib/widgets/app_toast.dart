import 'dart:async';

import 'package:flutter/material.dart';

/// Zeigt einen kurzen Toast statt einer SnackBar.
///
/// Liegt als `Overlay` über dem UI. Nur die kleine Toast-Pille selbst fängt
/// Taps ab — der restliche Screen (FABs, Tab-Leiste, Karte) bleibt bedienbar.
/// Ein **Tap auf die Pille blendet sie sofort aus** („wegklicken"); zusätzlich
/// verschwindet sie nach [duration] automatisch.
void showToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: message,
      duration: duration,
      onDismissed: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({
    required this.message,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  /// Blendet den Toast aus (Tap oder Timeout). Mehrfach-Aufrufe sind
  /// abgesichert, damit der OverlayEntry nicht doppelt entfernt wird.
  Future<void> _dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _timer?.cancel();
    await _fade.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 24,
      right: 24,
      // Über Tab-Leiste + FABs, damit der Toast nichts Wichtiges verdeckt.
      bottom: bottomInset + 96,
      child: FadeTransition(
        opacity: _fade,
        // Center begrenzt die Trefferfläche auf die Pille selbst — links und
        // rechts daneben bleiben Taps frei (nicht-blockierend). Ein Tap auf
        // die Pille schliesst sie sofort.
        child: Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
