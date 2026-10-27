# Makes each Theme's sky for Kula: six PNGs in assets/sky/<theme>/. Run from the repository root:
#   /Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_skies.py
# Names after a "--" make only those skies, for example "-- hiro".
#
# A painted sky is a function of the view direction, sampled for each texel.
# A rendered sky is a Blender sky texture that lights an empty world. One 90 degree camera renders
# each cube face. The face layout is the one engine/sky.odin states: face px
# holds the directions nearest +x, with its top row towards +y and its left
# column towards +z.

import math
import os
import sys

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


def write_face(path, srgb):
    image = bpy.data.images.new("face", SIDE, SIDE, alpha=False)
    rgba = numpy.ones((SIDE, SIDE, 4), dtype=numpy.float32)
    # Blender's first pixel row is the bottom one.
    rgba[:, :, :3] = srgb[::-1] / 255.0
    image.pixels.foreach_set(rgba.ravel())
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)


# Each face is supersampled SUPERSAMPLE x SUPERSAMPLE times, so pyramid edges are smooth.
SUPERSAMPLE = 3


def paint_theme(name, paint):
    clear_scene()
    out = os.path.join(SKY, name)
    os.makedirs(out, exist_ok=True)
    n = SIDE * SUPERSAMPLE
    t = (2.0 * numpy.arange(n) + 1.0) / n - 1.0
    u, v = numpy.meshgrid(t, t)
    for face, direction in FACES.items():
        x, y, z = direction(u, v)
        d = numpy.stack(numpy.broadcast_arrays(x, y, z), axis=-1).astype(numpy.float64)
        d /= numpy.linalg.norm(d, axis=-1, keepdims=True)
        colour = paint(d).reshape(SIDE, SUPERSAMPLE, SIDE, SUPERSAMPLE, 3).mean(axis=(1, 3))
        write_face(os.path.join(out, face + ".png"), numpy.round(numpy.clip(colour, 0.0, 255.0)))


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
# Azimuth in degrees from -z towards +x, half width and height in degrees, and
# how far each fades into the horizon colour. The first faces the start view.
HIRO_PYRAMIDS = [
    (-38.0, 9.0, 7.0, 0.55),
    (-12.0, 10.0, 8.0, 0.45),
    (-24.0, 22.0, 17.0, 0.0),
    (-6.0, 4.0, 3.0, 0.15),
    (-46.0, 3.0, 2.2, 0.1),
    (150.0, 12.0, 9.0, 0.5),
]
HIRO_PYRAMID_LIT = (232, 166, 96)
HIRO_PYRAMID_SHADE = (184, 116, 62)
# Theme.roc's hiro sun dir, reversed: where the light comes from.
HIRO_SUN = numpy.array((2.0, 3.0, 6.0)) / 7.0
HIRO_SUN_COLOUR = numpy.array((255.0, 252.0, 238.0))


def paint_hiro(d):
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    elevation = numpy.degrees(numpy.arcsin(numpy.clip(y, -1.0, 1.0)))
    azimuth = numpy.degrees(numpy.arctan2(x, -z))
    sky = ramp(HIRO_SKY, numpy.maximum(elevation, 0.0))

    # Clouds lie on a flat layer above the ground, so they thin out and shrink towards the horizon.
    up = numpy.maximum(y, 0.05)
    cloud = fbm(x / up * 1.6, z / up * 3.2, 5)
    cover = smoothstep(0.52, 0.78, cloud) * smoothstep(6.0, 18.0, elevation) * (1.0 - smoothstep(55.0, 72.0, elevation))
    sky += (numpy.array(HIRO_CLOUD) - sky) * (0.75 * cover)[..., None]

    sun_angle = numpy.degrees(numpy.arccos(numpy.clip(d @ HIRO_SUN, -1.0, 1.0)))
    glow = 0.45 * numpy.exp(-sun_angle / 7.0) + smoothstep(2.6, 1.8, sun_angle)
    sky += (HIRO_SUN_COLOUR - sky) * numpy.clip(glow, 0.0, 1.0)[..., None]

    horizon = ramp(HIRO_SKY, numpy.zeros_like(elevation))
    for centre, half, height, fade in HIRO_PYRAMIDS:
        offset = (azimuth - centre + 180.0) % 360.0 - 180.0
        top = height * (1.0 - numpy.abs(offset) / half)
        inside = smoothstep(-0.25, 0.25, top - elevation) * smoothstep(-1.0, -0.5, elevation)
        face = numpy.where((offset > 0.0)[..., None], numpy.array(HIRO_PYRAMID_LIT, float), numpy.array(HIRO_PYRAMID_SHADE, float))
        courses = 1.0 - 0.06 * (numpy.floor(elevation / (height / 12.0)) % 2.0)
        stone = face * courses[..., None]
        stone += (horizon - stone) * fade
        sky += (stone - sky) * inside[..., None]

    # Dunes lie on the ground plane, so they shrink towards the horizon and fade into its haze.
    down = numpy.maximum(-y, 0.02)
    dune = fbm(x / down * 0.9, z / down * 0.9, 5)
    ridge = 1.0 - numpy.abs(2.0 * fbm(x / down * 0.35 + 5.0, z / down * 0.6, 3) - 1.0)
    shade = 1.0 + (0.3 * (dune - 0.5) + 0.22 * (ridge - 0.6)) * smoothstep(0.0, 0.12, -y)
    sand = ramp(HIRO_SAND, numpy.minimum(elevation, 0.0)) * shade[..., None]

    below = smoothstep(0.0, -0.6, elevation)[..., None]
    return sky + (sand - sky) * below


PAINTED = {"hiro": paint_hiro}


def chosen(argv):
    known = [theme["name"] for theme in THEMES] + list(PAINTED)
    names = argv[argv.index("--") + 1:] if "--" in argv else known
    unknown = [name for name in names if name not in known]
    if unknown:
        raise SystemExit("make_skies.py: no sky named " + ", ".join(unknown))
    return names


for name in chosen(sys.argv):
    if name in PAINTED:
        paint_theme(name, PAINTED[name])
    else:
        render_theme(next(theme for theme in THEMES if theme["name"] == name))
