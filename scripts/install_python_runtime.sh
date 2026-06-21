#!/bin/sh
set -e

# Unsigned/CI builds can disable extension framework signing explicitly.
if [ "${PALLADIUM_DISABLE_PYTHON_DYLIB_CODESIGN:-}" = "1" ]; then
  export CODE_SIGNING_ALLOWED=NO
  export EXPANDED_CODE_SIGN_IDENTITY=""
  export EXPANDED_CODE_SIGN_IDENTITY_NAME=""
fi

# If Xcode provides an empty/whitespace identity, force-signing should be skipped.
SIGN_IDENTITY_TRIMMED=$(echo "${EXPANDED_CODE_SIGN_IDENTITY:-}" | tr -d '[:space:]')
if [ -z "$SIGN_IDENTITY_TRIMMED" ]; then
  export CODE_SIGNING_ALLOWED=NO
fi

source "$PROJECT_DIR/Frameworks/Python.xcframework/build/utils.sh"

install_dylib () {
    PYTHON_XCFRAMEWORK_PATH=$1
    INSTALL_BASE=$2
    FULL_EXT=$3

    # The name of the extension file
    EXT=$(basename "$FULL_EXT")
    # The name and location of the module
    MODULE_PATH=$(dirname "$FULL_EXT")
    MODULE_NAME=$(echo $EXT | cut -d "." -f 1)
    # The location of the extension file, relative to the bundle
    RELATIVE_EXT=${FULL_EXT#$CODESIGNING_FOLDER_PATH/}
    # The path to the extension file, relative to the install base
    PYTHON_EXT=${RELATIVE_EXT/$INSTALL_BASE/}
    # The full dotted name of the extension module, constructed from the file path.
    FULL_MODULE_NAME=$(echo $PYTHON_EXT | cut -d "." -f 1 | tr "/" ".");
    # A bundle identifier; not actually used, but required by Xcode framework packaging
    FRAMEWORK_BUNDLE_ID=$(echo $PRODUCT_BUNDLE_IDENTIFIER.$FULL_MODULE_NAME | tr "_" "-")
    # The name of the framework folder.
    FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"

    # If the framework folder doesn't exist, create it.
    if [ ! -d "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER" ]; then
        echo "Creating framework for $RELATIVE_EXT"
        mkdir -p "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
        cp "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/build/$PLATFORM_FAMILY_NAME-dylib-Info-template.plist" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
        plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
        plutil -replace CFBundleIdentifier -string "$FRAMEWORK_BUNDLE_ID" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
    fi

    echo "Installing binary for $FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
    mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
    # Create a placeholder .fwork file where the .so was
    echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > ${FULL_EXT%.so}.fwork
    # Create a back reference to the .so file location in the framework
    echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"

    # If the framework provides an xcprivacy file, install it.
    if [ -e "$MODULE_PATH/$MODULE_NAME.xcprivacy" ]; then
        echo "Installing XCPrivacy file for $FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
        XCPRIVACY_FILE="$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/PrivacyInfo.xcprivacy"
        if [ -e "$XCPRIVACY_FILE" ]; then
          rm -rf "$XCPRIVACY_FILE"
        fi
        mv "$MODULE_PATH/$MODULE_NAME.xcprivacy" "$XCPRIVACY_FILE"
    fi

    SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ -z "$(echo "$SIGN_IDENTITY" | tr -d '[:space:]')" ]; then
        SIGN_IDENTITY="-"
    fi

    echo "Signing framework as $SIGN_IDENTITY..."
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
}

install_python Frameworks/Python.xcframework

copy_privacy_manifest() {
  MANIFEST_NAME=$1
  FRAMEWORK_NAME=$2
  SOURCE_PATH="$PROJECT_DIR/privacy-manifests/python/$MANIFEST_NAME"
  TARGET_FRAMEWORK="$CODESIGNING_FOLDER_PATH/Frameworks/$FRAMEWORK_NAME"
  TARGET_PATH="$TARGET_FRAMEWORK/PrivacyInfo.xcprivacy"

  if [ ! -f "$SOURCE_PATH" ] || [ ! -d "$TARGET_FRAMEWORK" ]; then
    return
  fi

  cp "$SOURCE_PATH" "$TARGET_PATH"
  echo "Installed privacy manifest for $FRAMEWORK_NAME"

  SIGN_IDENTITY_TRIMMED=$(echo "${EXPANDED_CODE_SIGN_IDENTITY:-}" | tr -d '[:space:]')
  if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ] || [ -z "$SIGN_IDENTITY_TRIMMED" ]; then
    echo "Skipping framework re-signing for $FRAMEWORK_NAME (simulator or no signing identity)."
    return
  fi

  echo "Re-signing $FRAMEWORK_NAME after privacy manifest update..."
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$TARGET_FRAMEWORK"
}

copy_privacy_manifest "_ssl.xcprivacy" "_ssl.framework"
copy_privacy_manifest "_hashlib.xcprivacy" "_hashlib.framework"
