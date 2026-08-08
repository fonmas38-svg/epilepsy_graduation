import 'package:flutter/material.dart';

import '../core/enums.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label});

  final RiskLabel label;

  Color get _color => switch (label) {
        RiskLabel.stable => const Color(0xFF1B7F4E),
        RiskLabel.watch => const Color(0xFFB7791F),
        RiskLabel.highRisk => const Color(0xFFB42318),
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label.labelAr,
        style: TextStyle(color: _color, fontWeight: FontWeight.w700),
      ),
    );
  }
}
