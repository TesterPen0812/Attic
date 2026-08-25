#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'rbconfig'
require 'tmpdir'

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

puts 'Project generation is repeatable and Attic.xcodeproj is current'
