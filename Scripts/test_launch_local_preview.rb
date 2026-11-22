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

  def stubbed_release_like_build(swift_flags:, conditions: "", entitlements: LOCAL_ENTITLEMENTS, measure: false)
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
        env, SCRIPT, "--release-like", *(measure ? ["--measure"] : []), "--build-only",
        "--derived-data", File.join(dir, "dd"), chdir: ROOT
      )
      built = File.exist?(env["STUB_LOG"])
      signing_file = File.join(dir, "dd", "PreviewState", "measure.entitlements")
      signing = File.exist?(signing_file) ? File.read(signing_file) : nil
      return [stdout, stderr, status, built, signing]
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

  MEASURE_FLAGS = "$(inherited) -DATTIC_LOCAL_ONLY -DATTIC_MEASURE"
  TASK_ALLOW_ENTITLEMENTS = LOCAL_ENTITLEMENTS.sub(
    "</dict>", "<key>com.apple.security.get-task-allow</key><true/>\n</dict>"
  )

  def test_measure_adds_only_attic_measure_to_the_release_like_build
    plain, plain_stderr, plain_status = dry_run("--release-like")
    measure, stderr, status = dry_run("--release-like", "--measure")
    assert plain_status.success?, plain_stderr
    assert status.success?, stderr
    plain_command = plain[/^build_command=.*$/]
    measure_command = measure[/^build_command=.*$/]

    assert_includes measure, "measure=true"
    assert_includes measure, "build_label=debug=0 measure=1 opt=1 frame_monitor=off"
    assert_includes plain, "build_label=debug=0 measure=0 opt=1 frame_monitor=off"
    refute_includes plain_command, "ATTIC_MEASURE"
    # The only differences: the flag, and the app-only entitlements file
    # (a global CODE_SIGN_ENTITLEMENTS would also re-sign the agent helper).
    expected = plain_command
      .sub("-DATTIC_LOCAL_ONLY", "-DATTIC_LOCAL_ONLY\\ -DATTIC_MEASURE")
      .sub(/ build $/, " ATTIC_MACOS_ENTITLEMENTS=")
    assert measure_command.start_with?(expected), "#{measure_command}\nis not\n#{expected}..."
    assert_match(%r{ ATTIC_MACOS_ENTITLEMENTS=\S*/PreviewState/measure\.entitlements ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW=YES build $}, measure_command)
    refute_includes plain_command, "GET_TASK_ALLOW"
    refute_includes measure_command, "CODE_SIGN_ENTITLEMENTS"
    refute_includes measure_command, "ATTIC_FIRST_TOUCH_LOG"
    refute_includes measure_command, "ATTIC_IDLE_SAMPLER"
  end

  def test_measure_requires_release_like
    [[], ["--optimized"], ["--first-touch-log"]].each do |extra|
      _stdout, stderr, status = dry_run("--measure", *extra)

      refute status.success?, "--measure #{extra.join(' ')} must be rejected"
      assert_includes stderr, "--measure requires --release-like"
    end
  end

  def test_measure_build_signs_with_the_project_entitlements_plus_get_task_allow
    stdout, stderr, status, built, signing = stubbed_release_like_build(
      swift_flags: MEASURE_FLAGS, entitlements: TASK_ALLOW_ENTITLEMENTS, measure: true
    )

    assert status.success?, stderr
    assert built
    source = File.read(File.join(ROOT, "Attic", "AtticNotesLocal.entitlements"))
    keys = ->(xml) { xml.scan(%r{<key>([^<]*)</key>}).flatten.sort }
    assert_equal (keys.(source) + ["com.apple.security.get-task-allow"]).sort, keys.(signing)
    assert_match(%r{^summary build_label=debug=0 measure=1 opt=1 frame_monitor=off configuration=Release get_task_allow=true cloud_push_keys=0 }, stdout)
  end

  def test_measure_refuses_settings_without_attic_measure
    _stdout, stderr, status, built = stubbed_release_like_build(
      swift_flags: "$(inherited) -DATTIC_LOCAL_ONLY", entitlements: TASK_ALLOW_ENTITLEMENTS, measure: true
    )

    refute status.success?
    assert_includes stderr, "measure build settings lack ATTIC_MEASURE"
    refute built
  end

  def test_plain_release_like_refuses_settings_with_attic_measure
    ["$(inherited) -DATTIC_LOCAL_ONLY -DATTIC_MEASURE", "$(inherited) -DATTIC_LOCAL_ONLY"].each_with_index do |flags, index|
      conditions = index.zero? ? "" : "$(inherited) ATTIC_MEASURE"
      _stdout, stderr, status, built = stubbed_release_like_build(swift_flags: flags, conditions: conditions)

      refute status.success?, "#{flags} #{conditions} must stop the build"
      assert_includes stderr, "carry ATTIC_MEASURE without --measure"
      refute built
    end
  end

  def test_measure_build_refuses_a_signature_without_get_task_allow
    _stdout, stderr, status, built = stubbed_release_like_build(swift_flags: MEASURE_FLAGS, measure: true)

    refute status.success?
    assert_includes stderr, "measure build lacks get-task-allow"
    assert built
  end

  def test_plain_release_like_refuses_a_signature_with_get_task_allow
    _stdout, stderr, status, built, signing = stubbed_release_like_build(
      swift_flags: "$(inherited) -DATTIC_LOCAL_ONLY", entitlements: TASK_ALLOW_ENTITLEMENTS
    )

    refute status.success?
    assert_includes stderr, "release-like build carries get-task-allow"
    assert built
    assert_nil signing, "plain release-like must not write a measure entitlements file"
  end

  def test_plain_release_like_summary_is_labelled_without_measure
    stdout, stderr, status = stubbed_release_like_build(swift_flags: "$(inherited) -DATTIC_LOCAL_ONLY")

    assert status.success?, stderr
    assert_match(/^summary build_label=debug=0 measure=0 opt=1 frame_monitor=off configuration=Release get_task_allow=absent cloud_push_keys=0 /, stdout)
  end

  def test_frame_monitor_is_a_launch_variable_labelled_on_the_summary
    stdout, stderr, status = dry_run("--release-like", "--measure", "--frame-monitor")
    assert status.success?, stderr
    assert_includes stdout, "build_label=debug=0 measure=1 opt=1 frame_monitor=on"
    assert_match(/^launch_command=\/usr\/bin\/open -n --env ATTIC_FRAME_MONITOR=1 /, stdout)
    # The build itself is the same: the monitor runs only on the variable.
    plain_measure, = dry_run("--release-like", "--measure")
    assert_equal plain_measure[/^build_command=.*$/], stdout[/^build_command=.*$/]
    refute_includes plain_measure, "ATTIC_FRAME_MONITOR"

    _stdout, stderr, status = dry_run("--release-like", "--frame-monitor")
    refute status.success?
    assert_includes stderr, "--frame-monitor with --release-like requires --measure"
  end

  def test_frame_monitor_compiles_for_measure_and_reads_its_variable_only_at_start
    monitor = File.read(File.join(ROOT, "Attic", "Performance", "AtticFrameMonitor.swift"))
    assert_includes monitor, "#if DEBUG || ATTIC_MEASURE\n"
    assert_equal 1, monitor.scan("ATTIC_FRAME_MONITOR\"]").size
    assert_includes File.read(File.join(ROOT, "Attic", "Performance", "NoteDragProbe.swift")), "#if DEBUG\n"
    delegate = File.read(File.join(ROOT, "Attic", "App", "AppDelegate.swift"))
    assert_includes delegate, "#if DEBUG || ATTIC_MEASURE\n        AtticFrameMonitor.startIfRequested()\n        #endif\n"
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
