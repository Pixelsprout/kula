# Makes each Theme's sky for Kula: six PNGs in assets/sky/<theme>/. Run from the repository root:
#   /Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_skies.py
# Names after a "--" make only those skies, for example "-- hiro".
#
# A painted sky is a function of the view direction, sampled for each texel.
# The hiro sky also lays pyramids that Cycles renders over its paint.
# A rendered sky is a Blender sky texture that lights an empty world. One 90 degree camera renders
# each cube face. The face layout is the one engine/sky.odin states: face px
# holds the directions nearest +x, with its top row towards +y and its left
# column towards +z.

import math
import os
import random
import sys
import tempfile

import bmesh
import bpy
import numpy
from mathutils import Matrix, Vector

SKY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sky")
SIDE = 256

# u and v run from -1 at the left and top to 1 at the right and bottom.
FACES = {
    "px": lambda u, v: (1.0, -v, -u),
    "nx": lambda u, v: (-1.0, -v, u),
    "py": lambda u, v: (u, 1.0, v),
    "ny": lambda u, v: (u, -1.0, -v),
    "pz": lambda u, v: (u, -v, 1.0),
    "nz": lambda u, v: (-u, -v, -1.0),
}


# Each light is the sun's dir in Theme.roc. The painted sun sits where the
# light comes from. tint colours the sky, and ground is the linear colour below
# the horizon.
THEMES = [
    {
        "name": "haze",
        "light": (-2.0 / 7.0, -6.0 / 7.0, -3.0 / 7.0),
        "air": 1.0,
        "aerosol": 4.0,
        "ozone": 1.0,
        "tint": (0.9, 0.9, 0.95),
        "ground": (0.2, 0.2, 0.22),
    },
    {
        "name": "inca",
        "light": (3.0 / 7.0, -6.0 / 7.0, -2.0 / 7.0),
        "air": 0.4,
        "aerosol": 8.0,
        "ozone": 0.0,
        "tint": (1.0, 0.62, 0.32),
        "ground": (0.25, 0.14, 0.06),
    },
    {
        "name": "arctic",
        "light": (-3.0 / 7.0, -6.0 / 7.0, 2.0 / 7.0),
        "air": 1.0,
        "aerosol": 0.5,
        "ozone": 2.0,
        "tint": (0.85, 0.95, 1.0),
        "ground": (0.35, 0.42, 0.5),
    },
]

# Scales the sky texture's radiance into display range.
BRIGHTNESS = 0.05

# EEVEE draws no sky texture sun disc, so the world paints its own. It is
# wider than the real sun, so it reads at 256 texels a face.
SUN_RADIUS = math.radians(2.0)
SUN_EDGE = math.radians(0.5)
SUN_COLOUR = (4.0, 3.8, 3.4)


# Engine directions are +y up. Blender is +z up.
def to_blender(d):
    return Vector((d[0], -d[2], d[1]))


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def world(theme):
    w = bpy.data.worlds.new(theme["name"])
    w.use_nodes = True
    nodes = w.node_tree.nodes
    links = w.node_tree.links
    nodes.clear()

    sun = -to_blender(theme["light"]).normalized()
    sky = nodes.new("ShaderNodeTexSky")
    sky.sky_type = "MULTIPLE_SCATTERING"
    sky.sun_disc = False
    sky.sun_elevation = math.asin(sun.z)
    sky.sun_rotation = math.atan2(sun.x, sun.y)
    sky.air_density = theme["air"]
    sky.aerosol_density = theme["aerosol"]
    sky.ozone_density = theme["ozone"]

    tint = nodes.new("ShaderNodeMix")
    tint.data_type = "RGBA"
    tint.blend_type = "MULTIPLY"
    tint.inputs["Factor"].default_value = 1.0
    links.new(sky.outputs["Color"], tint.inputs["A"])
    tint.inputs["B"].default_value = (*(c * BRIGHTNESS for c in theme["tint"]), 1.0)

    coord = nodes.new("ShaderNodeTexCoord")
    view = nodes.new("ShaderNodeVectorMath")
    view.operation = "NORMALIZE"
    links.new(coord.outputs["Generated"], view.inputs[0])

    facing = nodes.new("ShaderNodeVectorMath")
    facing.operation = "DOT_PRODUCT"
    links.new(view.outputs["Vector"], facing.inputs[0])
    facing.inputs[1].default_value = sun
    disc = nodes.new("ShaderNodeMapRange")
    disc.inputs["From Min"].default_value = math.cos(SUN_RADIUS + SUN_EDGE)
    disc.inputs["From Max"].default_value = math.cos(SUN_RADIUS)
    links.new(facing.outputs["Value"], disc.inputs["Value"])
    painted = nodes.new("ShaderNodeMix")
    painted.data_type = "RGBA"
    links.new(disc.outputs["Result"], painted.inputs["Factor"])
    links.new(tint.outputs["Result"], painted.inputs["A"])
    painted.inputs["B"].default_value = (*SUN_COLOUR, 1.0)

    # Below the horizon the sky fades to the ground colour over a few degrees.
    xyz = nodes.new("ShaderNodeSeparateXYZ")
    links.new(view.outputs["Vector"], xyz.inputs["Vector"])
    below = nodes.new("ShaderNodeMapRange")
    below.inputs["From Min"].default_value = 0.0
    below.inputs["From Max"].default_value = -0.05
    links.new(xyz.outputs["Z"], below.inputs["Value"])

    ground = nodes.new("ShaderNodeMix")
    ground.data_type = "RGBA"
    links.new(below.outputs["Result"], ground.inputs["Factor"])
    links.new(painted.outputs["Result"], ground.inputs["A"])
    ground.inputs["B"].default_value = (*theme["ground"], 1.0)

    background = nodes.new("ShaderNodeBackground")
    links.new(ground.outputs["Result"], background.inputs["Color"])
    out = nodes.new("ShaderNodeOutputWorld")
    links.new(background.outputs["Background"], out.inputs["Surface"])
    return w


