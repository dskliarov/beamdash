deps:
	@mix setup

run: deps
	@mix phx.server

# make nx-train NX_ARGS="--per-class 200 --iterations 300 --seed 3"
NX_ARGS ?=

nx-train:
	@mix beamdash.nx_train $(NX_ARGS)

.PHONY: deps run nx-train
