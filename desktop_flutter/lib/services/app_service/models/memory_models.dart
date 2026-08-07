part of '../models.dart';

class MemoryCollectionSummary {
  const MemoryCollectionSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.languagePairs,
    required this.tags,
    required this.revision,
    required this.entryCount,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final List<String> languagePairs;
  final List<String> tags;
  final int revision;
  final int entryCount;
  final String updatedAt;

  factory MemoryCollectionSummary.fromJson(Object? value) {
    final map = _stringMap(value);
    return MemoryCollectionSummary(
      id: _stringValue(map['id']) ?? '',
      name: _stringValue(map['name']) ?? '',
      description: _stringValue(map['description']) ?? '',
      languagePairs: _stringList(map['language_pairs']),
      tags: _stringList(map['tags']),
      revision: _intValue(map['revision']) ?? 1,
      entryCount:
          _intValue(map['entries']) ??
          (map['entries'] is List ? (map['entries'] as List).length : 0),
      updatedAt: _stringValue(map['updated_at']) ?? '',
    );
  }
}

class MemoryCollectionDetail {
  const MemoryCollectionDetail({
    required this.summary,
    required this.entries,
    required this.raw,
  });

  final MemoryCollectionSummary summary;
  final List<MemoryEntryItem> entries;
  final Map<String, Object?> raw;

  factory MemoryCollectionDetail.fromJson(Object? value) {
    final envelope = _stringMap(value);
    final map = envelope.containsKey('collection')
        ? _stringMap(envelope['collection'])
        : envelope;
    return MemoryCollectionDetail(
      summary: MemoryCollectionSummary.fromJson(map),
      entries: _objectList(map['entries'])
          .map(MemoryEntryItem.fromJson)
          .where((entry) => entry.id.isNotEmpty)
          .toList(),
      raw: map,
    );
  }
}

class MemoryEntryItem {
  const MemoryEntryItem({
    required this.id,
    required this.source,
    required this.target,
    required this.category,
    required this.status,
    required this.notes,
    required this.aliases,
    required this.constraint,
    required this.memoryType,
    required this.priority,
    required this.raw,
  });

  final String id;
  final String source;
  final String target;
  final String category;
  final String status;
  final String notes;
  final List<String> aliases;
  final String constraint;
  final String memoryType;
  final int priority;
  final Map<String, Object?> raw;

  factory MemoryEntryItem.fromJson(Object? value) {
    final map = _stringMap(value);
    return MemoryEntryItem(
      id: _stringValue(map['id']) ?? '',
      source: _stringValue(map['source']) ?? '',
      target: _stringValue(map['target']) ?? '',
      category: _stringValue(map['category']) ?? 'term',
      status: _stringValue(map['status']) ?? 'proposed',
      notes: _stringValue(map['notes']) ?? '',
      aliases: _stringList(map['aliases']),
      constraint: _stringValue(map['constraint']) ?? '',
      memoryType: _stringValue(map['memory_type']) ?? '',
      priority: _intValue(map['priority']) ?? 50,
      raw: map,
    );
  }
}
