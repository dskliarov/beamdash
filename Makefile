deps:
	@mix setup

run: deps
	@mix phx.server

.PHONY: deps run
