extends SceneTree
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var recipe = CharacterFactory.load_recipe(args[1]) if args[0] == "character" else CreatureFactory.load_recipe(args[1])
	print("RECIPE_NULL" if recipe == null else "RECIPE_NON_NULL")
	quit(0)
