import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:dart_git/git.dart';
import 'package:dart_git/utils/utils.dart';

class CheckoutCommand extends Command {
  @override
  final name = 'checkout';

  @override
  final description = 'Switch branches or restore working tree files';

  CheckoutCommand() {
    argParser.addOption('branch', abbr: 'b', defaultsTo: '');
  }

  @override
  Future run() async {
    var gitRootDir = GitRepository.findRootDir(Directory.current.path)!;
    var repo = await GitRepository.load(gitRootDir).get();

    var branchName = argResults!['branch'] as String;
    if (branchName.isNotEmpty) {
      var remoteFullBranchName = '';
      if (argResults!.rest.isNotEmpty) {
        remoteFullBranchName = argResults!.rest[0];
      } else {
        var branches = await repo.branches().get();
        if (branches.contains(branchName)) {
          await repo.checkoutBranch(branchName);
          return;
        } else {
          // FIXME: This should lookup which remote has it
          remoteFullBranchName = 'origin/$branchName';
        }
      }

      var remoteName = splitPath(remoteFullBranchName).item1;
      var remoteBranchName = splitPath(remoteFullBranchName).item2;

      var remoteRefR = await repo.remoteBranch(remoteName, remoteBranchName);
      if (remoteRefR.failed) {
        print('fatal: remote $remoteName branch $remoteBranchName not found');
        return;
      }
      var remoteRef = remoteRefR.get();

      await repo.createBranch(branchName, hash: remoteRef.hash);
      await repo.checkout('.');
      await repo.setUpstreamTo(
          repo.config.remote(remoteName)!, remoteBranchName);
      print(
          "Branch '$branchName' set up to track remote branch '$remoteBranchName' from '$remoteName'.");

      var headRefResult = await repo.head();
      if (headRefResult.failed) {
        print('fatal: head not found');
        return;
      }

      var headRef = headRefResult.get();
      if (headRef.target!.branchName() == branchName) {
        print("Already on '$branchName'");
      }

      return;
    }

    if (argResults!.arguments.isEmpty) {
      print('Must provide a file');
      exit(1);
    }

    var pathSpec = argResults!.arguments[0];
    var branches = await repo.branches().get();
    if (branches.contains(pathSpec)) {
      await repo.checkoutBranch(pathSpec);
      return;
    }

    // TODO: Check if one of the remotes contains this branch

    var objectsUpdatedR = await repo.checkout(pathSpec);

    if (objectsUpdatedR.failed) {
      print(
          "error: pathspec '$pathSpec' did not match any file(s) known to git");
      exit(1);
    }
    var objectsUpdated = objectsUpdatedR.get();
    print('Updated $objectsUpdated path from the index');
  }
}
