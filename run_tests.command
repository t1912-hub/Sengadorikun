#!/bin/bash
# PencilTest のテストを実行します。ダブルクリックでも動きます。
set -e
cd "$(dirname "$0")"
echo "==> テストをコンパイル"
swiftc -O Shared/FrameStore.swift Shared/MP4Exporter.swift Shared/SequenceExporter.swift Tests/main.swift -o /tmp/penciltest-tests
echo "==> 実行"
/tmp/penciltest-tests
