// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest
@testable import TulsiGenerator

// Note: Rather than test the serializer's output, we make use of the knowledge that
// buildSerializerWithRuleEntries modifies a project directly.
class BazelTargetGeneratorTests: XCTestCase {
  let bazelURL = NSURL(fileURLWithPath: "__BAZEL_BINARY_")
  let rootURL = NSURL.fileURLWithPath("/root", isDirectory: true)
  var project: PBXProject! = nil
  var targetGenerator: BazelTargetGenerator! = nil

  override func setUp() {
    super.setUp()
    project = PBXProject(name: "TestProject")
    targetGenerator = BazelTargetGenerator(bazelURL: bazelURL,
                                           project: project,
                                           buildScriptPath: "",
                                           envScriptPath: "",
                                           options: TulsiOptionSet(),
                                           localizedMessageLogger: MockLocalizedMessageLogger())

  }

  // MARK: - Tests

  func testGenerateFileReferenceForSingleBUILDFilePath() {
    let buildFilePath = "some/path/BUILD"
    targetGenerator.generateFileReferencesForFilePaths([buildFilePath])
    XCTAssertEqual(project.mainGroup.children.count, 1)

    let fileRef = project.mainGroup.allSources.first!
    let sourceRelativePath = fileRef.sourceRootRelativePath
    XCTAssertEqual(sourceRelativePath, buildFilePath)
    XCTAssertEqual(fileRef.sourceTree, SourceTree.Group, "SourceTree mismatch for generated BUILD file \(buildFilePath)")
  }

  func testGenerateFileReferenceForBUILDFilePaths() {
    let buildFilePaths = ["BUILD", "some/path/BUILD", "somewhere/else/BUILD"]
    targetGenerator.generateFileReferencesForFilePaths(buildFilePaths)
    XCTAssertEqual(project.mainGroup.children.count, buildFilePaths.count)

    for fileRef in project.mainGroup.allSources {
      XCTAssert(buildFilePaths.contains(fileRef.sourceRootRelativePath), "Path mismatch for generated BUILD file \(fileRef.path)")
      XCTAssertEqual(fileRef.sourceTree, SourceTree.Group, "SourceTree mismatch for generated BUILD file \(fileRef.path)")
    }
  }

  func testMainGroupForOutputFolder() {
    func assertOutputFolder(output: String,
                            workspace: String,
                            generatesSourceTree sourceTree: SourceTree,
                            path: String?,
                            line: UInt = __LINE__) {
      let outputURL = NSURL(fileURLWithPath: output, isDirectory: true)
      let workspaceURL = NSURL(fileURLWithPath: workspace, isDirectory: true)
      let group = BazelTargetGenerator.mainGroupForOutputFolder(outputURL,
                                                                workspaceRootURL: workspaceURL)
      XCTAssertEqual(group.sourceTree, sourceTree, line: line)
      XCTAssertEqual(group.path, path, line: line)
    }

    assertOutputFolder("/", workspace: "/", generatesSourceTree: .SourceRoot, path: nil)
    assertOutputFolder("/output", workspace: "/output", generatesSourceTree: .SourceRoot, path: nil)
    assertOutputFolder("/output/", workspace: "/output", generatesSourceTree: .SourceRoot, path: nil)
    assertOutputFolder("/output", workspace: "/output/", generatesSourceTree: .SourceRoot, path: nil)
    assertOutputFolder("/", workspace: "/output", generatesSourceTree: .SourceRoot, path: "output")
    assertOutputFolder("/output", workspace: "/output/workspace", generatesSourceTree: .SourceRoot, path: "workspace")
    assertOutputFolder("/output/", workspace: "/output/workspace", generatesSourceTree: .SourceRoot, path: "workspace")
    assertOutputFolder("/output", workspace: "/output/workspace/", generatesSourceTree: .SourceRoot, path: "workspace")
    assertOutputFolder("/output", workspace: "/output/deep/path/workspace", generatesSourceTree: .SourceRoot, path: "deep/path/workspace")
    assertOutputFolder("/path/to/workspace/output", workspace: "/path/to/workspace", generatesSourceTree: .SourceRoot, path: "..")
    assertOutputFolder("/output", workspace: "/", generatesSourceTree: .SourceRoot, path: "..")
    assertOutputFolder("/output/", workspace: "/", generatesSourceTree: .SourceRoot, path: "..")
    assertOutputFolder("/path/to/workspace/three/deep/output", workspace: "/path/to/workspace", generatesSourceTree: .SourceRoot, path: "../../..")
    assertOutputFolder("/path/to/output", workspace: "/elsewhere/workspace", generatesSourceTree: .Absolute, path: "/elsewhere/workspace")
  }
}


