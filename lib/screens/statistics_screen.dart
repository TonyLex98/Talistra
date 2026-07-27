import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/library_service.dart';
import '../services/statistics_service.dart';

class StatisticsScreen extends StatelessWidget {
  const StatisticsScreen({super.key});

  String _formatDuration(int totalSeconds, AppLocalizations l10n) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    if (hours > 0) return l10n.durationHoursMinutes(hours, minutes);
    if (minutes > 0) return l10n.durationMinutes(minutes);
    return l10n.durationSeconds(totalSeconds);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stats = context.watch<StatisticsService>();
    final library = context.watch<LibraryService>();
    final scheme = Theme.of(context).colorScheme;

    final byDocument = stats.byDocument;
    final byDay = stats.byDay;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.statisticsScreenTitle)),
      body: byDocument.isEmpty && byDay.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.statisticsEmpty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  l10n.statisticsByDay,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                for (final entry in byDay)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: Text(_formatDay(entry.day)),
                    subtitle: Text(l10n.statisticsPagesShort(entry.pages)),
                    trailing: Text(_formatDuration(entry.seconds, l10n)),
                  ),
                if (byDocument.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    l10n.statisticsByBook,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final entry in byDocument)
                    Builder(
                      builder: (context) {
                        final title = library.documents
                            .where((d) => d.id == entry.documentId)
                            .map((d) => d.title)
                            .cast<String?>()
                            .firstWhere((_) => true, orElse: () => null);
                        if (title == null) return const SizedBox.shrink();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.book_outlined),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            l10n.statisticsPagesShort(entry.pages),
                          ),
                          trailing: Text(_formatDuration(entry.seconds, l10n)),
                        );
                      },
                    ),
                ],
                const SizedBox(height: 20),
                Text(
                  l10n.statisticsNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  String _formatDay(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final value = DateTime(day.year, day.month, day.day);
    final difference = today.difference(value).inDays;
    if (difference == 0) return 'Сегодня';
    if (difference == 1) return 'Вчера';
    return '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';
  }
}