# A cube face is a mirror image of a camera view, so the camera's +x points
# to the face's left and mirror() flips the render. The camera looks down its
# -z with +y up.
def face_rotation(direction):
    forward = Vector(direction(0.0, 0.0))
    left = forward - Vector(direction(1.0, 0.0))
    up = forward - Vector(direction(0.0, 1.0))
    columns = [to_blender(left), to_blender(up), -to_blender(forward)]
    return Matrix([[c[i] for c in columns] for i in range(3)]).to_quaternion()


# A new image carries no render stamp, so a rerun writes the same bytes.
def mirror(path):
    render = bpy.data.images.load(path)
    pixels = numpy.array(render.pixels[:]).reshape(SIDE, SIDE, 4)
    bpy.data.images.remove(render)
    image = bpy.data.images.new("face", SIDE, SIDE, alpha=False)
    image.pixels = pixels[:, ::-1].ravel()
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)


def render_theme(theme):
    clear_scene()
    scene = bpy.context.scene
    scene.world = world(theme)
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = SIDE
    scene.render.resolution_y = SIDE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "8"
    scene.view_settings.view_transform = "Standard"

    cam_data = bpy.data.cameras.new("cube")
    cam_data.angle = math.pi / 2
    cam = bpy.data.objects.new("cube", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.rotation_mode = "QUATERNION"

    out = os.path.join(SKY, theme["name"])
    os.makedirs(out, exist_ok=True)
    for name, direction in FACES.items():
        cam.rotation_quaternion = face_rotation(direction)
        path = os.path.join(out, name + ".png")
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        mirror(path)


def write_face(path, srgb, side):
    image = bpy.data.images.new("face", side, side, alpha=False)
    rgba = numpy.ones((side, side, 4), dtype=numpy.float32)
    # Blender's first pixel row is the bottom one.
    rgba[:, :, :3] = srgb[::-1] / 255.0
    image.pixels.foreach_set(rgba.ravel())
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)


# Each face is supersampled SUPERSAMPLE x SUPERSAMPLE times, so pyramid edges are smooth.
SUPERSAMPLE = 3


def paint_theme(name, paint, side=SIDE, layers=None):
    n = side * SUPERSAMPLE
    over = layers(n) if layers else {}
    clear_scene()
    out = os.path.join(SKY, name)
    os.makedirs(out, exist_ok=True)
    t = (2.0 * numpy.arange(n) + 1.0) / n - 1.0
    u, v = numpy.meshgrid(t, t)
    for face, direction in FACES.items():
        x, y, z = direction(u, v)
        d = numpy.stack(numpy.broadcast_arrays(x, y, z), axis=-1).astype(numpy.float64)
        d /= numpy.linalg.norm(d, axis=-1, keepdims=True)
        colour = paint(d)
        if face in over:
            layer = over[face]
            alpha = layer[..., 3:]
            laid = to_srgb(to_linear(colour) * (1.0 - alpha) + layer[..., :3])
            colour = numpy.where(alpha > 0.0, laid, colour)
        colour = colour.reshape(side, SUPERSAMPLE, side, SUPERSAMPLE, 3).mean(axis=(1, 3))
        write_face(os.path.join(out, face + ".png"), numpy.round(numpy.clip(colour, 0.0, 255.0)), side)


