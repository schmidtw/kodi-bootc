# Kodi bootc image — build, test, and publish.
# Override any variable on the command line, e.g.:
#   make build FEDORA_VERSION=43
#   make push  GHCR_OWNER=myuser

FEDORA_VERSION ?= 44
IMAGE          ?= kodi-bootc
TAG            ?= latest
GHCR_OWNER     ?= schmidtw
REGISTRY       ?= ghcr.io/$(GHCR_OWNER)

LOCAL_IMAGE    := localhost/$(IMAGE):$(TAG)
REMOTE_IMAGE   := $(REGISTRY)/$(IMAGE):$(TAG)

OUTPUT         ?= ./output
CONFIG         := install/config.toml
BIB            := quay.io/centos-bootc/bootc-image-builder:latest

# bootc-image-builder needs root + privileged + access to local image storage.
# The image ref is supplied per-target: LOCAL for VM testing, REMOTE (ghcr.io)
# for real install media so the installed box knows where to pull updates from.
BIB_RUN = sudo podman run --rm -it --privileged --security-opt label=disable \
	-v $(CURDIR)/$(CONFIG):/config.toml:ro \
	-v $(CURDIR)/$(OUTPUT):/output \
	-v /var/lib/containers/storage:/var/lib/containers/storage \
	$(BIB) --config /config.toml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the container image locally
	podman build --build-arg FEDORA_VERSION=$(FEDORA_VERSION) -t $(LOCAL_IMAGE) .

.PHONY: check
check: build ## Sanity-check the built image (packages + enabled services)
	podman run --rm $(LOCAL_IMAGE) rpm -q kodi tailscale mesa-va-drivers-freeworld
	podman run --rm $(LOCAL_IMAGE) systemctl is-enabled kodi.service tailscaled.service

$(CONFIG): ## Create local install config from the template (gitignored)
	cp -n install/config.toml.example $(CONFIG)
	@echo ">> $(CONFIG) ready. Interactive ISO install needs no edits;"
	@echo ">> uncomment the user block only for an unattended install."

.PHONY: config
config: $(CONFIG) ## Ensure install/config.toml exists

.PHONY: qcow2
qcow2: build config ## Build a qcow2 from the LOCAL image for VM testing
	mkdir -p $(OUTPUT)
	$(BIB_RUN) --type qcow2 $(LOCAL_IMAGE)

.PHONY: raw
raw: config ## Build a raw disk from the ghcr.io image (publish it first)
	mkdir -p $(OUTPUT)
	$(BIB_RUN) --type raw $(REMOTE_IMAGE)

.PHONY: iso
iso: config ## Build an installer ISO from the ghcr.io image (publish it first)
	mkdir -p $(OUTPUT)
	$(BIB_RUN) --type anaconda-iso $(REMOTE_IMAGE)

.PHONY: vm
vm: qcow2 ## Boot the qcow2 in qemu to watch Kodi start
	qemu-system-x86_64 -enable-kvm -m 4096 -cpu host \
		-device virtio-vga-gl -display gtk,gl=on \
		-drive file=$(OUTPUT)/qcow2/disk.qcow2,if=virtio

.PHONY: push
push: build ## Tag and push the image to ghcr.io (run `podman login ghcr.io` first)
	podman tag $(LOCAL_IMAGE) $(REMOTE_IMAGE)
	podman push $(REMOTE_IMAGE)

.PHONY: lint
lint: ## Run bootc container lint against the built image
	podman run --rm $(LOCAL_IMAGE) bootc container lint

.PHONY: packages
packages: ## List installed packages in the built image (name + version)
	@podman run --rm $(LOCAL_IMAGE) rpm -qa | sort

.PHONY: clean
clean: ## Remove build output and the local image
	sudo rm -rf $(OUTPUT)
	-podman rmi $(LOCAL_IMAGE)
