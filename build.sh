#!/usr/bin/env bash

set -u -e -o pipefail

readonly currentDir=$(cd $(dirname $0); pwd)

cd ${currentDir}

NODE_PACKAGES=(adapter-qunit
  hay
  launcher-chrome
  plugin-webpack
  reporter-junit
  reporter-spec)

BUILD_ALL=true
BUNDLE=true
VERSION_PREFIX=$(node -p "require('./package.json').version")
COMPILE_SOURCE=true
TYPECHECK_ALL=true
export NODE_PATH=${NODE_PATH:-}:${currentDir}/dist/tools

for ARG in "$@"; do
  case "$ARG" in
    --quick-bundle=*)
      COMPILE_SOURCE=false
      TYPECHECK_ALL=false
      BUILD_EXAMPLES=false
      BUILD_TOOLS=false
      ;;
    --packages=*)
      PACKAGES_STR=${ARG#--packages=}
      NODE_PACKAGES=( ${PACKAGES_STR//,/ } )
      BUILD_ALL=false
      ;;
    --bundle=*)
      BUNDLE=( "${ARG#--bundle=}" )
      ;;
    --compile=*)
      COMPILE_SOURCE=${ARG#--compile=}
      ;;
    *)
      echo "Unknown option $ARG."
      exit 1
      ;;
  esac
done

isIgnoredDirectory() {
  name=$(basename ${1})
  if [[ -f "${1}" || "${name}" == "src" || "${name}" == "test" ]]; then
    return 0
  else
    return 1
  fi
}

containsElement () {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

addBanners() {
  for file in ${1}/*; do
    if [[ -f ${file} && "${file##*.}" != "map" ]]; then
      cat ${LICENSE_BANNER} > ${file}.tmp
      cat ${file} >> ${file}.tmp
      mv ${file}.tmp ${file}
    fi
  done
}

minify() {
  # Iterate over the files in this directory, rolling up each into ${2} directory
  regex="(.+).js"
  files=(${1}/*)
  echo "${files[@]}"
  for file in "${files[@]}"; do
    echo "${file}"
    base_file=$( basename "${file}" )
    if [[ "${base_file}" =~ $regex && "${base_file##*.}" != "map" ]]; then
      local out_file=$(dirname "${file}")/${BASH_REMATCH[1]}.min.js
      $UGLIFYJS -c --screw-ie8 --comments -o ${out_file} --source-map ${out_file}.map --prefix relative --source-map-include-sources ${file}
    fi
  done
}

compilePackage() {
  # For NODE_PACKAGES items
  echo "======      [${3}]: COMPILING: ${TSC} -p ${1}/tsconfig.json"
  $TSC -p ${1}/tsconfig.json

  # Build subpackages
  for DIR in ${1}/* ; do
    [ -d "${DIR}" ] || continue
    BASE_DIR=$(basename "${DIR}")
    # Skip over directories that are not nested entry points
    [[ -e ${DIR}/tsconfig.json ]] || continue
    compilePackage ${DIR} ${2}/${BASE_DIR} ${3}
  done
}

compilePackageES5() {
  echo "======      [${3}]: COMPILING: ${TSC} -p ${1}/tsconfig.json --target es5 -d false --outDir ${2} --importHelpers true --sourceMap"
  local package_name=$(basename "${2}")
  $TSC -p ${1}/tsconfig.json --target es5 -d false --outDir ${2} --importHelpers true --sourceMap

  for DIR in ${1}/* ; do
    [ -d "${DIR}" ] || continue
    BASE_DIR=$(basename "${DIR}")
    # Skip over directories that are not nested entry points
    [[ -e ${DIR}/tsconfig.json ]] || continue
    compilePackageES5 ${DIR} ${2} ${3}
  done
}

addNgcPackageJson() {
  for DIR in ${1}/* ; do
    [ -d "${DIR}" ] || continue
    # Confirm there is an ${PACKAGE}.d.ts and ${PACKAGE}.metadata.json file. If so, create
    # the package.json and recurse.
    if [[ -f ${DIR}/${PACKAGE}.d.ts && -f ${DIR}/${PACKAGE}.metadata.json ]]; then
      echo '{"typings": "${PACKAGE}.d.ts"}' > ${DIR}/package.json
      addNgcPackageJson ${DIR}
    fi
  done
}

updateVersionReferences() {
  NPM_DIR="$1"
  (
    echo "======      VERSION: Updating version references in ${NPM_DIR}"
    cd ${NPM_DIR}
    echo "======       EXECUTE: perl -p -i -e \"s/0\.0\.0\-PLACEHOLDER/${VERSION}/g\" $""(grep -ril 0\.0\.0\-PLACEHOLDER .)"
    perl -p -i -e "s/0\.0\.0\-PLACEHOLDER/${VERSION}/g" $(grep -ril 0\.0\.0\-PLACEHOLDER .) < /dev/null 2> /dev/null
  )
}

dropLast() {
  local last_item=$(basename ${1})
  local regex=local regex="(.+)/${last_item}"
  if [[ "${1}" =~ $regex ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "${1}"
  fi
}

VERSION="${VERSION_PREFIX}"
echo "====== BUILDING: Version ${VERSION}"

N="
"
TSC=`pwd`/node_modules/.bin/tsc
UGLIFYJS=`pwd`/node_modules/.bin/uglifyjs
ROLLUP=`pwd`/node_modules/.bin/rollup

if [[ ${BUILD_ALL} == true && ${TYPECHECK_ALL} == true ]]; then
  rm -rf ./dist/all/
  rm -rf ./dist/packages

  mkdir -p ./dist/all/

  TSCONFIG="packages/tsconfig.json"
  $TSC -p ${TSCONFIG}
fi

if [[ ${BUILD_ALL} == true ]]; then
  rm -rf ./dist/packages
  if [[ ${BUNDLE} == true ]]; then
    rm -rf ./dist/packages-dist
  fi
fi

for PACKAGE in ${NODE_PACKAGES[@]}
do
  PWD=`pwd`
  ROOT_DIR=${PWD}/packages
  SRC_DIR=${ROOT_DIR}/${PACKAGE}
  ROOT_OUT_DIR=${PWD}/dist/packages
  OUT_DIR=${ROOT_OUT_DIR}/${PACKAGE}
  OUT_DIR_ESM5=${ROOT_OUT_DIR}/${PACKAGE}/esm5
  NPM_DIR=${PWD}/dist/packages-dist/${PACKAGE}
  ESM2015_DIR=${NPM_DIR}/esm2015
  ESM5_DIR=${NPM_DIR}/esm5
  BUNDLES_DIR=${NPM_DIR}/bundles

  LICENSE_BANNER=${ROOT_DIR}/license-banner.txt

  if [[ ${COMPILE_SOURCE} == true ]]; then
    rm -rf ${OUT_DIR}
    rm -f ${ROOT_OUT_DIR}/${PACKAGE}.js
    compilePackage ${SRC_DIR} ${OUT_DIR} ${PACKAGE}
  fi

  if [[ ${BUNDLE} == true ]]; then
    echo "======      BUNDLING ${PACKAGE}: ${SRC_DIR} ====="
    rm -rf ${NPM_DIR} && mkdir -p ${NPM_DIR}

    echo "======        Copy ${PACKAGE} node tool"
    rsync -a ${OUT_DIR}/ ${NPM_DIR}

    echo "======        Copy ${PACKAGE} package.json and .externs.js files"
    rsync -am --include="package.json" --include="*/" --exclude=* ${SRC_DIR}/ ${NPM_DIR}/
    rsync -am --include="*.externs.js" --include="*/" --exclude=* ${SRC_DIR}/ ${NPM_DIR}/

    cp ${ROOT_DIR}/README.md ${NPM_DIR}/
  fi


  if [[ -d ${NPM_DIR} ]]; then
    updateVersionReferences ${NPM_DIR}
  fi
done
