#!/usr/bin/env ruby

require "minitest/autorun"
require "open3"

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

  def test_launcher_never_uses_broad_process_name_kills
    source = File.read(SCRIPT)

    refute_match(/\bkillall\b/, source)
    refute_match(/\bpkill\b/, source)
    assert_includes source, "command does not match the exact recorded executable"
    assert_includes source, "attic-exclusive-ui.lock"
  end
end
