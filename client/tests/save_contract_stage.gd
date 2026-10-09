class_name SaveContractStage
extends RefCounted
## Reviewed retained mastery stages and the one planned stature reader.
## Reader preparation never authorizes capability8 writes or recipe5 origination.


static func refusal_reason() -> String:
	return stage_refusal(
		UpdateManifest.SAVE_CAPABILITY_READS, SaveVault.VAULT_READ_VERSION,
		UpdateManifest.SAVE_CAPABILITY_WRITES, SaveVault.VAULT_VERSION,
		CharacterFactory.RECIPE_VERSION, CharacterFactory.RECIPE_WRITE_VERSION)


static func stage_refusal(
		reads: int, vault_reads: int, writes: int, vault_writes: int,
		recipe_reads: int, recipe_writes: int) -> String:
	if vault_reads != 5 or recipe_writes != 4:
		return "unsupported vault reader or recipe writer stage"
	if reads == 7 and recipe_reads == 4:
		if (writes == 6 and vault_writes == 4) or (writes == 7 and vault_writes == 5):
			return ""
	elif reads == 8 and recipe_reads == 5 and writes == 7 and vault_writes == 5:
		return ""
	return "unsupported save reader/writer stage"
