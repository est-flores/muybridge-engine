Pod::Spec.new do |s|
  s.name             = 'muybridge_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for Muybridge hardware-accelerated video playback.'
  s.homepage         = 'https://github.com/est-flores/muybridge-engine'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Formula Systems, LLC. All rights reserved.' }
  s.author           = { 'Formula Systems' => 'dev@formula.systems' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '13.0'

  s.source_files = [
    'Classes/*.{swift,h}',
    'Classes/engine_core/*.cpp',
    'Classes/engine_ios/*.{mm,h}',
  ]

  s.public_header_files = [
    'Classes/MuybridgeBridge.h',
  ]

  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '$(PODS_TARGET_SRCROOT)/Classes/engine_include',
      '$(PODS_TARGET_SRCROOT)/Classes/engine_ios',
    ].join(' '),
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'MUYBRIDGE_PLATFORM_IOS=1',
  }

  s.frameworks = %w[AVFoundation CoreMedia CoreVideo VideoToolbox Metal MetalKit QuartzCore]

  s.dependency 'Flutter'
end
