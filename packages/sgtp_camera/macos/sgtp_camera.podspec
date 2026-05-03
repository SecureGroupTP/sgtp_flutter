Pod::Spec.new do |s|
  require 'shellwords'

  gst_modules = 'gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-audio-1.0'
  framework_pkgconfig = '/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/pkgconfig'
  env_pkgconfig = ENV.fetch('PKG_CONFIG_PATH', '')
  pkgconfig_path = [framework_pkgconfig, env_pkgconfig].reject(&:empty?).join(':')
  pkgconfig_prefix = pkgconfig_path.empty? ? '' : "PKG_CONFIG_PATH=#{pkgconfig_path.shellescape} "

  pkg_config_available = system('command -v pkg-config >/dev/null 2>&1')
  cflags = pkg_config_available ? `#{pkgconfig_prefix}pkg-config --cflags #{gst_modules}`.strip : ''
  ldflags = pkg_config_available ? `#{pkgconfig_prefix}pkg-config --libs #{gst_modules}`.strip : ''
  has_gstreamer = !cflags.empty? && !ldflags.empty?

  if !has_gstreamer && defined?(Pod::UI)
    Pod::UI.warn(
      'sgtp_camera: pkg-config/GStreamer not found; building the macOS stub. ' \
      'Install GStreamer.framework and pkg-config to enable camera support.'
    )
  end

  s.name             = 'sgtp_camera'
  s.version          = '0.1.0'
  s.summary          = 'GStreamer-based camera plugin for SGTP'
  s.homepage         = 'https://github.com/placeholder'
  s.license          = { :type => 'MIT' }
  s.author           = { 'SGTP' => 'placeholder@example.com' }
  s.source           = { :path => '.' }

  s.platform = :osx, '10.14'
  s.source_files = has_gstreamer ? 'Classes/sgtp_camera.c' : 'Classes/sgtp_camera_stub.c'

  # GStreamer.framework must be installed at /Library/Frameworks/GStreamer.framework
  # Install via: https://gstreamer.freedesktop.org/data/pkg/osx/
  s.frameworks = []
  s.xcconfig = {
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) /Library/Frameworks',
    'OTHER_LDFLAGS' => "$(inherited) #{ldflags}".strip,
    'OTHER_CFLAGS'  => "$(inherited) #{cflags}".strip,
  }

  s.dependency 'FlutterMacOS'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
