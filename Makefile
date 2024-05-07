.DEFAULT_GOAL := foundry

.PHONY: install
install:
	pnpm install

.PHONY: foundry
foundry:
	docker run --rm \
    -v $$(pwd):/app/foundry \
    -u $$(id -u):$$(id -g) \
		-p 8545:8545 \
    ghcr.io/paradigmxyz/foundry-alphanet:latest \
    --foundry-directory /app/foundry \
    --foundry-command "$(cmd)"