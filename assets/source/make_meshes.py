# Builds each Theme's <theme>_face.glb, ball.glb and the item meshes for Kula.
# Run from the repository root:
#   /Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_meshes.py
# Names after a "--" build only those meshes, for example "-- coin".
#
# Blender is +Z up. The glTF export turns that into +Y up, so a quad facing
# Blender +Z faces glTF +Y, like the engine's primitive plane.

import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix

MESHES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "meshes")

# Kula draws faces with a white tint, so each texture carries its Theme's
# colour. The exit's red tint multiplies it.
FACE_TEXTURE_SIZE = 64

# Low enough that the sun leaves a soft highlight on the ball.
BALL_ROUGHNESS = 0.4
BALL_WHITE = (0.9, 0.9, 0.9, 1.0)
BALL_RED = (0.8, 0.05, 0.03, 1.0)
BALL_SEGMENTS = 32
BALL_RINGS = 16
BALL_WEDGES = 8

# The original's coin model is GGI data, so the shape and colour are Kula's
# own. The coin is 0.4 cell wide.
COIN_SEGMENTS = 48
COIN_BRONZE = (0.7, 0.38, 0.14, 1.0)
COIN_ROUGHNESS = 0.4
# The engine has no environment map, so a full metal draws its flat face
# almost black. A part metal keeps the face bronze.
COIN_METALLIC = 0.4
# (radius, height above the middle plane) from the centre of one face out to
# the middle of the edge: the flat field, the raised rim and the bevel. The
# other face mirrors it.
COIN_PROFILE = [
    (0.0, 0.016),
    (0.15, 0.016),
    (0.158, 0.028),
    (0.18, 0.028),
    (0.2, 0.012),
]


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, colour, roughness=0.5, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.use_backface_culling = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = colour
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


# The export writes the image as a PNG in the .glb. Linear interpolation
# exports as a mipmapped minification filter.
def texture_material(name, image):
    mat = material(name, (1.0, 1.0, 1.0, 1.0))
    nodes = mat.node_tree.nodes
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Linear"
    mat.node_tree.links.new(tex.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    return mat


def linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def scaled(colour, s):
    return tuple(c * s for c in colour)


# Each pattern takes the texel's distance from the nearest edge, its offset
# from the centre and a noise value near 1, and gives a linear colour.
def haze_texel(edge, dx, dy, noise):
    if edge < 4:
        return scaled((0.6, 0.63, 0.7), noise)
    return scaled((0.42, 0.45, 0.52), noise)


# A groove, a raised rim and a stepped diamond, like carved sandstone.
def inca_texel(edge, dx, dy, noise):
    if edge < 3:
        return scaled((0.3, 0.18, 0.08), noise)
    if edge < 6:
        return scaled((0.68, 0.47, 0.24), noise)
    step = int((abs(dx) + abs(dy)) / 5)
    shade = 0.55 if step % 2 == 0 else 0.47
    return scaled((shade, shade * 0.66, shade * 0.31), noise)


# Bright bevelled edges and faint diagonal frost lines.
def arctic_texel(edge, dx, dy, noise):
    if edge < 3:
        return scaled((0.9, 0.95, 1.0), noise)
    if int(dx + dy) % 16 == 0:
        return scaled((0.75, 0.86, 0.96), noise)
    return scaled((0.62, 0.75, 0.88), noise)


# Pack name, texel pattern and noise strength. The names match Theme.roc.
THEMES = [
    ("haze", haze_texel, 0.04),
    ("inca", inca_texel, 0.06),
    ("arctic", arctic_texel, 0.03),
]


# Blender stores byte image pixels as sRGB, so the linear colours convert here.
# A fixed seed keeps the committed files stable.
def face_image(name, texel, noise_amount):
    size = FACE_TEXTURE_SIZE
    rng = random.Random(name)
    image = bpy.data.images.new(name + "_face", size, size, alpha=False)
    pixels = []
    centre = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            edge = min(x, y, size - 1 - x, size - 1 - y)
            noise = 1.0 + rng.uniform(-noise_amount, noise_amount)
            colour = texel(edge, x - centre, y - centre, noise)
            pixels.extend([linear_to_srgb(c) for c in colour] + [1.0])
    image.pixels = pixels
    image.file_format = "PNG"
    return image


def new_object(name, mesh):
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def export(obj, file_name):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(MESHES, file_name),
        export_format="GLB",
        use_selection=True,
        export_texcoords=True,
        export_image_format="AUTO",
        export_animations=False,
    )


