Pod::Spec.new do |s|
  s.name             = 'muybridge_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for Muybridge hardware-accelerated video playback.'
  s.homepage         = 'https://github.com/formula-systems-org/muybridge-engine'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Formula Systems' => 'dev@formula.systems' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '13.0'

  s.source_files = [
    'Classes/**/*.swift',
    '../../src/core/*.cpp',
    '../../platform/ios/src/*.{mm,h}',
    '../../include/**/*.h',
  ]

  s.public_header_files = [
    '../../include/**/*.h',
    '../../platform/ios/src/MuybridgeBridge.h',
  ]

  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '$(PODS_TARGET_SRCROOT)/../../include',
      '$(PODS_TARGET_SRCROOT)/../../platform/ios/src',
    ].join(' '),
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'MUYBRIDGE_PLATFORM_IOS=1',
  }

  s.frameworks = %w[AVFoundation CoreMedia CoreVideo VideoToolbox Metal MetalKit QuartzCore]

  s.dependency 'Flutter'
end
