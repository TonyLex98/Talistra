import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:provider/provider.dart';

import '../models/app_language.dart';
import '../services/model_download_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../widgets/language_picker_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          _SectionHeader('Перевод'),
          _LanguageSection(),
          Divider(height: 32),
          _SectionHeader('Оформление'),
          _ThemeSection(),
          SizedBox(height: 16),
          _ReadingThemeSection(),
          Divider(height: 32),
          _SectionHeader('О приложении'),
          _AboutSection(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LanguageSection extends StatelessWidget {
  const _LanguageSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final translation = context.read<TranslationService>();

    return Column(
      children: [
        ListTile(
          leading: Text(settings.sourceAppLanguage.flag, style: const TextStyle(fontSize: 22)),
          title: const Text('Язык оригинала'),
          subtitle: Text(settings.sourceAppLanguage.displayName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showLanguagePicker(
              context: context,
              current: settings.sourceLanguage,
              title: 'С какого языка переводить',
            );
            if (picked != null) settings.setSourceLanguage(picked);
          },
        ),
        Center(
          child: IconButton.filledTonal(
            icon: const Icon(Icons.swap_vert),
            tooltip: 'Поменять языки местами',
            onPressed: settings.swapLanguages,
          ),
        ),
        ListTile(
          leading: Text(settings.targetAppLanguage.flag, style: const TextStyle(fontSize: 22)),
          title: const Text('Язык перевода'),
          subtitle: Text(settings.targetAppLanguage.displayName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showLanguagePicker(
              context: context,
              current: settings.targetLanguage,
              title: 'На какой язык переводить',
            );
            if (picked != null) settings.setTargetLanguage(picked);
          },
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Перевод выполняется прямо на устройстве — офлайн-модели для выбранных языков '
            'скачиваются один раз и не требуют интернета при чтении.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _ModelStatusTile(
          language: settings.sourceLanguage,
          appLanguage: settings.sourceAppLanguage,
          translation: translation,
        ),
        _ModelStatusTile(
          language: settings.targetLanguage,
          appLanguage: settings.targetAppLanguage,
          translation: translation,
        ),
      ],
    );
  }
}

class _ModelStatusTile extends StatefulWidget {
  const _ModelStatusTile({
    required this.language,
    required this.appLanguage,
    required this.translation,
  });

  final TranslateLanguage language;
  final AppLanguage appLanguage;
  final TranslationService translation;

  @override
  State<_ModelStatusTile> createState() => _ModelStatusTileState();
}

class _ModelStatusTileState extends State<_ModelStatusTile> {
  bool? _downloaded;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _ModelStatusTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) _refresh();
  }

  Future<void> _refresh() async {
    final downloaded = await widget.translation.isModelDownloaded(widget.language);
    if (mounted) setState(() => _downloaded = downloaded);
  }

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      await widget.translation.deleteModel(widget.language);
      await _refresh();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<ModelDownloadService>();
    final isDownloadingThis = downloadService.isDownloadingLanguage(widget.language);

    String subtitle;
    if (isDownloadingThis) {
      subtitle = 'Загрузка... ${downloadService.elapsedSeconds} с';
    } else if (_downloaded == null) {
      subtitle = 'Проверка...';
    } else {
      subtitle = _downloaded! ? 'Скачана, доступна офлайн' : 'Не скачана';
    }

    Widget trailing;
    if (isDownloadingThis || _deleting) {
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      trailing = TextButton(
        onPressed: _downloaded == null || downloadService.isDownloading
            ? null
            : (_downloaded == true ? _delete : () => downloadService.download(widget.language).then((_) => _refresh())),
        child: Text(_downloaded == true ? 'Удалить' : 'Скачать'),
      );
    }

    return ListTile(
      dense: true,
      leading: const SizedBox(width: 22),
      title: Text('Модель: ${widget.appLanguage.displayName}'),
      subtitle: Text(subtitle),
      trailing: trailing,
    );
  }
}

class _ThemeSection extends StatelessWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(value: ThemeMode.system, label: Text('Системная'), icon: Icon(Icons.brightness_auto)),
          ButtonSegment(value: ThemeMode.light, label: Text('Светлая'), icon: Icon(Icons.light_mode)),
          ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная'), icon: Icon(Icons.dark_mode)),
        ],
        selected: {settings.themeMode},
        onSelectionChanged: (selection) => settings.setThemeMode(selection.first),
      ),
    );
  }
}

class _ReadingThemeSection extends StatelessWidget {
  const _ReadingThemeSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Фон адаптивного режима',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ReadingTheme>(
            segments: [
              for (final theme in ReadingTheme.values)
                ButtonSegment(value: theme, label: Text(theme.label)),
            ],
            selected: {settings.readingTheme},
            onSelectionChanged: (selection) => settings.setReadingTheme(selection.first),
          ),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        'TransRead — читалка PDF со встроенным переводом слов на устройстве. '
        'Нажмите на слово при чтении, чтобы увидеть перевод.',
      ),
    );
  }
}
