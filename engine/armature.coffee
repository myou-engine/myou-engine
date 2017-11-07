{GameObject} = require './gameobject'
{mat4, vec3, quat} = require 'vmath'

# FUTURE OPTIMIZATION STRATEGIES
# Make a single flat array for positions and rotations,
# Sending them as textures where available
# Or as uniformMatrix4fv where not
# Baking animation loops into spare framebuffer texture
# sending bone locations in parent space instead of local

# Uniforms (in armature space) = parent uniform * base pose * local

#UNIT_MAT4 = mat4.create()
VECTOR_Y = vec3.new 0, 1, 0

class Bone
    constructor: (@context)->
        # Base pose position and rotation in PARENT space
        @base_position = vec3.create()
        @base_rotation = quat.create()
        # Position and rotation in LOCAL (base) space
        @position = vec3.create()
        @rotation = quat.create()
        #@rotation_order = 'Q'
        @scale = vec3.new 1, 1, 1
        # parents and constraints will set those
        @final_position = vec3.create()
        @final_rotation = quat.create()
        @final_scale = vec3.new 1, 1, 1
        # which will be used to compute
        @matrix = mat4.create() # World matrix
        # Object local matrix (relative to rest pose)
        @ol_matrix = mat4.create()
        # TODO: probably it was faster to use this for constraintless
        #       armatures (test)
        #@parent_matrix = UNIT_MAT4 # pointer to parent's

        # Set at the beginning, using recalculate_bone_matrices
        # with the rest pose and without constraints
        @inv_rest_matrix = mat4.create()
        @deform_id = -1
        @constraints = []


class Armature extends GameObject

    type : 'ARMATURE'

    constructor: (context)->
        super context
        @bones = {} # all bones by name
        @_bone_list = [] # all bones, ordered, parents first
        @deform_bones = []
        @unfc = 0  # uniform count
        @_m = mat4.create()

    add_bones: (bones)->
        for b in bones
            bone = new Bone @context
            vec3.copyArray bone.base_position, b['position']
            quat.copyArray bone.base_rotation, b['rotation']
            deform_id = b['deform_id']
            if deform_id != -1
                bone.deform_id = deform_id
                @deform_bones[deform_id] = bone
            parent = b['parent']
            if parent != ""
                bone.parent = @bones[parent]
                #bone.parent_matrix = bone.parent.matrix
            # TODO: only for debug
            bone.blength = b.blength
            #bone.name = b.name
            @_bone_list.push bone
            @bones[b.name] = bone
        # Note: this relies on constraints not being evaluated
        # because they are not added yet
        @recalculate_bone_matrices()
        i = 0
        for bone in @_bone_list
            # Get inverse matrix from rest pose, which
            # is used in recalculate_bone_matrices
            mat4.invert bone.inv_rest_matrix, bone.matrix
            # Not needed for poses stored in actions
            i += 1
        for b in bones
            for c in b['constraints']
                c[0] = BoneConstraints.prototype[c[0]]
                c[1] = @bones[c[1]]
                c[2] = @bones[c[2]]
            @bones[b.name].constraints = b['constraints']
        return

    recalculate_bone_matrices: ->
        for bone in @_bone_list
            pos = bone.final_position
            rot = quat.copy bone.final_rotation, bone.rotation
            scl = vec3.copy bone.final_scale, bone.scale
            vec3.transformQuat pos, bone.position, bone.base_rotation
            vec3.add pos, bone.base_position, pos
            quat.mul rot, bone.base_rotation, bone.rotation

            parent = bone.parent
            if parent
                vec3.mul scl, parent.final_scale, scl
                quat.mul rot, parent.final_rotation, rot
                vec3.mul pos, pos, parent.final_scale
                vec3.transformQuat pos, pos, parent.final_rotation
                vec3.add pos, pos, parent.final_position

            for con in bone.constraints
                con[0](con[1], con[2], con[3], con[4])

        for bone in @_bone_list
            m = bone.matrix
            pos = bone.final_position
            rot = bone.final_rotation
            scl = bone.final_scale
            # TODO: scale is not calculated correctly
            #       when parent's scale X!=Y!=Z
            mat4.fromRTS m, rot, pos, scl
            mat4.mul bone.ol_matrix, m, bone.inv_rest_matrix, m

        return

    apply_pose_arrays: (pose)->
        for bname of pose
            p = pose[bname]
            b = @bones[bname]
            vec3.copyArray b.position, p.position
            quat.copyArray b.rotation, p.rotation
            vec3.copyArray b.scale, p.scale
        return

rotation_to = (out, p1, p2, maxang)->
    angle = Math.atan2 vec3.len(vec3.cross(vec3.create(),p1,p2)), vec3.dot(p1,p2)
    angle = Math.max -maxang, Math.min(maxang, angle)
    axis = vec3.cross vec3.create(), p1, p2
    vec3.normalize axis, axis
    quat.setAxisAngle out, axis, angle
    quat.normalize out, out
    return out

