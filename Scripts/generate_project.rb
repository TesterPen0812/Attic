#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'
require 'fileutils'
require 'optparse'
require 'securerandom'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
DEFAULT_PROJECT_PATH = File.join(ROOT, 'Attic.xcodeproj')
options = { project_path: DEFAULT_PROJECT_PATH }

OptionParser.new do |parser|
  parser.banner = 'Usage: ruby Scripts/generate_project.rb [options]'
  parser.on('--output PATH', 'Write the generated project to PATH') do |path|
    options[:project_path] = File.expand_path(path)
  end
  parser.on('-h', '--help', 'Show this help without changing the project') do
    puts parser
    exit
  end
end.parse!

project_path = options.fetch(:project_path)
FileUtils.mkdir_p(File.dirname(project_path))
staging_directory = Dir.mktmpdir('.attic-project-', File.dirname(project_path))
at_exit { FileUtils.rm_rf(staging_directory) if File.exist?(staging_directory) }
staged_project_path = File.join(staging_directory, File.basename(project_path))
# xcodeproj 1.27 can emit Xcode 16 projects but does not expose Apple's
# compatibility object version 71 as a constructor option. Generate using its
# supported format, then normalize the serialized project below.
project = Xcodeproj::Project.new(staged_project_path, false, 77)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2660'
project.root_object.attributes['LastUpgradeCheck'] = '2660'
project.add_build_configuration('Local', :debug)

app = project.new_target(:application, 'Attic', :osx, '14.0')
unit_tests = project.new_target(:unit_test_bundle, 'AtticTests', :osx, '14.0')
ui_tests = project.new_target(:ui_test_bundle, 'AtticUITests', :osx, '14.0')
mobile_app = project.new_target(:application, 'AtticMobile', :ios, '17.0')
mobile_tests = project.new_target(:unit_test_bundle, 'AtticMobileTests', :ios, '17.0')
mobile_ui_tests = project.new_target(:ui_test_bundle, 'AtticMobileUITests', :ios, '17.0')
unit_tests.add_dependency(app)
ui_tests.add_dependency(app)
mobile_tests.add_dependency(mobile_app)
mobile_ui_tests.add_dependency(mobile_app)

def add_swift_sources(project, target, group_name, directory)
  group = project.main_group.new_group(group_name, group_name)
  Dir.glob(File.join(ROOT, directory, '**', '*.swift')).sort.each do |path|
    relative = path.delete_prefix("#{ROOT}/")
    reference = group.new_file(relative.delete_prefix("#{group_name}/"))
    target.source_build_phase.add_file_reference(reference)
  end
  group
end

app_group = add_swift_sources(project, app, 'Attic', 'Attic')
add_swift_sources(project, unit_tests, 'AtticTests', 'AtticTests')
add_swift_sources(project, ui_tests, 'AtticUITests', 'AtticUITests')
mobile_group = add_swift_sources(project, mobile_app, 'AtticMobile', 'AtticMobile')
add_swift_sources(project, mobile_tests, 'AtticMobileTests', 'AtticMobileTests')
add_swift_sources(project, mobile_ui_tests, 'AtticMobileUITests', 'AtticMobileUITests')

shared_mobile_sources = [
  'Canvas/CanvasControls.swift',
  'Canvas/CanvasImageImporter.swift',
  'Canvas/CanvasImageTypes.swift',
  'Canvas/CanvasInputStateMachine.swift',
  'Canvas/CanvasSendable.swift',
  'Canvas/CanvasSession.swift',
  'Canvas/CanvasStrokeCodec.swift',
  'Canvas/CanvasSurface.swift',
  'Canvas/CanvasSurfaceIOS.swift',
  'Canvas/CanvasSurfaceInteraction.swift',
  'Canvas/CanvasSurfaceRenderer.swift',
  'Canvas/CanvasTypes.swift',
  'Canvas/CanvasViewport.swift',
  'Design/AtticTheme.swift',
  'Design/TaskActionsMenu.swift',
  'Models/CanvasBoardItem.swift',
  'Models/CanvasImageItem.swift',
  'Models/CanvasStrokeItem.swift',
  'Models/TaskItem.swift',
  'Models/TaskTypes.swift',
  'Models/NoteItem.swift',
  'Services/CanvasStore.swift',
  'Services/CanvasStoreBoards.swift',
  'Services/CanvasStoreCloudSync.swift',
  'Services/CanvasStoreImages.swift',
  'Services/CanvasStoreLifecycle.swift',
  'Services/CanvasStorePersistence.swift',
  'Services/CanvasStoreReplicaResolution.swift',
  'Services/CanvasStoreStrokes.swift',
  'Services/PersistenceController.swift',
  'Services/NoteStore.swift',
  'Services/TaskStore.swift'
]
shared_mobile_sources.each do |path|
  reference = app_group.files.find { |file| file.path == path }
  abort "Missing shared source: Attic/#{path}" unless reference

  mobile_app.source_build_phase.add_file_reference(reference)
