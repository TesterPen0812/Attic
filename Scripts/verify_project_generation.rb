#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'rbconfig'
require 'tmpdir'
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
GENERATOR = File.join(__dir__, 'generate_project.rb')
CHECKED_PROJECT = File.join(ROOT, 'Attic.xcodeproj')
PROJECT_FILES = [
  'project.pbxproj',
  'xcshareddata/xcschemes/CanvasLab.xcscheme',
  'project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
  'xcshareddata/xcschemes/Attic.xcscheme',
  'xcshareddata/xcschemes/AtticMobile.xcscheme',
  'xcshareddata/xcschemes/AtticRoundTrips.xcscheme'
].freeze

def generate(destination)
  success = system(
    RbConfig.ruby,
    GENERATOR,
    '--output',
    destination,
    out: File::NULL,
    err: File::NULL
  )
  abort 'Project generation failed' unless success
end

def digest(project_path)
  missing = PROJECT_FILES.reject { |relative| File.file?(File.join(project_path, relative)) }
  abort "Project is missing generated files: #{missing.join(', ')}" unless missing.empty?

  contents = PROJECT_FILES.map do |relative|
    relative + "\0" + File.binread(File.join(project_path, relative))
  end
  Digest::SHA256.hexdigest(contents.join)
end

Dir.mktmpdir('attic-project-check') do |directory|
  generated_project = File.join(directory, 'generated', 'Attic.xcodeproj')
  generate(generated_project)
  generated_digest = digest(generated_project)

  generate(generated_project)
  abort 'Project generation is not repeatable' unless digest(generated_project) == generated_digest

  checked_digest = digest(CHECKED_PROJECT)
  next if checked_digest == generated_digest

  abort <<~MESSAGE
    Attic.xcodeproj is stale relative to Scripts/generate_project.rb and the source tree.
    Run `bundle exec ruby Scripts/generate_project.rb`, review the generated project, and commit it.
  MESSAGE
end

project = Xcodeproj::Project.open(CHECKED_PROJECT)
host = project.targets.find { |target| target.name == 'AtticUnitTestHost' }
# The operation crash helper is the unit host's own executable, copied into
# Contents/MacOS and signed on its own (no second compile of the app sources).
abort 'Crash helper must not be a separate target that compiles the app again' if
  project.targets.any? { |target| target.name == 'AtticOperationCrashHelper' }
embed = host.shell_script_build_phases.find { |phase| phase.name == 'Embed operation crash helper' }
abort 'Missing crash helper embed phase on the unit host' unless embed
link_index = host.build_phases.index(host.frameworks_build_phase)
abort 'Crash helper must be copied after the host executable links' unless
  link_index && host.build_phases.index(embed) > link_index &&
  host.build_phases.index(embed) > host.build_phases.index(host.source_build_phase)
helper_output = '$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/AtticOperationCrashHelper'
abort 'Crash helper must be embedded in host Contents/MacOS' unless
  embed.output_paths == [helper_output] &&
  embed.input_paths.include?('$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)') &&
  embed.shell_script.include?('helper="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/AtticOperationCrashHelper"') &&
  embed.shell_script.include?('host="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"')
# Signing the copy with an explicit entitlements file injects no base
# entitlements (no get-task-allow): the helper carries only sandbox + inherit.
abort 'Helper must disable injected entitlements and force runtime signing' unless
  embed.shell_script.include?('--options runtime') &&
  embed.shell_script.include?('--entitlements "${SRCROOT}/AtticOperationCrashHelper/Helper.entitlements" "$helper"') &&
  embed.shell_script.scan('/usr/bin/codesign').length == 1
host_sources = host.source_build_phase.files.map { |file| file.file_ref.real_path.to_s }
abort 'Unit host must compile the crash helper entry point' unless
  host_sources.any? { |path| path.end_with?('/AtticUnitTestHost/OperationCrashHelperMode.swift') }
abort 'Unit host must compile crash hooks for its helper mode' unless host.build_configurations.all? { |config|
  config.build_settings.fetch('OTHER_SWIFT_FLAGS', '').include?('-DATTIC_OPERATION_CRASH_TESTS')
}
app = project.targets.find { |target| target.name == 'Attic' }
app_sources = app.source_build_phase.files.map { |file| file.file_ref.real_path.to_s }
model_sources = app_sources.select { |path| path.include?('/Models/') || path.end_with?('/PersistenceController.swift') }
abort 'Crash helper schema sources differ from app' unless (model_sources - host_sources).empty?
abort 'Shipping app must not enable crash hooks' if app.build_configurations.any? { |config|
  config.build_settings.fetch('OTHER_SWIFT_FLAGS', '').include?('ATTIC_OPERATION_CRASH_TESTS')
}

# A target that compiles a source naming WholeTableRead must compile the helper too (the deferred mobile target included).
# Test bundles reach it through `@testable import Attic`.
project.targets.select { |target| target.respond_to?(:source_build_phase) && !target.test_target_type? }.each do |target|
  paths = target.source_build_phase.files.filter_map { |file| file.file_ref&.real_path&.to_s }
  next if paths.any? { |path| path.end_with?('/WholeTableRead.swift') }
  users = paths.select { |path| path.end_with?('.swift') && File.exist?(path) && File.read(path).include?('WholeTableRead.') }
  abort "#{target.name} compiles #{users.map { |path| File.basename(path) }.join(', ')} without WholeTableRead.swift" unless users.empty?
end

puts 'Project generation is repeatable and Attic.xcodeproj is current'
