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

/// An oldest supported OS version: an iOS or macOS deployment version
/// (major.minor.patch), or an Android API level (major only).
final class OSVersion implements Comparable<OSVersion> {
  const OSVersion(this.major, [this.minor = 0, this.patch = 0]);

  factory OSVersion.apple(AppleVersion version) =>
      OSVersion(version.major, version.minor, version.patch);

  /// Parses `12`, `12.3` or `12.3.1`.
  factory OSVersion.parse(String text) {
    final parts = text.split('.');
    final numbers = parts.map(int.tryParse).toList();
    if (parts.length > 3 || numbers.any((n) => n == null || n < 0)) {
      throw FormatException('Invalid OS version "$text".');
    }
    return OSVersion(
      numbers[0]!,
      numbers.length > 1 ? numbers[1]! : 0,
      numbers.length > 2 ? numbers[2]! : 0,
    );
  }

  /// Reads an int (a whole version) or a string such as `"12.3"`.
  factory OSVersion.fromJson(Object? json, String where) => switch (json) {
    final int major when major >= 0 => OSVersion(major),
    final String text => OSVersion.parse(text),
    _ => throw FormatException(
      '$where must be an int or a version string such as "12.3".',
    ),
  };

  final int major;
  final int minor;
  final int patch;

  AppleVersion toApple() => AppleVersion(major, minor: minor, patch: patch);

  /// An int for a whole version, as manifests before kiln 0.2 have.
  Object toJson() => minor == 0 && patch == 0 ? major : toString();

  @override
  int compareTo(OSVersion other) => major != other.major
      ? major.compareTo(other.major)
      : minor != other.minor
      ? minor.compareTo(other.minor)
      : patch.compareTo(other.patch);

  bool operator <(OSVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is OSVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => [
    major,
    if (minor != 0 || patch != 0) minor,
    if (patch != 0) patch,
  ].join('.');
}

/// Why prebuilt files with [minOSVersion] cannot serve [code], or null if
/// they can.
String? compatibilityProblem(CodeConfig code, OSVersion? minOSVersion) {
  if (code.linkModePreference == LinkModePreference.static) {
    return 'the build asks for static linking, and prebuilt files are '
        'dynamic libraries';
  }
  if (minOSVersion == null) return null;
  final (label, version) = switch (code.targetOS) {
    OS.iOS => ('iOS', OSVersion.apple(code.iOS.deploymentVersion)),
    OS.macOS => ('macOS', OSVersion.apple(code.macOS.deploymentVersion)),
    OS.android => ('Android API', OSVersion(code.android.targetNdkApi)),
    _ => (null, null),
  };
  if (label == null || version == null || !(version < minOSVersion)) {
    return null;
  }
  return 'the app supports $label $version, and the prebuilt files need '
      '$label $minOSVersion or later';
}
