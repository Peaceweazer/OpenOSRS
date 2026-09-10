extends RefCounted
## One active entity instance in a simulated timeline.
##
## lineage_id  : the worldline the instance belongs to (VALE, KEY_K17, ...).
## instance_id : a specific temporal portion of that worldline.
##
## Temporal duplication never creates a new lineage: VALE:BASE and
## VALE:TR:CASE003_TRANSFER_VALE are both Inspector Vale.

var instance_id := ""
var lineage_id := ""
var entity_type := ""
var exists := false
var location := ""
var state := {}          ## field -> bool/int/String
var knowledge := {}      ## token -> Array of acquisition provenance records
var temporal := false    ## true only for instances materialized by a temporal arrival
var transfer_id := ""    ## transfer that produced this instance (temporal only)
var origin := []         ## Array of provenance records explaining existence
var removal = null       ## provenance record for departure/destruction, or null

func clone():
	var c = get_script().new()
	c.instance_id = instance_id
	c.lineage_id = lineage_id
	c.entity_type = entity_type
	c.exists = exists
	c.location = location
	c.state = state.duplicate(true)
	c.knowledge = knowledge.duplicate(true)
	c.temporal = temporal
	c.transfer_id = transfer_id
	c.origin = origin.duplicate(true)
	c.removal = null if removal == null else removal.duplicate(true)
	return c

## Causal state summary. Deliberately excludes provenance: provenance is a
## diagnostic overlay and must not influence fixed-point comparison.
func summary() -> Dictionary:
	var tokens := knowledge.keys()
	tokens.sort()
	return {
		"instance_id": instance_id,
		"lineage_id": lineage_id,
		"entity_type": entity_type,
		"exists": exists,
		"location": location,
		"state": state,
		"knowledge": tokens,
		"temporal": temporal,
	}

## The subset of an instance that survives a physical temporal transfer.
func transferable_snapshot() -> Dictionary:
	var tokens := knowledge.keys()
	tokens.sort()
	return {
		"location": location,
		"state": state.duplicate(true),
		"knowledge": tokens,
	}
