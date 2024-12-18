#!/usr/bin/env bash

set -euo pipefail
zig build dist -Dversion=$1 --summary all

