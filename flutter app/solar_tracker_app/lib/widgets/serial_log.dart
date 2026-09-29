import 'package:flutter/material.dart';

import '../models/tracker_state.dart';

class SerialLog extends StatefulWidget {
  const SerialLog({
    super.key,
    required this.entries,
    required this.onClear,
    this.initiallyExpanded = false,
  });
  final bool initiallyExpanded;
  final List<LogEntry> entries;
  final VoidCallback onClear;
  @override
  State<SerialLog> createState() => _SerialLogState();
}

class _SerialLogState extends State<SerialLog> {
  final _scroll = ScrollController();
  @override
  void didUpdateWidget(covariant SerialLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        widget.entries.isNotEmpty &&
        (oldWidget.entries.isEmpty ||
            !identical(widget.entries.last, oldWidget.entries.last));
    if (changed && (!_scroll.hasClients || _scroll.position.extentAfter < 48)) {
      _scrollToEnd();
    }
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      initiallyExpanded: widget.initiallyExpanded,
      title: const Text('Serial monitor'),
      subtitle: Text('${widget.entries.length} / 200 lines'),
      onExpansionChanged: (expanded) {
        if (expanded) _scrollToEnd();
      },
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: widget.onClear,
            icon: const Icon(Icons.clear_all),
            label: const Text('Clear'),
          ),
        ),
        Container(
          height: 220,
          decoration: BoxDecoration(
            color: const Color(0xffeef2ec),
            borderRadius: BorderRadius.circular(12),
          ),
          child: widget.entries.isEmpty
              ? const Center(
                  child: Text('Received lines and sent commands appear here.'),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: widget.entries.length,
                  itemBuilder: (context, index) {
                    final entry = widget.entries[index];
                    final time =
                        '${entry.time.hour.toString().padLeft(2, '0')}:${entry.time.minute.toString().padLeft(2, '0')}:${entry.time.second.toString().padLeft(2, '0')}';
                    return Text(
                      '$time ${entry.outgoing ? 'TX' : 'RX'} ${entry.text}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
