# Debian APT Sources (DEB822 format)
# Placeholder: {{DEBIAN_SUITE}} (e.g., bookworm, trixie)

Types: deb
URIs: http://deb.debian.org/debian/
Suites: {{DEBIAN_SUITE}} {{DEBIAN_SUITE}}-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: {{DEBIAN_SUITE}}-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
