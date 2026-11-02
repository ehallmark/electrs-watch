# Override for another phone: make install DEVICE="Other iPhone"
DEVICE ?= Evan's iPhone

.PHONY: install

# Builds an Ad Hoc copy and installs it over the existing app, keeping its data.
# The phone needs Developer Mode on. See docs/RELEASING.md.
install:
	scripts/release-build.sh --install "$(DEVICE)"
