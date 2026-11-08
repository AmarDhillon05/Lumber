Pod::Spec.new do |s|
  s.name           = 'LumberMedia'
  s.version        = '1.0.0'
  s.summary        = 'AVFoundation helpers for Lumber'
  s.description    = 'Muxes the rendered mix onto the camera clip and exports AAC audio.'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = {
    :ios => '16.4'
  }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'AVFoundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }

  s.source_files = "**/*.{h,m,mm,swift}"
end
