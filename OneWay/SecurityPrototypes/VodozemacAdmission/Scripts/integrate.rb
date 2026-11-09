require 'xcodeproj'
project = Xcodeproj::Project.open('OneWay.xcodeproj')
abort 'Admission targets already exist; inspect before rerunning' if project.targets.any? { |t| t.name == 'OneWayVodozemacAdmission' }
root='SecurityPrototypes/VodozemacAdmission'
group=project.main_group.new_group('VodozemacAdmission',root)
crypto=project.new_target(:framework,'OneWayVodozemacAdmission',:ios,'18.0')
host=project.new_target(:application,'VodozemacAdmissionHost',:ios,'18.0')
tests=project.new_target(:unit_test_bundle,'VodozemacAdmissionTests',:ios,'18.0')
def sources(target,group,paths)
  paths.each { |path| target.source_build_phase.add_file_reference(group.new_file(path)) }
end
sources(crypto,group,['Generated/oneway_vodozemac.swift','Swift/ProtectedStore.swift','Swift/OneWayE2EEEngine.swift'])
attachment=project.main_group.new_file('SecurityPrototypes/Phase1B2/Sources/OneWayPhase1B2/AttachmentEnvelope.swift')
crypto.source_build_phase.add_file_reference(attachment)
sources(host,group,['Host/AdmissionHost.swift'])
sources(tests,group,['Tests/AdmissionTests.swift'])
host.add_dependency(crypto);tests.add_dependency(crypto);tests.add_dependency(host)
host.frameworks_build_phase.add_file_reference(crypto.product_reference)
tests.frameworks_build_phase.add_file_reference(crypto.product_reference)
copy=host.new_copy_files_build_phase('Embed Admission Framework');copy.dst_subfolder_spec='10'
copy.add_file_reference(crypto.product_reference).settings={'ATTRIBUTES'=>['CodeSignOnCopy','RemoveHeadersOnCopy']}
[crypto,host,tests].each do |t|
  t.build_configurations.each do |c|
    c.build_settings.merge!({'SWIFT_VERSION'=>'5.0','GENERATE_INFOPLIST_FILE'=>'YES','PRODUCT_BUNDLE_IDENTIFIER'=>"is.oneway.alt2.#{t.name}",'CODE_SIGN_STYLE'=>'Automatic','DEVELOPMENT_TEAM'=>'','ENABLE_TESTABILITY'=>'YES','SWIFT_STRICT_CONCURRENCY'=>'minimal','SUPPORTED_PLATFORMS'=>'iphoneos iphonesimulator','TARGETED_DEVICE_FAMILY'=>'1,2'})
    c.build_settings['PRODUCT_NAME']='$(TARGET_NAME)'
    c.build_settings['SWIFT_INCLUDE_PATHS']='$(inherited) "$(SRCROOT)/SecurityPrototypes/VodozemacAdmission/Generated"'
    c.build_settings['HEADER_SEARCH_PATHS']='$(inherited) "$(SRCROOT)/SecurityPrototypes/VodozemacAdmission/Generated"'
  end
end
crypto.build_configurations.each do |c|
  c.build_settings.merge!({'DEFINES_MODULE'=>'YES','SKIP_INSTALL'=>'YES','ALT2_MODE'=>'stable','HEADER_SEARCH_PATHS'=>'$(inherited) "$(SRCROOT)/SecurityPrototypes/VodozemacAdmission/Generated"','SWIFT_INCLUDE_PATHS'=>'$(inherited) "$(SRCROOT)/SecurityPrototypes/VodozemacAdmission/Generated"','OTHER_LDFLAGS'=>'$(inherited) -lsqlite3 -lresolv -liconv "$(SRCROOT)/SecurityPrototypes/VodozemacAdmission/Artifacts/$(ALT2_MODE)/$(PLATFORM_NAME)/liboneway_vodozemac.a"'})
end
host.build_configurations.each { |c| c.build_settings['LD_RUNPATH_SEARCH_PATHS']='$(inherited) @executable_path/Frameworks';c.build_settings['SKIP_INSTALL']='NO' }
tests.build_configurations.each do |c|
  c.build_settings.merge!({'TEST_HOST'=>'$(BUILT_PRODUCTS_DIR)/VodozemacAdmissionHost.app/VodozemacAdmissionHost','BUNDLE_LOADER'=>'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS'=>'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
end
scheme=Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.set_launch_target(host)
scheme.add_test_target(tests)
scheme.test_action.build_configuration='Debug'
scheme.save_as('OneWay.xcodeproj','VodozemacAdmission',true)
project.save
