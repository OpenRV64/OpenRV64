# Target-neutral Make introspection used by run/backends/make.sh.
#
# This fragment is loaded after the top-level Makefile. Configurations select
# the exact variables and source groups to record; the runner owns hashing and
# artifact snapshots.

.PHONY: openrv64-run-record-config openrv64-run-record-sources \
	openrv64-run-record-artifacts

openrv64-run-record-config:
	$(info OPENRV64_RUN_CONFIG_V1)
	$(foreach variable,$(RUN_RECORD_VARIABLES),$(info $(variable)=$($(variable))))
	@:

openrv64-run-record-sources:
	$(info OPENRV64_RUN_INPUTS_V1)
	$(foreach variable,$(RUN_SOURCE_VARIABLES),$(foreach input,$($(variable)),$(info $(input))))
	$(foreach input,$(RUN_SOURCE_PATHS),$(info $(input)))
	@:

openrv64-run-record-artifacts:
	$(info OPENRV64_RUN_ARTIFACTS_V1)
	$(foreach variable,$(RUN_ARTIFACT_VARIABLES),$(info $(variable)=$($(variable))))
	@:
