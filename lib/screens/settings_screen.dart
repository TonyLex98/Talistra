import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:provider/provider.dart';

import '../models/app_language.dart';
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
  bool _busy = false;
  bool _downloading = false;
  int _elapsedSeconds = 0;
  Timer? _ticker;

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

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final downloaded = await widget.translation.isModelDownloaded(widget.language);
    if (mounted) setState(() => _downloaded = downloaded);
  }

  Future<void> _toggle() async {
    final wasDownloaded = _downloaded == true;
    setState(() {
      _busy = true;
      _downloading = !wasDownloaded;
      _elapsedSeconds = 0;
    });
    if (_downloading) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
    }
    try {
      if (wasDownloaded) {
        await widget.translation.deleteModel(widget.language);
      } else {
        await widget.translation.downloadModel(widget.language);
      }
      await _refresh();
    } finally {
      _ticker?.cancel();
      if (mounted) setState(() => _busy = _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const SizedBox(width: 22),
      title: Text('Модель: ${widget.appLanguage.displayName}'),
      subtitle: Text(
        _downloading
            ? 'Загрузка... $_elapsedSeconds с'
            : _downloaded == null
            ? 'Проверка...'
            : (_downloaded! ? 'Скачана, доступна офлайн' : 'Не скачана'),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _downloaded == null ? null : _toggle,
              child: Text(_downloaded == true ? 'Удалить' : 'Скачать'),
            ),
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

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        'TransRead — читалка PDF со встроенным переводом слов на устройстве. '
        'Выделите слово или фразу долгим нажатием, чтобы увидеть перевод.',
      ),
    );
  }
}
