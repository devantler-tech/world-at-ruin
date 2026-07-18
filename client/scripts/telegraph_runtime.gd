## Telegraph cast->resolve runtime (issue #175, Phase 2 combat epic #9).
##
## Owns the cast lifecycle for a single telegraphed zone: begin -> advance(dt)
## -> resolve, with snapshot-at-resolution semantics — the hit set is computed
## only from positions at the resolution instant, so stepping out during the
## cast is what dodging MEANS. Geometry is delegated to Telegraph (telegraph.gd),
## never reimplemented here. Presentation and consumers arrive with this child;
## damage application and AI casters are later children.
class_name TelegraphRuntime