class BazelTargetGeneratorTestsWithFiles: XCTestCase {
  let bazelURL = NSURL(fileURLWithPath: "__BAZEL_BINARY_")
  let sdkRoot = "sdkRoot"
  var project: PBXProject! = nil
  var targetGenerator: BazelTargetGenerator! = nil

  var sourceFileNames = [String]()
  var pathFilters = Set<String>([""])
  var sourceFileReferences = [PBXFileReference]()
  var pchFile: PBXFileReference! = nil

  override func setUp() {
    super.setUp()

    project = PBXProject(name: "TestProject")
    sourceFileNames = ["test.swift", "test.cc"]
    pathFilters = Set<String>([""])
    rebuildSourceFileReferences()
    pchFile = project.mainGroup.getOrCreateFileReferenceBySourceTree(.Group, path: "pch.pch")
    let options = TulsiOptionSet()
    options[.SDKROOT].projectValue = sdkRoot
    targetGenerator = BazelTargetGenerator(bazelURL: bazelURL,
                                           project: project,
                                           buildScriptPath: "",
                                           envScriptPath: "",
                                           options: options,
                                           localizedMessageLogger: MockLocalizedMessageLogger())
  }

  // MARK: - Tests

  func testGenerateBazelCleanTarget() {
    let scriptPath = "scriptPath"
    let workingDirectory = "/directory/of/work"
    targetGenerator.generateBazelCleanTarget(scriptPath, workingDirectory: workingDirectory)
    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)

    XCTAssertNotNil(targets[BazelTargetGenerator.BazelCleanTarget] as? PBXLegacyTarget)
    let target = targets[BazelTargetGenerator.BazelCleanTarget] as! PBXLegacyTarget

    XCTAssertEqual(target.buildToolPath, scriptPath)

