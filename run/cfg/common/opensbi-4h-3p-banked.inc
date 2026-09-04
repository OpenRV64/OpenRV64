# Banked 3P backend building block for the OpenSBI/Linux platform harness.
# This fragment deliberately selects only the register-file implementation;
# scheduling, renaming, forwarding, and queue geometry belong to later layers.

RUN_MAKE_ARGUMENTS+=(
    OPENSBI_4H_BANKED_GPR=1
)