end

assets = app_group.new_file('Resources/Assets.xcassets')
app.resources_build_phase.add_file_reference(assets)
mobile_app.resources_build_phase.add_file_reference(assets)
privacy_manifest = app_group.new_file('Resources/PrivacyInfo.xcprivacy')
app.resources_build_phase.add_file_reference(privacy_manifest)
mobile_app.resources_build_phase.add_file_reference(privacy_manifest)
app_group.new_file('Attic.entitlements')
app_group.new_file('AtticDebug.entitlements')
app_group.new_file('AtticLocal.entitlements')
app_group.new_file('AtticNotesLocal.entitlements')
app_group.new_file('Info.plist')
mobile_group.new_file('AtticMobile.entitlements')
mobile_group.new_file('Info.plist')

project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end

app.build_configurations.each do |config|
  settings = config.build_settings
  # Keep the official defaults while giving isolated UI hosts target-specific
  # override points. A global PRODUCT_BUNDLE_IDENTIFIER override also changes
  # the UI-test bundle and can make XCTest's runner unlaunchable.
  settings['ATTIC_MACOS_BUNDLE_IDENTIFIER'] = 'com.taha.Attic'
  settings['ATTIC_MACOS_PRODUCT_NAME'] = 'Attic'
  settings['ATTIC_MACOS_EXECUTABLE_NAME'] = 'Attic'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(ATTIC_MACOS_BUNDLE_IDENTIFIER)'
  settings['PRODUCT_NAME'] = '$(ATTIC_MACOS_PRODUCT_NAME)'
  settings['EXECUTABLE_NAME'] = '$(ATTIC_MACOS_EXECUTABLE_NAME)'
  settings['PRODUCT_MODULE_NAME'] = 'Attic'
  settings['ATTIC_DISPLAY_NAME'] = 'Attic'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'Attic/Info.plist'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Attic/AtticNotesLocal.entitlements'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = 'ZGZWS73268'
  settings['ENABLE_APP_SANDBOX'] = 'YES'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  settings['OTHER_SWIFT_FLAGS'] = '$(inherited) -DATTIC_LOCAL_ONLY'
  settings['MARKETING_VERSION'] = '1.1'
  settings['CURRENT_PROJECT_VERSION'] = '11'
end

unit_tests.build_configurations.each do |config|
  settings = config.build_settings
  # TEST_HOST is evaluated in the unit-test target's build-setting scope, so
  # keep ordinary Local/Debug runs usable when no isolated-host overrides are
  # supplied on the xcodebuild command line.
  settings['ATTIC_MACOS_PRODUCT_NAME'] = 'Attic'
  settings['ATTIC_MACOS_EXECUTABLE_NAME'] = 'Attic'
  settings['ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER'] = 'com.taha.AtticTests'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER)'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['OTHER_SWIFT_FLAGS'] = '$(inherited) -DATTIC_LOCAL_ONLY'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = 'ZGZWS73268'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/$(ATTIC_MACOS_PRODUCT_NAME).app/Contents/MacOS/$(ATTIC_MACOS_EXECUTABLE_NAME)'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

ui_tests.build_configurations.each do |config|
  settings = config.build_settings
  settings['ATTIC_MACOS_UI_TEST_BUNDLE_IDENTIFIER'] = 'com.taha.AtticUITests'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(ATTIC_MACOS_UI_TEST_BUNDLE_IDENTIFIER)'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = 'ZGZWS73268'
  settings['TEST_TARGET_NAME'] = 'Attic'
end

mobile_app.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.emanueledipietro.Attic'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['PRODUCT_MODULE_NAME'] = 'AtticMobile'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'AtticMobile/Info.plist'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'AtticMobile/AtticMobile.entitlements'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = 'HR24WHR326'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['SDKROOT'] = 'iphoneos'
  settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['SUPPORTS_MACCATALYST'] = 'NO'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '9'
  settings['ICLOUD_CONTAINER_ENVIRONMENT'] = config.name == 'Release' ? 'Production' : 'Development'
  settings['APS_ENVIRONMENT'] = config.name == 'Release' ? 'production' : 'development'
  abort "Mismatched AtticMobile CloudKit/APNs environment for #{config.name}" unless
    (settings['ICLOUD_CONTAINER_ENVIRONMENT'] == 'Production') ==
      (settings['APS_ENVIRONMENT'] == 'production')
end

mobile_tests.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.emanueledipietro.AtticMobileTests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = 'HR24WHR326'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['SDKROOT'] = 'iphoneos'
  settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/AtticMobile.app/AtticMobile'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

