extends "res://scripts/shell/update_check.gd"
## The external transport/authority boundary is replaced only in this disposable
## boot probe. The real main caller supplies the observed eligibility facts.

func check(installed: Dictionary, _configuration: Dictionary,
		_tls_options: TLSOptions = null, _timeout_seconds: float = MAX_CHECK_SECONDS,
		_clock: Callable = Callable()) -> Dictionary:
	return {"trusted": false, "error": "disposable transport observation",
		"decision": {}, "observed_installed": installed.duplicate(true)}
