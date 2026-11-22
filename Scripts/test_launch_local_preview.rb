#!/usr/bin/env ruby

require "minitest/autorun"
require "open3"
require "tmpdir"

class LaunchLocalPreviewTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(__dir__, "launch_local_preview.zsh")

  def dry_run(*arguments)
    Open3.capture3(SCRIPT, "--dry-run", *arguments, chdir: ROOT)
  end

  def test_defaults_are_local_unique_and_do_not_install_or_mutate_appearance
    stdout, stderr, status = dry_run

    assert status.success?, stderr
    assert_match(/^bundle_id=com\.taha\.Attic\.preview\.[0-9a-f]{12}$/, stdout)
    assert_match(/^derived_data=\/tmp\/attic-preview-derived-/, stdout)
    assert_includes stdout, "-DATTIC_LOCAL_ONLY"
    assert_includes stdout, "appearance=unchanged"
    refute_includes stdout, "/Applications"
    refute_includes stdout, "appearance_command="
  end

  def test_every_requested_identity_path_and_signing_value_is_resolved
    stdout, stderr, status = dry_run(
      "--display-name", "Attic Ledger Preview",
      "--bundle-id", "com.taha.Attic.ledger.preview",
      "--executable-name", "AtticLedgerPreview",
      "--derived-data", "/tmp/attic-ledger-derived",
      "--install-dir", "/tmp/attic-ledger-install",
      "--signing-identity", "-",
      "--appearance", "dark"
    )

    assert status.success?, stderr
    assert_includes stdout, "display_name=Attic Ledger Preview"
    assert_includes stdout, "bundle_id=com.taha.Attic.ledger.preview"
    assert_includes stdout, "executable_name=AtticLedgerPreview"
    assert_includes stdout, "derived_data=/tmp/attic-ledger-derived"
    assert_includes stdout, "preview_app=/tmp/attic-ledger-install/Attic Ledger Preview.app"
    assert_includes stdout, "appearance_command=explicit isolated defaults update"
  end

  def test_official_bundle_identity_is_rejected
    _stdout, stderr, status = dry_run("--bundle-id", "com.taha.Attic")

    refute status.success?
    assert_includes stderr, "official com.taha.Attic identity is not a preview identity"
  end

  def test_applications_requires_a_second_explicit_opt_in
    _stdout, stderr, status = dry_run("--install-dir", "/Applications")

    refute status.success?
    assert_includes stderr, "requires --allow-applications-install"
  end

  def test_display_name_cannot_escape_an_explicit_install_directory
    _stdout, stderr, status = dry_run(
      "--display-name", "../Attic",
      "--install-dir", "/tmp/attic-preview-test"
    )

    refute status.success?
    assert_includes stderr, "single path-safe component"
  end

  def test_executable_name_reaches_only_the_app_target
    stdout, stderr, status = dry_run("--executable-name", "AtticLedgerPreview")

    assert status.success?, stderr
    assert_includes stdout, "ATTIC_MACOS_PRODUCT_NAME=AtticLedgerPreview"
    assert_includes stdout, "ATTIC_MACOS_EXECUTABLE_NAME=AtticLedgerPreview"
    # A command-line PRODUCT_NAME renames the Swift package targets too
    # (cmark-gfm), and the build fails with "Multiple commands produce".
    refute_match(/(^|[\s'"])PRODUCT_NAME=/, stdout)
    refute_match(/(^|[\s'"])EXECUTABLE_NAME=/, stdout)
  end

  def test_launcher_never_uses_broad_process_name_kills
    source = File.read(SCRIPT)

    refute_match(/\bkillall\b/, source)
    refute_match(/\bpkill\b/, source)
    assert_includes source, "command does not match the exact recorded executable"
    assert_includes source, "attic-exclusive-ui.lock"
  end

  def test_release_like_builds_release_without_debug_or_diagnostic_flags
    stdout, stderr, status = dry_run("--release-like")

    assert status.success?, stderr
    assert_includes stdout, "release_like=true"
    assert_includes stdout, "configuration=Release"
    assert_includes stdout, "-configuration Release"
    assert_match(%r{CONFIGURATION_BUILD_DIR=/tmp/attic-preview-derived-[0-9a-f]{12}/Build/Products/Release}, stdout)
    assert_includes stdout, "-DATTIC_LOCAL_ONLY"
    refute_includes stdout, "ATTIC_FIRST_TOUCH_LOG"
    refute_includes stdout, "ATTIC_IDLE_SAMPLER"
    %w[
      SWIFT_OPTIMIZATION_LEVEL=-O
      SWIFT_COMPILATION_MODE=wholemodule
      ENABLE_DEBUG_DYLIB=NO
      ENABLE_TESTABILITY=NO
      STRIP_INSTALLED_PRODUCT=NO
      CODE_SIGN_IDENTITY=-
    ].each { |setting| assert_includes stdout, setting }
    # Without DEBUG the app would otherwise pick the Production store name;
    # the preview keeps the same development.store a Local preview opens.
    assert_includes stdout, "store_environment=Development"
    assert_match(/^bundle_id=com\.taha\.Attic\.preview\.[0-9a-f]{12}$/, stdout)
  end

  def test_release_like_rejects_debug_build_options
    [
      ["--optimized"],
      ["--first-touch-log"],
      ["--configuration", "Local"]
    ].each do |extra|
      _stdout, stderr, status = dry_run("--release-like", *extra)

      refute status.success?, "--release-like #{extra.join(' ')} must be rejected"
      assert_includes stderr, "--release-like cannot be combined"
    end
  end

  # A stubbed xcodebuild (settings read and a fake build product) and a stubbed
  # codesign (entitlements read), so the release-like guards run end to end
  # without a real build.
  STUB_XCODEBUILD = <<~'ZSH'
    #!/bin/zsh
    if (( ${@[(I)-showBuildSettings]} )); then
      print -- "Build settings for action build and target AtticAgentHelper:"
      print -- "    OTHER_SWIFT_FLAGS = $(inherited) -DATTIC_LOCAL_ONLY"
      print -- "Build settings for action build and target Attic:"
      print -- "    CODE_SIGN_ENTITLEMENTS = Attic/AtticNotesLocal.entitlements"
      print -- "    OTHER_SWIFT_FLAGS = $STUB_SWIFT_FLAGS"
      print -- "    SWIFT_ACTIVE_COMPILATION_CONDITIONS = $STUB_CONDITIONS"
      exit 0
    fi
    for a in "$@"; do
      case $a in
        CONFIGURATION_BUILD_DIR=*) dir=${a#*=} ;;
        ATTIC_MACOS_EXECUTABLE_NAME=*) exe=${a#*=} ;;
        PRODUCT_BUNDLE_IDENTIFIER=*) id=${a#*=} ;;
        INFOPLIST_FILE=*) plist=${a#*=} ;;
      esac
    done
    print -- built >>"$STUB_LOG"
    /bin/mkdir -p "$dir/$exe.app/Contents/MacOS"
    /bin/cp "$plist" "$dir/$exe.app/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string "$id" "$dir/$exe.app/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleExecutable -string "$exe" "$dir/$exe.app/Contents/Info.plist"
    print -- stub >"$dir/$exe.app/Contents/MacOS/$exe"
    /bin/chmod +x "$dir/$exe.app/Contents/MacOS/$exe"
  ZSH
  STUB_CODESIGN = <<~'ZSH'
    #!/bin/zsh
    if (( ${@[(I)--entitlements]} )); then /bin/cat "$STUB_ENTITLEMENTS"; fi
    exit 0
  ZSH
  LOCAL_ENTITLEMENTS = <<~XML
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    </dict></plist>
  XML

  def stubbed_release_like_build(swift_flags:, conditions: "", entitlements: LOCAL_ENTITLEMENTS)
    Dir.mktmpdir("attic-release-like-guard") do |dir|
      dir = File.realpath(dir)
      { "xcodebuild" => STUB_XCODEBUILD, "codesign" => STUB_CODESIGN }.each do |name, body|
        File.write(File.join(dir, name), body)
        File.chmod(0o755, File.join(dir, name))
      end
      File.write(File.join(dir, "entitlements.plist"), entitlements)
      env = {
        "ATTIC_XCODEBUILD_COMMAND" => File.join(dir, "xcodebuild"),
        "ATTIC_CODESIGN_COMMAND" => File.join(dir, "codesign"),
        "STUB_SWIFT_FLAGS" => swift_flags,
        "STUB_CONDITIONS" => conditions,
        "STUB_ENTITLEMENTS" => File.join(dir, "entitlements.plist"),
        "STUB_LOG" => File.join(dir, "stub.log")
      }
      stdout, stderr, status = Open3.capture3(
        env, SCRIPT, "--release-like", "--build-only",
        "--derived-data", File.join(dir, "dd"), chdir: ROOT
      )
      built = File.exist?(env["STUB_LOG"])
      return [stdout, stderr, status, built]
    end
  end

  def test_release_like_refuses_settings_without_attic_local_only
    _stdout, stderr, status, built = stubbed_release_like_build(swift_flags: "$(inherited)")

    refute status.success?
    assert_includes stderr, "lack ATTIC_LOCAL_ONLY"
    refute built, "nothing may be built once the settings fail"
  end

  def test_release_like_refuses_debug_in_resolved_settings
    _stdout, stderr, status, built = stubbed_release_like_build(
      swift_flags: "$(inherited) -DATTIC_LOCAL_ONLY", conditions: "$(inherited) DEBUG"
    )

    refute status.success?
    assert_includes stderr, "carry DEBUG or a Local diagnostic flag"
    refute built
  end

  def test_release_like_refuses_any_icloud_or_push_entitlement
    %w[
      com.apple.developer.icloud-services
      com.apple.developer.icloud-container-identifiers
      com.apple.developer.icloud-container-environment
      com.apple.developer.ubiquity-container-identifiers
      com.apple.developer.ubiquity-kvstore-identifier
      aps-environment
      com.apple.developer.aps-environment
    ].each do |key|
      entitlements = LOCAL_ENTITLEMENTS.sub("</dict>", "<key>#{key}</key><string>Production</string>\n</dict>")
      _stdout, stderr, status, built = stubbed_release_like_build(
        swift_flags: "$(inherited) -DATTIC_LOCAL_ONLY", entitlements: entitlements
      )

      refute status.success?, "#{key} must stop the build"
      assert_includes stderr, "carries iCloud or push entitlements (#{key})"
      assert built
    end
  end

  def test_release_like_prints_the_resolved_entitlements_file
    stdout, stderr, status, built = stubbed_release_like_build(swift_flags: "$(inherited) -DATTIC_LOCAL_ONLY")

    assert status.success?, stderr
    assert built
    assert_includes stdout, "code_sign_entitlements=Attic/AtticNotesLocal.entitlements"
  end

  def test_desktop_run_passes_release_like_through_and_finds_its_product
    wrapper = File.join(ROOT, "script", "build_and_run.sh")
    stdout, stderr, status = Open3.capture3(wrapper, "--dry-run", "--release-like", chdir: ROOT)
    assert status.success?, stderr
    assert_includes stdout, "release_like=true"
    assert_includes stdout, "-configuration Release"
    assert_match(/^bundle_id=com\.taha\.Attic\.local\.[0-9a-f]{12}$/, stdout)
    assert_includes File.read(wrapper), "Build/Products/$CONFIGURATION/"
  end

  def test_desktop_run_delegates_to_same_isolated_launcher
    wrapper = File.join(ROOT, "script", "build_and_run.sh")
    stdout, stderr, status = Open3.capture3(wrapper, "--dry-run", chdir: ROOT)
    assert status.success?, stderr
    assert_match(/^bundle_id=com\.taha\.Attic\.local\.[0-9a-f]{12}$/, stdout)
    assert_includes stdout, "signing_identity=-"
    assert_includes stdout, "-DATTIC_LOCAL_ONLY"
    refute_includes stdout, "/Applications"
    refute_match(/\b(pkill|killall)\b/, File.read(wrapper))
  end
end
