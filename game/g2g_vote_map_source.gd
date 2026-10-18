extends DotVoteMapSource

## dot-vote's map source, carrying the pack a Workshop map came from.
##
## [DotVoteMapSource] builds a choice from the map's name alone, so a subscribed map would
## be listed on the ballot, in a nomination and in `/mapmenu` as a bare "Name" with nothing
## to say it is not this game's own. [code]DotVoteChoice.label()[/code] prints "Name [Pack]"
## once [member DotVoteChoice.pack_title] is set, and everything that lists a choice calls it.

func _to_choice(map: Object) -> DotVoteChoice:
	var choice := super._to_choice(map)
	if choice != null and map != null:
		choice.pack_title = str(map.get("pack_title"))
	return choice
