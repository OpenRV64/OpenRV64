# OpenRV64 build entry point.
#
# Keep module order explicit: configuration and source manifests must be parsed
# before targets and build recipes that consume them.

OPENRV64_MAKEFILES := Makefile $(wildcard scripts/make/*.mk)

include scripts/make/config.mk
include scripts/make/artifacts.mk
include scripts/make/sources.mk
include scripts/make/targets.mk
include scripts/make/compliance.mk
include scripts/make/software.mk
include scripts/make/opensbi.mk
include scripts/make/soc-tests.mk
include scripts/make/core-tests.mk
include scripts/make/performance.mk
include scripts/make/synthesis.mk
include scripts/make/software-builds.mk
include scripts/make/platform-builds.mk
include scripts/make/core-builds.mk
include scripts/make/backend-builds.mk
include scripts/make/compliance-builds.mk
include scripts/make/prefetch-config.mk
include scripts/make/prefetch-runner.mk
include scripts/make/stream.mk
include scripts/make/stride.mk
include scripts/make/icache.mk
include scripts/make/lz4.mk
include scripts/make/prefetch-suite.mk
include scripts/make/prefetch-builds.mk
include scripts/make/clean.mk
