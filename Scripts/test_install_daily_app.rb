#!/usr/bin/env ruby
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class InstallDailyAppTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(__dir__, "install_daily_app.zsh")

  def invoke(*arguments)
    Open3.capture3(SCRIPT, *arguments, chdir: ROOT)
  end

  def test_no_arguments_only_explain_usage
    stdout, stderr, status = invoke
    assert status.success?, stderr
    assert_includes stdout, "Usage:"
    refute_includes stdout, "source_sha="
  end

  def test_dry_run_resolves_separate_fixed_daily_identity_and_local_store
    stdout, stderr, status = invoke("--dry-run")
    assert status.success?, stderr
    assert_includes stdout, "target_app=/Applications/Attic Daily.app"
    assert_includes stdout, "bundle_id=com.taha.Attic\n"
    assert_includes stdout, "configuration=Local"
    assert_includes stdout, "compile_flags=ATTIC_LOCAL_ONLY ATTIC_DAILY"
    assert_includes stdout, "store_environment=Development"
    assert_includes stdout, "Attic/AtticNotesLocal.entitlements"
    assert_includes stdout, "project_team_id=ZGZWS73268"
    assert_includes stdout, "local_signing_team=ZGZWS73268"
  end

  def test_explicit_local_signing_override_does_not_change_project_team
    stdout, stderr, status = invoke("--dry-run", "--development-team", "AQ484LXN59",
                                   "--signing-identity", "12F1981F20A99BA8CC316439D7A04ACE14643BC0")
    assert status.success?, stderr
    assert_includes stdout, "project_team_id=ZGZWS73268"
    assert_includes stdout, "local_signing_team=AQ484LXN59"
    assert_includes stdout, "bundle_id=com.taha.Attic\n"
  end

  def test_signing_override_rejects_ad_hoc_names_and_invalid_team_ids
    [["--signing-identity", "-"], ["--signing-identity", "Apple Development"],
     ["--development-team", "bad"]].each do |arguments|
      _, _, status = invoke("--dry-run", *arguments)
      refute status.success?
    end
  end

  def test_install_requires_pinned_commit_before_building
    _, stderr, status = invoke("--install")
    refute status.success?
    assert_includes stderr, "installation requires --expected-sha"
  end

  def test_short_or_mismatched_commit_is_rejected
    _, stderr, status = invoke("--install", "--expected-sha", "fb1b52f")
    refute status.success?
    assert_includes stderr, "full 40-character commit"
    _, stderr, status = invoke("--install", "--expected-sha", "0" * 40)
    refute status.success?
    assert_includes stderr, "does not match"
  end

  def test_callers_cannot_redirect_installer_to_another_app_or_store
    ["--bundle-id", "--install-dir", "--configuration"].each do |argument|
      _, stderr, status = invoke("--dry-run", argument, "unexpected")
      refute status.success?
      assert_includes stderr, "unknown option"
    end
  end

  def test_conflicting_modes_are_rejected
    _, stderr, status = invoke("--dry-run", "--install")
    refute status.success?
    assert_includes stderr, "choose exactly one mode"
  end

  def test_dirty_checkout_is_rejected_before_install_side_effects
    Dir.mktmpdir("attic-daily-policy-") do |root|
      FileUtils.mkdir_p(File.join(root, "Scripts"))
      script = File.join(root, "Scripts", "install_daily_app.zsh")
      FileUtils.cp(SCRIPT, script)
      commands = [
        ["init", "-q"], ["add", "Scripts"],
        ["-c", "user.name=Attic Test", "-c", "user.email=test@example.invalid",
         "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"]
      ]
      commands.each do |arguments|
        _, stderr, status = Open3.capture3("git", *arguments, chdir: root)
        assert status.success?, stderr
      end
      sha, = Open3.capture3("git", "rev-parse", "HEAD", chdir: root)
      File.write(File.join(root, "unfinished.txt"), "Preserve this uncommitted work")
      _, stderr, status = Open3.capture3(script, "--install", "--expected-sha", sha.strip, chdir: root)
      refute status.success?
      assert_includes stderr, "requires a clean source tree"
      refute File.exist?(File.join(root, ".build"))
      assert_equal "Preserve this uncommitted work", File.read(File.join(root, "unfinished.txt"))
    end
  end

  def test_development_launcher_still_rejects_the_official_identity
    _, stderr, status = Open3.capture3(File.join(ROOT, "script/build_and_run.sh"),
                                    "--dry-run", "--bundle-id", "com.taha.Attic", chdir: ROOT)
    refute status.success?
    assert_includes stderr, "official com.taha.Attic identity is not a preview identity"
  end
end
