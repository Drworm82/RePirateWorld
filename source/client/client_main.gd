extends Node

func _ready() -> void:
	print("[CLIENT] ClientMain _ready. GameMode=", GameMode.mode(), " is_client=", GameMode.is_client())
	if not tree_exiting.is_connected(_on_tree_exiting):
		tree_exiting.connect(_on_tree_exiting)
	multiplayer.multiplayer_peer = null

func _on_tree_exiting() -> void:
	print("[CLIENT] ClientMain is exiting the scene tree.")
