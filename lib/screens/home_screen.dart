import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../widgets/document_tile.dart';
import '../widgets/model_suggestion_card.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _importing = false;
  List<TranslateLanguage> _missingModels = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkMissingModels());
  }

  Future<void> _checkMissingModels() async {
    final settings = context.read<SettingsService>();
    final translation = context.read<TranslationService>();
    final missing = await translation.missingModels(
      settings.sourceLanguage,
      settings.targetLanguage,
    );
    if (mounted) setState(() => _missingModels = missing);
  }

  Future<void> _importPdf() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: false,
    );
    final picked = result?.files.single;
    if (picked?.path == null) return;
    if (!mounted) return;

    setState(() => _importing = true);
    try {
      final library = context.read<LibraryService>();
      final title = p.basenameWithoutExtension(picked!.name);
      final document = await library.importPdf(
        sourcePath: picked.path!,
        title: title,
      );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(documentId: document.id)),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final documents = library.documents;
    final translationService = context.read<TranslationService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('TransRead'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Настройки',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_missingModels.isNotEmpty)
            ModelSuggestionCard(
              key: ValueKey(_missingModels.join(',')),
              languages: _missingModels,
              translationService: translationService,
              onDone: _checkMissingModels,
            ),
          Expanded(
            child: documents.isEmpty ? _buildEmptyState(context) : _buildList(documents),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _importPdf,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_importing ? 'Добавление...' : 'Добавить PDF'),
      ),
    );
  }

  Widget _buildList(List<LibraryDocument> documents) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final doc = documents[index];
        return DocumentTile(
          document: doc,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ReaderScreen(documentId: doc.id)),
          ),
          onDelete: () => context.read<LibraryService>().remove(doc.id),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_rounded, size: 72, color: scheme.primary),
            const SizedBox(height: 20),
            Text(
              'Ваша библиотека пуста',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Добавьте PDF-файл, чтобы начать читать и переводить слова одним нажатием.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
