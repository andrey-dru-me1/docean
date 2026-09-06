import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/tag_hierarchy.dart';

void main() {
  group('implicitAncestors', () {
    test('returns proper prefixes for a slash-separated tag', () {
      expect(implicitAncestors('a/b/c'), equals(['a', 'a/b']));
    });

    test('returns empty list for a top-level tag', () {
      expect(implicitAncestors('a'), isEmpty);
    });

    test('throws ArgumentError on empty string', () {
      expect(() => implicitAncestors(''), throwsArgumentError);
    });

    test('throws ArgumentError on double slash', () {
      expect(() => implicitAncestors('a//b'), throwsArgumentError);
    });
  });

  group('isValidTagPath', () {
    test('rejects empty string', () {
      expect(isValidTagPath(''), isFalse);
    });

    test('rejects leading slash', () {
      expect(isValidTagPath('/a'), isFalse);
    });

    test('rejects trailing slash', () {
      expect(isValidTagPath('a/'), isFalse);
    });

    test('rejects double slash', () {
      expect(isValidTagPath('a//b'), isFalse);
    });

    test('rejects segment exceeding 60 characters', () {
      expect(isValidTagPath('a/${'x' * 61}'), isFalse);
    });

    test('rejects more than 8 segments', () {
      expect(isValidTagPath('a/a/a/a/a/a/a/a/a'), isFalse);
    });

    test('accepts a normal slash-separated tag', () {
      expect(isValidTagPath('study/mit/machine-learning'), isTrue);
    });

    test('accepts tag with space', () {
      expect(isValidTagPath('work docer'), isTrue);
    });

    test('accepts single-character segment', () {
      expect(isValidTagPath('a/b'), isTrue);
    });

    test('accepts exactly 8 segments', () {
      expect(isValidTagPath('a/b/c/d/e/f/g/h'), isTrue);
    });

    test('accepts exactly 60-character segment', () {
      expect(isValidTagPath('a/${'x' * 60}'), isTrue);
    });

    test('rejects invalid characters', () {
      expect(isValidTagPath('a:b'), isFalse);
    });

    test('accepts tag with underscore and dot', () {
      expect(isValidTagPath('my_tag/file.txt'), isTrue);
    });
  });

  group('validateTagPath', () {
    test('returns null for valid tag', () {
      expect(validateTagPath('a/b'), isNull);
    });

    test('returns error message for invalid tag', () {
      expect(validateTagPath(''), isNotNull);
      expect(validateTagPath('/a'), isNotNull);
    });
  });

  group('isHierarchical', () {
    test('true when tag contains slash', () {
      expect(isHierarchical('a/b'), isTrue);
    });

    test('false for top-level tag', () {
      expect(isHierarchical('a'), isFalse);
    });
  });

  group('topLevelOf', () {
    test('returns first segment', () {
      expect(topLevelOf('study/mit/ml'), equals('study'));
    });

    test('returns the tag itself when top-level', () {
      expect(topLevelOf('solo'), equals('solo'));
    });
  });

  group('parentOf', () {
    test('returns parent path for hierarchical tag', () {
      expect(parentOf('study/mit'), equals('study'));
      expect(parentOf('mit/seminar'), equals('mit'));
    });

    test('returns empty string for top-level tag', () {
      expect(parentOf('solo'), equals(''));
    });
  });

  group('lastSegmentOf', () {
    test('returns last segment', () {
      expect(lastSegmentOf('a/b/c'), equals('c'));
    });

    test('returns the tag itself when top-level', () {
      expect(lastSegmentOf('solo'), equals('solo'));
    });
  });

  group('isDirtag', () {
    test('true when another tag is a deeper prefix of same path', () {
      expect(isDirtag('study', ['study/mit/ml']), isTrue);
    });

    test('false when no deeper tag exists', () {
      expect(isDirtag('study/mit/ml', ['study/mit/ml']), isFalse);
    });

    test('ignores property tags in allTags', () {
      expect(isDirtag('student', ['student:Alice']), isFalse);
    });
  });

  group('implicitTagSet', () {
    test('returns tag plus all ancestors', () {
      expect(
        implicitTagSet('a/b/c'),
        equals({'a/b/c', 'a/b', 'a'}),
      );
    });

    test('returns single tag for top-level', () {
      expect(implicitTagSet('a'), equals({'a'}));
    });
  });

  group('docContained', () {
    test('true when doc has path exactly', () {
      expect(docContained({'study/mit'}, 'study/mit'), isTrue);
    });

    test('true when doc has a deeper tag', () {
      expect(docContained({'study/mit/ml'}, 'study'), isTrue);
      expect(docContained({'study/mit/ml'}, 'study/mit'), isTrue);
    });

    test('false when doc does not have path or deeper tag', () {
      expect(docContained({'study/mit/ml'}, 'study/lecture'), isFalse);
    });

    test('ignores property tags', () {
      expect(docContained({'student:Alice'}, 'student'), isFalse);
    });
  });

  group('containedCount and containedDocIds', () {
    final tagsByDoc = <String, Set<String>>{
      'knn': {'study/lecture', 'study/mit/ml'},
      'qsort': {'study/seminar', 'study/mit/cprog'},
    };

    test('containedCount counts docs with matching prefix', () {
      expect(containedCount('study', tagsByDoc), equals(2));
      expect(containedCount('study/mit', tagsByDoc), equals(2));
      expect(containedCount('study/lecture', tagsByDoc), equals(1));
    });

    test('containedDocIds returns correct doc ids', () {
      expect(
        containedDocIds('study', tagsByDoc),
        equals({'knn', 'qsort'}),
      );
      expect(
        containedDocIds('study/mit', tagsByDoc),
        equals({'knn', 'qsort'}),
      );
      expect(
        containedDocIds('study/lecture', tagsByDoc),
        equals({'knn'}),
      );
    });
  });

  group('directSubTags', () {
    final tagsByDoc = <String, Set<String>>{
      'knn': {'study/lecture', 'study/mit/ml'},
      'qsort': {'study/seminar', 'study/mit/cprog'},
    };

    test('spec example: directSubTags study returns mit first then leaves alpha', () {
      expect(
        directSubTags('study', tagsByDoc),
        equals(['mit', 'lecture', 'seminar']),
      );
    });

    test('spec example: directSubTags study/mit returns both leaves alpha', () {
      expect(
        directSubTags('study/mit', tagsByDoc),
        equals(['cprog', 'ml']),
      );
    });
  });

  group('topLevelTags', () {
    test('spec example: knn and qsort yield [study]', () {
      final tagsByDoc = <String, Set<String>>{
        'knn': {'study/lecture', 'study/mit/ml'},
        'qsort': {'study/seminar', 'study/mit/cprog'},
      };
      expect(topLevelTags(tagsByDoc), equals(['study']));
    });

    test('property-only doc produces no entries', () {
      final tagsByDoc = <String, Set<String>>{
        'd': {'student:Alice'},
      };
      expect(topLevelTags(tagsByDoc), isEmpty);
    });
  });

  group('directlyAssignedDocIds', () {
    final tagsByDoc = <String, Set<String>>{
      'knn': {'study/lecture', 'study/mit/ml'},
      'qsort': {'study/seminar', 'study/mit/cprog'},
    };

    test('empty when no doc is directly assigned study', () {
      expect(directlyAssignedDocIds('study', tagsByDoc), isEmpty);
    });

    test('returns doc with exactly study/lecture', () {
      expect(
        directlyAssignedDocIds('study/lecture', tagsByDoc),
        equals({'knn'}),
      );
    });
  });

  group('suggestTagCompletions', () {
    final allTags = [
      'study',
      'study/mit',
      'study/mit/machine-learning',
      'seminar',
    ];

    test('tier 3: segment prefix matches machine-learning', () {
      expect(
        suggestTagCompletions('machine-le', allTags),
        contains('study/mit/machine-learning'),
      );
    });

    test('tier 4: subsequence smitml matches machine-learning', () {
      expect(
        suggestTagCompletions('smitml', allTags),
        contains('study/mit/machine-learning'),
      );
    });

    test('tier ordering: exact beats prefix beats segment-prefix beats subsequence', () {
      final tags = ['ma/x', 'a/ma', 'mxa', 'ma'];
      final result = suggestTagCompletions('ma', tags);
      expect(result, equals(['ma', 'ma/x', 'a/ma', 'mxa']));
    });

    test('limit is honored', () {
      final tags = ['a', 'a/b', 'a/b/c', 'a/b/c/d', 'a/b/c/d/e'];
      expect(suggestTagCompletions('a', tags, limit: 3), hasLength(3));
    });

    test('empty query returns empty list', () {
      expect(suggestTagCompletions('', allTags), isEmpty);
    });

    test('whitespace-only query returns empty list', () {
      expect(suggestTagCompletions('   ', allTags), isEmpty);
    });

    test('ignores property tags', () {
      final tags = ['student:Alice', 'study'];
      final result = suggestTagCompletions('stu', tags);
      expect(result, contains('study'));
      expect(result, isNot(contains('student:Alice')));
    });

    test('case insensitive', () {
      final tags = ['study/mit/machine-learning'];
      expect(
        suggestTagCompletions('MACHINE-LE', tags),
        contains('study/mit/machine-learning'),
      );
    });
  });

  group('renamedTagsByDoc', () {
    test('spec example: rename seminar to mit/seminar', () {
      final tagsByDoc = <String, Set<String>>{
        'd1': {'seminar', 'x'},
        'd2': {'study/mit/ml'},
        'd3': {'mit/seminar'},
      };
      final result = renamedTagsByDoc(tagsByDoc, 'seminar', 'mit/seminar');
      expect(result.length, equals(1));
      expect(result['d1'], equals({'mit/seminar', 'x'}));
      expect(result.containsKey('d2'), isFalse);
      expect(result.containsKey('d3'), isFalse);
    });

    test('collision case: rename b to a/b collapses duplicate', () {
      final tagsByDoc = <String, Set<String>>{
        'd4': {'a/b', 'b'},
      };
      final result = renamedTagsByDoc(tagsByDoc, 'b', 'a/b');
      expect(result['d4'], equals({'a/b'}));
    });

    test('preserves property tags in output', () {
      final tagsByDoc = <String, Set<String>>{
        'd1': {'seminar', 'student:Alice'},
      };
      final result = renamedTagsByDoc(tagsByDoc, 'seminar', 'mit/seminar');
      expect(result['d1'], equals({'mit/seminar', 'student:Alice'}));
    });

    test('throws ArgumentError on invalid newPath', () {
      final tagsByDoc = <String, Set<String>>{
        'd1': {'a'},
      };
      expect(
        () => renamedTagsByDoc(tagsByDoc, 'a', '/invalid'),
        throwsArgumentError,
      );
    });

    test('returns empty map when no doc contains oldPath', () {
      final tagsByDoc = <String, Set<String>>{
        'd1': {'a'},
      };
      final result = renamedTagsByDoc(tagsByDoc, 'b', 'c');
      expect(result, isEmpty);
    });
  });
}