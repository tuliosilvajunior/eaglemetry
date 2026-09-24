import 'package:flutter/widgets.dart';

/// Caps the process-wide Flutter image cache.
///
/// OSM tiles on a 1080p head unit fill the engine default (100 MB / 1 000
/// images) and stay there because History is keep-alive. 32 MB holds one
/// full-screen map plus the line-art assets; the rest is evicted LRU.
void applyImageCacheBudget() {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSizeBytes = kImageCacheMaxBytes;
  cache.maximumSize = kImageCacheMaxImages;
}

/// Drops decoded tiles when a map leaves the tree.
///
/// The budget above only bounds the cache. A keep-alive History tab would
/// otherwise hold a full map until something else pushed it out.
void evictMapImageCache() {
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
}

/// 32 MiB. About 128 decoded 256×256 tiles, one full-screen OSM view.
const kImageCacheMaxBytes = 32 * 1024 * 1024;

/// Image count cap beside [kImageCacheMaxBytes]. Whichever bound hits first.
const kImageCacheMaxImages = 200;
