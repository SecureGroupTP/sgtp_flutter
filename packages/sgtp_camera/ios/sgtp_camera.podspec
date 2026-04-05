Pod::Spec.new do |s|
  s.name             = 'sgtp_camera'
  s.version          = '0.1.0'
  s.summary          = 'GStreamer-based camera plugin for SGTP'
  s.homepage         = 'https://github.com/placeholder'
  s.license          = { :type => 'MIT' }
  s.author           = { 'SGTP' => 'placeholder@example.com' }
  s.source           = { :path => '.' }

  s.platform = :ios, '12.0'
  s.source_files = 'Classes/**/*.{h,m,c}'

  # GStreamer iOS XCFramework must be installed.
  # Download from https://gstreamer.freedesktop.org/data/pkg/ios/
  # and place at ~/Library/Developer/GStreamer/iPhone.sdk/GStreamer.framework
  s.vendored_frameworks = [
    '${HOME}/Library/Developer/GStreamer/iPhone.sdk/GStreamer.framework'
  ]
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo',
                 'CoreAudio', 'AudioToolbox', 'VideoToolbox',
                 'Foundation', 'UIKit'
  s.libraries = 'iconv', 'resolv', 'z', 'bz2', 'c++'

  s.dependency 'Flutter'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) IOS=1',
  }
end