# A 1 x 1 quad centred on the origin that winds counter-clockwise seen from
# +Z. Its uvs span the whole texture.
def make_face(name, texel, noise_amount):
    clear_scene()
    half = 0.5
    verts = [(-half, -half, 0.0), (half, -half, 0.0), (half, half, 0.0), (-half, half, 0.0)]
    mesh = bpy.data.meshes.new("face")
    mesh.from_pydata(verts, [], [(0, 1, 2, 3)])
    uvs = mesh.uv_layers.new(name="UVMap")
    for loop in mesh.loops:
        x, y, _ = verts[loop.vertex_index]
        uvs.data[loop.index].uv = (x + half, y + half)
    mesh.materials.append(texture_material(name + "_face", face_image(name, texel, noise_amount)))
    mesh.update()
    export(new_object(name + "_face", mesh), name + "_face.glb")


# A UV sphere of diameter 1, like the primitive sphere. The wedges run pole to
# pole, so a roll about any horizontal axis shows.
def make_ball():
    clear_scene()
    mesh = bpy.data.meshes.new("ball")
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=BALL_SEGMENTS, v_segments=BALL_RINGS, radius=0.5)
    for f in bm.faces:
        c = f.calc_center_median()
        angle = math.atan2(c.y, c.x) % (2.0 * math.pi)
        f.material_index = int(angle / (2.0 * math.pi) * BALL_WEDGES) % 2
        f.smooth = True
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(material("ball_white", BALL_WHITE, BALL_ROUGHNESS))
    mesh.materials.append(material("ball_red", BALL_RED, BALL_ROUGHNESS))
    export(new_object("ball", mesh), "ball.glb")


