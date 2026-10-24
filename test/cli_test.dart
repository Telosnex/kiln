import 'package:kiln/src/cli.dart';
import 'package:test/test.dart';

void main() {
  test('parseDefine', () {
    expect(parseDefine('a=b'), {'a': 'b'});
    expect(parseDefine('a=b=c'), {'a': 'b=c'});
    expect(parseDefine('a=null'), {'a': 'null'});
    expect(parseDefine('android={"ndk_version":"28.2.13676358"}'), {
      'android': {'ndk_version': '28.2.13676358'},
    });
    expect(() => parseDefine('=b'), throwsFormatException);
    expect(() => parseDefine('a'), throwsFormatException);
  });
}
