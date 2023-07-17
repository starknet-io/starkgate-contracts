#!/bin/bash
pushd $(dirname "$0")/..

set -ex


TARGET=$1

mkdir -p target/$TARGET/starkgate

scripts/build-cairo.sh
scripts/build-solidity.sh

cp -r cairo_contracts target/$TARGET/starkgate
cp -r artifacts target/$TARGET/starkgate/solidity_contracts

cd target/$TARGET
rm -rf $TARGET.tar.gz

tar czvf ../$TARGET.tar.gz starkgate

popd