mobile_ui_tests.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.emanueledipietro.AtticMobileUITests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = 'HR24WHR326'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['SDKROOT'] = 'iphoneos'
  settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['TEST_TARGET_NAME'] = 'AtticMobile'
end

# xcodeproj includes the current random project/target UUIDs in proxy paths when
# predictabilizing target dependencies. Stable placeholders remove that random
# input; the real deterministic UUIDs are restored immediately afterwards.
target_proxies = project.objects.grep(Xcodeproj::Project::Object::PBXContainerItemProxy)
proxy_targets = target_proxies.to_h do |proxy|
  target = project.targets.find { |candidate| candidate.uuid == proxy.remote_global_id_string }
  abort "Missing target for dependency proxy #{proxy.uuid}" unless target

  [proxy, target]
end
proxy_targets.each_with_index do |(proxy, _target), index|
  proxy.container_portal = 'PROJECT'
  proxy.remote_global_id_string = "DEPENDENCY_TARGET_#{index}"
end
project.predictabilize_uuids
proxy_targets.each do |proxy, target|
  proxy.container_portal = project.root_object.uuid
  proxy.remote_global_id_string = target.uuid
end

target_attributes = project.root_object.attributes['TargetAttributes'] ||= {}
target_attributes[mobile_app.uuid] = {
  'SystemCapabilities' => {
    'com.apple.BackgroundModes' => { 'enabled' => 1 },
    'com.apple.iCloud' => { 'enabled' => 1 },
    'com.apple.Push' => { 'enabled' => 1 }
  }
}

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.launch_action.build_configuration = 'Local'
scheme.add_test_target(unit_tests)
scheme.add_test_target(ui_tests)
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'ATTIC_TESTING', value: '1', enabled: true }
])
scheme.save_as(staged_project_path, 'Attic', true)

mobile_scheme = Xcodeproj::XCScheme.new
mobile_scheme.add_build_target(mobile_app)
mobile_scheme.set_launch_target(mobile_app)
mobile_scheme.launch_action.build_configuration = 'Local'
mobile_scheme.add_test_target(mobile_tests)
mobile_scheme.add_test_target(mobile_ui_tests)
mobile_scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'ATTIC_TESTING', value: '1', enabled: true }
])
mobile_scheme.save_as(staged_project_path, 'AtticMobile', true)

# Keep target UUIDs stable when the macOS source graph changes. The checked-in
# schemes are part of the generated project contract, and changing only the
# macOS target's source list must not churn their buildable references.
stable_target_uuids = {
  app => 'A7714C2169D9DBD5A01DC94837E1C051',
  unit_tests => '6276F3101BBBD6791E37F0DC63F158C3',
  ui_tests => '29D42C445B39133F6CE8ED3394F0BD54',
  mobile_app => '6A9C0775F09BF19B3C70496EEC4AF237',
  mobile_tests => 'A7E2FBB4FDEEC93FE643B32D6940915E',
  mobile_ui_tests => '1BD194A0EE08899209C8473CFFD68DA0'
}.freeze

project.save

project_file = File.join(staged_project_path, 'project.pbxproj')
project_contents = File.read(project_file)
stable_target_uuids.each do |target, stable_uuid|
  project_contents.gsub!(target.uuid, stable_uuid)
end
project_contents.sub!("\tobjectVersion = 77;", "\tobjectVersion = 71;")
project_contents.gsub!(/^\s*minimizedProjectReferenceProxies = 0;\n/, '')
project_contents.gsub!(/^\s*preferredProjectObjectVersion = 77;\n/, '')
File.write(project_file, project_contents)

['Attic', 'AtticMobile'].each do |scheme_name|
  scheme_file = File.join(
    staged_project_path,
    'xcshareddata',
    'xcschemes',
    "#{scheme_name}.xcscheme"
  )
  scheme_contents = File.read(scheme_file)
  stable_target_uuids.each do |target, stable_uuid|
    scheme_contents.gsub!(target.uuid, stable_uuid)
  end
  File.write(scheme_file, scheme_contents)
end

Xcodeproj::Project.open(staged_project_path)

backup_path = "#{project_path}.backup-#{Process.pid}-#{SecureRandom.hex(4)}"
FileUtils.mv(project_path, backup_path) if File.exist?(project_path)
begin
  FileUtils.mv(staged_project_path, project_path)
rescue StandardError
  FileUtils.mv(backup_path, project_path) if File.exist?(backup_path) && !File.exist?(project_path)
  raise
ensure
  FileUtils.rm_rf(backup_path) if File.exist?(project_path)
  FileUtils.rm_rf(staging_directory)
end

puts "Generated #{project_path}"
