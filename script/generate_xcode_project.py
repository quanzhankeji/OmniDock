#!/usr/bin/env python3
"""Generate OmniDock.xcodeproj for local extension builds and App Store archives."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
PROJECT_NAME = "OmniDock"
BUNDLE_ID = "com.quanzhankeji.OmniDock"
FINDER_EXTENSION_NAME = "OmniDockFinderSync"
FINDER_EXTENSION_BUNDLE_ID = f"{BUNDLE_ID}.FinderSync"
MIN_MACOS = "12.3"
XCODE_VERSION = "2630"

FRAMEWORKS = [
    "AppKit",
    "ApplicationServices",
    "Carbon",
    "CoreGraphics",
    "CoreImage",
    "CoreMedia",
    "FinderSync",
    "IOKit",
    "ScreenCaptureKit",
]
FINDER_EXTENSION_FRAMEWORKS = ["AppKit", "FinderSync"]


def oid(seed: str) -> str:
    return hashlib.sha1(seed.encode("utf-8")).hexdigest().upper()[:24]


def q(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def list_app_sources() -> list[str]:
    app = sorted(rel(path) for path in (ROOT / "Sources" / PROJECT_NAME).rglob("*.swift"))
    core = sorted(rel(path) for path in (ROOT / "Sources" / "OmniDockCore").rglob("*.swift"))
    return [*app, *core]


def list_finder_extension_sources() -> list[str]:
    extension = sorted(
        rel(path) for path in (ROOT / "Sources" / FINDER_EXTENSION_NAME).rglob("*.swift")
    )
    shared = sorted(
        rel(path)
        for path in (ROOT / "Sources" / "OmniDockCore" / "FinderExtensionShared").rglob("*.swift")
    )
    return [*extension, *shared]


def list_swift_sources() -> list[str]:
    return sorted(set([*list_app_sources(), *list_finder_extension_sources()]))


def list_resource_references() -> list[str]:
    resources = [
        "Resources/Assets.xcassets",
        "Resources/OmniDock-Development.entitlements",
        "Resources/OmniDock-AppStore.entitlements",
        "Resources/OmniDock-Info.plist",
        "Resources/OmniDockFinderSync.entitlements",
        "Resources/OmniDockFinderSync-Info.plist",
        "Resources/PrivacyInfo.xcprivacy",
    ]
    resources.extend(
        sorted(
            rel(path)
            for path in (ROOT / "Sources" / "OmniDockCore" / "Resources").rglob("*")
            if path.is_file()
        )
    )
    return resources


def build_settings(settings: dict[str, object], indent: str = "\t\t\t\t") -> str:
    lines: list[str] = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            lines.append(f"{indent}{key} = (")
            for item in value:
                lines.append(f"{indent}\t{q(str(item))},")
            lines.append(f"{indent});")
        elif value in {"YES", "NO"}:
            lines.append(f"{indent}{key} = {value};")
        else:
            lines.append(f"{indent}{key} = {q(str(value))};")
    return "\n".join(lines)


def generate_pbxproj() -> str:
    swift_sources = list_app_sources()
    finder_extension_sources = list_finder_extension_sources()
    all_swift_sources = sorted(set([*swift_sources, *finder_extension_sources]))
    resource_refs = list_resource_references()

    main_group = oid("group:main")
    sources_group = oid("group:sources")
    resources_group = oid("group:resources")
    frameworks_group = oid("group:frameworks")
    products_group = oid("group:products")

    target = oid("target:OmniDock")
    finder_extension_target = oid(f"target:{FINDER_EXTENSION_NAME}")
    project = oid("project:OmniDock")
    product_ref = oid("product:OmniDock.app")
    finder_extension_product_ref = oid(f"product:{FINDER_EXTENSION_NAME}.appex")
    sources_phase = oid("phase:sources")
    finder_extension_sources_phase = oid(f"phase:{FINDER_EXTENSION_NAME}:sources")
    frameworks_phase = oid("phase:frameworks")
    finder_extension_frameworks_phase = oid(f"phase:{FINDER_EXTENSION_NAME}:frameworks")
    resources_phase = oid("phase:resources")
    resource_script_phase = oid("phase:copy-local-resources")
    embed_extensions_phase = oid("phase:embed-app-extensions")
    finder_extension_dependency = oid(f"dependency:{PROJECT_NAME}:{FINDER_EXTENSION_NAME}")
    finder_extension_proxy = oid(f"proxy:{PROJECT_NAME}:{FINDER_EXTENSION_NAME}")
    project_debug = oid("config:project:debug")
    project_release = oid("config:project:release")
    target_debug = oid("config:target:debug")
    target_release = oid("config:target:release")
    finder_extension_debug = oid(f"config:target:{FINDER_EXTENSION_NAME}:debug")
    finder_extension_release = oid(f"config:target:{FINDER_EXTENSION_NAME}:release")
    project_config_list = oid("config-list:project")
    target_config_list = oid("config-list:target")
    finder_extension_config_list = oid(f"config-list:target:{FINDER_EXTENSION_NAME}")

    file_refs = {path: oid(f"file:{path}") for path in [*all_swift_sources, *resource_refs]}
    source_build_files = {path: oid(f"build:sources:{path}") for path in swift_sources}
    finder_extension_source_build_files = {
        path: oid(f"build:sources:{FINDER_EXTENSION_NAME}:{path}")
        for path in finder_extension_sources
    }
    resource_build_files = {
        path: oid(f"build:resources:{path}")
        for path in resource_refs
        if path.endswith(".xcassets")
    }
    all_frameworks = sorted(set([*FRAMEWORKS, *FINDER_EXTENSION_FRAMEWORKS]))
    framework_refs = {name: oid(f"framework:{name}") for name in all_frameworks}
    framework_build_files = {name: oid(f"build:frameworks:{PROJECT_NAME}:{name}") for name in FRAMEWORKS}
    finder_extension_framework_build_files = {
        name: oid(f"build:frameworks:{FINDER_EXTENSION_NAME}:{name}")
        for name in FINDER_EXTENSION_FRAMEWORKS
    }
    embed_extension_build_file = oid(f"build:embed:{FINDER_EXTENSION_NAME}")

    lines: list[str] = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {};",
        "\tobjectVersion = 56;",
        "\tobjects = {",
        "",
        "/* Begin PBXBuildFile section */",
    ]

    for path in swift_sources:
        name = Path(path).name
        lines.append(
            f"\t\t{source_build_files[path]} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};"
        )
    for path in finder_extension_sources:
        name = Path(path).name
        lines.append(
            f"\t\t{finder_extension_source_build_files[path]} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};"
        )
    for name in FRAMEWORKS:
        lines.append(
            f"\t\t{framework_build_files[name]} /* {name}.framework in Frameworks */ = "
            f"{{isa = PBXBuildFile; fileRef = {framework_refs[name]} /* {name}.framework */; }};"
        )
    for name in FINDER_EXTENSION_FRAMEWORKS:
        lines.append(
            f"\t\t{finder_extension_framework_build_files[name]} /* {name}.framework in Frameworks */ = "
            f"{{isa = PBXBuildFile; fileRef = {framework_refs[name]} /* {name}.framework */; }};"
        )
    for path in resource_build_files:
        name = Path(path).name
        lines.append(
            f"\t\t{resource_build_files[path]} /* {name} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};"
        )
    lines.append(
        f"\t\t{embed_extension_build_file} /* {FINDER_EXTENSION_NAME}.appex in Embed App Extensions */ = "
        f"{{isa = PBXBuildFile; fileRef = {finder_extension_product_ref} /* {FINDER_EXTENSION_NAME}.appex */; "
        "settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };"
    )
    lines.extend(["/* End PBXBuildFile section */", "", "/* Begin PBXFileReference section */"])

    lines.append(
        f"\t\t{product_ref} /* {PROJECT_NAME}.app */ = "
        f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {q(PROJECT_NAME + '.app')}; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    lines.append(
        f"\t\t{finder_extension_product_ref} /* {FINDER_EXTENSION_NAME}.appex */ = "
        f"{{isa = PBXFileReference; explicitFileType = wrapper.app-extension; includeInIndex = 0; "
        f"path = {q(FINDER_EXTENSION_NAME + '.appex')}; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    for path in all_swift_sources:
        name = Path(path).name
        lines.append(
            f"\t\t{file_refs[path]} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; "
            f"sourceTree = SOURCE_ROOT; }};"
        )
    for path in resource_refs:
        name = Path(path).name
        if path.endswith(".plist"):
            file_type = "text.plist.xml"
        elif path.endswith(".xcprivacy"):
            file_type = "text.xml"
        elif path.endswith(".strings"):
            file_type = "text.plist.strings"
        elif path.endswith(".xcassets"):
            file_type = "folder.assetcatalog"
        else:
            file_type = "file"
        lines.append(
            f"\t\t{file_refs[path]} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {q(path)}; "
            f"sourceTree = SOURCE_ROOT; }};"
        )
    for name in all_frameworks:
        lines.append(
            f"\t\t{framework_refs[name]} /* {name}.framework */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {q(name + '.framework')}; "
            f"path = {q('System/Library/Frameworks/' + name + '.framework')}; sourceTree = SDKROOT; }};"
        )
    lines.extend([
        "/* End PBXFileReference section */",
        "",
        "/* Begin PBXCopyFilesBuildPhase section */",
    ])
    lines.append(f"\t\t{embed_extensions_phase} /* Embed App Extensions */ = {{")
    lines.append("\t\t\tisa = PBXCopyFilesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tdstPath = \"\";")
    lines.append("\t\t\tdstSubfolderSpec = 13;")
    lines.append("\t\t\tfiles = (")
    lines.append(
        f"\t\t\t\t{embed_extension_build_file} /* {FINDER_EXTENSION_NAME}.appex in Embed App Extensions */,"
    )
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = \"Embed App Extensions\";")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.extend([
        "/* End PBXCopyFilesBuildPhase section */",
        "",
        "/* Begin PBXFrameworksBuildPhase section */",
    ])

    lines.append(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for name in FRAMEWORKS:
        lines.append(f"\t\t\t\t{framework_build_files[name]} /* {name}.framework in Frameworks */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append(f"\t\t{finder_extension_frameworks_phase} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for name in FINDER_EXTENSION_FRAMEWORKS:
        lines.append(
            f"\t\t\t\t{finder_extension_framework_build_files[name]} "
            f"/* {name}.framework in Frameworks */,"
        )
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.extend(["/* End PBXFrameworksBuildPhase section */", "", "/* Begin PBXGroup section */"])

    lines.append(f"\t\t{main_group} = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{sources_group} /* Sources */,")
    lines.append(f"\t\t\t\t{resources_group} /* Resources */,")
    lines.append(f"\t\t\t\t{frameworks_group} /* Frameworks */,")
    lines.append(f"\t\t\t\t{products_group} /* Products */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{sources_group} /* Sources */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for path in all_swift_sources:
        lines.append(f"\t\t\t\t{file_refs[path]} /* {Path(path).name} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Sources;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{resources_group} /* Resources */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for path in resource_refs:
        lines.append(f"\t\t\t\t{file_refs[path]} /* {Path(path).name} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Resources;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{frameworks_group} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for name in all_frameworks:
        lines.append(f"\t\t\t\t{framework_refs[name]} /* {name}.framework */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Frameworks;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{products_group} /* Products */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{product_ref} /* {PROJECT_NAME}.app */,")
    lines.append(f"\t\t\t\t{finder_extension_product_ref} /* {FINDER_EXTENSION_NAME}.appex */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Products;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")
    lines.extend(["/* End PBXGroup section */", "", "/* Begin PBXNativeTarget section */"])

    lines.append(f"\t\t{target} /* {PROJECT_NAME} */ = {{")
    lines.append("\t\t\tisa = PBXNativeTarget;")
    lines.append(f"\t\t\tbuildConfigurationList = {target_config_list} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;")
    lines.append("\t\t\tbuildPhases = (")
    lines.append(f"\t\t\t\t{sources_phase} /* Sources */,")
    lines.append(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    lines.append(f"\t\t\t\t{resources_phase} /* Resources */,")
    lines.append(f"\t\t\t\t{resource_script_phase} /* Copy App Resources */,")
    lines.append(f"\t\t\t\t{embed_extensions_phase} /* Embed App Extensions */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tbuildRules = ();")
    lines.append("\t\t\tdependencies = (")
    lines.append(f"\t\t\t\t{finder_extension_dependency} /* PBXTargetDependency */,")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tname = {q(PROJECT_NAME)};")
    lines.append(f"\t\t\tproductName = {q(PROJECT_NAME)};")
    lines.append(f"\t\t\tproductReference = {product_ref} /* {PROJECT_NAME}.app */;")
    lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    lines.append("\t\t};")
    lines.append(f"\t\t{finder_extension_target} /* {FINDER_EXTENSION_NAME} */ = {{")
    lines.append("\t\t\tisa = PBXNativeTarget;")
    lines.append(
        f"\t\t\tbuildConfigurationList = {finder_extension_config_list} "
        f"/* Build configuration list for PBXNativeTarget \"{FINDER_EXTENSION_NAME}\" */;"
    )
    lines.append("\t\t\tbuildPhases = (")
    lines.append(f"\t\t\t\t{finder_extension_sources_phase} /* Sources */,")
    lines.append(f"\t\t\t\t{finder_extension_frameworks_phase} /* Frameworks */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tbuildRules = ();")
    lines.append("\t\t\tdependencies = ();")
    lines.append(f"\t\t\tname = {q(FINDER_EXTENSION_NAME)};")
    lines.append(f"\t\t\tproductName = {q(FINDER_EXTENSION_NAME)};")
    lines.append(
        f"\t\t\tproductReference = {finder_extension_product_ref} "
        f"/* {FINDER_EXTENSION_NAME}.appex */;"
    )
    lines.append("\t\t\tproductType = \"com.apple.product-type.app-extension\";")
    lines.append("\t\t};")
    lines.extend(["/* End PBXNativeTarget section */", "", "/* Begin PBXContainerItemProxy section */"])
    lines.append(f"\t\t{finder_extension_proxy} /* PBXContainerItemProxy */ = {{")
    lines.append("\t\t\tisa = PBXContainerItemProxy;")
    lines.append(f"\t\t\tcontainerPortal = {project} /* Project object */;")
    lines.append("\t\t\tproxyType = 1;")
    lines.append(f"\t\t\tremoteGlobalIDString = {finder_extension_target};")
    lines.append(f"\t\t\tremoteInfo = {q(FINDER_EXTENSION_NAME)};")
    lines.append("\t\t};")
    lines.extend(["/* End PBXContainerItemProxy section */", "", "/* Begin PBXProject section */"])

    lines.append(f"\t\t{project} /* Project object */ = {{")
    lines.append("\t\t\tisa = PBXProject;")
    lines.append("\t\t\tattributes = {")
    lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    lines.append(f"\t\t\t\tLastSwiftUpdateCheck = {XCODE_VERSION};")
    lines.append(f"\t\t\t\tLastUpgradeCheck = {XCODE_VERSION};")
    lines.append("\t\t\t\tTargetAttributes = {")
    lines.append(f"\t\t\t\t\t{target} = {{")
    lines.append(f"\t\t\t\t\t\tCreatedOnToolsVersion = {q('26.3')};")
    lines.append("\t\t\t\t\t\tProvisioningStyle = Automatic;")
    lines.append("\t\t\t\t\t\tSystemCapabilities = {")
    lines.append("\t\t\t\t\t\t\tcom.apple.ApplicationGroups.iOS = { enabled = 1; };")
    lines.append("\t\t\t\t\t\t\tcom.apple.Sandbox = { enabled = 1; };")
    lines.append("\t\t\t\t\t\t};")
    lines.append("\t\t\t\t\t};")
    lines.append(f"\t\t\t\t\t{finder_extension_target} = {{")
    lines.append(f"\t\t\t\t\t\tCreatedOnToolsVersion = {q('26.3')};")
    lines.append("\t\t\t\t\t\tProvisioningStyle = Automatic;")
    lines.append("\t\t\t\t\t\tSystemCapabilities = {")
    lines.append("\t\t\t\t\t\t\tcom.apple.ApplicationGroups.iOS = { enabled = 1; };")
    lines.append("\t\t\t\t\t\t\tcom.apple.Sandbox = { enabled = 1; };")
    lines.append("\t\t\t\t\t\t};")
    lines.append("\t\t\t\t\t};")
    lines.append("\t\t\t\t};")
    lines.append("\t\t\t};")
    lines.append(f"\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    lines.append("\t\t\tdevelopmentRegion = en;")
    lines.append("\t\t\thasScannedForEncodings = 0;")
    lines.append("\t\t\tknownRegions = (")
    lines.append("\t\t\t\ten,")
    lines.append("\t\t\t\t\"zh-Hans\",")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tmainGroup = {main_group};")
    lines.append("\t\t\tproductRefGroup = " + products_group + " /* Products */;")
    lines.append("\t\t\tprojectDirPath = \"\";")
    lines.append("\t\t\tprojectRoot = \"\";")
    lines.append("\t\t\ttargets = (")
    lines.append(f"\t\t\t\t{target} /* {PROJECT_NAME} */,")
    lines.append(f"\t\t\t\t{finder_extension_target} /* {FINDER_EXTENSION_NAME} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t};")
    lines.extend(["/* End PBXProject section */", "", "/* Begin PBXTargetDependency section */"])
    lines.append(f"\t\t{finder_extension_dependency} /* PBXTargetDependency */ = {{")
    lines.append("\t\t\tisa = PBXTargetDependency;")
    lines.append(f"\t\t\ttarget = {finder_extension_target} /* {FINDER_EXTENSION_NAME} */;")
    lines.append(f"\t\t\ttargetProxy = {finder_extension_proxy} /* PBXContainerItemProxy */;")
    lines.append("\t\t};")
    lines.extend(["/* End PBXTargetDependency section */", "", "/* Begin PBXResourcesBuildPhase section */"])

    lines.append(f"\t\t{resources_phase} /* Resources */ = {{")
    lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for path in resource_build_files:
        lines.append(f"\t\t\t\t{resource_build_files[path]} /* {Path(path).name} in Resources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.extend(["/* End PBXResourcesBuildPhase section */", "", "/* Begin PBXShellScriptBuildPhase section */"])

    resource_script = """set -euo pipefail

