# Essentials — one-shot setup for contracts, tests, and resolver.
#
# Quick start on a fresh clone:
#   make install   # installs Foundry (if missing) + all forge/npm dependencies
#   make test      # run the Foundry test suite
#
# Run `make help` for the full target list.

SHELL := /bin/bash
FOUNDRY_BIN := $(HOME)/.foundry/bin
PATH := $(FOUNDRY_BIN):$(PATH)

.DEFAULT_GOAL := help

.PHONY: help install foundry contracts resolver-deps \
        build test test-v deploy \
        resolver-keeper resolver-fallback fmt clean clean-all

help: ## Show this help
	@echo "Essentials — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ---- setup ---------------------------------------------------------------

install: foundry contracts resolver-deps ## Install everything (Foundry + forge libs + resolver deps)
	@echo "✓ all dependencies installed"

foundry: ## Install Foundry (forge/cast/anvil) if not already present
	@if command -v forge >/dev/null 2>&1; then \
		echo "✓ foundry already installed ($$(forge --version | head -n1))"; \
	else \
		echo "installing foundryup..."; \
		curl -L https://raw.githubusercontent.com/foundry-rs/foundry/master/foundryup/install | bash; \
		echo "installing forge/cast/anvil..."; \
		$(FOUNDRY_BIN)/foundryup; \
	fi

contracts: foundry ## Install Solidity dependencies (v4-core, v4-periphery, forge-std) and build
	forge install
	forge build

resolver-deps: ## Install the off-chain resolver's npm dependencies
	cd resolver && npm install

## ---- contracts -------------------------------------------------------------

build: ## Compile the contracts
	forge build

test: ## Run the Foundry test suite
	forge test

test-v: ## Run the Foundry test suite with logs (-vv)
	forge test -vv

fmt: ## Format Solidity sources
	forge fmt

deploy: ## Deploy EssentialsHook — usage: make deploy POOL_MANAGER=0x... RPC_URL=... PRIVATE_KEY=...
	forge script script/DeployEssentialsHook.s.sol --sig "run(address)" $(POOL_MANAGER) \
		--rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

## ---- interact (against an already-deployed hook) ------------------------

status: ## Show current batch status — usage: make status HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. RPC_URL=...
	HOOK=$(HOOK) TOKEN0=$(TOKEN0) TOKEN1=$(TOKEN1) forge script script/Interact.s.sol --sig "status()" --rpc-url $(RPC_URL)

queue-swap: ## Queue a swap — usage: make queue-swap HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. ZERO_FOR_ONE=true AMOUNT_IN=1000000000000000000 RPC_URL=... PRIVATE_KEY=...
	HOOK=$(HOOK) TOKEN0=$(TOKEN0) TOKEN1=$(TOKEN1) forge script script/Interact.s.sol \
		--sig "queueSwap(bool,uint256)" $(ZERO_FOR_ONE) $(AMOUNT_IN) --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

settle: ## Settle the current batch — usage: make settle HOOK=0x.. TOKEN0=0x.. TOKEN1=0x.. RPC_URL=... PRIVATE_KEY=...
	HOOK=$(HOOK) TOKEN0=$(TOKEN0) TOKEN1=$(TOKEN1) forge script script/Interact.s.sol --sig "settle()" --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

add-liquidity: ## Add liquidity — usage: make add-liquidity HOOK=.. TOKEN0=.. TOKEN1=.. TICK_LOWER=-600 TICK_UPPER=600 LIQUIDITY=1000000000000000000 RPC_URL=... PRIVATE_KEY=...
	HOOK=$(HOOK) TOKEN0=$(TOKEN0) TOKEN1=$(TOKEN1) forge script script/Interact.s.sol \
		--sig "addLiquidity(int24,int24,int256)" $(TICK_LOWER) $(TICK_UPPER) $(LIQUIDITY) --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

remove-liquidity: ## Remove liquidity — usage: make remove-liquidity HOOK=.. TOKEN0=.. TOKEN1=.. ROUTER=0x.. TICK_LOWER=-600 TICK_UPPER=600 LIQUIDITY=1000000000000000000 RPC_URL=... PRIVATE_KEY=...
	HOOK=$(HOOK) TOKEN0=$(TOKEN0) TOKEN1=$(TOKEN1) forge script script/Interact.s.sol \
		--sig "removeLiquidity(address,int24,int24,int256)" $(ROUTER) $(TICK_LOWER) $(TICK_UPPER) $(LIQUIDITY) --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

demo: ## Run the full live sandwich demo end-to-end on a fresh local anvil chain
	./script/demo/run_local_demo.sh

## ---- resolver ---------------------------------------------------------------

resolver-keeper: ## Run the batch-settlement keeper — needs HOOK_ADDRESS, PRIVATE_KEY, POOL_KEYS env vars
	cd resolver && npm run keeper

resolver-fallback: ## Check the CoW Protocol / Flashbots Protect fallback for a given order — usage: make resolver-fallback SELL_TOKEN=0x.. BUY_TOKEN=0x.. SELL_AMOUNT=1000000000000000000
	cd resolver && node src/toxicFlowFallback.js --sellToken $(SELL_TOKEN) --buyToken $(BUY_TOKEN) --sellAmount $(SELL_AMOUNT)

## ---- cleanup ---------------------------------------------------------------

clean: ## Remove Foundry build artifacts
	forge clean

clean-all: clean ## Also remove all installed dependencies (forge libs + node_modules)
	rm -rf lib
	rm -rf resolver/node_modules
