################################################################################
#
# myshell
#
################################################################################

MYSHELL_SITE = $(BR2_EXTERNAL_MYLINUX_PATH)/shell
MYSHELL_SITE_METHOD = local
MYSHELL_DEPENDENCIES = qt6base qt6declarative qt6wayland host-qt6declarative
MYSHELL_CONF_OPTS = -DCMAKE_BUILD_TYPE=Release

$(eval $(cmake-package))
