import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/app/theme.dart';
import 'package:opencode_mobile/core/api/api_errors.dart';
import 'package:opencode_mobile/core/api/opencode_client.dart';
import 'package:opencode_mobile/core/models/project.dart';
import 'package:opencode_mobile/core/models/server_config.dart';
import 'package:opencode_mobile/features/connection/connection_providers.dart';
import 'package:opencode_mobile/features/sessions/session_target_sheet.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';

import '../../support/fake_adapter.dart';

class _Connected extends ConnectionNotifier {
  _Connected(this.connection);

  final ActiveConnection connection;

  @override
  ActiveConnection? build() => connection;
}

void main() {
  const project = Project(
    id: 'p1',
    directory: '/home/me/app',
    vcs: 'git',
    sandboxes: ['/home/me/app', '/sandbox/x'],
  );

  test('only Git projects offer targets', () {
    expect(offersSessionTargets(project), isTrue);
    expect(
      offersSessionTargets(const Project(id: 'p2', directory: '/a')),
      isFalse,
    );
    expect(
      offersSessionTargets(
        const Project(id: 'global', directory: '/a', vcs: 'git'),
      ),
      isFalse,
    );
  });

  group('sheet', () {
    late FakeAdapter adapter;
    SessionTarget? picked;

    Future<void> open(WidgetTester tester) async {
      adapter = FakeAdapter({
        '/api/vcs': FakeRoute.json({
          'data': {
            'branch': {'current': 'main', 'default': 'main'},
          },
        }),
        '/api/worktree': FakeRoute.json([
          {'directory': '/home/me/app'},
          {'directory': '/data/worktree/p1/brave-fox', 'strategy': 'git'},
        ]),
        '/api/vcs/branch': (RequestOptions request) => FakeRoute.json({
          'data': [
            for (final b in ['main', 'feature/login', 'fix/crash'])
              if (b.contains(
                request.queryParameters['search'] as String? ?? '',
              ))
                b,
          ],
        }),
      });
      final client = OpenCodeClient(
        baseUrl: 'http://pc.local:4096',
        username: 'opencode',
        password: 'pw',
        dio: fakeDio(adapter),
      );
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.platformDispatcher.localesTestValue = const [Locale('ja')];
      picked = null;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(
              () => _Connected(
                ActiveConnection(
                  server: const ServerConfig(
                    id: 'srv',
                    baseUrl: 'http://pc.local:4096',
                  ),
                  client: client,
                  health: const ServerHealth(version: '2.0.23', pid: 1),
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async =>
                      picked = await SessionTargetSheet.show(context, project),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists local, new workspace and other worktrees', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('セッションの実行先'), findsOneWidget);
      expect(find.text('ローカルリポジトリ'), findsOneWidget);
      expect(find.text('新しいワークスペース'), findsOneWidget);
      expect(find.text('mainから'), findsOneWidget);
      expect(find.text('ワークツリー'), findsOneWidget);
      // The local repository is not listed again; sandboxes are.
      expect(find.text('brave-fox'), findsOneWidget);
      expect(find.text('x'), findsOneWidget);
      expect(find.text('app'), findsNothing);

      await tester.tap(find.text('brave-fox'));
      await tester.pumpAndSettle();
      expect(
        picked,
        isA<WorktreeTarget>().having(
          (t) => t.directory,
          'directory',
          '/data/worktree/p1/brave-fox',
        ),
      );
    });

    testWidgets('local repository', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('target-local')));
      await tester.pumpAndSettle();
      expect(picked, isA<LocalTarget>());
    });

    testWidgets('a new workspace can start from another branch', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('target-branch')));
      await tester.pumpAndSettle();
      expect(find.text('feature/login'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('branch-search')), 'fix');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('feature/login'), findsNothing);
      expect(
        adapter.requests.last.queryParameters,
        containsPair('search', 'fix'),
      );

      await tester.tap(find.text('fix/crash'));
      await tester.pumpAndSettle();
      expect(find.text('fix/crashから'), findsOneWidget);

      await tester.tap(find.byKey(const Key('target-new')));
      await tester.pumpAndSettle();
      expect(
        picked,
        isA<NewWorkspaceTarget>().having(
          (t) => t.branch,
          'branch',
          'fix/crash',
        ),
      );
    });

    testWidgets('a new workspace defaults to the local HEAD', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('target-new')));
      await tester.pumpAndSettle();
      expect(
        picked,
        isA<NewWorkspaceTarget>().having((t) => t.branch, 'branch', isNull),
      );
    });
  });
}
