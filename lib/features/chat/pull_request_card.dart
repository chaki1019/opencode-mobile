import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/timeline.dart';
import '../../l10n/l10n.dart';
import 'revert_providers.dart';

/// A GitHub pull request the agent linked to, for example after running
/// `gh pr create`.
class PullRequestLink {
  const PullRequestLink({
    required this.owner,
    required this.repo,
    required this.number,
  });

  final String owner;
  final String repo;
  final int number;

  Uri get url => Uri.https('github.com', '/$owner/$repo/pull/$number');

  @override
  bool operator ==(Object other) =>
      other is PullRequestLink &&
      other.owner.toLowerCase() == owner.toLowerCase() &&
      other.repo.toLowerCase() == repo.toLowerCase() &&
      other.number == number;

  @override
  int get hashCode =>
      Object.hash(owner.toLowerCase(), repo.toLowerCase(), number);
}

final _pullRequestUrl = RegExp(
  r'https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/(\d+)',
);

/// Shows at most this many cards under one message, so a reply that lists
/// many pull requests does not turn into a wall of cards.
const _maxCards = 3;

/// The pull requests linked in [texts], in order of first mention.
List<PullRequestLink> findPullRequests(Iterable<String> texts) {
  final found = <PullRequestLink>{};
  for (final text in texts) {
    for (final m in _pullRequestUrl.allMatches(text)) {
      found.add(
        PullRequestLink(owner: m[1]!, repo: m[2]!, number: int.parse(m[3]!)),
      );
    }
  }
  return found.toList();
}

/// The pull requests an assistant message links to, in its text or in the
/// output of its tool calls.
List<PullRequestLink> pullRequestsIn(AssistantEntry entry) => findPullRequests([
  for (final content in entry.content)
    switch (content) {
      final TextContent c => c.text,
      final ToolContent c => c.output ?? '',
      ReasoningContent() => '',
    },
]).take(_maxCards).toList();

/// A card for a pull request the agent opened: opens it on GitHub, or puts a
/// request to merge it in the input so the user can check and send it.
class PullRequestCard extends ConsumerWidget {
  const PullRequestCard({super.key, required this.link, this.sessionId});

  final PullRequestLink link;

  /// The session whose input gets the merge request. Without it the card
  /// only offers opening the pull request.
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.merge_type, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${link.owner}/${link.repo} #${link.number}',
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  context.l10n.pullRequest,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      link.url,
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(context.l10n.openOnGitHub),
                  ),
                  if (sessionId case final id?)
                    TextButton.icon(
                      onPressed: () => ref
                          .read(composerDraftProvider(id).notifier)
                          .offer(context.l10n.askToMergeMessage('${link.url}')),
                      icon: const Icon(Icons.call_merge, size: 18),
                      label: Text(context.l10n.askToMerge),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
