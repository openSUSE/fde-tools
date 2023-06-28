PKGNAME		= fde-tools-$(shell ./fde.sh --version)

CCOPT		= -O0 -g
LIBDIR		= /usr/lib64
SBINDIR		= /usr/sbin
SYSCONFIGDIR	= /etc/sysconfig
FDE_CONFIG_DIR	= /etc/fde
FDE_SHARE_DIR	= /usr/share/fde
FIRSTBOOTDIR	= /usr/share/jeos-firstboot
CFLAGS		= -Wall $(CCOPT)
FIDO_LINK	= -lfido2 -lcrypto
CRPYT_LINK	= -lcryptsetup -ljson-c
TOOLS		= fde-token fdectl-grub-tpm2
TOKEN_LINK	= -lcryptsetup
TOKEN_ABI_PATH	= cryptsetup/libcryptsetup-token.sym
TOKEN_PLUGINS	= libcryptsetup-token-grub-tpm2.so

LIBSCRIPTS	= grub2 \
		  luks \
		  tpm \
		  uefi \
		  util \
		  ui/dialog \
		  ui/shell \
		  commands/passwd \
		  commands/add-secondary-key \
		  commands/add-secondary-password \
		  commands/remove-secondary-password \
		  commands/tpm-activate \
		  commands/tpm-enable \
		  commands/tpm-disable \
		  commands/tpm-authorize \
		  commands/tpm-present \
		  commands/tpm-wipe

_LIBSCRIPTS	= $(addprefix share/,$(LIBSCRIPTS))

SUBDIRS := man bash-completion

.PHONY: all install $(SUBDIRS)

all:: $(TOOLS) $(SUBDIRS) $(TOKEN_PLUGINS)

install:: $(TOOLS)
	install -d $(DESTDIR)/usr/bin
	install -m 755 $(TOOLS) $(DESTDIR)/usr/bin

install:: $(TOKEN_PLUGINS)
	install -d $(DESTDIR)/$(LIBDIR)/cryptsetup
	install -m 755 $(TOKEN_PLUGINS) $(DESTDIR)/$(LIBDIR)/cryptsetup

install::
	@mkdir -p $(DESTDIR)$(FIRSTBOOTDIR)/modules
	@cp -v firstboot/fde $(DESTDIR)$(FIRSTBOOTDIR)/modules/fde
	@mkdir -p $(DESTDIR)$(SYSCONFIGDIR)
	@cp -v sysconfig.fde $(DESTDIR)$(SYSCONFIGDIR)/fde-tools
	@mkdir -p $(DESTDIR)$(FDE_SHARE_DIR)
	@for name in $(LIBSCRIPTS); do \
		d=$$(dirname $$name); \
		mkdir -p $(DESTDIR)$(FDE_SHARE_DIR)/$$d; \
		cp -v share/$$name $(DESTDIR)$(FDE_SHARE_DIR)/$$d; \
	done
	@mkdir -p $(DESTDIR)$(SBINDIR)
	@install -m 555 -v fde.sh $(DESTDIR)$(SBINDIR)/fdectl
	@install -m 755 -v -d $(DESTDIR)$(FDE_CONFIG_DIR)

$(SUBDIRS):
	$(MAKE) -C $@

install:: $(SUBDIRS)
	@for d in $(SUBDIRS); do \
		$(MAKE) -C $$d install; \
	done

clean:
	rm -f $(TOOLS)
	rm -f $(TOKEN_PLUGINS)
	rm -rf build

fde-token: build/fde-token.o
	$(CC) -o $@ $< $(FIDO_LINK)

fdectl-grub-tpm2: build/fdectl-grub-tpm2.o
	$(CC) -o $@ $< $(CRPYT_LINK)

libcryptsetup-token-grub-tpm2.so: build/cryptsetup/cryptsetup-token-grub-tpm2.o
	$(CC) -o $@ $< $(TOKEN_LINK) -shared -Wl,--version-script=$(TOKEN_ABI_PATH)

build/cryptsetup/%.o: cryptsetup/%.c
	@mkdir -p build/cryptsetup
	$(CC) -o $@ -fPIC $(CFLAGS) -c $<

build/%.o: src/%.c
	@mkdir -p build
	$(CC) -o $@ $(CFLAGS) -c $<

dist:
	mkdir -p $(PKGNAME)
	cp -a Makefile sysconfig.fde fde.sh src share firstboot $(SUBDIRS) $(PKGNAME)
	@find $(PKGNAME) -name '.*.swp' -o -name '*.{rej,orig}' | xargs -rt rm
	tar -cvjf $(PKGNAME).tar.bz2 $(PKGNAME)/*
	rm -rf $(PKGNAME)
