#!/usr/bin/env bash

set -e
zig build cross -Drelease -Dstrip=true --summary all
mv ./zig-out/bin/gh-ignorer-* .

