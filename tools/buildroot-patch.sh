#!/bin/sh
# Apply mylinux's local Buildroot fixes to the Buildroot checkout inside the Debian machine.
# Idempotent. Run after cloning Buildroot (see PLAN.md, Phase 1) and after `git pull` there.
# 1. qt6base: Qt >= 6.11 decides the Wayland features in qtbase, Buildroot 2026.08 does not know.
orb run -m debian python3 - <<'PY'
import os; p=os.path.expanduser('~/br/buildroot/package/qt6/qt6base/qt6base.mk'); s=open(p).read()
snippet='''
# mylinux: Qt >= 6.11 decides the wayland features in qtbase (see buildroot-patches/ in BR2_EXTERNAL)
ifeq ($(BR2_PACKAGE_QT6WAYLAND),y)
QT6BASE_DEPENDENCIES += wayland wayland-protocols
QT6BASE_CONF_OPTS += -DFEATURE_wayland_client=ON
HOST_QT6BASE_DEPENDENCIES += host-wayland
HOST_QT6BASE_CONF_OPTS += -DFEATURE_wayland_client=ON
ifeq ($(BR2_PACKAGE_QT6WAYLAND_COMPOSITOR),y)
QT6BASE_DEPENDENCIES += libxkbcommon
QT6BASE_CONF_OPTS += -DFEATURE_wayland_server=ON
HOST_QT6BASE_CONF_OPTS += -DFEATURE_wayland_server=ON
endif
endif
'''
if 'mylinux: Qt >= 6.11' in s:
    print('qt6base.mk: already patched')
else:
    i = s.rfind('$(eval $(cmake-package))')
    open(p,'w').write(s[:i] + snippet + '\n' + s[i:]); print('qt6base.mk: patched')
PY
