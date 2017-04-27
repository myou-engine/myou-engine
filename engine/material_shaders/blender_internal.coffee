
GPU_DYNAMIC_GROUP_MISC     = 0x10000
GPU_DYNAMIC_GROUP_LAMP     = 0x20000
GPU_DYNAMIC_GROUP_OBJECT   = 0x30000
GPU_DYNAMIC_GROUP_SAMPLER  = 0x40000
GPU_DYNAMIC_GROUP_MIST     = 0x50000
GPU_DYNAMIC_GROUP_WORLD    = 0x60000
GPU_DYNAMIC_GROUP_MAT      = 0x70000

GPU_DYNAMIC_OBJECT_VIEWMAT       = 1  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_MAT           = 2  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_VIEWIMAT      = 3  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_IMAT          = 4  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_COLOR         = 5  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_AUTOBUMPSCALE = 6  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_LOCTOVIEWMAT  = 7  | GPU_DYNAMIC_GROUP_OBJECT
GPU_DYNAMIC_OBJECT_LOCTOVIEWIMAT = 8  | GPU_DYNAMIC_GROUP_OBJECT

#                                                                 point   sun    spot   hemi   area
GPU_DYNAMIC_LAMP_DYNVEC          = 1  | GPU_DYNAMIC_GROUP_LAMP #           X      X      X      X
GPU_DYNAMIC_LAMP_DYNCO           = 2  | GPU_DYNAMIC_GROUP_LAMP #    X             X             X
GPU_DYNAMIC_LAMP_DYNIMAT         = 3  | GPU_DYNAMIC_GROUP_LAMP #                  X
GPU_DYNAMIC_LAMP_DYNPERSMAT      = 4  | GPU_DYNAMIC_GROUP_LAMP #           X      X
GPU_DYNAMIC_LAMP_DYNENERGY       = 5  | GPU_DYNAMIC_GROUP_LAMP #    X      X      X      X      X
GPU_DYNAMIC_LAMP_DYNCOL          = 6  | GPU_DYNAMIC_GROUP_LAMP #    X      X      X      X      X
GPU_DYNAMIC_LAMP_DISTANCE        = 7  | GPU_DYNAMIC_GROUP_LAMP #    X             X
GPU_DYNAMIC_LAMP_ATT1            = 8  | GPU_DYNAMIC_GROUP_LAMP #    X             X
GPU_DYNAMIC_LAMP_ATT2            = 9  | GPU_DYNAMIC_GROUP_LAMP #    X             X
GPU_DYNAMIC_LAMP_SPOTSIZE        = 10 | GPU_DYNAMIC_GROUP_LAMP #                  X
GPU_DYNAMIC_LAMP_SPOTBLEND       = 11 | GPU_DYNAMIC_GROUP_LAMP #               missing?
GPU_DYNAMIC_LAMP_SPOTSCALE       = 12 | GPU_DYNAMIC_GROUP_LAMP #                  X
GPU_DYNAMIC_LAMP_COEFFCONST      = 13 | GPU_DYNAMIC_GROUP_LAMP #    X             X
GPU_DYNAMIC_LAMP_COEFFLIN        = 14 | GPU_DYNAMIC_GROUP_LAMP #    X             X
GPU_DYNAMIC_LAMP_COEFFQUAD       = 15 | GPU_DYNAMIC_GROUP_LAMP #    X             X

GPU_DYNAMIC_SAMPLER_2DBUFFER     = 1  | GPU_DYNAMIC_GROUP_SAMPLER
GPU_DYNAMIC_SAMPLER_2DIMAGE      = 2  | GPU_DYNAMIC_GROUP_SAMPLER
GPU_DYNAMIC_SAMPLER_2DSHADOW     = 3  | GPU_DYNAMIC_GROUP_SAMPLER

GPU_DYNAMIC_MIST_ENABLE          = 1  | GPU_DYNAMIC_GROUP_MIST
GPU_DYNAMIC_MIST_START           = 2  | GPU_DYNAMIC_GROUP_MIST
GPU_DYNAMIC_MIST_DISTANCE        = 3  | GPU_DYNAMIC_GROUP_MIST
GPU_DYNAMIC_MIST_INTENSITY       = 4  | GPU_DYNAMIC_GROUP_MIST
GPU_DYNAMIC_MIST_TYPE            = 5  | GPU_DYNAMIC_GROUP_MIST
GPU_DYNAMIC_MIST_COLOR           = 6  | GPU_DYNAMIC_GROUP_MIST

