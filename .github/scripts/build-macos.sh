#!/bin/bash
set -e -x

source .github/scripts/travis_retry.sh

# Used by CMake and clang
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION

# Work-around issue building on newer XCode versions.
# https://github.com/pandas-dev/pandas/issues/23424#issuecomment-446393981
if [ $MACOS_MIN_VERSION == "10.6" ]; then
    # Note that distutils allows higher but not lower target versions,
    # relative to the target version of Python itself.
    # The resulting wheel platform tags still have 10.6 (=target of Python itself),
    # even though technically the wheel should only be run on 10.9 upwards. Bug?
    # See https://github.com/python/cpython/blob/9c42f8cda/Lib/distutils/spawn.py#L103-L111.
    export MACOSX_DEPLOYMENT_TARGET=10.9
fi

# Install Python
# Note: The GitHub Actions supplied Python versions are not used
# as they are built without MACOSX_DEPLOYMENT_TARGET/-mmacosx-version-min
# being set to an older target for widest wheel compatibility.
# Instead we install python.org binaries which are built with 10.6/10.9 target
# and hence provide wider compatibility for the wheels we create.
# See https://github.com/actions/setup-python/issues/26.
pushd external
git clone https://github.com/matthew-brett/multibuild.git
cd multibuild
set +x # reduce noise
source osx_utils.sh
get_macpython_environment $PYTHON_VERSION venv $MACOS_MIN_VERSION
source venv/bin/activate
set -x
popd

export HOMEBREW_NO_BOTTLE_SOURCE_FALLBACK=1
export HOMEBREW_CURL_RETRIES=3
export HOMEBREW_NO_INSTALL_CLEANUP=1

# brew tries to update itself and Ruby during 'brew install ..'' but fails doing so with
# "Homebrew must be run under Ruby 2.3! You're running 2.0.0.".
# Updating brew separately seems to avoid this issue.
travis_retry brew update

# Build wheel
travis_retry pip install numpy==$NUMPY_VERSION cython wheel delocate
pip freeze
brew rm --ignore-dependencies jpeg || true
# TODO is it save to use prebuilt bottles?
#     which macOS deployment target would bottles have? -> likely same as host os
#     would delocate-wheel detect incompatibilities?
# see https://github.com/matthew-brett/delocate/issues/56
brew install jpeg jasper little-cms2
export CC=clang
export CXX=clang++
export CFLAGS="-arch x86_64"
export CXXFLAGS=$CFLAGS
export LDFLAGS=$CFLAGS
export ARCHFLAGS=$CFLAGS
python setup.py bdist_wheel
delocate-listdeps --all dist/*.whl # lists library dependencies
delocate-wheel --require-archs=x86_64 dist/*.whl # copies library dependencies into wheel
delocate-listdeps --all dist/*.whl # verify

# Dump target versions of dependend libraries.
# Currently, delocate does not support checking those.
# See https://github.com/matthew-brett/delocate/issues/56.
mkdir tmp_wheel
pushd tmp_wheel
unzip ../dist/*.whl
ls -al rawpy/.dylibs
echo "Dumping LC_VERSION_MIN_MACOSX"
for file in rawpy/.dylibs/*; do
    echo $file
    otool -l $file | grep -A 3 LC_VERSION_MIN_MACOSX
done
popd

# Install rawpy
pip install dist/*.whl

# Test installed rawpy
travis_retry pip install numpy -U # scipy should trigger an update, but that doesn't happen
travis_retry pip install -r dev-requirements.txt
# make sure it's working without any required libraries installed
brew rm --ignore-dependencies jpeg jasper little-cms2
mkdir tmp_for_test
pushd tmp_for_test
nosetests --verbosity=3 --nocapture ../test
popd
