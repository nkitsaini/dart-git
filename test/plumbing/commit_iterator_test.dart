import 'package:test/test.dart';

import 'package:dart_git/dart_git.dart';
import 'package:dart_git/plumbing/commit_iterator.dart';
import '../lib.dart';

void main() {
  test('BFS', () async {
    var gitDir = await openFixture(
        'test/data/git-7a725350b88b05ca03541b59dd0649fda7f521f2.tgz');

    var repo = await GitRepository.load(gitDir);
    var headCommit = await repo.headCommit();

    var iter = commitIteratorBFS(
      objStorage: repo.objStorage,
      from: headCommit,
    );

    var actual = <String>[];
    await for (var commit in iter) {
      var hash = commit.hash.toString();
      actual.add(hash);
    }

    var expected = <String>[
      '6ecf0ef2c2dffb796033e5a02219af86ec6584e5',
      '918c48b83bd081e863dbe1b80f8998f058cd8294',
      'af2d6a6954d532f8ffb47615169c8fdf9d383a1a',
      '1669dce138d9b841a518c64b10914d88f5e488ea',
      '35e85108805c84807bc66a02d91535e1e24b38b9',
      'a5b8b09e2f8fcb0bb99d3ccb0958157b40890d69',
      'b029517f6300c2da0f4b651b8642506cd6aaf45d',
      'b8e471f58bcbca63b07bda20e428190409c2db47',
    ];

    expect(actual, expected);
  });
}
