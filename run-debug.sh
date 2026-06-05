#!/usr/bin/env bash

xcodegen generate

xcodebuild \
  -scheme Starcat \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath build/DerivedData \
  build

open build/DerivedData/Build/Products/Debug/Starcat.appd