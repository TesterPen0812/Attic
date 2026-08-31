#!/usr/bin/env ruby

require "minitest/autorun"
require "open3"

class RunLocalUITestsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(__dir__, "run_local_ui_tests.zsh")

  def dry_run(*arguments)
    Open3.capture3(SCRIPT, "--dry-run", *arguments, chdir: ROOT)
  end

  def test_defaults_use_three_distinct_local_identities_and_signed_two_stage_run
    stdout, stderr, status = dry_run

    assert status.success?, stderr
    app_id = stdout[/^app_bundle_id=(.+)$/, 1]
    ui_id = stdout[/^ui_test_bundle_id=(.+)$/, 1]
    unit_id = stdout[/^unit_test_bundle_id=(.+)$/, 1]
    assert_match(/^com\.taha\.Attic\./, app_id)
    assert_match(/^com\.taha\.Attic\./, ui_id)
    assert_match(/^com\.taha\.Attic\./, unit_id)
    assert_equal 3, [app_id, ui_id, unit_id].uniq.count
    assert_includes stdout, "build-for-testing"
    assert_includes stdout, "test-without-building"
    assert_includes stdout, "CODE_SIGNING_ALLOWED=YES"
    assert_includes stdout, "CODE_SIGNING_REQUIRED=YES"
    assert_includes stdout, "-DATTIC_LOCAL_ONLY"
    assert_includes stdout, "scheme=AtticUI"
    assert_includes stdout, "ui_lock=/tmp/attic-exclusive-ui.lock"
    refute_match(/(?:^|\s)PRODUCT_BUNDLE_IDENTIFIER=/, stdout)
    refute_includes stdout, "platform=macOS,arch=arm64"
    refute_includes File.read(SCRIPT), "arch=arm64"
  end

  def test_explicit_identities_and_selection_are_target_specific
    stdout, stderr, status = dry_run(
      "--app-bundle-id", "com.taha.Attic.ui.host",
      "--ui-test-bundle-id", "com.taha.Attic.ui.tests",
      "--unit-test-bundle-id", "com.taha.Attic.unit.tests",
      "--product-name", "AtticUIHost",
      "--display-name", "Attic UI Host",
      "--derived-data", "/tmp/attic-ui-host-derived",
      "--result-bundle", "/tmp/attic-ui-host.xcresult",
      "--only-testing", "AtticUITests/CanvasUITests/testModeDockExpandsOnHoverAndCollapsesAfterPointerLeaves"
    )

    assert status.success?, stderr
    assert_includes stdout, "ATTIC_MACOS_BUNDLE_IDENTIFIER=com.taha.Attic.ui.host"
    assert_includes stdout, "ATTIC_MACOS_UI_TEST_BUNDLE_IDENTIFIER=com.taha.Attic.ui.tests"
    assert_includes stdout, "ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=com.taha.Attic.unit.tests"
    assert_includes stdout, "ATTIC_MACOS_PRODUCT_NAME=AtticUIHost"
    assert_includes stdout, "-only-testing:AtticUITests/CanvasUITests/testModeDockExpandsOnHoverAndCollapsesAfterPointerLeaves"
  end

  def test_official_or_duplicate_identifiers_are_rejected
    _stdout, stderr, status = dry_run("--app-bundle-id", "com.taha.Attic")
    refute status.success?
    assert_includes stderr, "unique com.taha.Attic.*"

    _stdout, stderr, status = dry_run(
      "--app-bundle-id", "com.taha.Attic.same",
      "--ui-test-bundle-id", "com.taha.Attic.same"
    )
    refute status.success?
    assert_includes stderr, "must all be distinct"
  end

  def test_source_requires_atomic_ui_lock_and_never_disables_signing
    source = File.read(SCRIPT)

    assert_includes source, "if ! /bin/mkdir \"$ui_lock_path\""
    assert_includes source, "trap release_ui_lock EXIT"
    assert_includes source, "CODE_SIGNING_ALLOWED=YES"
    refute_includes source, "CODE_SIGNING_ALLOWED=NO"
    assert_operator source.index("build-for-testing"), :<, source.index("/bin/mkdir \"$ui_lock_path\"")
    assert_operator source.index("/bin/mkdir \"$ui_lock_path\""), :<, source.rindex("test-without-building")
  end

  def test_build_only_is_explicit_and_stops_before_live_lock
    stdout, stderr, status = dry_run("--build-only")

    assert status.success?, stderr
    assert_includes stdout, "build_only=true"
    source = File.read(SCRIPT)
    assert_operator source.index("$build_only && exit 0"), :<, source.index("lock_owner=")
  end

  def test_ordinary_unit_tests_use_dedicated_no_ui_host
    generator = File.read(File.join(__dir__, "generate_project.rb"))
    host_settings = generator[/unit_host\.build_configurations\.each.*?^end$/m]
    unit_settings = generator[/unit_tests\.build_configurations\.each.*?^end$/m]

    refute_nil host_settings
    assert_includes host_settings,
      "settings['ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER'] = 'com.taha.Attic.UnitTestHost'"
    assert_includes host_settings,
      "settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER)'"
    assert_includes host_settings,
      "settings['PRODUCT_NAME'] = '$(ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME)'"
    assert_includes host_settings,
      "settings['EXECUTABLE_NAME'] = '$(ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME)'"
    assert_includes host_settings, "settings['INFOPLIST_KEY_LSUIElement'] = 'YES'"
    refute_nil unit_settings
    assert_includes unit_settings,
      "settings['ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER'] = 'com.taha.Attic.UnitTestHost'"
    assert_includes unit_settings,
      "settings['OTHER_SWIFT_FLAGS'] = '$(inherited) -DATTIC_LOCAL_ONLY -module-alias Attic=AtticUnitTestHost'"
    assert_includes unit_settings,
      "$(ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME).app/Contents/MacOS/$(ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME)"
  end

  def test_default_scheme_is_unit_only_and_ui_runner_uses_dedicated_scheme
    generator = File.read(File.join(__dir__, "generate_project.rb"))
    unit_scheme = generator[/scheme = Xcodeproj::XCScheme\.new.*?scheme\.save_as\(staged_project_path, 'Attic', true\)/m]
    ui_scheme = generator[/ui_scheme = Xcodeproj::XCScheme\.new.*?ui_scheme\.save_as\(staged_project_path, 'AtticUI', true\)/m]

    refute_nil unit_scheme
    assert_includes unit_scheme, "scheme.build_action.entries.last.build_for_testing = false"
    assert_includes unit_scheme, "scheme.add_build_target(unit_host, false)"
    assert_includes unit_scheme, "scheme.add_test_target(unit_tests)"
    refute_includes unit_scheme, "scheme.add_test_target(ui_tests)"
    refute_nil ui_scheme
    assert_includes ui_scheme, "ui_scheme.add_test_target(ui_tests)"
    assert_includes File.read(SCRIPT), 'scheme="AtticUI"'
  end
end