def to_linear(srgb):
    c = srgb / 255.0
    return numpy.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(linear):
    c = numpy.clip(linear, 0.0, 1.0)
    return 255.0 * numpy.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1.0 / 2.4) - 0.055)


def smoothstep(edge0, edge1, x):
    t = numpy.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# Value noise on a plane from a fixed lattice, so a rerun paints the same sky.
LATTICE = numpy.random.default_rng(1998).random((256, 256))


def value_noise(px, py):
    ix = numpy.floor(px)
    iy = numpy.floor(py)
    fx = px - ix
    fy = py - iy
    ix = ix.astype(numpy.int64) & 255
    iy = iy.astype(numpy.int64) & 255
    sx = fx * fx * (3.0 - 2.0 * fx)
    sy = fy * fy * (3.0 - 2.0 * fy)
    a = LATTICE[iy, ix]
    b = LATTICE[iy, (ix + 1) & 255]
    c = LATTICE[(iy + 1) & 255, ix]
    e = LATTICE[(iy + 1) & 255, (ix + 1) & 255]
    return (a + (b - a) * sx) + ((c + (e - c) * sx) - (a + (b - a) * sx)) * sy


def fbm(px, py, octaves):
    total = numpy.zeros_like(px)
    amplitude = 0.5
    for k in range(octaves):
        total += amplitude * value_noise(px * 2.0**k + 17.0 * k, py * 2.0**k + 31.0 * k)
        amplitude *= 0.5
    return total / (1.0 - 0.5**octaves)


def ramp(keys, x):
    xs = [k[0] for k in keys]
    return numpy.stack([numpy.interp(x, xs, [k[1][c] for k in keys]) for c in range(3)], axis=-1)


# The Hiro sky: a white zenith, blue sky with soft clouds, pyramids on the
# horizon and orange sand below. The sRGB colours by elevation in degrees are
# the band averages of the original's Hiro skybox (HIRO.TGI). Every pixel is
# painted here; no texture of the original is used.
HIRO_SKY = [
    (0.0, (150, 178, 186)),
    (3.75, (112, 159, 173)),
    (11.25, (91, 152, 184)),
    (18.75, (78, 141, 183)),
    (26.25, (79, 134, 183)),
    (33.75, (80, 130, 183)),
    (41.25, (79, 127, 184)),
    (48.75, (83, 129, 189)),
    (56.25, (98, 142, 195)),
    (63.75, (120, 165, 206)),
    (71.25, (168, 200, 223)),
    (78.75, (228, 244, 246)),
    (86.25, (255, 255, 255)),
    (90.0, (255, 255, 255)),
]
HIRO_SAND = [
    (-90.0, (218, 131, 34)),
    (-78.75, (216, 130, 32)),
    (-71.25, (212, 127, 30)),
    (-63.75, (210, 125, 30)),
    (-56.25, (212, 126, 31)),
    (-48.75, (206, 121, 26)),
    (-41.25, (190, 110, 22)),
    (-33.75, (183, 103, 17)),
    (-26.25, (189, 108, 25)),
    (-18.75, (201, 121, 37)),
    (-11.25, (204, 129, 53)),
    (-3.0, (214, 150, 88)),
    (0.0, (222, 172, 118)),
]
HIRO_CLOUD = (238, 244, 248)
# Theme.roc's hiro sun dir, reversed: where the light comes from.
HIRO_SUN = numpy.array((2.0, 3.0, 6.0)) / 7.0
HIRO_SUN_COLOUR = numpy.array((255.0, 252.0, 238.0))


