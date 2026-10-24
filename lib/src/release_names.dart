/// Release tag for prebuilt files with source key [sourceKey].
String nativeReleaseTag(String sourceKey) =>
    'native-${sourceKey.substring(0, 16)}';

/// Release tag for runtime files whose name and SHA-256 hash to [setKey].
String runtimeReleaseTag(String setKey) => 'runtime-${setKey.substring(0, 16)}';

/// Asset name of file [fileName] of target [target].
String nativeAssetName(String target, String fileName) =>
    '$target-$fileName.gz';

/// Download URL of a GitHub release asset.
String githubAssetUrl(String repository, String tag, String assetName) =>
    'https://github.com/$repository/releases/download/$tag/$assetName';

/// Page URL of a GitHub release.
String githubReleaseUrl(String repository, String tag) =>
    'https://github.com/$repository/releases/tag/$tag';

/// Name of the file that a release-mode hook run writes into its output
/// directory, for `prebuilt:build`.
const releaseSidecarName = 'native_prebuilt_release.json';
