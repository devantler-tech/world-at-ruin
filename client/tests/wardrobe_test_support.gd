class_name WardrobeTestSupport
extends RefCounted
## Real creator controls; test-owned expectations remain in each scene.


static func picker_with(creator: CharacterCreator, item_name: String) -> OptionButton:
	for node: Node in creator.find_children("*", "OptionButton", true, false):
		var picker := node as OptionButton
		for index in picker.item_count:
			if picker.get_item_text(index) == item_name:
				return picker
	return null


static func select_item(picker: OptionButton, item_name: String) -> bool:
	for index in picker.item_count:
		if picker.get_item_text(index) == item_name:
			picker.select(index)
			picker.item_selected.emit(index)
			return true
	return false
