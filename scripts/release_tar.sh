#!/bin/bash
pushd $(dirname "$0")/..

set -ex


TARGET=$1

mkdir -p target/$TARGET/starkgate/

scripts/build-solidity.sh
scarb --release build

cp -r artifacts target/$TARGET/starkgate/solidity_contracts
cp -r target/release/ target/$TARGET/starkgate/cairo_contracts/
rm -rf target/$TARGET/starkgate/cairo_contracts/incremental
rm -rf target/$TARGET/starkgate/cairo_contracts/.fingerprint

cd target/$TARGET
rm -rf $TARGET.tar.gz

tar czvf ../$TARGET.tar.gz starkgate

popd
