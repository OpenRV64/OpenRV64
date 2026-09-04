# Current large Tomasulo queue/register geometry for OpenSBI/Linux.

source "${config_common_dir:?config_common_dir is required}/opensbi-4h-3p-tomasulo.inc"

RUN_MAKE_ARGUMENTS+=(
    OPENSBI_4H_HELD_RETIRE_DEPTH=64
    OPENSBI_4H_HELD_ISSUE_WINDOW_DEPTH=32
    OPENSBI_4H_HELD_PHYS_REG_COUNT=63
)
