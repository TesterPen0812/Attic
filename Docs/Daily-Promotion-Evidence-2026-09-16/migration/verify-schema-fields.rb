#!/usr/bin/env ruby
require "open3"

ROOT = "/Users/taha/Developer/attic-task-panels-v2"
INSTALLED = "8b03586df79c6d667a6aea444b74f7167e552568"
CANDIDATE = "f8a18a09b7d6cc914ab97fdfad252d1f2f8b3d6c"
FILES = %w[
  Attic/Models/TaskItem.swift
  Attic/Models/NoteItem.swift
  Attic/Models/NoteAttachment.swift
  Attic/Models/CanvasBoardItem.swift
  Attic/Models/CanvasStrokeItem.swift
  Attic/Models/CanvasImageItem.swift
  Attic/Models/CanvasSemanticObjectItem.swift
].freeze

def git_models(revision)
  FILES.to_h do |path|
    output, error, status = Open3.capture3("git", "show", "#{revision}:#{path}", chdir: ROOT)
    abort(error) unless status.success?
    [path, output]
  end
end

def declarations(text)
  result = {}
  text.split("@Model").drop(1).each do |model_text|
    name = model_text[/final class\s+(\w+)/, 1]
    next unless name
    prefix = model_text.split(/^\s*init\s*\(/, 2).first
    fields = prefix.lines.each_with_object([]) do |line, values|
      next if line.include?("@Transient")
      match = line.match(/(?:@Attribute\(([^)]*)\)\s+)?(?:private\s+)?var\s+(\w+)\s*:\s*([^=]+?)\s*=/)
      next unless match
      attribute = match[1]&.strip || "none"
      type = match[3].strip.gsub(/\s+/, " ")
      values << [match[2], type, attribute]
    end
    result[name] = fields
  end
  result
end

def source_declarations(revision)
  git_models(revision).values.reduce({}) { |all, text| all.merge(declarations(text)) }
end

harness = File.read(File.join(__dir__, "MigrationGate.swift"))
installed_harness = harness[/private enum Installed8b03586 \{(.*?)\/\/ Exact persisted fields/m, 1]
candidate_harness = harness[/private enum CandidateF8a18a0 \{(.*?)\n\}\n\nfunc installedSchema/m, 1]
abort("unable to locate harness schema sections") unless installed_harness && candidate_harness

comparisons = {
  "installed" => [source_declarations(INSTALLED), declarations(installed_harness)],
  "candidate" => [source_declarations(CANDIDATE), declarations(candidate_harness)],
}

failed = false
comparisons.each do |label, (source, reproduced)|
  puts "#{label}_models=#{source.keys.sort.join(',')}"
  if source == reproduced
    puts "#{label}_persisted_fields_and_attributes=MATCH"
  else
    failed = true
    puts "#{label}_persisted_fields_and_attributes=MISMATCH"
    (source.keys | reproduced.keys).sort.each do |model|
      next if source[model] == reproduced[model]
      puts "#{model}.source=#{source[model].inspect}"
      puts "#{model}.harness=#{reproduced[model].inspect}"
    end
  end
end

_output, _error, status = Open3.capture3(
  "git", "diff", "--quiet", "#{CANDIDATE}..HEAD", "--", *FILES, chdir: ROOT
)
if status.success?
  puts "current_head_model_sources_match_candidate=true"
else
  failed = true
  puts "current_head_model_sources_match_candidate=false"
end

exit(failed ? 1 : 0)
