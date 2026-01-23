# Maintainer: GhostKellz <ghost@ghostkellz.sh>
pkgname=nvsync
pkgver=0.2.2
pkgrel=1
pkgdesc="VRR/G-Sync Control for Linux - Frame limiting and display sync management"
arch=('x86_64')
url="https://github.com/ghostkellz/nvsync"
license=('MIT')
depends=('glibc')
makedepends=('zig>=0.16')
optdepends=(
    'nvidia-utils: NVIDIA G-Sync detection and control'
    'libdrm: DRM/KMS VRR control'
    'wlr-randr: wlroots VRR control'
)
provides=('libnvsync.so')
backup=('etc/nvsync/profiles.json')
install=nvsync.install
source=(
    "$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz"
    'nvsync.service'
    '90-nvsync.rules'
)
sha256sums=('SKIP' 'SKIP' 'SKIP')

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

    # udev rules for non-root VRR access
    install -Dm644 "$srcdir/90-nvsync.rules" "$pkgdir/usr/lib/udev/rules.d/90-nvsync.rules"

    # systemd user service for daemon mode
    install -Dm644 "$srcdir/nvsync.service" "$pkgdir/usr/lib/systemd/user/nvsync.service"

    # Default config directory
    install -dm755 "$pkgdir/etc/nvsync"

    # Documentation
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