def paint_hiro(d):
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    elevation = numpy.degrees(numpy.arcsin(numpy.clip(y, -1.0, 1.0)))
    sky = ramp(HIRO_SKY, numpy.maximum(elevation, 0.0))

    # Clouds lie on a flat layer above the ground, so they thin out and shrink towards the horizon.
    up = numpy.maximum(y, 0.05)
    cloud = fbm(x / up * 1.6, z / up * 3.2, 5)
    cover = smoothstep(0.52, 0.78, cloud) * smoothstep(6.0, 18.0, elevation) * (1.0 - smoothstep(55.0, 72.0, elevation))
    sky += (numpy.array(HIRO_CLOUD) - sky) * (0.75 * cover)[..., None]

    sun_angle = numpy.degrees(numpy.arccos(numpy.clip(d @ HIRO_SUN, -1.0, 1.0)))
    glow = 0.45 * numpy.exp(-sun_angle / 7.0) + smoothstep(2.6, 1.8, sun_angle)
    sky += (HIRO_SUN_COLOUR - sky) * numpy.clip(glow, 0.0, 1.0)[..., None]

    # Dunes lie on the ground plane, so they shrink towards the horizon and fade into its haze.
    down = numpy.maximum(-y, 0.02)
    dune = fbm(x / down * 0.9, z / down * 0.9, 5)
    ridge = 1.0 - numpy.abs(2.0 * fbm(x / down * 0.35 + 5.0, z / down * 0.6, 3) - 1.0)
    shade = 1.0 + (0.3 * (dune - 0.5) + 0.22 * (ridge - 0.6)) * smoothstep(0.0, 0.12, -y)
    sand = ramp(HIRO_SAND, numpy.minimum(elevation, 0.0)) * shade[..., None]

    below = smoothstep(0.0, -0.6, elevation)[..., None]
    return sky + (sand - sky) * below


# The Hiro pyramids are real geometry that Cycles renders over the painted sky,
# lit by the hiro Theme sun. Units are metres. Each row is the azimuth in
# degrees from -z towards +x, the distance to the centre, the base width, the
# height and the share of the height at the top that keeps its smooth casing.
# The first three are the large Giza-like group in front of the start view, and
# the last is the lone pyramid behind it. Each base faces the axes, as the
# blocks do, so its sides take the same light as the block faces.
HIRO_PYRAMIDS = [
    (-27.0, 470.0, 230.0, 146.0, 0.0),
    (-7.0, 820.0, 215.0, 143.0, 0.18),
    (-47.0, 640.0, 105.0, 66.0, 0.0),
    (-55.0, 590.0, 34.0, 22.0, 0.0),
    (-59.0, 600.0, 30.0, 19.0, 0.0),
    (-62.0, 610.0, 28.0, 17.0, 0.0),
    (6.0, 560.0, 40.0, 26.0, 0.0),
    (148.0, 500.0, 125.0, 80.0, 0.0),
]
# Each base centre sits this many degrees below the horizon, where the painted
# sky has turned into sand.
HIRO_BASE_DIP = 1.0
# The lowest metres of each pyramid fade out, so its base melts into the sand.
HIRO_GROUND_MIST = 6.0
# Over this distance half of a pyramid's colour turns to the haze colour.
HIRO_HAZE_HALF = 900.0
HIRO_HAZE = (184, 172, 156)
# Theme.roc's hiro sun. Cycles divides diffuse light by pi, as the engine does.
HIRO_SUN_LIGHT = (1.7 * 140.0 / 128.0, 1.7 * 128.0 / 128.0, 1.7 * 102.0 / 128.0)
# The Theme's fill and ambient light the block faces that turn away from the sun.
# Cycles traces the light off the sand instead, so the pyramids take no fill and
# half of the ambient.
HIRO_AMBIENT = (0.39 * 128.0 / 128.0, 0.39 * 128.0 / 128.0, 0.39 * 140.0 / 128.0)
HIRO_SAND_ALBEDO = (0.66, 0.32, 0.08)
# A fixed seed and sample count, so a rerun renders the same pixels on the same
# machine and Blender version.
PYRAMID_SEED = 1998
PYRAMID_SAMPLES = 32
PYRAMID_TEXTURE_SIZE = 256
PYRAMID_COURSES = 32
PYRAMID_STONES = 16
PYRAMID_STONE = (0.4, 0.2, 0.065)
PYRAMID_CASING = (0.46, 0.26, 0.1)
PYRAMID_ROUGHNESS = 0.9
HIRO_SIDE = 512


def linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


