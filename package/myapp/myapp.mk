################################################################################
#
# myapp
#
################################################################################

MYAPP_SITE = $(BR2_EXTERNAL_MYLINUX_PATH)/app
MYAPP_SITE_METHOD = local
MYAPP_DEPENDENCIES = qt6base qt6declarative host-qt6declarative
MYAPP_CONF_OPTS = -DCMAKE_BUILD_TYPE=Release

$(eval $(cmake-package))
