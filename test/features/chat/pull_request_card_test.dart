import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/core/models/timeline.dart';
import 'package:opencode_mobile/features/chat/pull_request_card.dart';

void main() {
  test('finds pull request links in order, once each', () {
    final links = findPullRequests([
      'Opened https://github.com/acme/web-app/pull/12.',
      'See also https://github.com/Acme/Web-App/pull/12 and '
          'https://github.com/acme/api.v2/pull/7/files',
      'Not a PR: https://github.com/acme/web-app/issues/3',
    ]);
    expect(links.map((l) => '${l.url}'), [
      'https://github.com/acme/web-app/pull/12',
      'https://github.com/acme/api.v2/pull/7',
    ]);
  });

  test('reads text and tool output, and caps the number of cards', () {
    final entry = AssistantEntry(
      id: 'm1',
      content: [
        const ToolContent(
          id: 't1',
          name: 'bash',
          status: ToolStatus.completed,
          output: 'https://github.com/a/b/pull/1\n',
        ),
        const ReasoningContent('https://github.com/a/b/pull/9'),
        const TextContent(
          'https://github.com/a/b/pull/2 https://github.com/a/b/pull/3 '
          'https://github.com/a/b/pull/4',
        ),
      ],
    );
    expect(pullRequestsIn(entry).map((l) => l.number), [1, 2, 3]);
  });
}