# Each course is a row of stones with a dark joint below it. Each course's
# joints sit half a stone along from the course below.
def pyramid_image():
    size = PYRAMID_TEXTURE_SIZE
    rng = random.Random("pyramid")
    course_height = size // PYRAMID_COURSES
    stone_width = size // PYRAMID_STONES
    shades = [[rng.uniform(0.92, 1.04) for _ in range(PYRAMID_STONES)] for _ in range(PYRAMID_COURSES)]
    image = bpy.data.images.new("pyramid", size, size, alpha=False)
    pixels = []
    for y in range(size):
        course = y // course_height
        offset = stone_width // 2 if course % 2 else 0
        for x in range(size):
            stone = ((x + offset) % size) // stone_width
            joint = y % course_height == 0 or (x + offset) % stone_width == 0
            shade = 0.86 if joint else shades[course][stone]
            noise = 1.0 + rng.uniform(-0.04, 0.04)
            pixels.extend([linear_to_srgb(c * shade * noise) for c in PYRAMID_STONE] + [1.0])
    image.pixels = pixels
    image.pack()
    return image


# Four sloped sides with a 1 x 1 base on the origin and the apex 1 above, flat
# shaded, so the sun lights each side on its own. A side's v runs from its base
# to the apex.
def pyramid_mesh(material):
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    base = [bm.verts.new(corner) for corner in [(-0.5, -0.5, 0.0), (0.5, -0.5, 0.0), (0.5, 0.5, 0.0), (-0.5, 0.5, 0.0)]]
    apex = bm.verts.new((0.0, 0.0, 1.0))
    for i in range(4):
        side = bm.faces.new((base[i], base[(i + 1) % 4], apex))
        for loop, uv in zip(side.loops, [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]):
            loop[uv_layer].uv = uv
    bm.faces.new(list(reversed(base)))
    for f in bm.faces:
        f.smooth = False
    mesh = bpy.data.meshes.new("pyramid")
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(material)
    return mesh


# Sandstone courses, a smooth casing over the top "cap" share of the height,
# haze that grows with distance, and a fade over the bottom "mist" share.
def pyramid_material():
    mat = bpy.data.materials.new("pyramid")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = PYRAMID_ROUGHNESS
    out = nodes["Material Output"]

    tex = nodes.new("ShaderNodeTexImage")
    tex.image = pyramid_image()
    tex.interpolation = "Linear"
    coord = nodes.new("ShaderNodeTexCoord")
    height = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord.outputs["Object"], height.inputs["Vector"])
    cap = nodes.new("ShaderNodeAttribute")
    cap.attribute_type = "OBJECT"
    cap.attribute_name = "cap"
    start = nodes.new("ShaderNodeMath")
    start.operation = "SUBTRACT"
    start.inputs[0].default_value = 1.0
    links.new(cap.outputs["Fac"], start.inputs[1])
    casing = nodes.new("ShaderNodeMath")
    casing.operation = "GREATER_THAN"
    links.new(height.outputs["Z"], casing.inputs[0])
    links.new(start.outputs["Value"], casing.inputs[1])
    stone = nodes.new("ShaderNodeMix")
    stone.data_type = "RGBA"
    links.new(casing.outputs["Value"], stone.inputs["Factor"])
    links.new(tex.outputs["Color"], stone.inputs["A"])
    stone.inputs["B"].default_value = (*PYRAMID_CASING, 1.0)
    links.new(stone.outputs["Result"], bsdf.inputs["Base Color"])

    camera = nodes.new("ShaderNodeCameraData")
    haze = nodes.new("ShaderNodeMath")
    haze.operation = "MULTIPLY"
    haze.inputs[1].default_value = -math.log(2.0) / HIRO_HAZE_HALF
    links.new(camera.outputs["View Distance"], haze.inputs[0])
    clear = nodes.new("ShaderNodeMath")
    clear.operation = "EXPONENT"
    links.new(haze.outputs["Value"], clear.inputs[0])
    air = nodes.new("ShaderNodeEmission")
    air.inputs["Color"].default_value = (*to_linear(numpy.array(HIRO_HAZE, float)), 1.0)
    hazed = nodes.new("ShaderNodeMixShader")
    links.new(clear.outputs["Value"], hazed.inputs["Fac"])
    links.new(air.outputs["Emission"], hazed.inputs[1])
    links.new(bsdf.outputs["BSDF"], hazed.inputs[2])

    mist_top = nodes.new("ShaderNodeAttribute")
    mist_top.attribute_type = "OBJECT"
    mist_top.attribute_name = "mist"
    mist = nodes.new("ShaderNodeMapRange")
    mist.interpolation_type = "SMOOTHSTEP"
    mist.inputs["From Min"].default_value = 0.0
    links.new(mist_top.outputs["Fac"], mist.inputs["From Max"])
    links.new(height.outputs["Z"], mist.inputs["Value"])
    clear_air = nodes.new("ShaderNodeBsdfTransparent")
    faded = nodes.new("ShaderNodeMixShader")
    links.new(mist.outputs["Result"], faded.inputs["Fac"])
    links.new(clear_air.outputs["BSDF"], faded.inputs[1])
    links.new(hazed.outputs["Shader"], faded.inputs[2])
    links.new(faded.outputs["Shader"], out.inputs["Surface"])
    return mat