    // The script should launch the test scriptPath with bazelURL's path as the only argument.
    let expectedScriptArguments = "\"\(bazelURL.path!)\""
    XCTAssertEqual(target.buildArgumentsString, expectedScriptArguments)
  }

  func testGenerateBazelCleanTargetAppliesToRulesAddedBeforeAndAfter() {
    do {
      try targetGenerator.generateBuildTargetsForRuleEntries([makeTestRuleEntry("before", type: "ios_application")])
    } catch let e as NSError {
      XCTFail("Failed to generate build targets with error \(e.localizedDescription)")
    }

    targetGenerator.generateBazelCleanTarget("scriptPath")

    do {
      try targetGenerator.generateBuildTargetsForRuleEntries([makeTestRuleEntry("after", type: "ios_application")])
    } catch let e as NSError {
      XCTFail("Failed to generate build targets with error \(e.localizedDescription)")
    }

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 3)

    XCTAssertNotNil(targets[BazelTargetGenerator.BazelCleanTarget] as? PBXLegacyTarget)
    let integrationTarget = targets[BazelTargetGenerator.BazelCleanTarget] as! PBXLegacyTarget

    for target in project.allTargets {
      if target === integrationTarget { continue }
      XCTAssertEqual(target.dependencies.count, 1, "Mismatch in dependency count for target added \(target.name)")
      let targetProxy = target.dependencies[0].targetProxy
      XCTAssert(targetProxy.containerPortal === project, "Mismatch in container for dependency in target added \(target.name)")
      XCTAssert(targetProxy.target === integrationTarget, "Mismatch in target dependency for target added \(target.name)")
      XCTAssertEqual(targetProxy.proxyType,
          PBXContainerItemProxy.ProxyType.TargetReference,
          "Mismatch in target dependency type for target added \(target.name)")
    }
  }

  func testGenerateTopLevelBuildConfigurations() {
    targetGenerator.generateTopLevelBuildConfigurations()

    let topLevelConfigs = project.buildConfigurationList.buildConfigurations
    XCTAssertEqual(topLevelConfigs.count, 3)

    let topLevelBuildSettings = [
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGNING_REQUIRED": "NO",
        "ENABLE_TESTABILITY": "YES",
        "HEADER_SEARCH_PATHS": "$(SRCROOT)",
        "IPHONEOS_DEPLOYMENT_TARGET": "8.4",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": sdkRoot,
    ]
    XCTAssertNotNil(topLevelConfigs["Debug"])
    XCTAssertEqual(topLevelConfigs["Debug"]!.buildSettings, topLevelBuildSettings)
    XCTAssertNotNil(topLevelConfigs["Release"])
    XCTAssertEqual(topLevelConfigs["Release"]!.buildSettings, topLevelBuildSettings)
    XCTAssertNotNil(topLevelConfigs["Fastbuild"])
    XCTAssertEqual(topLevelConfigs["Fastbuild"]!.buildSettings, topLevelBuildSettings)
  }

  func testGenerateTopLevelBuildConfigurationsWithAdditionalIncludes() {
    let additionalIncludePaths = Set<String>(["additional", "include/paths"])
    targetGenerator.generateTopLevelBuildConfigurations(additionalIncludePaths)

    let topLevelConfigs = project.buildConfigurationList.buildConfigurations
    XCTAssertEqual(topLevelConfigs.count, 3)

    let topLevelBuildSettings = [
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGNING_REQUIRED": "NO",
        "ENABLE_TESTABILITY": "YES",
        "HEADER_SEARCH_PATHS": "$(SRCROOT) $(SRCROOT)/additional $(SRCROOT)/include/paths",
        "IPHONEOS_DEPLOYMENT_TARGET": "8.4",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": sdkRoot,
    ]
    XCTAssertNotNil(topLevelConfigs["Debug"])
    XCTAssertEqual(topLevelConfigs["Debug"]!.buildSettings, topLevelBuildSettings)
    XCTAssertNotNil(topLevelConfigs["Release"])
    XCTAssertEqual(topLevelConfigs["Release"]!.buildSettings, topLevelBuildSettings)
    XCTAssertNotNil(topLevelConfigs["Fastbuild"])
    XCTAssertEqual(topLevelConfigs["Fastbuild"]!.buildSettings, topLevelBuildSettings)
  }

  func testGenerateTargetsForRuleEntriesWithNoEntries() {
    do {
      try targetGenerator.generateBuildTargetsForRuleEntries([])
    } catch let e as NSError {
      XCTFail("Failed to generate build targets with error \(e.localizedDescription)")
    }

    let targets = project.targetByName
    XCTAssert(targets.isEmpty)
  }

  func testGenerateTargetsForRuleEntries() {
    let rule1BuildPath = "test/app"
    let rule1TargetName = "TestApplication"
    let rule1BuildTarget = "\(rule1BuildPath):\(rule1TargetName)"
    let rule2BuildPath = "test/objclib"
    let rule2TargetName = "ObjectiveCLibrary"
    let rule2BuildTarget = "\(rule2BuildPath):\(rule2TargetName)"
    let rules = [
      makeTestRuleEntry(rule1BuildTarget, type: "ios_application"),
      makeTestRuleEntry(rule2BuildTarget, type: "objc_library"),
    ]

    do {
      try targetGenerator.generateBuildTargetsForRuleEntries(rules)
    } catch let e as NSError {
      XCTFail("Failed to generate build targets with error \(e.localizedDescription)")
    }

    let topLevelConfigs = project.buildConfigurationList.buildConfigurations
    XCTAssertEqual(topLevelConfigs.count, 0)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 2)

    do {
      let expectedBuildSettings = [
          "BAZEL_TARGET": "test/app:TestApplication",
          "BAZEL_TARGET_IPA": "test/app/TestApplication.ipa",
          "BUILD_PATH": rule1BuildPath,
          "PRODUCT_NAME": rule1TargetName,
      ]
      let expectedTarget = TargetDefinition(
          name: rule1TargetName,
          buildConfigurations: [
              BuildConfigurationDefinition(
                  name: "Debug",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Release",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Fastbuild",
                  expectedBuildSettings: expectedBuildSettings
              ),
          ],
          expectedBuildPhases: [
              ShellScriptBuildPhaseDefinition(bazelURL: bazelURL, buildTarget: rule1BuildTarget)
          ]
      )
      assertTarget(expectedTarget, inTargets: targets)
    }
    do {
      let expectedBuildSettings = [
          "BAZEL_TARGET": "test/objclib:ObjectiveCLibrary",
          "BUILD_PATH": rule2BuildPath,
          "PRODUCT_NAME": rule2TargetName,
      ]
      let expectedTarget = TargetDefinition(
          name: rule2TargetName,
          buildConfigurations: [
              BuildConfigurationDefinition(
                  name: "Debug",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Release",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Fastbuild",
                  expectedBuildSettings: expectedBuildSettings
              ),
          ],
          expectedBuildPhases: [
              ShellScriptBuildPhaseDefinition(bazelURL: bazelURL, buildTarget: rule2BuildTarget)
          ]
      )
      assertTarget(expectedTarget, inTargets: targets)
    }
  }

  func testGenerateTargetsForLinkedRuleEntriesWithNoSources() {
    let rule1BuildPath = "test/app"
    let rule1TargetName = "TestApplication"
    let rule1BuildTarget = "\(rule1BuildPath):\(rule1TargetName)"
    let rule2BuildPath = "test/testbundle"
    let rule2TargetName = "TestBundle"
    let rule2BuildTarget = "\(rule2BuildPath):\(rule2TargetName)"
    let rule2Attributes = ["xctest_app": rule1BuildTarget]
    let rules = [
      makeTestRuleEntry(rule1BuildTarget, type: "ios_application"),
      makeTestRuleEntry(rule2BuildTarget, type: "ios_test", attributes: rule2Attributes),
    ]

    do {
      try targetGenerator.generateBuildTargetsForRuleEntries(rules)
    } catch let e as NSError {
      XCTFail("Failed to generate build targets with error \(e.localizedDescription)")
    }

    let topLevelConfigs = project.buildConfigurationList.buildConfigurations
    XCTAssertEqual(topLevelConfigs.count, 0)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 2)

    do {
      let expectedBuildSettings = [
          "BAZEL_TARGET": "test/app:TestApplication",
          "BAZEL_TARGET_IPA": "test/app/TestApplication.ipa",
          "BUILD_PATH": rule1BuildPath,
          "PRODUCT_NAME": rule1TargetName,
      ]
      let expectedTarget = TargetDefinition(
          name: rule1TargetName,
          buildConfigurations: [
              BuildConfigurationDefinition(
                  name: "Debug",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Release",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Fastbuild",
                  expectedBuildSettings: expectedBuildSettings
              ),
          ],
          expectedBuildPhases: [
              ShellScriptBuildPhaseDefinition(bazelURL: bazelURL, buildTarget: rule1BuildTarget)
          ]
      )
      assertTarget(expectedTarget, inTargets: targets)
    }
    do {
      let expectedBuildSettings = [
          "BAZEL_TARGET": "test/testbundle:TestBundle",
          "BAZEL_TARGET_IPA": "test/testbundle/TestBundle.ipa",
          "BUILD_PATH": rule2BuildPath,
          "BUNDLE_LOADER": "$(TEST_HOST)",
          "PRODUCT_NAME": rule2TargetName,
          "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/\(rule1TargetName).app/\(rule1TargetName)",
      ]
      let expectedTarget = TargetDefinition(
          name: rule2TargetName,
          buildConfigurations: [
              BuildConfigurationDefinition(
                  name: "Debug",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Release",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Fastbuild",
                  expectedBuildSettings: expectedBuildSettings
              ),
          ],
          expectedBuildPhases: [
              ShellScriptBuildPhaseDefinition(bazelURL: bazelURL, buildTarget: rule2BuildTarget)
          ]
      )
      assertTarget(expectedTarget, inTargets: targets)
    }
  }

  func testGenerateTargetsForLinkedRuleEntriesWithSources() {
    let rule1BuildPath = "test/app"
    let rule1TargetName = "TestApplication"
    let rule1BuildTarget = "\(rule1BuildPath):\(rule1TargetName)"
    let testRuleBuildPath = "test/testbundle"
    let testRuleTargetName = "TestBundle"
    let testRuleBuildTarget = "\(testRuleBuildPath):\(testRuleTargetName)"
    let testRuleAttributes = ["xctest_app": rule1BuildTarget]
    let testSources = ["sourceFile1.m", "sourceFile2.mm"]
    let testRule = makeTestRuleEntry(testRuleBuildTarget,
                                     type: "ios_test",
                                     attributes: testRuleAttributes,
                                     sourceFiles: testSources)
    let rules = [
      makeTestRuleEntry(rule1BuildTarget, type: "ios_application"),
      testRule,
    ]
    do {
      try targetGenerator.generateBuildTargetsForRuleEntries(rules)
    } catch let e as NSError {
      XCTFail("Failed to generate build targets with error \(e.localizedDescription)")
    }

    // Configs will be minimally generated for Debug and the test runner dummy.
    let topLevelConfigs = project.buildConfigurationList.buildConfigurations
    XCTAssertEqual(topLevelConfigs.count, 4)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 2)
    do {
      let expectedBuildSettings = [
          "BAZEL_TARGET": "test/app:TestApplication",
          "BAZEL_TARGET_IPA": "test/app/TestApplication.ipa",
          "BUILD_PATH": rule1BuildPath,
          "PRODUCT_NAME": rule1TargetName,
      ]
      var testRunnerExpectedBuildSettings = expectedBuildSettings
      testRunnerExpectedBuildSettings["DEBUG_INFORMATION_FORMAT"] = "dwarf"
      testRunnerExpectedBuildSettings["ONLY_ACTIVE_ARCH"] = "YES"
      testRunnerExpectedBuildSettings["OTHER_CFLAGS"] = "-help"
      testRunnerExpectedBuildSettings["OTHER_LDFLAGS"] = "-help"
      let expectedTarget = TargetDefinition(
          name: rule1TargetName,
          buildConfigurations: [
              BuildConfigurationDefinition(
                  name: "Debug",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Release",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Fastbuild",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "__TulsiTestRunner_Debug",
                  expectedBuildSettings: testRunnerExpectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "__TulsiTestRunner_Release",
                  expectedBuildSettings: testRunnerExpectedBuildSettings
              ),
          ],
          expectedBuildPhases: [
              ShellScriptBuildPhaseDefinition(bazelURL: bazelURL,
                                              buildTarget: rule1BuildTarget),
          ]
      )
      assertTarget(expectedTarget, inTargets: targets)
    }
    do {
      let expectedBuildSettings = [
          "BAZEL_TARGET": "test/testbundle:TestBundle",
          "BAZEL_TARGET_IPA": "test/testbundle/TestBundle.ipa",
          "BUILD_PATH": testRuleBuildPath,
          "BUNDLE_LOADER": "$(TEST_HOST)",
          "PRODUCT_NAME": testRuleTargetName,
          "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/\(rule1TargetName).app/\(rule1TargetName)",
      ]
      var testRunnerExpectedBuildSettings = expectedBuildSettings
      testRunnerExpectedBuildSettings["DEBUG_INFORMATION_FORMAT"] = "dwarf"
      testRunnerExpectedBuildSettings["ONLY_ACTIVE_ARCH"] = "YES"
      testRunnerExpectedBuildSettings["OTHER_CFLAGS"] = "-help"
      testRunnerExpectedBuildSettings["OTHER_LDFLAGS"] = "-help"
      let expectedTarget = TargetDefinition(
          name: testRuleTargetName,
          buildConfigurations: [
              BuildConfigurationDefinition(
                  name: "Debug",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Release",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "Fastbuild",
                  expectedBuildSettings: expectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "__TulsiTestRunner_Debug",
                  expectedBuildSettings: testRunnerExpectedBuildSettings
              ),
              BuildConfigurationDefinition(
                  name: "__TulsiTestRunner_Release",
                  expectedBuildSettings: testRunnerExpectedBuildSettings
              ),
          ],
          expectedBuildPhases: [
              SourcesBuildPhaseDefinition(files: testSources, mainGroup: project.mainGroup),
              ShellScriptBuildPhaseDefinition(bazelURL: bazelURL,
                                              buildTarget: testRuleBuildTarget)
          ]
      )
      assertTarget(expectedTarget, inTargets: targets)
    }
  }

  func testGenerateIndexerWithNoSources() {
    let ruleEntry = makeTestRuleEntry("test/app:TestApp", type: "ios_application")
    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry, ruleEntryMap: [:], pathFilters: pathFilters)
    let targets = project.targetByName
    XCTAssert(targets.isEmpty)
  }

  func testGenerateIndexerWithNoPCHFile() {
    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_application",
                                      sourceFiles: sourceFileNames)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry, ruleEntryMap: [:], pathFilters: pathFilters)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName, sourceFileNames: sourceFileNames, inTargets: targets)
  }

  func testGenerateIndexer() {
    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry("test/app:TestApp",
                                      type: "ios_application",
                                      attributes: ["pch": ["path": pchFile.path!, "src": true]],
                                      sourceFiles: sourceFileNames)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry, ruleEntryMap: [:], pathFilters: pathFilters)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName, sourceFileNames: sourceFileNames, pchFile: pchFile, inTargets: targets)
  }

  func testGenerateIndexerWithBridgingHeader() {
    let bridgingHeaderFilePath = "some/place/bridging-header.h"
    let ruleAttributes = ["bridging_header": ["path": bridgingHeaderFilePath, "src": true]]

    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_binary",
                                      attributes: ruleAttributes,
                                      sourceFiles: sourceFileNames)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry, ruleEntryMap: [:], pathFilters: pathFilters)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName,
                          sourceFileNames: sourceFileNames,
                          bridgingHeader: "$(SRCROOT)/\(bridgingHeaderFilePath)",
                          inTargets: targets)
  }

  func testGenerateIndexerWithGeneratedBridgingHeader() {
    let bridgingHeaderFilePath = "some/place/bridging-header.h"
    let bridgingHeaderInfo = ["path": bridgingHeaderFilePath,
                              "rootPath": "bazel-out/darwin_x86_64-fastbuild/genfiles",
                              "src": false]
    let ruleAttributes = ["bridging_header": bridgingHeaderInfo]

    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_binary",
                                      attributes: ruleAttributes,
                                      sourceFiles: sourceFileNames)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry, ruleEntryMap: [:], pathFilters: pathFilters)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName,
                          sourceFileNames: sourceFileNames,
                          bridgingHeader: "bazel-genfiles/\(bridgingHeaderFilePath)",
                          inTargets: targets)
  }

  func testGenerateIndexerWithXCDataModel() {
    let dataModel = "test.xcdatamodeld"
    let ruleAttributes = ["datamodels": [["path": "\(dataModel)/v1.xcdatamodel", "src": true],
                                         ["path": "\(dataModel)/v2.xcdatamodel", "src": true]]]

    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_binary",
                                      attributes: ruleAttributes,
                                      sourceFiles: sourceFileNames)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry,
                                                      ruleEntryMap: [:],
                                                      pathFilters: pathFilters)

    var allSourceFiles = sourceFileNames
    allSourceFiles.append(dataModel)
    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName,
                          sourceFileNames: allSourceFiles,
                          inTargets: targets)
  }

  func testGenerateIndexerWithSourceFilter() {
    sourceFileNames.append("this/file/should/appear.m")
    pathFilters.insert("this/file/should")
    rebuildSourceFileReferences()

    var allSourceFiles = sourceFileNames
    allSourceFiles.append("filtered/file.m")
    allSourceFiles.append("this/file/should/not/appear.m")

    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_application",
                                      sourceFiles: allSourceFiles)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry,
                                                      ruleEntryMap: [:],
                                                      pathFilters: pathFilters)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName, sourceFileNames: sourceFileNames, inTargets: targets)
  }

  func testGenerateIndexerWithRecursiveSourceFilter() {
    sourceFileNames.append("this/file/should/appear.m")
    sourceFileNames.append("this/file/should/also/appear.m")
    pathFilters.insert("this/file/should/...")
    rebuildSourceFileReferences()

    var allSourceFiles = sourceFileNames
    allSourceFiles.append("filtered/file.m")

    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_application",
                                      sourceFiles: allSourceFiles)
    let indexerTargetName = "_indexer_TestApp_\(buildLabel.hashValue)"

    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry,
                                                      ruleEntryMap: [:],
                                                      pathFilters: pathFilters)

    let targets = project.targetByName
    XCTAssertEqual(targets.count, 1)
    validateIndexerTarget(indexerTargetName, sourceFileNames: sourceFileNames, inTargets: targets)
  }

  func testGenerateBUILDRefsWithoutSourceFilter() {
    let buildFilePath = "this/file/should/not/BUILD"
    pathFilters.insert("this/file/should")
    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_application",
                                      sourceFiles: sourceFileNames,
                                      buildFilePath: buildFilePath)
    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry,
                                                      ruleEntryMap: [:],
                                                      pathFilters: pathFilters)
    XCTAssertNil(fileRefForPath(buildFilePath))
  }

  func testGenerateBUILDRefsWithSourceFilter() {
    let buildFilePath = "this/file/should/BUILD"
    pathFilters.insert("this/file/should")
    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_application",
                                      sourceFiles: sourceFileNames,
                                      buildFilePath: buildFilePath)
    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry,
                                                      ruleEntryMap: [:],
                                                      pathFilters: pathFilters)
    XCTAssertNotNil(fileRefForPath(buildFilePath))
  }

  func testGenerateBUILDRefsWithRecursiveSourceFilter() {
    let buildFilePath = "this/file/should/BUILD"
    pathFilters.insert("this/file/...")
    let buildLabel = BuildLabel("test/app:TestApp")
    let ruleEntry = makeTestRuleEntry(buildLabel,
                                      type: "ios_application",
                                      sourceFiles: sourceFileNames,
                                      buildFilePath: buildFilePath)
    targetGenerator.generateIndexerTargetForRuleEntry(ruleEntry,
                                                      ruleEntryMap: [:],
                                                      pathFilters: pathFilters)
    XCTAssertNotNil(fileRefForPath(buildFilePath))
  }

  // MARK: - Helper methods

  private func rebuildSourceFileReferences() {
    sourceFileReferences = []
    for file in sourceFileNames {
      sourceFileReferences.append(project.mainGroup.getOrCreateFileReferenceBySourceTree(.Group, path: file))
    }
  }

  private func makeTestRuleEntry(label: String,
                                 type: String,
                                 attributes: [String: AnyObject] = [:],
                                 sourceFiles: [String] = [],
                                 dependencies: Set<String> = Set<String>(),
                                 buildFilePath: String? = nil) -> RuleEntry {
    return makeTestRuleEntry(BuildLabel(label),
                             type: type,
                             attributes: attributes,
                             sourceFiles: sourceFiles,
                             dependencies: dependencies,
                             buildFilePath: buildFilePath)
  }

  private func makeTestRuleEntry(label: BuildLabel,
                                 type: String,
                                 attributes: [String: AnyObject] = [:],
                                 sourceFiles: [String] = [],
                                 dependencies: Set<String> = Set<String>(),
                                 buildFilePath: String? = nil) -> RuleEntry {
    return RuleEntry(label: label,
                     type: type,
                     attributes: attributes,
                     sourceFiles: sourceFiles,
                     dependencies: dependencies,
                     buildFilePath: buildFilePath)
  }

  private struct TargetDefinition {
    let name: String
    let buildConfigurations: [BuildConfigurationDefinition]
    let expectedBuildPhases: [BuildPhaseDefinition]
  }

  private struct BuildConfigurationDefinition {
    let name: String
    let expectedBuildSettings: Dictionary<String, String>?
  }

  private class BuildPhaseDefinition {
    let isa: String
    let files: [String]
    let fileSet: Set<String>
    let mainGroup: PBXReference?

    init (isa: String, files: [String], mainGroup: PBXReference? = nil) {
      self.isa = isa
      self.files = files
      self.fileSet = Set(files)
      self.mainGroup = mainGroup
    }

    func validate(phase: PBXBuildPhase, line: UInt = __LINE__) {
      // Validate the file set.
      XCTAssertEqual(phase.files.count,
                     fileSet.count,
                     "Mismatch in file count in build phase",
                     line: line)
      for buildFile in phase.files {
        // Grab the full path of the file. Note that this assumes all groups used in the test are
        // group relative.
        var pathElements = [String]()
        var node: PBXReference! = buildFile.fileRef
        while node != nil && node !== mainGroup {
          pathElements.append(node.path!)
          node = node.parent
        }
        let path = pathElements.reverse().joinWithSeparator("/")
        XCTAssert(fileSet.contains(path),
                  "Found unexpected file '\(path)' in build phase",
                  line: line)
      }
    }
  }

  private class SourcesBuildPhaseDefinition: BuildPhaseDefinition {
    let settings: [String: String]?

    init(files: [String], mainGroup: PBXReference, settings: [String: String]? = nil) {
      self.settings = settings
      super.init(isa: "PBXSourcesBuildPhase", files: files, mainGroup: mainGroup)
    }

    override func validate(phase: PBXBuildPhase, line: UInt = __LINE__) {
      super.validate(phase, line: line)

      for buildFile in phase.files {
        if settings != nil {
          XCTAssertNotNil(buildFile.settings, "Settings for file \(buildFile) must == \(settings)",
                          line: line)
          if buildFile.settings != nil {
            XCTAssertEqual(buildFile.settings!, settings!, line: line)
          }
        } else {
          XCTAssertNil(buildFile.settings, "Settings for file \(buildFile) must be nil",
                       line: line)
        }
      }
    }
  }

  private class ShellScriptBuildPhaseDefinition: BuildPhaseDefinition {
    let bazelURL: NSURL
    let buildTarget: String

    init(bazelURL: NSURL, buildTarget: String) {
      self.bazelURL = bazelURL
      self.buildTarget = buildTarget
      super.init(isa: "PBXShellScriptBuildPhase", files: [])
    }

    override func validate(phase: PBXBuildPhase, line: UInt = __LINE__) {
      super.validate(phase, line: line)

      // Guaranteed by the test infrastructure below, failing this indicates a programming error in
      // the test fixture, not in the code being tested.
      let scriptBuildPhase = phase as! PBXShellScriptBuildPhase

      let script = scriptBuildPhase.shellScript

      // TODO(abaire): Consider doing deeper validation of the script.
      XCTAssert(script.containsString(bazelURL.path!), line: line)
      XCTAssert(script.containsString(buildTarget), line: line)
    }
  }

  private func fileRefForPath(path: String) -> PBXReference? {
    let components = path.componentsSeparatedByString("/")
    var node = project.mainGroup
    componentLoop: for component in components {
      for child in node.children {
        if child.name == component {
          if let childGroup = child as? PBXGroup {
            node = childGroup
            continue componentLoop
          } else if component == components.last! {
            return child
          } else {
            return nil
          }
        }
      }
    }
    return nil
  }

  private func validateIndexerTarget(indexerTargetName: String,
                                     sourceFileNames: [String]?,
                                     pchFile: PBXFileReference? = nil,
                                     bridgingHeader: String? = nil,
                                     inTargets targets: Dictionary<String, PBXTarget> = Dictionary<String, PBXTarget>(),
                                     line: UInt = __LINE__) {
    var expectedBuildSettings = [
        "PRODUCT_NAME": indexerTargetName,
    ]
    if pchFile != nil {
      expectedBuildSettings["GCC_PREFIX_HEADER"] = "$(SRCROOT)/\(pchFile!.path!)"
    }
    if bridgingHeader != nil {
        expectedBuildSettings["SWIFT_OBJC_BRIDGING_HEADER"] = bridgingHeader!
    }

    var expectedBuildPhases = [BuildPhaseDefinition]()
    if sourceFileNames != nil {
      expectedBuildPhases.append(SourcesBuildPhaseDefinition(files: sourceFileNames!,
                                                             mainGroup: project.mainGroup))
    }

    let expectedTarget = TargetDefinition(
        name: indexerTargetName,
        buildConfigurations: [
            BuildConfigurationDefinition(
              name: "Debug",
              expectedBuildSettings: expectedBuildSettings
            ),
            BuildConfigurationDefinition(
              name: "Release",
              expectedBuildSettings: expectedBuildSettings
            ),
            BuildConfigurationDefinition(
              name: "Fastbuild",
              expectedBuildSettings: expectedBuildSettings
            ),
        ],
        expectedBuildPhases: expectedBuildPhases
    )
    assertTarget(expectedTarget, inTargets: targets, line: line)
  }

  private func assertTarget(targetDef: TargetDefinition,
                            inTargets targets: Dictionary<String, PBXTarget>,
                            line: UInt = __LINE__) {
    guard let target = targets[targetDef.name] else {
      XCTFail("Missing expected target '\(targetDef.name)'", line: line)
      return
    }

    let buildConfigs = target.buildConfigurationList.buildConfigurations
    XCTAssertEqual(buildConfigs.count,
                   targetDef.buildConfigurations.count,
                   "Build config mismatch in target '\(targetDef.name)'",
                   line: line)

    for buildConfigDef in targetDef.buildConfigurations {
      guard let config = buildConfigs[buildConfigDef.name] else {
        XCTFail("Missing expected build configuration '\(buildConfigDef.name)' in target '\(targetDef.name)'",
                line: line)
        continue
      }

      if buildConfigDef.expectedBuildSettings != nil {
        XCTAssertEqual(config.buildSettings,
                       buildConfigDef.expectedBuildSettings!,
                       "Build config mismatch for configuration '\(buildConfigDef.name)' in target '\(targetDef.name)'",
                       line: line)
      } else {
        XCTAssert(config.buildSettings.isEmpty, line: line)
      }
    }

    validateExpectedBuildPhases(targetDef.expectedBuildPhases,
                                inTarget: target,
                                line: line)
  }

  private func validateExpectedBuildPhases(phaseDefs: [BuildPhaseDefinition],
                                           inTarget target: PBXTarget,
                                           line: UInt = __LINE__) {
    let buildPhases = target.buildPhases
    XCTAssertEqual(buildPhases.count,
                   phaseDefs.count,
                   "Build phase count mismatch in target '\(target.name)'",
                   line: line)

    for phaseDef in phaseDefs {
      for phase in buildPhases {
        if phase.isa != phaseDef.isa {
          continue
        }
        phaseDef.validate(phase, line: line)
      }
    }
  }
}