class BoneConstraints
    # Assuming world coordinates
    copy_location: (owner, target)->
        quat.copy owner.final_position, target.final_position

    copy_rotation: (owner, target)->
        quat.copy owner.final_rotation, target.final_rotation

    copy_scale: (owner, target)->
        quat.copy owner.final_scale, target.final_scale

    track_to_y: (owner, target)->
        pass

    copy_rotation_one_axis: (owner, target, axis)->
        # Assuming local coordinates
        rot = target.final_rotation
        q = quat.create()
        if target.parent
            quat.invert q, target.parent.final_rotation
            rot = quat.mul quat.create(), q, rot
        t = vec3.transformQuat vec3.create(), axis, rot
        q = rotation_to q, t, axis, 9999
        quat.mul q, q, rot
        quat.mul owner.final_rotation, owner.final_rotation, q

    stretch_to: (owner, target, rest_length, bulge)->
        # Assuming scale of parents is 1 for now
        dist = vec3.dist owner.final_position, target.final_position
        scl = owner.final_scale
        scl.y *= dist / rest_length
        XZ = 1 - Math.sqrt(bulge) + Math.sqrt(bulge * (rest_length / dist))
        scl.x *= XZ
        scl.z *= XZ
        v = vec3.sub vec3.create(), target.final_position, owner.final_position
        v2 = vec3.transformQuat vec3.create(), VECTOR_Y, owner.final_rotation
        q = rotation_to quat.create(), v2, v, 9999
        quat.mul owner.final_rotation, q, owner.final_rotation

    ik: (owner, target, chain_length, num_iterations)->
        bones=[]
        tip_bone = b = owner
        while chain_length and b
            bones.push b
            b = b.parent
            chain_length -= 1
        first = bones[bones.length-1].final_position
        target = vec3.clone target.final_position
        vec3.sub target, target, first
        points = []
        for b in bones[...-1]
            points.push vec3.sub(vec3.create(), b.final_position, first)
        tip = vec3.new 0, tip_bone.blength, 0
        vec3.transformQuat tip, tip, tip_bone.final_rotation
        vec3.add tip, tip, tip_bone.final_position
        vec3.sub tip, tip, first
        points.unshift tip
        original_points = []
        for p in points
            original_points.push vec3.clone(p)

        # now we have a list of points (tips) relative to the base bone
        # from last (tip) to first (base)

        # for each iteration
        # - make all relative (including target)
        # - for each point
        #   - add the current point to all previous and target
        #   - get rotation from tip to target
        #   - rotate current and all previous points
        #        with the quat of the previous step

        q = []

        for [0...num_iterations] by 1
            vec3.sub target, target, points[0]
            for i in [0...points.length-1]
                vec3.sub points[i], points[i], points[i+1]
            for i in [0...points.length]
                vec3.add target, target, points[i]
                for j in [0...i]
                    vec3.add points[j], points[j], points[i]

                rotation_to q, points[0], target, 0.4
                # IK limits should be applied here to q
                for j in [0...i+1]
                    vec3.transformQuat points[j], points[j], q

        for i in [0...points.length]
            vec3.add points[i], points[i], first
            vec3.add original_points[i], original_points[i], first
        #for i in [0...point.length-1]
            #render_manager.debug.vectors.push [vec3.sub(vec3.create(), points[i], points[i+1]), vec3.clone(points[i+1]), {r: 1, g:1, b:0, a:1}]
        #render_manager.debug.vectors.push [vec3.sub(vec3.create(), points[points.length-1], first), first, {r: 1, g:1, b:0, a:1}]
        #for i in [0...original_points.length-1]
            #render_manager.debug.vectors.push [vec3.sub(vec3.create(), original_points[i], original_points[i+1]), vec3.clone(original_points[i+1]), {r: 1, g:0, b:1, a:1}]
        #render_manager.debug.vectors.push [vec3.sub(vec3.create(), original_points[original_points.length-1], first), first, {r: 1, g:0, b:1, a:1}]
        #for i in [0...points.length]
            #objects['Icosphere.00'+i].position = vec3.clone points[i]

        points.push first
        original_points.push first
        points.push {x: 0, y:0, z:0}
        original_points.push {x: 0, y:0, z:0}
        for i in [0...points.length-2]
            # Set bone to final position
            vec3.copy bones[i].final_position, points[i+1]
            # Make relative and exctract rotation
            vec3.sub points[i], points[i], points[i+1]
            vec3.sub original_points[i], original_points[i], original_points[i+1]
            rotation_to q, original_points[i], points[i], 100
            r = bones[i].final_rotation
            quat.mul r, q, r

module.exports = {Armature}
