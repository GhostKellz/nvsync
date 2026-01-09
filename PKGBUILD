# Maintainer: GhostKellz <ghost@ghostkellz.sh>
pkgname=nvsync
pkgver=1.0.0
pkgrel=1
pkgdesc="VRR/G-Sync Control for Linux - Frame limiting and display sync management"
arch=('x86_64')
url="https://github.com/ghostkellz/nvsync"
license=('MIT')
depends=('glibc')
makedepends=('zig>=0.14')
optdepends=(
    'nvidia-utils: NVIDIA G-Sync detection and control'
    'libdrm: DRM/KMS VRR control'
)
provides=('libnvsync.so')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "$pkgname-$pkgver"
    zig build -Doptimize=ReleaseFast -Dlinkage=dynamic
}

package() {
    cd "$pkgname-$pkgver"

    # CLI binary
    install -Dm755 zig-out/bin/nvsync "$pkgdir/usr/bin/nvsync"

    # Shared library for FFI
    install -Dm755 zig-out/lib/libnvsync.so "$pkgdir/usr/lib/libnvsync.so"

    # C header for development
    install -Dm644 include/nvsync.h "$pkgdir/usr/include/nvsync.h"

    # Documentation
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
