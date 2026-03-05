import 'dart:convert';
import 'dart:io';
import 'package:dart_appwrite/dart_appwrite.dart';

/// Appwrite Function: get_store_data
///
/// Aggregates ALL public data (books, categories, banners) into a single
/// JSON file in Appwrite Storage. The Flutter app reads this file instead
/// of querying the database directly.
///
/// Trigger: Event (book create/update/delete, banner change) OR Schedule (every 5 min)
///
/// Result: 50,000 users × 0 DB queries = 0 reads (instead of 150,000+/day)

final String? endpoint = Platform.environment['APPWRITE_ENDPOINT'];
final String? projectId = Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'];
final String? apiKey = Platform.environment['APPWRITE_API_KEY'];
final String? dbId = Platform.environment['DB_ID'];
final String? storeBucketId = Platform.environment['STORE_BUCKET_ID'];
final String? cacheBucketId = Platform.environment['CACHE_BUCKET_ID'];
final String? storeCol = Platform.environment['STORE_BOOKS_COLLECTION'];
final String? categoriesCol = Platform.environment['CATEGORIES_COLLECTION'];
final String? bannersCol = Platform.environment['BANNERS_COLLECTION'];

const String cacheFileId = 'store_cache_v1';

Future<dynamic> main(final context) async {
  // Validate environment
  final missingEnvs = <String>[];
  if (endpoint == null || endpoint!.isEmpty) {
    missingEnvs.add('APPWRITE_ENDPOINT');
  }
  if (projectId == null || projectId!.isEmpty) {
    missingEnvs.add('APPWRITE_FUNCTION_PROJECT_ID');
  }
  if (apiKey == null || apiKey!.isEmpty) missingEnvs.add('APPWRITE_API_KEY');
  if (dbId == null || dbId!.isEmpty) missingEnvs.add('DB_ID');
  if (cacheBucketId == null || cacheBucketId!.isEmpty) {
    missingEnvs.add('CACHE_BUCKET_ID');
  }

  if (missingEnvs.isNotEmpty) {
    context.error('❌ Missing environment variables: ${missingEnvs.join(', ')}');
    return context.res
        .json({'error': 'Missing env vars: ${missingEnvs.join(', ')}'}, 500);
  }

  final client =
      Client().setEndpoint(endpoint!).setProject(projectId!).setKey(apiKey!);

  final databases = Databases(client);
  final storage = Storage(client);

  try {
    context.log('📦 Building store cache...');

    // ============ 1. Fetch ALL books ============
    final booksResponse = await databases.listDocuments(
      databaseId: dbId!,
      collectionId: storeCol ?? 'store_books_table',
      queries: [
        Query.equal('is_visible', true),
        Query.orderDesc('\$createdAt'),
        Query.limit(500), // All books
        Query.select(['*', 'author.*', 'category.*']),
      ],
    );

    final books = booksResponse.documents
        .map((doc) => {
              '\$id': doc.$id,
              '\$createdAt': doc.$createdAt,
              'title': doc.data['title'],
              'description': doc.data['description'],
              'cover': doc.data['cover'],
              'file': doc.data['file'],
              'isbn_number': doc.data['isbn_number'],
              'price': doc.data['price'],
              'page_count': doc.data['page_count'],
              'show_dedication': doc.data['show_dedication'],
              'hidden_android': doc.data['hidden_android'] ?? false,
              'hidden_ios': doc.data['hidden_ios'] ?? false,
              'google_play_product_id': doc.data['google_play_product_id'],
              'author': doc.data['author'] is Map
                  ? {
                      '\$id': doc.data['author']['\$id'],
                      'name': doc.data['author']['name']
                    }
                  : doc.data['author'],
              'category': doc.data['category'] is Map
                  ? {
                      '\$id': doc.data['category']['\$id'],
                      'name': doc.data['category']['name']
                    }
                  : doc.data['category'],
            })
        .toList();

    context.log('📚 Fetched ${books.length} books');

    // ============ 2. Fetch ALL categories ============
    final categoriesResponse = await databases.listDocuments(
      databaseId: dbId!,
      collectionId: categoriesCol ?? 'categories',
      queries: [Query.limit(200)],
    );

    final categories = categoriesResponse.documents
        .map((doc) => {
              '\$id': doc.$id,
              'name': doc.data['name'],
            })
        .toList();

    context.log('📂 Fetched ${categories.length} categories');

    // ============ 3. Fetch active banners ============
    final bannersResponse = await databases.listDocuments(
      databaseId: dbId!,
      collectionId: bannersCol ?? 'announcement_banners',
      queries: [
        Query.equal('is_active', true),
        Query.orderDesc('priority'),
        Query.limit(20),
      ],
    );

    final now = DateTime.now().toIso8601String();
    final banners = bannersResponse.documents
        .where((doc) {
          final expiresAt = doc.data['expires_at'];
          if (expiresAt == null) return true;
          return DateTime.tryParse(expiresAt)?.isAfter(DateTime.now()) ?? true;
        })
        .map((doc) => {
              '\$id': doc.$id,
              '\$createdAt': doc.$createdAt,
              'image_file_id': doc.data['image_file_id'],
              'title': doc.data['title'],
              'action_url': doc.data['action_url'],
              'is_active': doc.data['is_active'],
              'priority': doc.data['priority'],
              'expires_at': doc.data['expires_at'],
            })
        .toList();

    context.log('🎯 Fetched ${banners.length} active banners');

    // ============ 4. Build cache JSON ============
    final cacheData = {
      'version': 1,
      'generated_at': now,
      'books': books,
      'categories': categories,
      'banners': banners,
    };

    final jsonBytes = utf8.encode(jsonEncode(cacheData));

    context.log(
        '📄 Cache JSON size: ${(jsonBytes.length / 1024).toStringAsFixed(1)} KB');

    // ============ 5. Upload to Storage (replace if exists) ============
    try {
      // Delete old cache file if exists
      await storage.deleteFile(bucketId: cacheBucketId!, fileId: cacheFileId);
      context.log('🗑️ Deleted old cache file');
    } catch (_) {
      // File doesn't exist yet — that's fine
    }

    await storage.createFile(
      bucketId: cacheBucketId!,
      fileId: cacheFileId,
      file: InputFile.fromBytes(bytes: jsonBytes, filename: 'store_cache.json'),
      permissions: [
        Permission.read(Role.any()), // Anyone can READ (guests too)
      ],
    );

    context.log('✅ Cache file uploaded successfully');

    return context.res.json({
      'success': true,
      'books': books.length,
      'categories': categories.length,
      'banners': banners.length,
      'size_kb': (jsonBytes.length / 1024).toStringAsFixed(1),
      'generated_at': now,
    });
  } catch (e, stack) {
    context.error('❌ Error building store cache: $e\n$stack');
    return context.res.json({'error': '$e'}, 500);
  }
}
