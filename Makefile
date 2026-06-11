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

# 2. Reactive chain: deploy ReactiveSteady (needs REGISTRY + DESTINATION_CHAIN_ID in .env).
#    Uses `forge create`, NOT `forge script`: ReactiveSteady's constructor calls subscribe() on the
#    Reactive system contract, which invokes a node-only precompile that Foundry's local EVM lacks.
#    `forge script` executes the constructor locally to assemble the broadcast and reverts ("Failure");
#    `forge create` runs the constructor on-chain only, where the precompile exists. The --value funds
#    the contract with REACT so its subscription registers (override with REACTIVE_FUND).
deploy-reactive:
	forge create src/reactive/ReactiveSteady.sol:ReactiveSteady \
		--rpc-url $(REACTIVE_LASNA_RPC_URL) --private-key $(PRIVATE_KEY) --broadcast \
		--value $(if $(REACTIVE_FUND),$(REACTIVE_FUND),0.05ether) \
		--constructor-args $(DESTINATION_CHAIN_ID) $(REGISTRY) \
			$(shell cast keccak "PlanDue(uint256)") $(DESTINATION_CHAIN_ID) \
			$(shell cast wallet address --private-key $(PRIVATE_KEY))

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
