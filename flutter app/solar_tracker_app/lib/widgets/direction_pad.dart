import 'package:flutter/material.dart';

import '../controllers/tracker_controller.dart';
import '../models/tracker_state.dart';

class DirectionPad extends StatelessWidget {
  const DirectionPad({super.key, required this.controller});
  final TrackerController controller;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(Direction.up, Icons.keyboard_arrow_up, 'Up'),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(Direction.left, Icons.keyboard_arrow_left, 'Left'),
            const SizedBox(
              width: 72,
              child: Icon(Icons.solar_power_outlined, color: Color(0xff687568)),
            ),
            _button(Direction.right, Icons.keyboard_arrow_right, 'Right'),
          ],
        ),
        const SizedBox(height: 8),
        _button(Direction.down, Icons.keyboard_arrow_down, 'Down'),
      ],
    ),
  );

  Widget _button(Direction direction, IconData icon, String label) {
    // Keep the gesture recognizer alive during an in-flight write. The
    // controller rejects extra sends but must still receive pointer-up.
    final enabled =
        controller.isConnected && controller.selectedMode == TrackerMode.manual;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? () => controller.nudge(direction) : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          key: ValueKey('direction-${direction.name}'),
          onTapDown: enabled ? (_) => controller.startHold(direction) : null,
          onTapUp: (_) => controller.stopHold(),
          onTapCancel: controller.stopHold,
          child: Material(
            color: enabled ? const Color(0xffdceedd) : const Color(0xffedf0ea),
            borderRadius: BorderRadius.circular(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 72,
                maxWidth: 72,
                minHeight: 64,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      color: enabled ? const Color(0xff175b36) : Colors.grey,
                    ),
                    Text(
                      label,
                      style: TextStyle(
                        color: enabled ? const Color(0xff175b36) : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
