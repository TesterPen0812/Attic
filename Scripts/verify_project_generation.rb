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
  'xcshareddata/xcschemes/Attic.xcscheme',
  'xcshareddata/xcschemes/AtticMobile.xcscheme'
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
helper = project.targets.find { |target| target.name == 'AtticOperationCrashHelper' }
abort 'Missing crash helper target' unless helper
embed = host.copy_files_build_phases.find { |phase| phase.name == 'Embed operation crash helper' }
abort 'Crash helper must be embedded in host Contents/MacOS' unless
  embed && embed.dst_subfolder_spec == '6' && embed.dst_path.empty? &&
  embed.files.any? { |file| file.file_ref == helper.product_reference &&
    file.settings.fetch('ATTRIBUTES', []).include?('CodeSignOnCopy') }
app = project.targets.find { |target| target.name == 'Attic' }
app_sources = app.source_build_phase.files.map { |file| file.file_ref.real_path.to_s }
helper_sources = helper.source_build_phase.files.map { |file| file.file_ref.real_path.to_s }
model_sources = app_sources.select { |path| path.include?('/Models/') || path.end_with?('/PersistenceController.swift') }
abort 'Crash helper schema sources differ from app' unless (model_sources - helper_sources).empty?
abort 'Helper must disable injected entitlements and force runtime signing' unless helper.build_configurations.all? { |config|
  config.build_settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] == 'NO' &&
    config.build_settings['OTHER_CODE_SIGN_FLAGS'] == '--options runtime'
}
abort 'Shipping app must not enable crash hooks' if app.build_configurations.any? { |config|
  config.build_settings.fetch('OTHER_SWIFT_FLAGS', '').include?('ATTIC_OPERATION_CRASH_TESTS')
}

puts 'Project generation is repeatable and Attic.xcodeproj is current'
