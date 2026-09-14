################################################################################
#
# libvterm
#
################################################################################

LIBVTERM_VERSION = 0.3.3
LIBVTERM_SITE = https://www.leonerd.org.uk/code/libvterm
LIBVTERM_LICENSE = MIT
LIBVTERM_LICENSE_FILES = LICENSE
LIBVTERM_INSTALL_STAGING = YES
LIBVTERM_DEPENDENCIES = host-libtool host-pkgconf

# a plain Makefile driven by libtool; the encoding tables are generated with perl at build time
LIBVTERM_MAKE_OPTS = $(TARGET_CONFIGURE_OPTS) LIBTOOL="$(HOST_DIR)/bin/libtool" PREFIX=/usr

define LIBVTERM_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(LIBVTERM_MAKE_OPTS) -C $(@D) libvterm.la
endef

define LIBVTERM_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(LIBVTERM_MAKE_OPTS) DESTDIR=$(STAGING_DIR) -C $(@D) install-inc install-lib
endef

define LIBVTERM_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(LIBVTERM_MAKE_OPTS) DESTDIR=$(TARGET_DIR) -C $(@D) install-lib
endef

$(eval $(generic-package))
