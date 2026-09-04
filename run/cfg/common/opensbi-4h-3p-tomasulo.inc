# Tomasulo policy layered on the banked 3P OpenSBI/Linux backend.

source "${config_common_dir:?config_common_dir is required}/opensbi-4h-3p-banked.inc"

RUN_MAKE_ARGUMENTS+=(
    OPENSBI_4H_HELD_HARNESS=tomasulo
    OPENSBI_4H_HELD_RENAME_MODE=1
    OPENSBI_4H_COMPLETION_FORWARD_MASK=7
    OPENSBI_4H_BRANCH_COMPLETION_FORWARD_MASK=0
    OPENSBI_4H_RELAX_WAW=1
    OPENSBI_4H_ENABLE_ISSUE_WINDOW=1
    OPENSBI_4H_ENABLE_SPECULATION_WINDOW=1
)
