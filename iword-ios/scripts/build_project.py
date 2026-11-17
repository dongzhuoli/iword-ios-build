"""Deterministic Xcode project generation; no XcodeGen installation is required."""
from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
objects = {}
counter = 0
def add(value):
    global counter
    counter += 1
    key = f'{counter:024X}'
    objects[key] = value
    return key

source_refs, source_builds = [], []
for source in sorted((ROOT / 'IWord').glob('*.swift')):
    ref = add(dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path=source.name, sourceTree='<group>'))
    source_refs.append(ref)
    source_builds.append(add(dict(isa='PBXBuildFile', fileRef=ref)))
assets = add(dict(isa='PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>'))
sample = add(dict(isa='PBXFileReference', lastKnownFileType='archive.zip', path='sample.zip', sourceTree='<group>'))
resource_builds = [add(dict(isa='PBXBuildFile', fileRef=ref)) for ref in [assets, sample]]
product = add(dict(isa='PBXFileReference', explicitFileType='wrapper.application', path='IWord.app', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0'))
group = add(dict(isa='PBXGroup', children=source_refs + [assets, sample], path='IWord', sourceTree='<group>'))
products = add(dict(isa='PBXGroup', children=[product], name='Products', sourceTree='<group>'))
main = add(dict(isa='PBXGroup', children=[group, products], sourceTree='<group>'))
core = add(dict(isa='XCLocalSwiftPackageReference', relativePath='Core'))
zip_package = add(dict(isa='XCRemoteSwiftPackageReference', repositoryURL='https://github.com/weichsel/ZIPFoundation.git', requirement=dict(kind='exactVersion', version='0.9.19')))
dependencies = [add(dict(isa='XCSwiftPackageProductDependency', package=core, productName=name)) for name in ['IWordDomain', 'IWordStorage']]
dependencies += [add(dict(isa='XCSwiftPackageProductDependency', package=zip_package, productName='ZIPFoundation'))]
frameworks = [add(dict(isa='PBXBuildFile', productRef=dependency)) for dependency in dependencies]
sources = add(dict(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=source_builds, runOnlyForDeploymentPostprocessing='0'))
resources = add(dict(isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=resource_builds, runOnlyForDeploymentPostprocessing='0'))
framework_phase = add(dict(isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files=frameworks, runOnlyForDeploymentPostprocessing='0'))
def configurations(target):
    result = []
    for name in ['Debug', 'Release']:
        settings = dict(IPHONEOS_DEPLOYMENT_TARGET='15.0', SWIFT_VERSION='5.0', SDKROOT='iphoneos', CLANG_ENABLE_MODULES='YES', SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O', ONLY_ACTIVE_ARCH='YES' if name == 'Debug' else 'NO', ENABLE_TESTABILITY='YES' if name == 'Debug' else 'NO')
        if target:
            settings.update(PRODUCT_BUNDLE_IDENTIFIER='biz.powerunion.iword', PRODUCT_NAME='$(TARGET_NAME)', CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='1.1.0', GENERATE_INFOPLIST_FILE='YES', INFOPLIST_FILE='IWord/Info.plist', INFOPLIST_KEY_CFBundleDisplayName='iWord', INFOPLIST_KEY_UILaunchScreen_Generation='YES', INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES', INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone='UIInterfaceOrientationPortrait', TARGETED_DEVICE_FAMILY='1', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', CODE_SIGN_STYLE='Automatic', SWIFT_EMIT_LOC_STRINGS='NO', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace='YES', INFOPLIST_KEY_UIFileSharingEnabled='NO')
        result.append(add(dict(isa='XCBuildConfiguration', buildSettings=settings, name=name)))
    return add(dict(isa='XCConfigurationList', buildConfigurations=result, defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
target_config = configurations(True)
project_config = configurations(False)
target = add(dict(isa='PBXNativeTarget', buildConfigurationList=target_config, buildPhases=[sources, resources, framework_phase], buildRules=[], dependencies=[], name='IWord', packageProductDependencies=dependencies, productName='IWord', productReference=product, productType='com.apple.product-type.application'))
ui_ref = add(dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path='OfflineFlowTests.swift', sourceTree='<group>'))
ui_group = add(dict(isa='PBXGroup', children=[ui_ref], path='UITests', sourceTree='<group>'))
objects[main]['children'].insert(1, ui_group)
ui_product = add(dict(isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='IWordUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0'))
objects[products]['children'].append(ui_product)
ui_build = add(dict(isa='PBXBuildFile', fileRef=ui_ref))
ui_phase = add(dict(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=[ui_build], runOnlyForDeploymentPostprocessing='0'))
ui_configs = []
for name in ['Debug','Release']:
    ui_configs.append(add(dict(isa='XCBuildConfiguration', name=name, buildSettings=dict(PRODUCT_BUNDLE_IDENTIFIER='biz.powerunion.iword.uitests', PRODUCT_NAME='$(TARGET_NAME)', IPHONEOS_DEPLOYMENT_TARGET='15.0', SWIFT_VERSION='5.0', SDKROOT='iphoneos', GENERATE_INFOPLIST_FILE='YES', TARGETED_DEVICE_FAMILY='1', TEST_TARGET_NAME='IWord', CODE_SIGN_STYLE='Automatic', ONLY_ACTIVE_ARCH='YES' if name == 'Debug' else 'NO'))))
ui_config = add(dict(isa='XCConfigurationList', buildConfigurations=ui_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
ui_dependency = add(dict(isa='PBXTargetDependency', target=target))
ui_target = add(dict(isa='PBXNativeTarget', buildConfigurationList=ui_config, buildPhases=[ui_phase], buildRules=[], dependencies=[ui_dependency], name='IWordUITests', productName='IWordUITests', productReference=ui_product, productType='com.apple.product-type.bundle.ui-testing'))
# Host-based tests exercise the real installer, update client and P1 data compatibility.
unit_refs = [add(dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path=source.name, sourceTree='<group>')) for source in sorted((ROOT / 'Tests').glob('*.swift'))]
fixture_ref = add(dict(isa='PBXFileReference', lastKnownFileType='folder', path='Fixtures', sourceTree='<group>'))
unit_group = add(dict(isa='PBXGroup', children=unit_refs + [fixture_ref], path='Tests', sourceTree='<group>'))
objects[main]['children'].insert(1, unit_group)
unit_product = add(dict(isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='IWordTests.xctest', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0'))
objects[products]['children'].append(unit_product)
unit_builds = [add(dict(isa='PBXBuildFile', fileRef=ref)) for ref in unit_refs]
unit_fixture = add(dict(isa='PBXBuildFile', fileRef=fixture_ref))
unit_phase = add(dict(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=unit_builds, runOnlyForDeploymentPostprocessing='0'))
unit_resources = add(dict(isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=[unit_fixture], runOnlyForDeploymentPostprocessing='0'))
unit_configs = []
for name in ['Debug','Release']:
    unit_configs.append(add(dict(isa='XCBuildConfiguration', name=name, buildSettings=dict(PRODUCT_BUNDLE_IDENTIFIER='biz.powerunion.iword.tests', PRODUCT_NAME='$(TARGET_NAME)', IPHONEOS_DEPLOYMENT_TARGET='15.0', SWIFT_VERSION='5.0', SDKROOT='iphoneos', GENERATE_INFOPLIST_FILE='YES', TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', ONLY_ACTIVE_ARCH='YES' if name == 'Debug' else 'NO', TEST_HOST='$(BUILT_PRODUCTS_DIR)/IWord.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/IWord', BUNDLE_LOADER='$(TEST_HOST)', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if name == 'Debug' else ''))))
unit_config = add(dict(isa='XCConfigurationList', buildConfigurations=unit_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
unit_dependency = add(dict(isa='PBXTargetDependency', target=target))
unit_target = add(dict(isa='PBXNativeTarget', buildConfigurationList=unit_config, buildPhases=[unit_phase, unit_resources], buildRules=[], dependencies=[unit_dependency], name='IWordTests', productName='IWordTests', productReference=unit_product, productType='com.apple.product-type.bundle.unit-test'))
project = add(dict(isa='PBXProject', attributes=dict(LastUpgradeCheck='1640', TargetAttributes={ui_target:dict(TestTargetID=target),unit_target:dict(TestTargetID=target)}), buildConfigurationList=project_config, compatibilityVersion='Xcode 14.0', developmentRegion='zh_CN', hasScannedForEncodings='0', knownRegions=['en', 'Base', 'zh_CN'], mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target,ui_target,unit_target], packageReferences=[core, zip_package]))
def dump(value, level=0):
    indent = '    ' * level
    if isinstance(value, dict):
        return '{\n' + '\n'.join('    ' * (level+1) + json.dumps(k, ensure_ascii=False) + ' = ' + dump(v, level+1) + ';' for k,v in value.items()) + '\n' + indent + '}'
    if isinstance(value, list):
        return '(' + ', '.join(dump(v, level) for v in value) + ')'
    return json.dumps(value, ensure_ascii=False)
path = ROOT / 'IWord.xcodeproj'
path.mkdir(exist_ok=True)
(path / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + dump(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=project)), encoding='utf-8')
scheme = path / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
(scheme / 'IWord.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="IWord.app" BlueprintName="IWord" ReferencedContainer="container:IWord.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{unit_target}" BuildableName="IWordTests.xctest" BlueprintName="IWordTests" ReferencedContainer="container:IWord.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="IWordUITests.xctest" BlueprintName="IWordUITests" ReferencedContainer="container:IWord.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="IWord.app" BlueprintName="IWord" ReferencedContainer="container:IWord.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''', encoding='utf-8')
print('Generated IWord.xcodeproj with', len(source_refs), 'Swift source files')