def sun_lamp(name, direction, colour):
    strength = max(colour)
    light = bpy.data.lights.new(name, "SUN")
    light.energy = strength * math.pi
    light.color = tuple(c / strength for c in colour)
    light.angle = math.radians(0.53)
    lamp = bpy.data.objects.new(name, light)
    lamp.rotation_mode = "QUATERNION"
    lamp.rotation_quaternion = to_blender(direction).normalized().to_track_quat("-Z", "Y")
    bpy.context.scene.collection.objects.link(lamp)


# Renders the pyramids alone on a clear film for each side face, n texels
# square, in paint_theme's layout: linear colour with premultiplied alpha.
def hiro_pyramids(n):
    clear_scene()
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = PYRAMID_SAMPLES
    scene.cycles.seed = PYRAMID_SEED
    scene.cycles.use_animated_seed = False
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.render.film_transparent = True
    scene.render.resolution_x = n
    scene.render.resolution_y = n
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "32"

    sky = bpy.data.worlds.new("hiro")
    sky.use_nodes = True
    sky.node_tree.nodes["Background"].inputs["Color"].default_value = (*HIRO_AMBIENT, 1.0)
    scene.world = sky
    sun_lamp("sun", tuple(-HIRO_SUN), HIRO_SUN_LIGHT)

    # The sand bounces warm light onto the shaded sides. The camera does not see it.
    sand = bpy.data.materials.new("sand")
    sand.use_nodes = True
    sand.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*HIRO_SAND_ALBEDO, 1.0)
    lowest = max(distance for _, distance, _, _, _ in HIRO_PYRAMIDS) * math.tan(math.radians(HIRO_BASE_DIP))
    bpy.ops.mesh.primitive_plane_add(size=20000.0, location=(0.0, 0.0, -lowest))
    ground = bpy.context.object
    ground.data.materials.append(sand)
    ground.visible_camera = False

    mesh = pyramid_mesh(pyramid_material())
    for i, (azimuth, distance, base, height, cap) in enumerate(HIRO_PYRAMIDS):
        a = math.radians(azimuth)
        pyramid = bpy.data.objects.new("pyramid%d" % i, mesh)
        dip = distance * math.tan(math.radians(HIRO_BASE_DIP))
        pyramid.location = to_blender((distance * math.sin(a), -dip, -distance * math.cos(a)))
        pyramid.scale = (base, base, height)
        pyramid["cap"] = cap
        pyramid["mist"] = HIRO_GROUND_MIST / height
        scene.collection.objects.link(pyramid)

    cam_data = bpy.data.cameras.new("cube")
    cam_data.angle = math.pi / 2
    cam_data.clip_end = 20000.0
    cam = bpy.data.objects.new("cube", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.rotation_mode = "QUATERNION"

    layers = {}
    with tempfile.TemporaryDirectory() as folder:
        for face in ["px", "nx", "pz", "nz"]:
            cam.rotation_quaternion = face_rotation(FACES[face])
            scene.render.filepath = os.path.join(folder, face + ".exr")
            bpy.ops.render.render(write_still=True)
            render = bpy.data.images.load(scene.render.filepath)
            pixels = numpy.empty(n * n * 4, dtype=numpy.float32)
            render.pixels.foreach_get(pixels)
            bpy.data.images.remove(render)
            # Blender's first row is the bottom one, and a face mirrors the camera view.
            layers[face] = pixels.reshape(n, n, 4)[::-1, ::-1]
    return layers


# Each painted sky is its paint function, its face side and an optional layer to lay over it.
PAINTED = {"hiro": (paint_hiro, HIRO_SIDE, hiro_pyramids)}


def chosen(argv):
    known = [theme["name"] for theme in THEMES] + list(PAINTED)
    names = argv[argv.index("--") + 1:] if "--" in argv else known
    unknown = [name for name in names if name not in known]
    if unknown:
        raise SystemExit("make_skies.py: no sky named " + ", ".join(unknown))
    return names


for name in chosen(sys.argv):
    if name in PAINTED:
        paint_theme(name, *PAINTED[name])
    else:
        render_theme(next(theme for theme in THEMES if theme["name"] == name))
