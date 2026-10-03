pkgname=wayland-cast-doctor
pkgver=2026.10.3
pkgrel=9
pkgdesc="Diagnose why desktop sharing, screenshots or the clipboard fail on any Wayland compositor"
arch=(any)
url="https://github.com/ljm-233/wayland-cast-doctor"
license=('GPL-3.0-or-later')
depends=(wayland-utils pipewire wireplumber dbus)
# This makepkg rejects "pkg:description" in optdepends outright, so the
# packages are listed bare and the README explains what each one is for.
optdepends=(niri-portal-cast linuxqq-wayland-fix)

source=()

package() {
	cd "$startdir"
	install -Dm755 wayland-cast-doctor.sh "$pkgdir"/usr/bin/wayland-cast-doctor
	install -Dm644 LICENSE "$pkgdir"/usr/share/licenses/$pkgname/LICENSE
}
