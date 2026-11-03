# Your phone's name, from Config/local.mk (ignored by git), for example:
#   DEVICE = My iPhone
# or per run: make install DEVICE="My iPhone"
-include Config/local.mk

.PHONY: install

# Builds an Ad Hoc copy and installs it over the existing app, keeping its data.
# The phone needs Developer Mode on. See docs/RELEASING.md.
install:
	@test -n "$(DEVICE)" || { echo 'Set DEVICE in Config/local.mk, for example: DEVICE = My iPhone' >&2; exit 1; }
	scripts/release-build.sh --install "$(DEVICE)"
