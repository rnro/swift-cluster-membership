#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Cluster Membership open source project
##
## Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -e

my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root_path="$my_path/.."

proto_path="$root_path/Protos"

pushd $proto_path >> /dev/null

declare -a public_protos
public_protos=(
  -name 'ClusterMembership.proto'
  -or -name 'SWIMNIO.proto'
)

# There are two visibility options: Public, Internal (default)
# https://github.com/apple/swift-protobuf/blob/master/Documentation/PLUGIN.md#generation-option-visibility---visibility-of-generated-types
if [[ ${#public_protos[@]} -ne 0 ]]; then
for visibility in public default; do
  swift_opt=''
  case "$visibility" in
    public)
        files=$(find . \( "${public_protos[@]}" \))
        swift_opt='--swift_opt=Visibility=Public'
      ;;
    default)
      files=$(find . -name '*.proto' -a \( \! \( "${public_protos[@]}" \) \) )
      ;;
  esac

  if (( ${#files} )); then
    for p in $files; do
        out_dir=$( dirname "$p" )
        base_name=$( echo basename "$p" | sed "s/.*\///" )
        out_name="${base_name%.*}.pb.swift"
        dest_dir="../Sources/${out_dir}/Protobuf"
        dest_file="${dest_dir}/${out_name}"
        mkdir -p ${dest_dir}
        command="protoc --swift_out=. ${p} ${swift_opt}"
        echo $command
       `$command`
        mv "${out_dir}/${out_name}" "${dest_file}"
    done
  fi
done
fi

popd >> /dev/null

declare -a internal_proto_paths
internal_proto_paths=(
    "$root_path/Samples/Protos"
)

for internal_proto_path in "${internal_proto_paths[@]}"; do
  (
    pushd "$internal_proto_path" >> /dev/null

    find . -name "*.proto" | while read p; do
      out_dir=$( dirname "$p" )
      base_name=$( echo basename "$p" | sed "s/.*\///" )
      out_name="${base_name%.*}.pb.swift"
      dest_dir="../${out_dir}/Protobuf"
      dest_file="${dest_dir}/${out_name}"
      mkdir -p ${dest_dir}
      command="protoc --swift_out=. ${p}"
      echo $command
      `$command`
      mv "${out_dir}/${out_name}" "${dest_file}"
    done

    popd >> /dev/null
  )
done

echo "Done."
