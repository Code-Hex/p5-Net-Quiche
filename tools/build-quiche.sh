#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir="$root/.deps/quiche"
expected=55886df3be579579207104c8e645825b6347a209

mkdir -p "$root/.deps"
if [ ! -d "$source_dir" ]; then
    git clone --depth 1 --branch 0.29.3 https://github.com/cloudflare/quiche.git "$source_dir"
fi
actual=$(git -C "$source_dir" rev-parse HEAD)
if [ "$actual" != "$expected" ]; then
    echo "Expected quiche $expected, found $actual at $source_dir" >&2
    exit 1
fi

# Preserve a developer's lockfile instead of silently replacing it.
if [ -f "$source_dir/Cargo.lock" ]; then
    if ! cmp -s "$root/builder/quiche-Cargo.lock" "$source_dir/Cargo.lock"; then
        echo "Cargo.lock differs from builder/quiche-Cargo.lock at $source_dir" >&2
        exit 1
    fi
else
    cp "$root/builder/quiche-Cargo.lock" "$source_dir/Cargo.lock"
fi

case "$(uname -s)" in
    Darwin) export CARGO_C_LIBDIR=@rpath ;;
esac
cargo build --manifest-path "$source_dir/Cargo.toml" --locked --release \
    -p quiche --features ffi,pkg-config-meta

case "$(uname -s)" in
    Darwin) name=libquiche.0.29.3.dylib; target=libquiche.dylib ;;
    Linux) name=libquiche.so.0; target=libquiche.so ;;
    *) echo 'Configure the shared library search path for your platform.' >&2; exit 1 ;;
esac
if [ ! -e "$source_dir/target/release/$name" ] && [ ! -L "$source_dir/target/release/$name" ]; then
    ln -s "$target" "$source_dir/target/release/$name"
fi
echo "quiche is ready. Set PKG_CONFIG_PATH to $source_dir/target/release"
