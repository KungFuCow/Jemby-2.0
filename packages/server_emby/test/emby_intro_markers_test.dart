import 'package:dio/dio.dart';
import 'package:server_emby/src/api/emby_items_api.dart';
import 'package:test/test.dart';

Dio fakeEmby(Map<String, dynamic> Function(RequestOptions) response) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(Response(
            requestOptions: options,
            data: response(options),
          ));
        },
      ),
    );
}

void main() {
  test('Skip Intro recognizes Emby chapter marker ticks', () async {
    final dio = fakeEmby((request) {
      expect(request.path, '/Users/user-1/Items/episode-1');
      return {
        'RunTimeTicks': 4000000000,
        'Chapters': [
          {'StartPositionTicks': 150000000, 'MarkerType': 'IntroStart'},
          {'StartPositionTicks': 800000000, 'MarkerType': 'IntroEnd'},
          {'StartPositionTicks': 3650000000, 'MarkerType': 'CreditsStart'},
        ],
      };
    });
    final segments = await EmbyItemsApi(dio, () => 'user-1')
        .getMediaSegments('episode-1');
    expect(segments, hasLength(2));
    expect(segments[0]['Type'], 'Intro');
    expect(segments[0]['StartTicks'], 150000000);
    expect(segments[0]['EndTicks'], 800000000);
    expect(segments[1]['Type'], 'Outro');
  });

  test('intro chapters fall back to the working JEmby 1.0 list endpoint',
      () async {
    final seen = <String>[];
    final dio = fakeEmby((request) {
      seen.add(request.path);
      if (request.path == '/Users/user-1/Items/episode-2') {
        return {'Chapters': []};
      }
      if (request.path == '/Users/user-1/Items') {
        expect(request.queryParameters['Ids'], 'episode-2');
        return {
          'Items': [
            {
              'Id': 'episode-2',
              'RunTimeTicks': 2000000000,
              'Chapters': [
                {'StartPositionTicks': 0, 'MarkerType': 'IntroStart'},
                {'StartPositionTicks': 400000000, 'MarkerType': 'IntroEnd'},
              ],
            },
          ],
        };
      }
      throw StateError('Unexpected request ${request.path}');
    });
    final segments = await EmbyItemsApi(dio, () => 'user-1')
        .getMediaSegments('episode-2');
    expect(segments, hasLength(1));
    expect(segments.single['Type'], 'Intro');
    expect(segments.single['EndTicks'], 400000000);
    expect(seen, [
      '/Users/user-1/Items/episode-2',
      '/Users/user-1/Items',
    ]);
  });

  test('CreditStart singular marker is recognized in third fallback', () async {
    final dio = fakeEmby((request) {
      if (request.path == '/Users/user-1/Items/episode-3') {
        return {'Chapters': []};
      }
      if (request.path == '/Users/user-1/Items') {
        return {'Items': []};
      }
      expect(request.path, '/Items/episode-3');
      return {
        'RunTimeTicks': 2000000000,
        'Chapters': [
          {'StartPositionTicks': 1600000000, 'MarkerType': 'CreditStart'},
        ],
      };
    });
    final segments = await EmbyItemsApi(dio, () => 'user-1')
        .getMediaSegments('episode-3');
    expect(segments, hasLength(1));
    expect(segments.single['Type'], 'Outro');
    expect(segments.single['StartTicks'], 1600000000);
  });
}
