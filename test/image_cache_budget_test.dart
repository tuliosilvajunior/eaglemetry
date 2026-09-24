import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/image_cache_budget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applyImageCacheBudget caps the process cache', () {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = 100 * 1024 * 1024;
    cache.maximumSize = 1000;

    applyImageCacheBudget();

    expect(cache.maximumSizeBytes, kImageCacheMaxBytes);
    expect(cache.maximumSize, kImageCacheMaxImages);
  });

  test('evictMapImageCache drops live and pending images', () {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    expect(cache.currentSize, 0);

    evictMapImageCache();

    expect(cache.currentSize, 0);
    expect(cache.liveImageCount, 0);
  });
}
