# Synthesis organization

Large OpenRV64 configurations are synthesized at named RTL module boundaries
by default. Whole-core flattening is an optional cross-check, not the normal
resource or timing workflow: it loses ownership information, prevents useful
incremental builds, and can present one impractically large Boolean network to
the mapper.

Module-local synthesis may flatten logic *below* the selected module boundary.
Each selected module writes a source-adjacent `<source-stem>_stats.md` history.
The histories are newest-first and every build record includes:

- the module's complete effective parameter set;
- Git commit, dirty-worktree state, and an RTL-input digest;
- synthesis profile, target family, tool version, and elapsed time;
- primitive/resource counts, structural path depth, and loop diagnostics;
- an explicit statement when physical timing has not been measured.

These reports can overlap hierarchically and must not be summed until the
manifest defines a non-overlapping partition. Rotate histories manually if
they become unwieldy; the generator deliberately does not discard old builds.
