/// Loads the stored services again — after a backup has been restored into
/// storage, the ones in memory still hold what was there before it.
class AppReloader {
  const AppReloader(this.reload);

  final Future<void> Function() reload;
}
