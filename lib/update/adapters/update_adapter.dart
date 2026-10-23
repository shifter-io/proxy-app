import '../update_models.dart';

abstract class UpdateAdapter {
  Future<InstalledIdentity> identity();
  Future<UpdateCapabilities> capabilities();
  Future<bool> eligible(Release release, {required bool automatic});
  Future<void> prepare(Release release, String? path);
  Future<void> install(Release release, String? path, String operationId);
  Future<void> startStoreDownload(String operationId, Release release);
  Future<Map<String, dynamic>> reconcile();
  Future<void> openStore();
}
