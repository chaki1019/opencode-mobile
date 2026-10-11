import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_errors.dart';
import '../../core/models/project.dart';
import '../../core/models/project_tools.dart';
import '../../l10n/l10n.dart';
import '../connection/connection_providers.dart';

/// Where a new session runs, as in OpenCode's own client: the project's
/// checkout, a worktree created for it, or a worktree that already exists.
sealed class SessionTarget {
  const SessionTarget();
}

class LocalTarget extends SessionTarget {
  const LocalTarget();
}

/// A new worktree checked out at [branch], or at the local repository's
/// HEAD when null.
class NewWorkspaceTarget extends SessionTarget {
  const NewWorkspaceTarget({this.branch});

  final String? branch;
}

class WorktreeTarget extends SessionTarget {
  const WorktreeTarget(this.directory);

  final String directory;
}

/// Only Git projects can have worktrees; the others start sessions in their
/// folder straight away.
bool offersSessionTargets(Project project) =>
    project.id != 'global' && project.vcs == 'git';

/// The last path segment, for naming a worktree by its folder.
String worktreeName(String directory) {
  final parts = directory.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? directory : parts.last;
}

/// The local repository's branch and the project's other checkouts.
class SessionTargets {
  const SessionTargets({this.branch, this.worktrees = const []});

  final String? branch;
  final List<String> worktrees;
}

final sessionTargetsProvider = FutureProvider.autoDispose
    .family<SessionTargets, Project>((ref, project) async {
      final client = ref.watch(connectionProvider)?.client;
      if (client == null) return const SessionTargets();
      final (branch, worktrees) = await (
        client
            .vcsBranch(directory: project.directory)
            .then<VcsBranch?>((b) => b)
            .catchError((_) => null, test: (e) => e is OpenCodeApiException),
        client
            .listWorktrees(project.id)
            .catchError(
              (_) => const <Worktree>[],
              test: (e) => e is OpenCodeApiException,
            ),
      ).wait;
      final seen = <String>{project.directory};
      return SessionTargets(
        branch: branch?.current,
        worktrees: [
          for (final directory in [
            ...worktrees.map((w) => w.directory),
            ...project.sandboxes,
          ])
            if (seen.add(directory)) directory,
        ],
      );
    });

/// Asks where a new session should run.
class SessionTargetSheet extends ConsumerStatefulWidget {
  const SessionTargetSheet({super.key, required this.project});

  final Project project;

  /// Resolves to the chosen target, or null when the sheet is dismissed.
  static Future<SessionTarget?> show(BuildContext context, Project project) =>
      showModalBottomSheet<SessionTarget>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => SessionTargetSheet(project: project),
      );

  @override
  ConsumerState<SessionTargetSheet> createState() => _SessionTargetSheetState();
}

class _SessionTargetSheetState extends ConsumerState<SessionTargetSheet> {
  /// The branch a new workspace starts from; null for the local HEAD.
  String? _branch;

  Future<void> _chooseBranch() async {
    final branch = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.8,
        child: _BranchPicker(
          directory: widget.project.directory,
          selected: _branch,
        ),
      ),
    );
    if (branch != null && mounted) setState(() => _branch = branch);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final targets = ref.watch(sessionTargetsProvider(widget.project));
    final current = targets.value?.branch;
    final base = _branch ?? current;
    final worktrees = targets.value?.worktrees ?? const <String>[];

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          heading(l10n.sessionTarget),
          ListTile(
            key: const Key('target-local'),
            leading: const Icon(Icons.desktop_windows_outlined),
            title: Text(l10n.sessionTargetLocal),
            subtitle: current == null ? null : Text(current),
            onTap: () => Navigator.pop(context, const LocalTarget()),
          ),
          ListTile(
            key: const Key('target-new'),
            leading: const Icon(Icons.add),
            title: Text(l10n.sessionTargetNewWorkspace),
            subtitle: Text(
              base == null
                  ? l10n.sessionTargetNewWorkspaceHint
                  : l10n.sessionTargetFromBranch(base),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              key: const Key('target-branch'),
              tooltip: l10n.sessionTargetChangeBranch,
              icon: const Icon(Icons.call_split),
              onPressed: _chooseBranch,
            ),
            onTap: () =>
                Navigator.pop(context, NewWorkspaceTarget(branch: _branch)),
          ),
          if (targets.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (worktrees.isNotEmpty) ...[
            const Divider(),
            heading(l10n.sessionTargetWorktrees),
            for (final directory in worktrees)
              ListTile(
                key: Key('target-worktree-$directory'),
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(worktreeName(directory)),
                subtitle: Text(
                  directory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, WorktreeTarget(directory)),
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Searches the repository's branches and returns the tapped one.
class _BranchPicker extends ConsumerStatefulWidget {
  const _BranchPicker({required this.directory, this.selected});

  final String directory;
  final String? selected;

  @override
  ConsumerState<_BranchPicker> createState() => _BranchPickerState();
}

class _BranchPickerState extends ConsumerState<_BranchPicker> {
  Timer? _debounce;
  late Future<List<String>> _branches = _load('');

  Future<List<String>> _load(String search) {
    final client = ref.read(connectionProvider)?.client;
    if (client == null) return Future.value(const []);
    return client.vcsBranches(directory: widget.directory, search: search);
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => setState(() {
        _branches = _load(value);
      }),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: const Key('branch-search'),
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.branchSearch,
              isDense: true,
            ),
            onChanged: _onSearch,
          ),
        ),
        Expanded(
          child: FutureBuilder(
            future: _branches,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('${snapshot.error}'));
              }
              final branches = snapshot.data;
              if (branches == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (branches.isEmpty) {
                return Center(child: Text(l10n.branchSearchEmpty));
              }
              return ListView.builder(
                itemCount: branches.length,
                itemBuilder: (context, index) {
                  final branch = branches[index];
                  return ListTile(
                    leading: const Icon(Icons.call_split),
                    title: Text(branch),
                    trailing: branch == widget.selected
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, branch),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
