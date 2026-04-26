extends Node2D

@export var N := 16				# Amount of cells in rows and columns (size of the grid)
@export var cell_size := 32		# Size of a single cell in pixels

var size := 0

# Density means "how much material does this cell contain"
var density: PackedFloat32Array
var density_prev: PackedFloat32Array

# "u" stores the horizontal velocity (x direction)
var u: PackedFloat32Array
var u_prev: PackedFloat32Array

# "v" stores the vertical velocity (y direction)
var v: PackedFloat32Array
var v_prev: PackedFloat32Array

func _ready():
	# Resize all the arrays properly
	# We use single array to store a grid, which is why we need to multiply N
	# The "+2" is added for borders, because there are two for each dimension (x, and y)
	# For x dimension, there's a single cell border on the left and on the right, hence "+2". Same for the y direction
	size = (N + 2) * (N + 2)

	density.resize(size)
	density_prev.resize(size)
	u.resize(size)
	v.resize(size)
	u_prev.resize(size)
	v_prev.resize(size)

	queue_redraw()

# This is a helper function that makes it easier to work with a grid when it is
# packed into a single-dimension array
# We can call it with the cell index (i and j) and it will translate it into
# an index in the single-dimension array
func IX(i: int, j: int) -> int:
	return i + (N + 2) * j

# This helper function translates the position we clicked on with the mouse
# into the cell coordinates
# So if we click somewhere in the grid, it will return a Vector2i, where the
# first element is the index of the cell in that grid in x dimension
# and the other element is the index of the cell in the y dimension
func cell_from_mouse(pos: Vector2) -> Vector2i:
	return Vector2i(floor(pos.x / cell_size), floor(pos.y / cell_size))

# This is the standard Godot function for processing input
# We want to detect a mouse click and inject density into the clicked cell
# Density is represented as a float number and is stored in the "density" array
func _input(event):
	if event is InputEventMouseButton and event.pressed:
		# figure out the cell that was clicked
		var cell := cell_from_mouse(to_local(event.position))
		var i := cell.x
		var j := cell.y

		if i >= 1 and i <= N and j >= 1 and j <= N:
			density[IX(i, j)] += 1.0	# inject density into the cell
			queue_redraw()				# tell Godot to redraw the grid

# This is the standard Godot function used for drawing
# We want to draw a simple grid of (N+2)*(N+2) rectangles of size cell_size
func _draw():
	for j in range(0, N + 2):
		for i in range(0, N + 2):
			var x := i * cell_size	# this translates the index into pixel position on screen
			var y := j * cell_size
			var rect := Rect2(x, y, cell_size, cell_size)

			var is_boundary := i == 0 or j == 0 or i == N + 1 or j == N + 1
			var fill := Color(0.08, 0.08, 0.08)
			if is_boundary:
				fill = Color(0.16, 0.08, 0.08)
			else:
				# Even though density can go above 1.0, we need to clamp it to values between 0.0 and 1.0 for drawing
				var d : float = clamp(density[IX(i, j)], 0.0, 1.0)
				fill = Color(d, d, d)

			draw_rect(rect, fill, true)
			draw_rect(rect, Color(0.35, 0.35, 0.35), false)
