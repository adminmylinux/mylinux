################################################################################
#
# inter (font)
#
################################################################################

INTER_VERSION = 4.1
INTER_SOURCE = Inter-$(INTER_VERSION).zip
INTER_SITE = https://github.com/rsms/inter/releases/download/v$(INTER_VERSION)
INTER_LICENSE = OFL-1.1
INTER_LICENSE_FILES = LICENSE.txt

define INTER_EXTRACT_CMDS
	$(UNZIP) -q -d $(@D) $(INTER_DL_DIR)/$(INTER_SOURCE)
endef

define INTER_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/usr/share/fonts/inter
	$(INSTALL) -m 0644 $(@D)/extras/ttf/Inter-Regular.ttf $(@D)/extras/ttf/Inter-Medium.ttf \
		$(@D)/extras/ttf/Inter-SemiBold.ttf $(@D)/extras/ttf/Inter-Bold.ttf \
		$(TARGET_DIR)/usr/share/fonts/inter/
endef

$(eval $(generic-package))
