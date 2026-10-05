import 'package:path/path.dart' as p;

/// Coarse file categories used by destination rules.
enum FileCategory {
  images('Images'),
  videos('Videos'),
  audio('Music & audio'),
  documents('Documents'),
  archives('Archives'),
  folders('Folders'),
  other('Other');

  const FileCategory(this.label);
  final String label;

  static const _ext = <String, FileCategory>{
    // images
    'jpg': images, 'jpeg': images, 'png': images, 'gif': images,
    'webp': images, 'heic': images, 'heif': images, 'bmp': images,
    'tif': images, 'tiff': images, 'svg': images, 'raw': images,
    'dng': images, 'cr2': images, 'nef': images, 'arw': images,
    // videos
    'mp4': videos, 'mov': videos, 'mkv': videos, 'avi': videos,
    'webm': videos, 'm4v': videos, '3gp': videos, 'wmv': videos,
    'flv': videos, 'mts': videos,
    // audio
    'mp3': audio, 'm4a': audio, 'aac': audio, 'flac': audio, 'wav': audio,
    'ogg': audio, 'opus': audio, 'wma': audio, 'aiff': audio,
    // documents
    'pdf': documents, 'doc': documents, 'docx': documents, 'xls': documents,
    'xlsx': documents, 'ppt': documents, 'pptx': documents, 'odt': documents,
    'ods': documents, 'odp': documents, 'txt': documents, 'md': documents,
    'rtf': documents, 'csv': documents, 'epub': documents, 'pages': documents,
    'numbers': documents, 'key': documents,
    // archives
    'zip': archives, 'rar': archives, '7z': archives, 'tar': archives,
    'gz': archives, 'tgz': archives, 'bz2': archives, 'xz': archives,
    'apk': archives, 'dmg': archives, 'iso': archives,
  };

  static FileCategory forPath(String path, {String? mime}) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    final byExt = _ext[ext];
    if (byExt != null) return byExt;
    if (mime != null) {
      if (mime.startsWith('image/')) return images;
      if (mime.startsWith('video/')) return videos;
      if (mime.startsWith('audio/')) return audio;
      if (mime.startsWith('text/')) return documents;
    }
    return other;
  }
}