# A disc on its edge, so the spin about the face normal shows its face and
# then its edge. Its axis is Blender Y, so glTF +Y runs up the face. The
# profile's corners stay sharp.
def make_coin():
    clear_scene()
    profile = COIN_PROFILE + [(r, -h) for r, h in reversed(COIN_PROFILE)]
    bm = bmesh.new()
    rings = []
    for r, h in profile:
        if r == 0.0:
            rings.append([bm.verts.new((0.0, h, 0.0))])
            continue
        angles = [2.0 * math.pi * i / COIN_SEGMENTS for i in range(COIN_SEGMENTS)]
        rings.append([bm.verts.new((r * math.cos(a), h, r * math.sin(a))) for a in angles])
    for a, b in zip(rings, rings[1:]):
        for i in range(COIN_SEGMENTS):
            j = (i + 1) % COIN_SEGMENTS
            if len(a) == 1:
                bm.faces.new((a[0], b[i], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[i], b[0], a[j]))
            else:
                bm.faces.new((a[i], b[i], b[j], a[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        e.smooth = e.calc_face_angle(0.0) < math.radians(30.0)
    mesh = bpy.data.meshes.new("coin")
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(material("coin_bronze", COIN_BRONZE, COIN_ROUGHNESS, COIN_METALLIC))
    export(new_object("coin", mesh), "coin.glb")


# The original's fruit models are GGI data, so the shapes and colours are
# Kula's own. Each mesh's origin is the item centre, 0.25 cell above the
# face. The bob drops it to 0.23 cell and the tilt leans it 13 degrees, so
# each fruit reaches at most 0.21 cell below its origin.
FRUIT_TEXTURE_SIZE = 128
FRUIT_ROUGHNESS = 0.45
# The engine draws one base colour texture for each mesh. The body takes
# the texture's left part, u from 0 to FRUIT_BODY_U. Each small part takes a
# solid patch on the right, at its FRUIT_PART_UV.
FRUIT_BODY_U = 0.75
FRUIT_PART_UV = {"stem": (0.875, 0.25), "leaf": (0.875, 0.75)}

# (radius, height) from the bottom pole to the top pole. Smooth curves run
# through these points.
APPLE_PROFILE = [
    (0.0, -0.14),
    (0.04, -0.15),
    (0.09, -0.16),
    (0.14, -0.142),
    (0.175, -0.095),
    (0.195, -0.025),
    (0.198, 0.04),
    (0.185, 0.1),
    (0.15, 0.145),
    (0.1, 0.166),
    (0.055, 0.16),
    (0.02, 0.13),
    (0.0, 0.115),
]
PUMPKIN_PROFILE = [
    (0.0, -0.11),
    (0.08, -0.13),
    (0.16, -0.115),
    (0.205, -0.06),
    (0.22, 0.0),
    (0.205, 0.065),
    (0.16, 0.115),
    (0.09, 0.135),
    (0.04, 0.12),
    (0.0, 0.1),
]
PUMPKIN_RIBS = 8
# A groove takes this share off the radius.
PUMPKIN_GROOVE = 0.08
# The watermelon lies along glTF z, so the tilt rocks its ends.
WATERMELON_LENGTH = 0.48
WATERMELON_RADIUS = 0.16
WATERMELON_STRIPES = 9


def catmull_rom(points, steps):
    out = []
    padded = [points[0]] + points + [points[-1]]
    for i in range(1, len(padded) - 2):
        p0, p1, p2, p3 = padded[i - 1:i + 3]
        for s in range(steps):
            t = s / steps
            out.append(tuple(
                0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t ** 3)
                for a, b, c, d in zip(p0, p1, p2, p3)
            ))
    out.append(points[-1])
    return out


def set_uvs(face, uv_layer, uvs):
    for loop, uv in zip(face.loops, uvs):
        loop[uv_layer].uv = uv


# A surface of revolution about Blender Z. The profile runs from a pole at
# the bottom to a pole at the top. scale(angle) multiplies the radius. Each
# face maps u to the angle and v to its place along the profile.
def lathe(bm, uv_layer, profile, segments, scale=lambda angle: 1.0):
    margin = 1.0 / FRUIT_TEXTURE_SIZE
    angles = [2.0 * math.pi * i / segments for i in range(segments)]
    rings = []
    for r, z in profile:
        if r <= 0.0:
            rings.append([bm.verts.new((0.0, 0.0, z))])
        else:
            rings.append([bm.verts.new((r * scale(a) * math.cos(a), r * scale(a) * math.sin(a), z)) for a in angles])

    def uv(i, k):
        return (margin + (FRUIT_BODY_U - 2.0 * margin) * i / segments, k / (len(rings) - 1))

    faces = []
    for k in range(len(rings) - 1):
        a, b = rings[k], rings[k + 1]
        for i in range(segments):
            j = (i + 1) % segments
            if len(a) == 1:
                f = bm.faces.new((a[0], b[j], b[i]))
                set_uvs(f, uv_layer, [uv(i + 0.5, k), uv(i + 1, k + 1), uv(i, k + 1)])
            elif len(b) == 1:
                f = bm.faces.new((a[i], a[j], b[0]))
                set_uvs(f, uv_layer, [uv(i, k), uv(i + 1, k), uv(i + 0.5, k + 1)])
            else:
                f = bm.faces.new((a[i], a[j], b[j], b[i]))
                set_uvs(f, uv_layer, [uv(i, k), uv(i + 1, k), uv(i + 1, k + 1), uv(i, k + 1)])
            faces.append(f)
    return faces


# A closed tube through path, mostly upward, with rings of the given radii.
def tube(bm, uv_layer, path, radii, sides):
    rings = []
    for (x, y, z), r in zip(path, radii):
        rings.append([bm.verts.new((x + r * math.cos(2.0 * math.pi * i / sides), y + r * math.sin(2.0 * math.pi * i / sides), z)) for i in range(sides)])
    faces = [bm.faces.new(list(reversed(rings[0]))), bm.faces.new(rings[-1])]
    for a, b in zip(rings, rings[1:]):
        for i in range(sides):
            j = (i + 1) % sides
            faces.append(bm.faces.new((a[i], a[j], b[j], b[i])))
    for f in faces:
        set_uvs(f, uv_layer, [FRUIT_PART_UV["stem"]] * len(f.loops))
    return faces


# A flat leaf: a lathe along its length, squashed to (length, width,
# thickness) with one end at the origin, turned up by lift, then turned to
# heading and moved to at. bmesh's own sphere does not rebuild byte for byte.
def leaf(bm, uv_layer, size, lift, heading, at):
    profile = [(math.sin(math.pi * k / 6), -math.cos(math.pi * k / 6)) for k in range(7)]
    faces = lathe(bm, uv_layer, profile, 10)
    verts = list({v for f in faces for v in f.verts})
    m = (Matrix.Translation(at) @ Matrix.Rotation(heading, 4, "Z") @ Matrix.Rotation(-lift, 4, "Y")
         @ Matrix.Translation((size[0], 0.0, 0.0)) @ Matrix.Diagonal((size[0], size[1], size[2], 1.0))
         @ Matrix.Rotation(math.pi / 2.0, 4, "Y"))
    bmesh.ops.transform(bm, matrix=m, verts=verts)
    for f in faces:
        set_uvs(f, uv_layer, [FRUIT_PART_UV["leaf"]] * len(f.loops))
        f.smooth = True
    return faces


# body(u, v) gives the body's linear colour at angle u and profile place v,
# each 0 to 1. A fixed seed keeps the committed files stable.
def fruit_image(name, body, parts):
    size = FRUIT_TEXTURE_SIZE
    rng = random.Random(name)
    image = bpy.data.images.new(name, size, size, alpha=False)
    pixels = []
    for y in range(size):
        for x in range(size):
            u = (x + 0.5) / size
            v = (y + 0.5) / size
            if u < FRUIT_BODY_U:
                colour = body(u / FRUIT_BODY_U, v)
            else:
                colour = parts["stem"] if v < 0.5 else parts["leaf"]
            noise = 1.0 + rng.uniform(-0.03, 0.03)
            pixels.extend([linear_to_srgb(c * noise) for c in colour] + [1.0])
    image.pixels = pixels
    image.file_format = "PNG"
    return image


def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def fruit_bmesh():
    bm = bmesh.new()
    return bm, bm.loops.layers.uv.new("UVMap")


def finish_fruit(name, bm, body_faces, body, parts):
    for f in body_faces:
        f.smooth = True
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for e in bm.edges:
        e.smooth = e.calc_face_angle(0.0) < math.radians(40.0)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    mat = texture_material(name, fruit_image(name, body, parts))
    mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = FRUIT_ROUGHNESS
    mesh.materials.append(mat)
    export(new_object(name, mesh), name + ".glb")


# A red apple, yellow-green round the stem, with faint streaks, a stem and a leaf.
def make_apple():
    clear_scene()
    bm, uv_layer = fruit_bmesh()
    body_faces = lathe(bm, uv_layer, catmull_rom(APPLE_PROFILE, 4), 40)
    tube(bm, uv_layer, [(0.0, 0.0, 0.1), (0.004, 0.0, 0.17), (0.016, 0.0, 0.215)], [0.013, 0.011, 0.009], 6)
    leaf(bm, uv_layer, (0.06, 0.028, 0.006), math.radians(30.0), math.radians(200.0), (0.004, 0.0, 0.165))

    def body(u, v):
        streak = 0.93 + 0.07 * math.sin(2.0 * math.pi * (17.0 * u + 0.4 * math.sin(2.0 * math.pi * 3.0 * u)))
        red = scaled((0.5, 0.015, 0.02), streak * (0.75 + 0.25 * min(1.0, v * 3.0)))
        blush = mix(red, (0.6, 0.2, 0.02), 0.35 * max(0.0, math.cos(2.0 * math.pi * u)) * (1.0 - abs(v - 0.55) * 2.0))
        return mix(blush, (0.45, 0.42, 0.06), (v - 0.86) / 0.12)

    finish_fruit("apple", bm, body_faces, body, {"stem": (0.12, 0.06, 0.02), "leaf": (0.1, 0.35, 0.04)})


# A long watermelon with wavy dark green stripes on light green.
def make_watermelon():
    clear_scene()
    bm, uv_layer = fruit_bmesh()
    half = WATERMELON_LENGTH / 2.0
    profile = []
    for k in range(25):
        z = -half + WATERMELON_LENGTH * k / 24
        r = WATERMELON_RADIUS * max(0.0, 1.0 - abs(z / half) ** 2.4) ** (1.0 / 2.4)
        profile.append((r, z))
    body_faces = lathe(bm, uv_layer, profile, 40)
    tube(bm, uv_layer, [(0.0, 0.0, half - 0.01), (0.0, 0.0, half + 0.015)], [0.01, 0.008], 6)
    bmesh.ops.rotate(bm, verts=bm.verts, matrix=Matrix.Rotation(math.pi / 2.0, 3, "X"))

    def body(u, v):
        wave = 0.08 * math.sin(2.0 * math.pi * 4.0 * v) + 0.05 * math.sin(2.0 * math.pi * 9.0 * v + u * 7.0)
        stripe = math.sin(2.0 * math.pi * (WATERMELON_STRIPES * u + wave))
        return mix((0.16, 0.36, 0.07), (0.01, 0.08, 0.01), (stripe + 0.15) / 0.3)

    finish_fruit("watermelon", bm, body_faces, body, {"stem": (0.12, 0.1, 0.03), "leaf": (0.1, 0.35, 0.04)})


# A squat orange pumpkin with deep ribs and a thick green-brown stem.
def make_pumpkin():
    clear_scene()
    bm, uv_layer = fruit_bmesh()

    def rib(angle):
        return abs(math.cos(PUMPKIN_RIBS / 2.0 * angle)) ** 0.5

    body_faces = lathe(bm, uv_layer, catmull_rom(PUMPKIN_PROFILE, 4), 64, lambda a: 1.0 - PUMPKIN_GROOVE * (1.0 - rib(a)))
    tube(bm, uv_layer, [(0.0, 0.0, 0.09), (0.004, 0.0, 0.15), (0.02, 0.0, 0.19)], [0.026, 0.021, 0.017], 5)

    def body(u, v):
        orange = scaled((0.8, 0.2, 0.012), 0.55 + 0.45 * rib(2.0 * math.pi * u))
        return mix(orange, (0.25, 0.12, 0.01), (v - 0.85) / 0.15)

    finish_fruit("pumpkin", bm, body_faces, body, {"stem": (0.12, 0.13, 0.03), "leaf": (0.1, 0.35, 0.04)})


# Each name is the stem of the .glb that its builder writes.
BUILDERS = {name + "_face": (lambda theme=(name, texel, noise): make_face(*theme)) for name, texel, noise in THEMES}
BUILDERS["ball"] = make_ball
BUILDERS["coin"] = make_coin
BUILDERS["apple"] = make_apple
BUILDERS["watermelon"] = make_watermelon
BUILDERS["pumpkin"] = make_pumpkin


def chosen(argv):
    names = argv[argv.index("--") + 1:] if "--" in argv else list(BUILDERS)
    unknown = [name for name in names if name not in BUILDERS]
    if unknown:
        raise SystemExit("make_meshes.py: no mesh named " + ", ".join(unknown))
    return names


os.makedirs(MESHES, exist_ok=True)
for name in chosen(sys.argv):
    BUILDERS[name]()