GPU_DYNAMIC_HORIZON_COLOR        = 1  | GPU_DYNAMIC_GROUP_WORLD
GPU_DYNAMIC_AMBIENT_COLOR        = 2  | GPU_DYNAMIC_GROUP_WORLD
GPU_DYNAMIC_ZENITH_COLOR         = 3  | GPU_DYNAMIC_GROUP_WORLD

GPU_DYNAMIC_MAT_DIFFRGB          = 1  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_REF              = 2  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_SPECRGB          = 3  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_SPEC             = 4  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_HARD             = 5  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_EMIT             = 6  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_AMB              = 7  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_ALPHA            = 8  | GPU_DYNAMIC_GROUP_MAT
GPU_DYNAMIC_MAT_MIR              = 9  | GPU_DYNAMIC_GROUP_MAT

# TODO: export constant names instead of numbers?

class BlenderInternalMaterial
    constructor: (@material) ->
        {data, _input_list, inputs} = @material
        for u in data.uniforms when u.type == -1
            path = u.path or u.index
            value = if u.value.length? then new Float32Array(u.value) else u.value
            _input_list.push inputs[path] = {value, type: u.count}
        return

    get_model_view_matrix_name: ->
        for u in @material.data.uniforms or []
            switch u.type
                when 1, GPU_DYNAMIC_OBJECT_VIEWMAT # model_view_matrix
                    return u.varname
        return "model_view_matrix"

    get_code: ->
        fragment = @material.data.fragment
        fragment = @material.context.SHADER_LIB + fragment
        return {fragment}

    get_uniform_assign: (gl, program) ->
        # TODO: reassign lamps when cloning etc
        {scene, scene:{objects}, render_scene} = @material
        code = [] # lines for the @uniform_assign_func function
        lamp_indices = {}
        lamps = []
        current_lamp = null
        current_input = -1
        locations = []
        textures = [] # temporary, see TODO in material
        for u in @material.data.uniforms or []
            if u.type == -1 # custom uniforms are material.inputs
                current_input++
            uloc = gl.getUniformLocation(program, u.varname)
            if not uloc? or uloc == -1
                continue
            # We'll use this location in a JS function that we'll be generating below
            # The result is @uniform_assign_func
            loc_idx = locations.length
            locations.push uloc
            # Magic numbers correspond to the old values of blender constants
            is_lamp = (u.type & 0xff0000) == GPU_DYNAMIC_GROUP_LAMP
            switch u.type
                when 6, 7, 9, 10, 11, 16
                    is_lamp = true
            if is_lamp
                current_lamp = lamp_indices[u.lamp] or current_lamp
                if not current_lamp?
                    current_lamp = lamp_indices[u.lamp] = lamps.length
                    lamp = objects[u.lamp]
                    lamps.push lamp
                    if not lamp?
                        console.error "Lamp '#{name}' not found, referenced in material '#{@material.name}"
                        continue
            switch u.type
                when 1, GPU_DYNAMIC_OBJECT_VIEWMAT # model_view_matrix
                    code # Ignored, used only for get_model_view_matrix_name()
                when 2, GPU_DYNAMIC_OBJECT_MAT # object_matrix
                    code.push "gl.uniformMatrix4fv(locations[#{loc_idx}], false, ob.world_matrix);"
                when 3, GPU_DYNAMIC_OBJECT_VIEWIMAT # inverse model_view_matrix
                    code.push "gl.uniformMatrix4fv(locations[#{loc_idx}], false, render._cam2world);"
                when 4, GPU_DYNAMIC_OBJECT_IMAT # inverse object_matrix
                    code.push "m4 = mat4.invert(render._m4, ob.world_matrix);"
                    code.push "gl.uniformMatrix4fv(locations[#{loc_idx}], false, m4);"
                when 5, GPU_DYNAMIC_OBJECT_COLOR # object color
                    code.push "gl.uniform4fv(locations[#{loc_idx}], ob.color);"
                when 6, GPU_DYNAMIC_LAMP_DYNVEC # lamp direction in camera space
                    code.push "gl.uniform3fv(locations[#{loc_idx}], lamps[#{current_lamp}]._dir);"
                when 7, GPU_DYNAMIC_LAMP_DYNCO # lamp position in camera space
                    code.push "gl.uniform3fv(locations[#{loc_idx}], lamps[#{current_lamp}]._view_pos);"
                when 9, GPU_DYNAMIC_LAMP_DYNPERSMAT # camera to lamp shadow matrix
                    code.push "gl.uniformMatrix4fv(locations[#{loc_idx}], false, lamps[#{current_lamp}]._cam2depth);"
                when 10, GPU_DYNAMIC_LAMP_DYNENERGY # lamp energy
                    code.push "gl.uniform1f(locations[#{loc_idx}], lamps[#{current_lamp}].energy);"
                when 11, GPU_DYNAMIC_LAMP_DYNCOL # lamp color
                    if u.datatype == 4 # vec3
                        code.push "gl.uniform3fv(locations[#{loc_idx}], lamps[#{current_lamp}].color);"
                    else # vec4
                        code.push "gl.uniform4fv(locations[#{loc_idx}], lamps[#{current_lamp}]._color4);"
                when 16, GPU_DYNAMIC_LAMP_DISTANCE # lamp falloff distance
                    code.push "gl.uniform1f(locations[#{loc_idx}], lamps[#{current_lamp}].falloff_distance);"
                when 19, GPU_DYNAMIC_LAMP_SPOTSIZE
                    # TODO: Wtf?
                    code#.push "gl.uniform1f(locations[#{loc_idx}], lamps[#{current_lamp}].spot_size);"
                when 20, GPU_DYNAMIC_LAMP_SPOTBLEND
                    code#.push "gl.uniform1f(locations[#{loc_idx}], lamps[#{current_lamp}].spot_blend);"
                when 14, GPU_DYNAMIC_SAMPLER_2DSHADOW
                    gl.uniform1i locations[loc_idx], textures.length
                    textures.push render_scene.objects[u.lamp].shadow_texture
                when 13, GPU_DYNAMIC_SAMPLER_2DIMAGE, GPU_DYNAMIC_SAMPLER_2DBUFFER # 2D image
                    tex = scene?.textures[u.image]
                    if not tex?
                        throw "Texture #{u.image} not found (in material #{@name})."
                    if not tex.loaded
                        tex.load()
                    gl.uniform1i locations[loc_idx], textures.length
                    textures.push tex
                when GPU_DYNAMIC_AMBIENT_COLOR
                    code.push "gl.uniform4fv(locations[#{loc_idx}], ob.scene.ambient_color);"
                when GPU_DYNAMIC_LAMP_COEFFCONST
                    console.warn u.lamp, 'TODO: lamp coefficient const'
                when GPU_DYNAMIC_LAMP_COEFFLIN
                    console.warn u.lamp, 'TODO: lamp coefficient lin'
                when GPU_DYNAMIC_LAMP_COEFFQUAD
                    console.warn u.lamp, 'TODO: lamp coefficient quad'
                when GPU_DYNAMIC_MIST_COLOR
                    var_mistcol = u.varname # TODO: mist
                when GPU_DYNAMIC_MIST_DISTANCE
                    var_mistdist = u.varname
                when GPU_DYNAMIC_MIST_ENABLE
                    var_mistenable = u.varname
                when GPU_DYNAMIC_MIST_INTENSITY
                    var_mistint = u.varname
                when GPU_DYNAMIC_MIST_START
                    var_miststart = u.varname
                when GPU_DYNAMIC_MIST_TYPE
                    var_misttype = u.varname
                when GPU_DYNAMIC_HORIZON_COLOR
                    code.push "gl.uniform3fv(locations[#{loc_idx}], ob.scene.background_color.subarray(0,3));"
                when -1 # custom
                    {value, type} = @material._input_list[current_input]
                    value_code = "input_list[#{current_input}].value"
                    code.push if value.length?
                        "gl.uniform#{value.length}fv(locations[#{loc_idx}], #{value_code});"
                    else if type == 1
                        "gl.uniform1f(locations[#{loc_idx}], #{value_code});"
                    else
                        filler = ([0,0,0,0][...type]+'')[1...]
                        "gl.uniform#{type}fv(locations[#{loc_idx}], [#{value_code}#{filler}]);"
                else
                    console.log "Warning: unknown uniform", u.varname, \
                        u.type>>16, u.type&0xffff, "of data type", \
                        ['0','1i','1f','2f','3f','4f','m3','m4','4ub'][u.datatype]
        func = new Function 'gl', 'locations', 'ob', 'lamps', 'input_list', 'render', 'mat4', code.join '\n'
        {uniform_assign_func: func, uniform_locations: locations, lamps, textures}


module.exports = {BlenderInternalMaterial}
