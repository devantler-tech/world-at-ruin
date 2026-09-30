class_name SaveContractStage
extends RefCounted
## The trusted harness recognizes only the retained reader and its planned
## mastery activation. Advancing beyond these stages needs another reviewed
## preparation; candidate constants cannot invent a new supported contract.


static func refusal_reason() -> String:
	if UpdateManifest.SAVE_CAPABILITY_READS != 7 or SaveVault.VAULT_READ_VERSION != 5:
		return "the retained mastery reader must advertise capability 7 / vault v5"
	var writes := UpdateManifest.SAVE_CAPABILITY_WRITES
	var vault := SaveVault.VAULT_VERSION
	if not ((writes == 6 and vault == 4) or (writes == 7 and vault == 5)):
		return "unsupported save writer stage: capability %d / vault v%d" % [writes, vault]
	return ""
