platform :ios, '17.0'

target 'AudiobookPlayer' do
  use_frameworks!

  # VLC media player for formats not supported by AVPlayer (MKV, WebM)
  # Note: MobileVLCKit only supports iOS, not Mac Catalyst
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  # Mark MobileVLCKit as not supporting Mac Catalyst
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if target.name == 'MobileVLCKit' || target.name.start_with?('MobileVLCKit')
        config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
      end
    end
  end

  # Patch Pods xcconfigs to exclude MobileVLCKit for Mac Catalyst (regular builds)
  xcconfigs_path = File.join(installer.sandbox.root, 'Target Support Files')
  if File.directory?(xcconfigs_path)
    Dir.glob(File.join(xcconfigs_path, '**/*.xcconfig')).each do |xcconfig|
      if File.read(xcconfig).include?('MobileVLCKit')
        content = File.read(xcconfig)
        # Remove -framework "MobileVLCKit" and -framework "OpenGLES"
        content = content.gsub(' -framework "MobileVLCKit"', '')
        content = content.gsub(' -framework "OpenGLES"', '')
        # Remove MobileVLCKit framework search paths
        content = content.gsub(/\s*"\$\{PODS_ROOT\}\/MobileVLCKit"/, '')
        content = content.gsub(/\s*"\$\{PODS_XCFRAMEWORKS_BUILD_DIR\}\/MobileVLCKit"/, '')
        content = content.gsub(/\s*"-F\$\{PODS_CONFIGURATION_BUILD_DIR\}\/MobileVLCKit"/, '')
        # Remove existing macosx conditional blocks
        content = content.gsub(/OTHER_LDFLAGS\[sdk=macosx.*\n?.*/, '')
        # Add conditional exclusion for Mac Catalyst
        content = content + "\n// Mac Catalyst: exclude MobileVLCKit\n"
        content = content + "OTHER_LDFLAGS[sdk=macosx*] = $(inherited)\n"
        content = content + "FRAMEWORK_SEARCH_PATHS[sdk=macosx*] = $(inherited)\n"
        File.write(xcconfig, content)
      end
    end
  end
end
