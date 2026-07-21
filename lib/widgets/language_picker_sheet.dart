import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../models/app_language.dart';

/// Opens a searchable bottom sheet listing every language ML Kit supports
/// and returns the one the user picked, or null if they dismissed it.
Future<TranslateLanguage?> showLanguagePicker({
  required BuildContext context,
  required TranslateLanguage current,
  required String title,
}) {
  return showModalBottomSheet<TranslateLanguage>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _LanguagePickerSheet(current: current, title: title),
  );
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet({required this.current, required this.title});

  final TranslateLanguage current;
  final String title;

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final languages = AppLanguage.all
        .where((l) => l.displayName.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                autofocus: false,
                decoration: InputDecoration(
                  hintText: 'Поиск языка',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: languages.length,
                itemBuilder: (ctx, i) {
                  final lang = languages[i];
                  final selected = lang.language == widget.current;
                  return ListTile(
                    leading: Text(lang.flag, style: const TextStyle(fontSize: 22)),
                    title: Text(lang.displayName),
                    trailing: selected
                        ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () => Navigator.pop(context, lang.language),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
