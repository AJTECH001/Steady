# Steady — build, test, and deploy targets.
# Loads variables from .env (copy .env.example -> .env first).
-include .env
export

.PHONY: build test snapshot deploy-dest deploy-reactive wire-dest wire-reactive demo poke

build:
	forge build

test:
	forge test -vv

snapshot:
	forge snapshot

# --- Deployment (Steady: destination = Unichain Sepolia, reactive = Lasna) ---

# 1. Destination chain: tokens, core, hook, executor, pool, liquidity.
deploy-dest:
	forge script script/deploy/01_DeploySteady.s.sol:DeploySteady \
		--rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --broadcast -vvv

# 2. Reactive chain: deploy ReactiveSteady (set REGISTRY + DESTINATION_CHAIN_ID first).
deploy-reactive:
	forge script script/deploy/02_DeployReactive.s.sol:DeployReactive \
		--rpc-url $(REACTIVE_LASNA_RPC_URL) --broadcast -vvv

# 3. Destination chain: point the executor at ReactiveSteady (set EXECUTOR + REACTIVE_STEADY).
wire-dest:
	forge script script/deploy/03_WireUnichain.s.sol:WireUnichain \
		--rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --broadcast -vvv

# 4. Reactive chain: point ReactiveSteady at the executor.
wire-reactive:
	forge script script/deploy/04_WireReactive.s.sol:WireReactive \
		--rpc-url $(REACTIVE_LASNA_RPC_URL) --broadcast -vvv

# 5. Destination chain: create + fund a plan (logs PLAN_ID).
demo:
	forge script script/deploy/05_Demo.s.sol:Demo \
		--rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --broadcast -vvv

# 6. Destination chain: poke the due plan (set PLAN_ID) -> ReactiveSteady executes it.
poke:
	forge script script/deploy/06_Poke.s.sol:Poke \
		--rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --broadcast -vvv
