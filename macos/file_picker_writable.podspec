#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint file_picker_writable.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'file_picker_writable'
  s.version          = '0.0.1'
  s.summary          = 'A new flutter plugin project.'
  s.description      = <<-DESC
A new flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'file_picker_writable/Sources/file_picker_writable/**/*'
  # PrivacyInfo.xcprivacy is only used by Swift Package Manager.
  s.exclude_files    = 'file_picker_writable/Sources/file_picker_writable/PrivacyInfo.xcprivacy'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
