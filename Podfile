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
  # Note: Mac Catalyst VLC exclusion from linker flags is handled by
  # scripts/package-maccatalyst-dmg.sh (patches xcconfigs before build)
end
