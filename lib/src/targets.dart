import 'package:code_assets/code_assets.dart';

/// A target name of ADR 001 §5: `<os>-<arch>`, and for iOS
/// `ios-<arch>-<iphoneos|iphonesimulator>`.
final class TargetName {
  TargetName(this.os, this.architecture, [this.iosSdk]) {
    if ((os == OS.iOS) != (iosSdk != null)) {
      throw ArgumentError('An iOS SDK is required for iOS targets only.');
    }
  }

  factory TargetName.of(CodeConfig code) => TargetName(
    code.targetOS,
    code.targetArchitecture,
    code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
  );

  factory TargetName.parse(String name) {
    final parts = name.split('-');
    OS? os;
    Architecture? architecture;
    IOSSdk? sdk;
    if (parts.length >= 2) {
      os = OS.values.where((o) => o.name == parts[0]).firstOrNull;
      architecture = Architecture.values
          .where((a) => a.name == parts[1])
          .firstOrNull;
    }
    if (os == OS.iOS && parts.length == 3) {
      sdk = switch (parts[2]) {
        'iphoneos' => IOSSdk.iPhoneOS,
        'iphonesimulator' => IOSSdk.iPhoneSimulator,
        _ => null,
      };
    }
    final valid =
        os != null &&
        architecture != null &&
        (os == OS.iOS ? sdk != null : parts.length == 2);
    if (!valid) throw FormatException('Invalid target name "$name".');
    return TargetName(os, architecture, sdk);
  }

  final OS os;
  final Architecture architecture;
  final IOSSdk? iosSdk;

  String get name => [
    os.name,
    architecture.name,
    if (iosSdk != null)
      iosSdk == IOSSdk.iPhoneOS ? 'iphoneos' : 'iphonesimulator',
  ].join('-');

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) => other is TargetName && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// Why prebuilt files with [minOSVersion] cannot serve [code], or null if
/// they can.
String? compatibilityProblem(CodeConfig code, int? minOSVersion) {
  if (code.linkModePreference == LinkModePreference.static) {
    return 'the build asks for static linking, and prebuilt files are '
        'dynamic libraries';
  }
  if (minOSVersion == null) return null;
  final (label, version) = switch (code.targetOS) {
    OS.iOS => ('iOS', code.iOS.targetVersion),
    OS.macOS => ('macOS', code.macOS.targetVersion),
    OS.android => ('Android API', code.android.targetNdkApi),
    _ => (null, null),
  };
  if (label == null || version == null || version >= minOSVersion) return null;
  return 'the app supports $label $version, and the prebuilt files need '
      '$label $minOSVersion or later';
}
