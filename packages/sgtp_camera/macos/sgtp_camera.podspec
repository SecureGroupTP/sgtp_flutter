Pod::Spec.new do |s|
  s.name             = 'sgtp_camera'
  s.version          = '0.1.0'
  s.summary          = 'GStreamer-based camera plugin for SGTP'
  s.homepage         = 'https://github.com/placeholder'
  s.license          = { :type => 'MIT' }
  s.author           = { 'SGTP' => 'placeholder@example.com' }
  s.source           = { :path => '.' }

  s.platform = :osx, '10.14'
  s.source_files = 'Classes/**/*'

  # GStreamer.framework must be installed at /Library/Frameworks/GStreamer.framework
  # Install via: https://gstreamer.freedesktop.org/data/pkg/osx/
  s.frameworks = []
  s.xcconfig = {
    'FRAMEWORK_SEARCH_PATHS' => '/Library/Frameworks',
    'OTHER_LDFLAGS' => '$(shell PKG_CONFIG_PATH=/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/pkgconfig pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-audio-1.0)',
    'OTHER_CFLAGS'  => '$(shell PKG_CONFIG_PATH=/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/pkgconfig pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-audio-1.0)',
  }

  s.dependency 'FlutterMacOS'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
