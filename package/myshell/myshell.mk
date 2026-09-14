################################################################################
#
# myshell
#
################################################################################

MYSHELL_SITE = $(BR2_EXTERNAL_MYLINUX_PATH)/shell
MYSHELL_SITE_METHOD = local
MYSHELL_DEPENDENCIES = qt6base qt6declarative qt6wayland libvncserver libvterm host-qt6declarative host-pkgconf
MYSHELL_CONF_OPTS = -DCMAKE_BUILD_TYPE=Release

$(eval $(cmake-package))
