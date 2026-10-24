import 'package:code_assets/code_assets.dart';
import 'package:prebuilt/prebuilt.dart';
import 'package:test/test.dart';

void main() {
  BuildDecision decide(String? mode, {String? repo, String? problem}) =>
      decideBuild(
        mode: NativeBuildMode.parse(mode),
        releaseRepository: repo,
        prebuiltProblem: problem,
      );

  group('D2', () {
    test('auto downloads when prebuilt files match', () {
      expect(decide(null), isA<UsePrebuilt>());
      expect(decide('auto'), isA<UsePrebuilt>());
    });
    test('auto builds from source otherwise, and says why', () {
      final d = decide('auto', problem: 'sources differ');
      expect(d, isA<BuildFromSource>());
      expect((d as BuildFromSource).reason, 'sources differ');
      expect(d.requested, isFalse);
    });
    test('download fails otherwise', () {
      expect(decide('download'), isA<UsePrebuilt>());
      final d = decide('download', problem: 'sources differ');
      expect((d as FailBuild).message, contains('sources differ'));
    });
    test('source always builds from source', () {
      expect(decide('source'), isA<BuildFromSource>());
      expect((decide('source') as BuildFromSource).requested, isTrue);
    });
    test('native_release builds from source; download conflicts', () {
      expect(decide(null, repo: 'a/b'), isA<BuildFromSource>());
      expect(decide('source', repo: 'a/b'), isA<BuildFromSource>());
      expect(decide('download', repo: 'a/b'), isA<FailBuild>());
    });
  });

  test('bad user defines are errors', () {
    expect(() => NativeBuildMode.parse('prebuilt'), throwsFormatException);
    expect(() => parseReleaseRepository(true), throwsFormatException);
    expect(
      parseReleaseRepository('Telosnex/webcrypto.dart'),
      'Telosnex/webcrypto.dart',
    );
  });

  group('target names', () {
    for (final name in [
      'android-arm',
      'android-arm64',
      'android-x64',
      'ios-arm64-iphoneos',
      'ios-arm64-iphonesimulator',
      'ios-x64-iphonesimulator',
      'linux-arm64',
      'linux-x64',
      'macos-arm64',
      'macos-x64',
      'windows-arm64',
      'windows-x64',
    ]) {
      test(name, () => expect(TargetName.parse(name).name, name));
    }
    test('invalid names', () {
      for (final name in [
        'ios-arm64',
        'macos-arm64-iphoneos',
        'beos-x64',
        'linux',
      ]) {
        expect(
          () => TargetName.parse(name),
          throwsFormatException,
          reason: name,
        );
      }
    });
    test('iOS SDK', () {
      expect(
        TargetName.parse('ios-arm64-iphonesimulator').iosSdk,
        IOSSdk.iPhoneSimulator,
      );
    });
  });
}