resources_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "$resources_dir"

/usr/bin/ditto "${SRCROOT}/Resources/PrivacyInfo.xcprivacy" "${resources_dir}/PrivacyInfo.xcprivacy"
/usr/bin/ditto "${SRCROOT}/LICENSE" "${resources_dir}/COPYING.txt"

for localization_dir in "${SRCROOT}"/Sources/OmniDockCore/Resources/*.lproj; do
  [[ -d "$localization_dir" ]] || continue
  /usr/bin/ditto "$localization_dir" "${resources_dir}/$(basename "$localization_dir")"
done

/usr/bin/xattr -dr com.apple.quarantine "$resources_dir" 2>/dev/null || true
/usr/bin/xattr -cr "${TARGET_BUILD_DIR}/${WRAPPER_NAME}" 2>/dev/null || true
"""
    lines.append(f"\t\t{resource_script_phase} /* Copy App Resources */ = {{")
    lines.append("\t\t\tisa = PBXShellScriptBuildPhase;")
    lines.append("\t\t\talwaysOutOfDate = 1;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = ();")
    lines.append("\t\t\tinputFileListPaths = ();")
    lines.append("\t\t\tinputPaths = (")
    lines.append("\t\t\t\t\"$(SRCROOT)/Resources/PrivacyInfo.xcprivacy\",")
    lines.append("\t\t\t\t\"$(SRCROOT)/LICENSE\",")
    lines.append("\t\t\t\t\"$(SRCROOT)/Sources/OmniDockCore/Resources\",")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = \"Copy App Resources\";")
    lines.append("\t\t\toutputFileListPaths = ();")
    lines.append("\t\t\toutputPaths = (")
    lines.append("\t\t\t\t\"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/PrivacyInfo.xcprivacy\",")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t\tshellPath = /bin/bash;")
    lines.append(f"\t\t\tshellScript = {q(resource_script)};")
    lines.append("\t\t};")

    lines.extend(["/* End PBXShellScriptBuildPhase section */", "", "/* Begin PBXSourcesBuildPhase section */"])

    lines.append(f"\t\t{sources_phase} /* Sources */ = {{")
    lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for path in swift_sources:
        lines.append(f"\t\t\t\t{source_build_files[path]} /* {Path(path).name} in Sources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append(f"\t\t{finder_extension_sources_phase} /* Sources */ = {{")
    lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for path in finder_extension_sources:
        lines.append(
            f"\t\t\t\t{finder_extension_source_build_files[path]} "
            f"/* {Path(path).name} in Sources */,"
        )
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.extend(["/* End PBXSourcesBuildPhase section */", "", "/* Begin XCBuildConfiguration section */"])

    base_project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
        "CLANG_WARN_STRICT_PROTOTYPES": "YES",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "MACOSX_DEPLOYMENT_TARGET": MIN_MACOS,
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "SDKROOT": "macosx",
        "SWIFT_VERSION": "5.0",
    }
    debug_project_settings = {
        **base_project_settings,
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    }
    release_project_settings = {
        **base_project_settings,
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    }
    base_target_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "3",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/OmniDock-Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MACOSX_DEPLOYMENT_TARGET": MIN_MACOS,
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "macosx",
        "SKIP_INSTALL": "NO",
        "SUPPORTED_PLATFORMS": "macosx",
        "SWIFT_VERSION": "5.0",
    }
    debug_target_settings = {
        **base_target_settings,
        "CODE_SIGN_ENTITLEMENTS": "Resources/OmniDock-Development.entitlements",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)"],
    }
    release_target_settings = {
        **base_target_settings,
        "CODE_SIGN_ENTITLEMENTS": "Resources/OmniDock-AppStore.entitlements",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "APP_STORE"],
    }
    base_finder_extension_settings = {
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "CODE_SIGN_ENTITLEMENTS": "Resources/OmniDockFinderSync.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "3",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/OmniDockFinderSync-Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
        "MACOSX_DEPLOYMENT_TARGET": MIN_MACOS,
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": FINDER_EXTENSION_BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "macosx",
        "SKIP_INSTALL": "YES",
        "SUPPORTED_PLATFORMS": "macosx",
        "SWIFT_VERSION": "5.0",
    }
    debug_finder_extension_settings = {**base_finder_extension_settings}
    release_finder_extension_settings = {**base_finder_extension_settings}

    for config_id, name, settings in [
        (project_debug, "Debug", debug_project_settings),
        (project_release, "Release", release_project_settings),
        (target_debug, "Debug", debug_target_settings),
        (target_release, "Release", release_target_settings),
        (finder_extension_debug, "Debug", debug_finder_extension_settings),
        (finder_extension_release, "Release", release_finder_extension_settings),
    ]:
        lines.append(f"\t\t{config_id} /* {name} */ = {{")
        lines.append("\t\t\tisa = XCBuildConfiguration;")
        lines.append("\t\t\tbuildSettings = {")
        lines.append(build_settings(settings))
        lines.append("\t\t\t};")
        lines.append(f"\t\t\tname = {name};")
        lines.append("\t\t};")

    lines.extend(["/* End XCBuildConfiguration section */", "", "/* Begin XCConfigurationList section */"])
    lines.append(f"\t\t{project_config_list} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{project_debug} /* Debug */,")
    lines.append(f"\t\t\t\t{project_release} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append(
        f"\t\t{finder_extension_config_list} /* Build configuration list for PBXNativeTarget \"{FINDER_EXTENSION_NAME}\" */ = {{"
    )
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{finder_extension_debug} /* Debug */,")
    lines.append(f"\t\t\t\t{finder_extension_release} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append(f"\t\t{target_config_list} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{target_debug} /* Debug */,")
    lines.append(f"\t\t\t\t{target_release} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.extend(["/* End XCConfigurationList section */", "", "\t};"])
    lines.append(f"\trootObject = {project} /* Project object */;")
    lines.append("}")
    return "\n".join(lines) + "\n"


def generate_scheme() -> str:
    target = oid("target:OmniDock")
    buildable = f"""            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{target}"
               BuildableName="{PROJECT_NAME}.app"
               BlueprintName="{PROJECT_NAME}"
               ReferencedContainer="container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion="{XCODE_VERSION}"
   version="1.7">
   <BuildAction
      parallelizeBuildables="YES"
      buildImplicitDependencies="YES"
      buildArchitectures="Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting="YES"
            buildForRunning="YES"
            buildForProfiling="YES"
            buildForArchiving="YES"
            buildForAnalyzing="YES">
{buildable}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration="Debug"
      selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv="YES"
      shouldAutocreateTestPlan="YES">
   </TestAction>
   <LaunchAction
      buildConfiguration="Debug"
      selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle="0"
      useCustomWorkingDirectory="NO"
      ignoresPersistentStateOnLaunch="NO"
      debugDocumentVersioning="YES"
      debugServiceExtension="internal"
      allowLocationSimulation="YES">
      <BuildableProductRunnable
         runnableDebuggingMode="0">
{buildable}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration="Release"
      shouldUseLaunchSchemeArgsEnv="YES"
      savedToolIdentifier=""
      useCustomWorkingDirectory="NO"
      debugDocumentVersioning="YES">
      <BuildableProductRunnable
         runnableDebuggingMode="0">
{buildable}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration="Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration="Release"
      revealArchiveInOrganizer="YES">
   </ArchiveAction>
</Scheme>
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify generated project files without writing them",
    )
    return parser.parse_args()


def generated_outputs() -> list[tuple[Path, bytes]]:
    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    schemes_dir = project_dir / "xcshareddata" / "xcschemes"
    return [
        (project_dir / "project.pbxproj", generate_pbxproj().encode("utf-8")),
        (schemes_dir / f"{PROJECT_NAME}.xcscheme", generate_scheme().encode("utf-8")),
    ]


def missing_inputs() -> list[Path]:
    required = [
        ROOT / "Resources" / "Assets.xcassets",
        ROOT / "Resources" / "OmniDock-Development.entitlements",
        ROOT / "Resources" / "OmniDock-AppStore.entitlements",
        ROOT / "Resources" / "OmniDock-Info.plist",
        ROOT / "Resources" / "OmniDockFinderSync.entitlements",
        ROOT / "Resources" / "OmniDockFinderSync-Info.plist",
        ROOT / "Resources" / "PrivacyInfo.xcprivacy",
        ROOT / "Sources" / PROJECT_NAME,
        ROOT / "Sources" / "OmniDockCore",
        ROOT / "Sources" / FINDER_EXTENSION_NAME,
    ]
    missing = [path for path in required if not path.exists()]
    if not list_swift_sources():
        missing.append(ROOT / "Sources")
    return missing


def main() -> int:
    args = parse_args()
    missing = missing_inputs()
    if missing:
        for path in missing:
            print(f"Missing input: {rel(path)}", file=sys.stderr)
        return 1
    outputs = generated_outputs()

    if args.check:
        stale_paths = [
            path
            for path, expected in outputs
            if not path.is_file() or path.read_bytes() != expected
        ]
        if stale_paths:
            for path in stale_paths:
                print(f"Out of date: {rel(path)}", file=sys.stderr)
            print("Run ./script/generate_xcode_project.py to regenerate.", file=sys.stderr)
            return 1
        print("Generated Xcode project and scheme are up to date.")
        return 0

    for path, contents in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)

    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    print(f"Generated {project_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
