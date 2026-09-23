class_name PoliceRole
extends RefCounted

## Roles that police cars switch between during a pursuit.  The assignment is
## re-evaluated by PoliceManager; each car steers towards the target point that
## belongs to its role instead of blindly driving at the player position.

enum Type {
	CHASE,      ## stay on the player, keep the pressure up
	INTERCEPT,  ## cut the corner / take a side street and come out ahead
	BLOCK,      ## take a position ahead of the player to close the road
	PIN,        ## push against the player and hold it in place
	SUPPORT,    ## cover an alternative escape route behind/beside
	REGROUP,    ## lost the player: return to the last known area / a road node
}

const ALL: Array[int] = [Type.CHASE, Type.INTERCEPT, Type.BLOCK, Type.PIN, Type.SUPPORT, Type.REGROUP]


static func name_of(role: int) -> String:
	match role:
		Type.CHASE: return "CHASE"
		Type.INTERCEPT: return "INTERCEPT"
		Type.BLOCK: return "BLOCK"
		Type.PIN: return "PIN"
		Type.SUPPORT: return "SUPPORT"
		Type.REGROUP: return "REGROUP"
	return "UNKNOWN"


static func color_of(role: int) -> Color:
	match role:
		Type.CHASE: return Color(1.0, 0.25, 0.2)
		Type.INTERCEPT: return Color(1.0, 0.6, 0.1)
		Type.BLOCK: return Color(0.9, 0.85, 0.2)
		Type.PIN: return Color(0.95, 0.2, 0.75)
		Type.SUPPORT: return Color(0.35, 0.6, 1.0)
		Type.REGROUP: return Color(0.6, 0.6, 0.6)
	return Color.WHITE
