{mat2, mat3, mat4, vec2, vec3, vec4, quat} = require 'gl-matrix'
timsort = require 'timsort'
{Filter, box_filter_code} = require './filters.coffee'
{Compositor, box_filter_code} = require './filters.coffee'
{Framebuffer, MainFramebuffer} = require './framebuffer.coffee'
{Mesh} = require './mesh.coffee'
{Material} = require './material.coffee'
VECTOR_MINUS_Z = vec3.fromValues 0,0,-1

# Render manager singleton. Performs all operations related to rendering to screen or to a buffer.
#
# Access it as `render_manager` member of the {Myou} instance.
class RenderManager
    constructor: (context, canvas, width, height, glflags)->
        try
            gl = canvas.getContext("webgl", glflags) or canvas.getContext("experimental-webgl", glflags)
        catch e
            null

        if not gl
            # MSIE <= 10 with the ActiveX WebGL plugin
            if navigator.appName == "Microsoft Internet Explorer"
                iecanvas = document.createElement 'object'
                iecanvas.type = "application/x-webgl"
                canvas.parentNode.replaceChild iecanvas, canvas
                canvas = iecanvas
                gl = canvas.getContext("webgl", glflags) or canvas.getContext("experimental-webgl", glflags)

        if not gl
            gl = window.WebGL

        if not gl
            # Try disabling multisampling
            # (Chrome is not following the specification by rejecting to create the context)
            glflags.antialias = false
            gl = canvas.getContext("webgl", glflags)

        if not gl
            context.MYOU_PARAMS.on_webgl_failed?()
            throw "Error: Can't start WebGL"

        @context = context
        @context.render_manager = @
        @canvas = canvas
        @gl = gl
        if vec3.create().byteLength == 24
            # TODO: convert only when necessary?
            gl.tmp2 = new Float32Array 2
            gl.tmp3 = new Float32Array 3
            gl.tmp4 = new Float32Array 4
            gl.tmp9 = new Float32Array 9
            gl.tmp16 = new Float32Array 16
            gl._uniform2fv = gl.uniform2fv
            gl.uniform2fv = (l, v) -> @tmp2.set(v);@_uniform2fv l, @tmp2
            gl._uniform3fv = gl.uniform3fv
            gl.uniform3fv = (l, v) -> @tmp3.set(v);@_uniform3fv l, @tmp3
            gl._uniform4fv = gl.uniform4fv
            gl.uniform4fv = (l, v) -> @tmp4.set(v);@_uniform4fv l, @tmp4
            gl._uniformMatrix3fv = gl.uniformMatrix3fv
            gl.uniformMatrix3fv = (l, t, v) -> @tmp9.set(v);@_uniformMatrix3fv l, t, @tmp9
            gl._uniformMatrix4fv = gl.uniformMatrix4fv
            gl.uniformMatrix4fv = (l, t, v) -> @tmp16.set(v);@_uniformMatrix4fv l, t, @tmp16
        @width = width
        @height = height
        @main_fb = new MainFramebuffer @context
        @temporary_framebuffers = {}
        @viewports = []
        @render_tick = 0
        @context_lost_count = 0
        @bound_textures = []
        @active_texture = -1
        @next_texture = 0
        @max_textures = gl.getParameter gl.MAX_TEXTURE_IMAGE_UNITS
        @frame_start = performance.now()
        @pixel_ratio_x = @pixel_ratio_y = 1
        @camera_z = vec3.create()
        @no_s3tc = @context.MYOU_PARAMS.no_s3tc
        ba = @context.MYOU_PARAMS.background_alpha
        @background_alpha = if ba? then ba else 1
        @compiled_shaders_this_frame = 0
        @use_frustum_culling = true
        @probes = []

        # Temporary variables
        @_cam2world = mat4.create()
        @_cam2world3 = mat3.create()
        @_world2cam = mat4.create()
        @_world2cam3 = mat3.create()
        @_world2cam_mx = mat4.create()
        @_world2cam3_mx = mat3.create()
        @_world2light = mat4.create()
        @projection_matrix_inverse = mat4.create()
        @_m4 = mat4.create()  # note: those are used
        @_m3 = mat3.create()  #       in several methods
        @_v = vec3.create()
        @_cam = null
        @_vp = null
        @_cull_left = vec3.create()
        @_cull_right = vec3.create()
        @_cull_top = vec3.create()
        @_cull_bottom = vec3.create()
        @_polygon_ratio = 1
        @_right_eye_factor = 0
        @triangles_drawn = 0
        @meshes_drawn = 0

        lost = (event)->
            event.preventDefault()
            @context.MYOU_PARAMS.on_context_lost?()
            render_manager.clear_context()
        restored = (event)->
            render_manager.restore_context()
            @context.MYOU_PARAMS.on_context_restored? and requestAnimationFrame(@context.MYOU_PARAMS.on_context_restored)
        canvas.addEventListener "webglcontextlost", lost, false
        canvas.addEventListener "webglcontextrestored", restored, false
        @initialize()

    # @private
    # (Re)initializes the GL context.
    initialize: ()->
        gl = @gl
        @extensions =
            standard_derivatives: gl.getExtension 'OES_standard_derivatives'
            texture_float: gl.getExtension 'OES_texture_float'
            texture_float_linear: gl.getExtension 'OES_texture_float_linear'
            texture_half_float: gl.getExtension 'OES_texture_half_float'
            texture_half_float_linear: gl.getExtension 'OES_texture_half_float_linear'
            compressed_texture_s3tc: gl.getExtension 'WEBGL_compressed_texture_s3tc'
            compressed_texture_astc: gl.getExtension 'KHR_texture_compression_astc_ldr' or 'WEBGL_compressed_texture_astc'
            texture_filter_anisotropic: gl.getExtension("EXT_texture_filter_anisotropic") or
                                    gl.getExtension("WEBKIT_EXT_texture_filter_anisotropic") or
                                    gl.getExtension("MOZ_EXT_texture_filter_anisotropic")
            lose_context: gl.getExtension "WEBGL_lose_context"
            depth_texture: gl.getExtension "WEBGL_depth_texture"
            shader_texture_lod: gl.getExtension "EXT_shader_texture_lod"
        if @no_s3tc
            @extensions['compressed_texture_s3tc'] = null

        @has_float_fb_support = false
        if @extensions.texture_float?
            @has_float_fb_support = true
            # TODO: use_depth is probably unnecessary
            # TODO: should we test available depth types?
            fb = new Framebuffer @context, {size: [4, 4], color_type: 'FLOAT', use_depth: true}
            @has_float_fb_support = fb.is_complete
            fb.destroy()

        @has_half_float_fb_support = false
        if @extensions.texture_half_float?
            @has_half_float_fb_support = true
            fb = new Framebuffer @context, {size: [4, 4], color_type: 'HALF_FLOAT', use_depth: true}
            @has_half_float_fb_support = fb.is_complete
            fb.destroy()

        # By default, shadows will be enabled depending on
        # support for linear interpolation in float textures and float framebuffers
        @enable_shadows = (@extensions.texture_float_linear? and @has_float_fb_support) or \
            (@extensions.texture_half_float_linear? and @has_half_float_fb_support)
        @_shadows_were_enabled = @enable_shadows

        @shadow_box_filter = new Filter @, box_filter_code, 'box_filter'

        @common_shadow_fb = null
        @debug = new Debug @context

        # Initial GL state
        gl.clearDepth 1.0
        gl.enable gl.DEPTH_TEST
        gl.depthFunc gl.LEQUAL
        gl.enable gl.CULL_FACE
        gl.cullFace gl.BACK
        @flip = false
        @cull_face_enabled = true
        # Not premultiplied alpha textures
        gl.blendFunc gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA
        # For premul, use  gl.ONE, gl.ONE_MINUS_SRC_ALPHA
        @attrib_bitmask = 0


        @blank_texture = new @context.Texture {@context},
            formats: raw_pixels: {
                width: 2, height: 2, pixels: 0 for [0...2*2*4]
            }
        @blank_texture.load()

        @white_texture = new @context.Texture {@context},
            formats: raw_pixels: {
                width: 2, height: 2, pixels: 255 for [0...2*2*4]
            }
        @white_texture.load()

        @blank_cube_texture = new @context.Cubemap size: 16, color: [0,0,0,0]

        @blank_textures = []
        @blank_textures[gl.TEXTURE_2D] = @blank_texture
        @blank_textures[gl.TEXTURE_CUBE_MAP] = @blank_cube_texture

        @quad = gl.createBuffer()
        gl.bindBuffer gl.ARRAY_BUFFER, @quad
        gl.bufferData gl.ARRAY_BUFFER, new(Float32Array)([0,1,0,0,0,0,1,1,0,1,0,0]), gl.STATIC_DRAW
        gl.bindBuffer gl.ARRAY_BUFFER, null

        @bg_mesh = new @context.Mesh
        @bg_mesh.load_from_lists([-1,-1,-1, 3,-1,-1, -1,3,-1],[0,1,2])
        @bg_mesh.stride = 3*4
        @bg_mesh.radius = 1e999
        @bg_mesh.materials = [null]

        @resize @width, @height, @pixel_ratio_x, @pixel_ratio_y

    # @private
    # Handles the "lost context" event.
    clear_context: ->
        @context_lost_count += 1
        for scene in @context.scenes
            for k, t of scene.textures
                t.gl_tex = null
        return

    # @private
    # Restores GL context after a "lost context" event.
    restore_context: ->
        @initialize()
        for scene in @context.scenes
            for k, t of scene.textures
                t.reupload()
        for _,m of @context.all_materials
            m.delete_all_shaders()
        for k, m in @context.mesh_datas
            m.reupload()
        return

    # @private
    # Changes state of face culling depending on `material.double_sided`
    set_cull_face: (enable)->
        if enable
            @gl.enable 2884 # 2884 = gl.CULL_FACE
        else
            @gl.disable 2884

    # Changes the resolution of the canvas and aspect ratio of viewports.
    # It doesn't handle the final size (that's done through HTML styles).
    # usually called when the window is resized.
    resize: (width, height, pixel_ratio_x=1, pixel_ratio_y=1)->
        @width = width
        @height = height
        @canvas.width = @main_fb.size_x = width * pixel_ratio_x
        @canvas.height = @main_fb.size_y = height * pixel_ratio_y
        @pixel_ratio_x = pixel_ratio_x
        @pixel_ratio_y = pixel_ratio_y
        @screen_size = [width, height]
        @largest_side = Math.max(width, height)
        @smallest_side = Math.min(width, height)
        @diagonal = Math.sqrt(width*width + height*height)
        filter_fb_needed = false
        for v in @viewports
            v.recalc_aspect()
            if v.post_processing_enabled
                filter_fb_needed = true

        if filter_fb_needed and @viewports.length != 0
            @recalculate_fb_size()

    # Change the aspect ratio of viewports. Useful for very quick changes
    # of the size of the canvas, such as with a CSS animation.
    # Much cheaper than a regular resize, because it doesn't change the resolution.
    resize_soft: (width, height)->
        for v in @viewports
            v.camera.aspect_ratio = width/height
            v.camera.recalculate_projection()
        return

    # Requests full screen status of the canvas. Note that browsers require
    # this function to be called from a user initiated event such as `click` or `keypress`.
    request_fullscreen: ->
        #https://dvcs.w3.org/hg/fullscreen/raw-file/tip/Overview.html#api
        c = @canvas
        (c.requestFullscreen or
         c.mozRequestFullScreen or
         c.webkitRequestFullscreen)()
        # TODO: differences in style if the canvas is not 100%

    # @private
    # @deprecated
    recalculate_fb_size: ->
        next_POT = (x)->
            x = Math.max(0, x-1)
            return Math.pow(2, Math.floor(Math.log(x)/Math.log(2))+1)
        # For nearest POT: pow(2, round(log(x)/log(2)))

        # Framebuffer needs to be power of two (POT), so we'll find out the
        # smallest POT that can be used by all viewports
        minx = miny = 0
        for v in @viewports
            minx = Math.max(minx, v.rect_pix[2])
            miny = Math.max(miny, v.rect_pix[3])
        minx = next_POT(minx)
        miny = next_POT(miny)
        if @common_filter_fb and (@common_filter_fb.width!=minx or @common_filter_fb.height!=miny)
            @common_filter_fb.destroy()
            @common_filter_fb = null
        if not @common_filter_fb
            @common_filter_fb = new Framebuffer @context,
                {size: [minx, miny], color_type: 'UNSIGNED_BYTE', depth_type: 'UNSIGNED_SHORT', use_depth: true}
        if not @common_filter_fb.is_complete
            throw "Common filter framebuffer is not complete"

        # Write fb_size to all materials that require it
        for k, scene of @context.scenes
            for kk, mat of scene.materials
                for sig,shader of mat.shaders
                    if shader.u_fb_size?
                        shader.use()
                        @gl.uniform2f shader.u_fb_size, minx, miny
        return

    # @private
    change_enabled_attributes: (bitmask)->
        gl = @gl
        previous = @attrib_bitmask
        mask = previous&~bitmask
        i = 0
        while mask!=0
            if mask&1
                gl.disableVertexAttribArray i
            i += 1
            mask >>= 1
        mask = bitmask&~previous
        i = 0
        while mask!=0
            if mask&1
                gl.enableVertexAttribArray i
            i += 1
            mask >>= 1
        @attrib_bitmask = bitmask

    # Binds a texture or cubemap to an unused GL texture slot
    # @param texture [Texture] Texture or [Cubemap]
    # @return [number] Active texture unit number
    # TODO: Check if a shader needs more textures than available
    bind_texture: (texture) ->
        {gl, bound_textures, active_texture, next_texture, max_textures} = @
        old_tex = bound_textures[texture.bound_unit]
        if texture.bound_unit != -1 or old_tex != texture
            texture.bound_unit = bound_unit = next_texture
            if active_texture != bound_unit
                @active_texture = bound_unit
                gl.activeTexture gl.TEXTURE0 + bound_unit
            if old_tex?
                old_tex.bound_unit = -1
                if old_tex.gl_target != texture.gl_target
                    # Not sure if this is needed
                    gl.bindTexture old_tex.gl_target, null
            if texture.loaded
                gl.bindTexture texture.gl_target, texture.gl_tex
            else
                gl.bindTexture texture.gl_target, @blank_textures[texture.gl_target].gl_tex
            bound_textures[bound_unit] = texture
            @next_texture = (next_texture+1) % max_textures
        else
            {bound_unit} = texture
            if active_texture != bound_unit
                @active_texture = bound_unit
                gl.activeTexture gl.TEXTURE0 + bound_unit
        # TODO: debug option to check if texture is actually bound
        return bound_unit

    # Unbinds a texture if it was bound
    unbind_texture: (texture) ->
        {gl, bound_textures} = @
        old_tex = bound_textures[texture.bound_unit]
        if old_tex == texture
            bound_textures[texture.bound_unit] = null
            gl.activeTexture gl.TEXTURE0 + texture.bound_unit
            gl.bindTexture texture.gl_target, null
            texture.bound_unit = -1
        return

    # Draws all enabled scenes of all the viewports in `render_manager.viewports`.
    # Usually called from {MainLoop}
    draw_all: ->
        # TODO: calculate all matrices first
        # TODO: have a list of objects instead of probes?
        for probe in @probes
            probe.render()

        @frame_start = performance.now()
        @render_tick += 1
        @triangles_drawn = 0
        @meshes_drawn = 0
        {_HMD} = @context
        if _HMD?.isPresenting
            pose = _HMD.getPose()
            nm = @context.neck_model

            if pose.position and @context.use_VR_position
                vec3.copy @viewports[0].camera.position, pose.position
                vec3.copy @viewports[1].camera.position, pose.position
            else if pose.orientation and nm
                vec3.transformQuat nm.neck, nm.orig_neck, pose.orientation
                nm.neck[2] -= nm.orig_neck[2]
                vec3.copy @viewports[0].camera.position, nm.neck
                vec3.copy @viewports[1].camera.position, nm.neck
            if pose.orientation
                quat.copy @viewports[0].camera.rotation, pose.orientation
                quat.copy @viewports[1].camera.rotation, pose.orientation

        for viewport in @viewports when viewport.camera.scene.enabled
            if viewport.compositor_enabled
                rect = viewport.rect_pix
                src_rect = [0, 0, rect[2], rect[3]]
                @draw_viewport(viewport, src_rect, @common_filter_fb, [0, 1])
                viewport.compositor.compose()
                # Draw translucid pass (post processing is required because it uses the filter fb)
                if viewport.camera.scene.mesh_passes[2].length
                    # TODO: how to properly do this?
                    old_clear_bits = viewport.clear_bits
                    viewport.clear_bits = 256
                    @draw_viewport(viewport, src_rect, viewport.dest_buffer, [2])
                    viewport.clear_bits = old_clear_bits
            else
                @draw_viewport viewport, viewport.rect_pix, viewport.dest_buffer, [0, 1]

        if pose?
            _HMD.submitFrame pose

        #@gl.flush()
        @debug.vectors.clear() # TODO: have them per scene? preserve for a bunch of frames?
        @compiled_shaders_this_frame = 0

    # @private
    # Draws a mesh.
    draw_mesh: (mesh, mesh2world, pass_=-1, material_override, world2cam_override, projection_override)->
        # TODO: Put all camera matrices into a single argument:
        # world2cam, cam2world, world2cam3, cam2world3 (aka camera.rotation_matrix),
        # projection, projection inverse
        # TODO: check epsilon, probably better to check sum of absolutes instead of sqrLen
        if vec3.sqrLen mesh.scale < 0.000001
            mesh.culled_in_last_frame = true
            return

        gl = @gl
        bound_textures = @bound_textures
        m4 = @_m4
        m3 = @_m3
        cam = @_cam

        if @use_frustum_culling
            # Cull object if it's outside camera frustum
            parented_pos = if mesh.parent then  mesh.get_world_position() else mesh.position
            pos = vec3.copy @_v, parented_pos
            if mesh.mirrors == 2
                pos[0] = -pos[0]
            vec3.sub pos, pos, cam.position
            r = mesh.radius
            distance_to_camera = vec3.dot pos, @camera_z

            if ((distance_to_camera+r) *
                (vec3.dot(pos, @_cull_top)+r) *
                (vec3.dot(pos, @_cull_left)+r) *
                (vec3.dot(pos, @_cull_right)+r) *
                (vec3.dot(pos, @_cull_bottom)+r)) < 0
                    mesh.culled_in_last_frame = true
                    return
            mesh.culled_in_last_frame = false

        # Select alternative mesh / LoD
        if @_vp?.camera?
            amesh = mesh.last_lod_object
            if not amesh? or @render_tick != mesh.last_lod_tick
                amesh = mesh.get_lod_mesh(@_vp, @context.mesh_lod_min_length_px)
                if not amesh.data
                    return
                mesh.last_lod_tick = @render_tick
        else
            amesh = mesh.data
            if not amesh.data
                return

        flip_normals = mesh._flip
        if @flip != flip_normals
            if (@flip = flip_normals)
                gl.frontFace 2304 # gl.CW
            else
                gl.frontFace 2305 # gl.CCW

        [inv_radius_x, inv_radius_y, inv_radius_z] = mesh.dimensions
        inv_radius_x = 2/inv_radius_x
        inv_radius_y = 2/inv_radius_y
        inv_radius_z = 2/inv_radius_z

        # Main routine for each submesh
        submesh_idx = -1

        for mat in amesh.materials
            submesh_idx += 1
            if not (pass_ == -1 or mesh.passes[submesh_idx] == pass_)
                continue

            if material_override?
                mat = material_override
            shader = mat.get_shader(mesh)
            if not shader._program?
                continue
            shader.use()

            if mat.double_sided == @cull_face_enabled
                @cull_face_enabled = not @cull_face_enabled
                @set_cull_face @cull_face_enabled

            # Assigning uniforms of the 3 main matrices:
            # model_view_matrix, normal_matrix and projection_matrix
            mat4.multiply m4, world2cam_override or @_world2cam, mesh2world
            gl.uniformMatrix4fv shader.u_model_view_matrix, false, m4
            if shader.u_normal_matrix?
                mat3.multiply m3, @_world2cam3, mesh.normal_matrix
                gl.uniformMatrix3fv shader.u_normal_matrix, false, m3
            gl.uniformMatrix4fv shader.u_projection_matrix, false, projection_override or cam.projection_matrix

            # Enabling textures and assigning their respective uniforms
            # TODO: figure out a way to do object-specific textures
            for tex_input in mat._texture_list
                if tex_input.is_probe
                    # this means it's the probe cube texture
                    tex = mesh.probe?.cubemap or @blank_cube_texture
                    tex_input.value = tex
                else
                    tex = tex_input.value
                if tex.bound_unit == -1
                    @bind_texture tex

            # Assigning uniforms of vertex modifiers
            mds = shader.modifier_data_store
            for modifier,i in mesh.vertex_modifiers
                modifier.update_uniforms gl, mds[i]

            # Assigning the rest of the uniforms (except
            shader.uniform_assign_func(gl, shader, mesh, this, mat4)

            # TODO: move this elsewhere
            if shader.u_uv_rect?
                [x,y,w,h] = mesh.uv_rect
                x += mesh.uv_right_eye_offset[0] * @_right_eye_factor
                y += mesh.uv_right_eye_offset[1] * @_right_eye_factor
                gl.uniform4f shader.u_uv_rect, x, y, w, h
            if shader.u_mesh_center?
                gl.uniform3fv shader.u_mesh_center, mesh.center
                gl.uniform3f shader.u_mesh_inv_dimensions, inv_radius_x, inv_radius_y, inv_radius_z

            # Bind vertex buffer, assign attribute pointers
            data = amesh.data
            stride = data.stride
            array_buffer = data.vertex_buffers[submesh_idx]
            if not array_buffer?
                continue
            gl.bindBuffer gl.ARRAY_BUFFER, array_buffer
            @change_enabled_attributes shader.attrib_bitmask
            for attr in shader.attrib_pointers
                # [location, number of components, type, offset]
                gl.vertexAttribPointer attr[0], attr[1], attr[2], false, stride, attr[3]

            # Bind index buffer, draw
            gl.bindBuffer gl.ELEMENT_ARRAY_BUFFER, data.index_buffers[submesh_idx]
            num_indices = data.num_indices[submesh_idx] # * @_polygon_ratio)|0
            gl.drawElements data.draw_method, num_indices, gl.UNSIGNED_SHORT, 0

            ## TODO: Enable in debug mode, silence after n errors
            # error = gl.getError()
            # if error != gl.NO_ERROR
            #     errcodes = {
            #         '1280': 'INVALID_ENUM',
            #         '1281': 'INVALID_VALUE',
            #         '1282': 'INVALID_OPERATION',
            #         '1205': 'OUT_OF_MEMORY'
            #     }
            #     console.error ('GL Error ' + errcodes[error] + ' when drawing ' + mesh.name +
            #             ' (' + mesh.mesh_name + ') with ' + mat.name)

            # @meshes_drawn += 1
            # @triangles_drawn += num_indices * 0.33333333333333333

        return

    # @private
    # Draws the scene background in a quad,
    # usually after opaque pass and before transparent pass
    draw_background: (scene, world2cam, cam2world, projection_matrix) ->
        @draw_mesh(@bg_mesh, cam2world, -1, scene.world_material, world2cam, projection_matrix)

    # @private
    # Draws a viewport. Usually called from `draw_all`.
    draw_viewport: (viewport, rect, dest_buffer, passes)->
        gl = @gl
        if gl.isContextLost()
            return
        @_cam = cam = viewport.debug_camera or viewport.camera
        @_vp = viewport
        scene = cam.scene

        m4 = @_m4
        m3 = @_m3

        # This condition is necessary for when the scene is drawn
        # several times in several viewports
        shadows_pending = false
        if scene.last_render_tick < @render_tick
            scene.last_render_tick = @render_tick
            if @enable_shadows
                shadows_pending = true
            else if @_shadows_were_enabled
                for lamp in scene.lamps
                    if lamp.shadow_fb?
                        lamp.destroy_shadow()
                @common_shadow_fb?.destroy()
            @_shadows_were_enabled = @enable_shadows

            if scene._children_are_ordered == false
                scene.reorder_children()
            # TODO: do this only for visible and modified objects
            #       (also, this is used in LookAt and other nodes)
            for ob in scene.armatures
                for c in ob.children
                    if c.visible and c.render
                        ob.recalculate_bone_matrices()
                        break
            for ob in scene.auto_updated_children
                ob._update_matrices()

        debug = @debug
        filter_fb = @common_filter_fb

        # Create cam2world from camera world matrix but ignoring scale
        cam_rm = mat3.copy @_cam2world3, cam.rotation_matrix
        cam_wm = cam.world_matrix
        cam2world = @_cam2world
        cam2world[0] = cam_rm[0]
        cam2world[1] = cam_rm[1]
        cam2world[2] = cam_rm[2]
        cam2world[4] = cam_rm[3]
        cam2world[5] = cam_rm[4]
        cam2world[6] = cam_rm[5]
        cam2world[8] = cam_rm[6]
        cam2world[9] = cam_rm[7]
        cam2world[10] = cam_rm[8]
        cam2world[12] = cam_wm[12]
        cam2world[13] = cam_wm[13]
        cam2world[14] = cam_wm[14]
        world2cam = @_world2cam
        world2cam3 = @_world2cam3
        world2cam_mx = @_world2cam_mx
        world2cam3_mx = @_world2cam3_mx
        world2light = @_world2light
        # Shift position for stereo VR rendering
        eye_shift = vec3.scale @_v, viewport.eye_shift, vec3.len(cam.world_matrix.subarray(8,11))
        vec3.transformMat4 cam2world.subarray(12,15), eye_shift, cam2world
        @_right_eye_factor = viewport.right_eye_factor

        mat4.invert world2cam, cam2world
        mat3.fromMat4 world2cam3, world2cam

        mat4.copy world2cam_mx, world2cam
        world2cam_mx[0] = -world2cam_mx[0]
        world2cam_mx[1] = -world2cam_mx[1]
        world2cam_mx[2] = -world2cam_mx[2]
        mat3.fromMat4 world2cam3_mx, world2cam_mx
        vec3.transformMat3 @camera_z, VECTOR_MINUS_Z, cam.rotation_matrix
        # Set plane vectors that will be used for culling objects in perspective
        vec3.transformMat3 @_cull_left, cam.cull_left, cam.rotation_matrix
        v = vec3.copy @_cull_right, cam.cull_left
        v[0] = -v[0]
        vec3.transformMat3 v, v, cam.rotation_matrix
        vec3.transformMat3 @_cull_bottom, cam.cull_bottom, cam.rotation_matrix
        v = vec3.copy @_cull_top, cam.cull_bottom
        v[1] = -v[1]
        vec3.transformMat3 v, v, cam.rotation_matrix

        mat4.invert @projection_matrix_inverse, cam.projection_matrix

        # For usage outside this render loop
        mat4.mul cam.world_to_screen_matrix, cam.projection_matrix, world2cam

        # unbind all textures
        # TODO: Is this necessary?
        for tex, i in @bound_textures when tex?
            tex.bound_unit = -1
            gl.activeTexture gl.TEXTURE0 + i
            gl.bindTexture tex.gl_target, null
        gl.activeTexture gl.TEXTURE0
        @active_texture = @next_texture = 0
        @bound_textures.clear()

        {mesh_lod_min_length_px} = @context

        # Render shadow buffers
        for lamp in scene.lamps
            if shadows_pending and lamp.shadow_options? and lamp.render_shadow
                if not lamp.shadow_fb?
                    # TODO: enable all at once to decide common fb size
                    lamp.init_shadow()
                size = lamp.shadow_fb.size_x * 2
                if not @common_shadow_fb?
                    @common_shadow_fb = new Framebuffer @context, {size: [size,size], use_depth: true}

                @common_shadow_fb.enable [0, 0, size, size]
                gl.clearColor 1,1,1,1  # TODO: which color should we use?
                gl.clear gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT
                mat = lamp._shadow_material
                mat4.invert world2light, lamp.world_matrix

                for ob in scene.mesh_passes[0]
                    data = ob.get_lod_mesh(@_vp, mesh_lod_min_length_px).data
                    if ob.visible and data and not ob.culled_in_last_frame
                        @draw_mesh ob, ob.world_matrix, -1, mat, world2light, lamp._projection_matrix

                lamp.shadow_fb.enable()
                @common_shadow_fb.draw_with_filter @shadow_box_filter, [0, 0, size, size]

            if lamp.shadow_fb?
                # Calculate and save cam2depth matrix for this lamp
                mat4.multiply m4, world2light, cam2world
                mat4.multiply lamp._cam2depth, lamp._depth_matrix, m4

            # Update lamp view pos and direction
            lamp.recalculate_render_data(world2cam)


        # Main drawing code to destination buffer (usually the screen)
        dest_buffer.enable rect

        clear_bits = viewport.clear_bits
        if scene.world_material? and @background_alpha >= 1
            # Don't clear color since we'll be rendering over it
            # TODO: Shouldn't @background_alpha be in the scene?
            clear_bits &= ~gl.COLOR_BUFFER_BIT
        else if clear_bits & gl.COLOR_BUFFER_BIT
            c = scene.background_color
            gl.clearColor c[0],c[1],c[2],@background_alpha
        clear_bits and gl.clear clear_bits

        # TODO: Think better about how to manage passes
        # Add a function for moving objects between passes freely?
        # Use a dynamic number of passes where each pass have a list of pre/post operations?
        # And a sort option

        # PASS -1  (background)
        if scene.bg_pass and scene.bg_pass.length
            for ob in scene.bg_pass
                if ob.visible == true and ob.render
                    @draw_mesh(ob, ob.world_matrix, 0)
            gl.clear gl.DEPTH_BUFFER_BIT

        # PASS 0  (solid objects)
        if passes.indexOf(0) >= 0
            # TODO: profile with timsort, etc
            # scene.mesh_passes[0].sort sort_by_mat_id
            for ob in scene.mesh_passes[0]
                if ob.visible == true and not ob.bg and not ob.fg and ob.render
                    @draw_mesh(ob, ob.world_matrix, 0)

        # Scene background
        if scene.world_material?
            @draw_background(scene, world2cam, cam2world, cam.projection_matrix)

        # PASS 1  (alpha)
        if passes.indexOf(1)>=0 and scene.mesh_passes[1].length
            gl.depthMask false
            gl.enable gl.BLEND
            # Sort by distence to camera
            z = @camera_z
            for ob in scene.mesh_passes[1]
                v = if ob.parent then ob.get_world_position() else ob.position
                x = v[0]
                if ob.mirrors == 2
                    x = -x
                ob._sqdist = - (x*z[0] + v[1]*z[1] + v[2]*z[2]) - (ob.zindex * (ob.dimensions[0]+ob.dimensions[1]+ob.dimensions[2])*0.166666)
                # ob._sqdist = -vec3.dot(s,z) - (ob.zindex * (ob.dimensions[0]+ob.dimensions[1]+ob.dimensions[2])*0.166666)
            timsort.sort scene.mesh_passes[1], (a,b)-> a._sqdist - b._sqdist

            for ob in scene.mesh_passes[1]
                if ob.visible == true and ob.render
                    @draw_mesh(ob, ob.world_matrix, 1)

            gl.disable gl.BLEND
            gl.depthMask true

        if scene.fg_pass and scene.fg_pass.length
            gl.clear gl.DEPTH_BUFFER_BIT
            for ob in scene.fg_pass
                if ob.visible == true and ob.render
                    @draw_mesh(ob, ob.world_matrix, 0)

        # PASS 2  (translucent)
        # Currently it uses the filter FB, so this has to be drawn unfiltered
        if passes.indexOf(2)>=0
            for ob in scene.mesh_passes[2]
                if ob.visible == true and ob.render
                    @draw_mesh ob, ob.world_matrix, 2


        # Debug physics and vectors (TODO: move vector to debug properties?)
        if @context.MYOU_PARAMS.debug
            mm4 = mat4.create()
            for ob in scene.children
                dob = ob.phy_debug_mesh
                if dob
                    if dob!=ob
                        posrot = ob.get_world_pos_rot()
                        dob.position = posrot[0]
                        dob.rotation = posrot[1]
                        dob.scale = ob.phy_he
                        dob._update_matrices()
                        # TODO: It's better to have a separate debug mesh
                        # than recalculating the matrices of the same mesh

                    # occluded pass
                    dob.color=vec4.clone [1,1,1,0.2]
                    gl.enable gl.BLEND
                    gl.disable gl.DEPTH_TEST
                    @draw_mesh dob, dob.world_matrix

                    # visible pass
                    gl.disable gl.BLEND
                    gl.enable gl.DEPTH_TEST
                    dob.color=vec4.clone [1,1,1,1]
                    @draw_mesh dob, dob.world_matrix

            gl.disable gl.DEPTH_TEST
            for dvec in @debug.vectors
                # TODO: draw something else when it's too small (a different arrow?)
                #       and a circle when it's 0
                dob = @debug.arrow
                dob.color = vec4.clone dvec[2]
                dob.position = dvec[1]
                v3 = dvec[0]
                v2 = vec3.cross [0,0,0], cam.position, v3
                v1 = vec3.normalize [0,0,0], vec3.cross([0,0,0],v2,v3)
                v2 = vec3.normalize [0,0,0], vec3.cross(v2,v3,v1)
                s = vec3.len v3
                vec3.scale v2,v2,s
                vec3.scale v1,v1,s
                ma = mat4.fromValues v1[0], v1[1], v1[2], 0,
                    v2[0], v2[1], v2[2], 0,
                    v3[0], v3[1], v3[2], 0,
                    dob.position[0], dob.position[1], dob.position[2], 1
                @draw_mesh dob, ma

            dob = @debug.bone
            for ob in scene.armatures
                for b in ob._bone_list
                    mat4.scale(mm4, b.matrix, [b.blength,b.blength,b.blength])
                    @draw_mesh dob, mm4

            gl.enable gl.DEPTH_TEST

    # Draws a cubemap texture.
    # Usually called from {Probe}
    draw_cubemap: (scene, cubemap, position, near, far) ->
        # TODO
        # * use frustum culling
        # * override LoD detection or set a camera for this
        {gl, use_frustum_culling} = @
        @use_frustum_culling = false

        world2cube = mat4.create()
        proj = mat4.frustum mat4.create(),-near,near,-near,near,near,far

        @unbind_texture cubemap

        fb = @temporary_framebuffers[cubemap.size]
        if not fb
            fb = @temporary_framebuffers[cubemap.size] = new Framebuffer @context,
                {size: [cubemap.size,cubemap.size], use_depth: true, \
                 color_type: 'UNSIGNED_BYTE', depth_type: 'UNSIGNED_SHORT'}
        fb.enable()
        for side in [0...6]
            fb.bind_to_cubemap_side cubemap, side
            dir = [[1.0, 0.0, 0.0],[-1.0, 0.0, 0.0],[0.0, 1.0, 0.0],
                [0.0, -1.0, 0.0],[0.0, 0.0, 1.0],[0.0, 0.0, -1.0]][side]
            up = [[0.0, -1.0, 0.0],[0.0, -1.0, 0.0],[0.0, 0.0, 1.0],
                [0.0, 0.0, -1.0],[0.0, -1.0, 0.0],[0.0, -1.0, 0.0]][side]
            dir[0] += position[0]
            dir[1] += position[1]
            dir[2] += position[2]
            mat4.lookAt world2cube, position, dir, up
            mat4.invert @_cam2world, world2cube
            mat3.fromMat4 @_cam2world3, @_cam2world
            mat3.fromMat4 @_world2cam3, world2cube
            [r,g,b] = scene.background_color
            gl.clearColor r,g,b,1
            gl.clear gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT
            if @do_log?
                @do_log = side == 0
            for lamp in scene.lamps
                lamp.recalculate_render_data world2cube
            for ob in scene.mesh_passes[0] when ob.probe?.cubemap != cubemap
                if ob.visible and ob.data
                    @draw_mesh ob, ob.world_matrix, -1, null, world2cube, proj
            scene.world_material? and @draw_background(scene, world2cube, @_cam2world, proj)
            if @do_log
                @do_log = false
                console.log @debug_uniform_logging_get_log()

        fb.unbind_cubemap()
        fb.disable()
        cubemap.generate_mipmap()
        @use_frustum_culling = use_frustum_culling
        return

    # @nodoc
    debug_uniform_logging: ->
        # This function logs calls to uniform functions
        # and it's useful to find uniforms changing when they shouldn't
        # Usage:
        #   if @do_log?
        #     @do_log = true
        #   [do all things]
        #   if @do_log
        #     @do_log = false
        #     console.log @debug_uniform_logging_get_log()
        # and then:
        #   rm.debug_uniform_logging()
        #   rm.debug_uniform_logging_break(number of uniform)
        gl = @gl
        @do_log = false
        @u_log_break = -1
        @u_log_number = 0
        for p in ['uniform1fv', 'uniform2fv', 'uniform3fv', 'uniform4fv']
            gl['_'+p] = gl[p]
            gl[p] = do (p) => (l,v) =>
                if @do_log
                    if @u_log_number == @u_log_break
                        debugger
                        @u_log_break = -1
                    @u_log += "#{@u_log_number++}: #{v}\n"
                return gl["_"+p](l,v)

        for p in ['uniform1v', 'uniform2v', 'uniform3v', 'uniform4v']
            gl['_'+p] = gl[p]
            gl[p] = do (p) => (l,v...) =>
                if @do_log
                    if @u_log_number == @u_log_break
                        debugger
                        @u_log_break = -1
                    @u_log += "#{@u_log_number++}: #{v}\n"
                return gl["_"+p](l,v...)

        for p in ['uniformMatrix3fv', 'uniformMatrix4fv']
            gl['_'+p] = gl[p]
            gl[p] = do (p) => (l,t,v)=>
                if @do_log
                    if @u_log_number == @u_log_break
                        debugger
                        @u_log_break = -1
                    @u_log += "#{@u_log_number++}: #{v}\n"
                return gl["_"+p](l,t,v)
        return

    # @nodoc
    debug_uniform_logging_get_log: ->
        {u_log} = @
        @u_log = ''
        @u_log_number = 0
        u_log

    # @nodoc
    debug_uniform_logging_break: (number) ->
        @u_log_break = number

    # @nodoc
    # This function makes sure that all vectors/matrices are typed arrays
    debug_uniform_type: ()->
        gl = @gl
        for p in ['uniform1fv', 'uniform2fv', 'uniform3fv', 'uniform4fv']
            gl['_'+p] = gl[p]
            gl[p] = do (p) => (l,v)->
                if not v.byteLength?
                    throw "wrong type"
                return gl["_"+p](l,v)

        for p in ['uniformMatrix3fv', 'uniformMatrix4fv']
            gl['_'+p] = gl[p]
            gl[p] = do (p) => (l,t,v)->
                if v.byteLength?
                    throw "wrong type"
                return gl["_"+p](l,t,v)
        return

    # @nodoc
    # This method allows to compare performance between few objects
    # and many object with similar total poly count.
    polycount_debug: (ratio=1)->
        total_polys = 0
        for ob in scene.children
            if ob.type == 'MESH' and ob.visible and ob.data and ob.render
                for n in ob.data.num_indices
                    total_polys += n
        inv_ratio = 1-ratio
        removed_polys = 0
        @removed_meshes = []
        for ob in scene.children
            if removed_polys/total_polys > inv_ratio
                return
            if ob.type == 'MESH' and ob.visible and ob.data and ob.render
                for n in ob.data.num_indices
                    removed_polys += n
                ob.visible = false
                scene.mesh_passes[0].remove ob
                scene.mesh_passes[1].remove ob
                @removed_meshes.push ob
        return

    # @nodoc
    # Call after using previous function.
    restore_polycount_debug: ()->
        for ob in @removed_meshes
            added_passes = []
            for pa in ob.passes
                if not added_passes[pa] and pa < 5
                    scene.mesh_passes[pa].push ob
                    added_passes[pa]=true
            ob.visible = true
        return



#Shader for debug shapes

plain_vs = """
        precision highp float;
        precision highp int;
        uniform mat4 model_view_matrix;
        uniform mat4 projection_matrix;
        attribute vec3 vertex;
        void main()
        {
            vec4 pos = projection_matrix * model_view_matrix * vec4(vertex, 1.0);
            pos.z -= 0.0005;
            gl_Position = pos;
        }"""
plain_fs = "precision mediump float;uniform vec4 color;void main(){gl_FragColor = color;}"


# Singleton instanced in {RenderManager} to draw the debug view of objects.
class Debug

    constructor: (@context)->
        @vectors = []
        if not @context.MYOU_PARAMS.debug
            return
        sin=Math.sin
        cos=Math.cos

        # Generate and save generic shapes for debug_physics
        box = new Mesh @context
        d=[1,1,1,
            1,-1,1,
            -1,-1,1,
            -1,1,1,
            1,1,-1,
            1,-1,-1,
            -1,-1,-1,
            -1,1,-1]
        box.load_from_lists(d, [0,1,1,2,2,3,3,0,4,5,5,6,6,7,7,4,
                    0,4,1,5,2,6,3,7])

        cylinder = new Mesh @context
        d=[]
        idx=[]
        a=(3.1416*2)/16
        for i in [0...16]
            d=d.concat [sin(a*i),cos(a*i),1]
            d=d.concat [sin(a*i),cos(a*i),-1]
            idx=idx.concat [i*2,(i*2+2)%32,i*2+1,(i*2+3)%32,]
            if i%2==0
                idx=idx.concat [i*2,i*2+1,]
        cylinder.load_from_lists d, idx

        sphere = new Mesh @context
        d = []
        idx = []
        for i in [0...16]
            d = d.concat sin(a*i),cos(a*i),0
            idx = idx.concat i, (i+1)%16
        for i in [0...16]
            d = d.concat 0,sin(a*i),cos(a*i)
            idx = idx.concat i+16, (i+1)%16+16
        for i in [0...16]
            d = d.concat sin(a*i),0,cos(a*i)
            idx = idx.concat i+32, (i+1)%16+32
        sphere.load_from_lists d, idx

        arrow = new Mesh @context
        d = [0,0,0,  0,0,1,  0,0.07,0.7,  0,-0.07,0.7,]
        arrow.load_from_lists d, [0,1,1,2,1,3]

        bone = new Mesh @context
        d = [0,0,0,
             -0.1, 0.1, -0.1,
              0.1, 0.1, -0.1,
              0.1, 0.1,  0.1,
             -0.1, 0.1,  0.1,
             0,1,0,1,
             ]
        bone.load_from_lists(d, [0,1,0,2,0,3,0,4,1,2,2,3,3,4,4,1,
                           5,1,5,2,5,3,5,4])

        @material = mat = new Material @context, {
            name: '_debug',
            vertex: plain_vs,
            fragment: plain_fs,
            uniforms: [{'type':5,'varname':'color'}],
        }

        for ob in [box, cylinder, sphere, arrow, bone]
            ob.elements = []
            ob.stride = 4
            ob.materials = [mat]
            ob.color = vec4.create 1,1,1,1
            ob.data.draw_method = @context.render_manager.gl.LINES
            ob.scale = [1,1,1]
            ob._update_matrices()

        @box = box
        @cylinder = cylinder
        @sphere = sphere
        @arrow = arrow
        @bone = bone

        @vectors = []

    # @private
    debug_mesh_from_va_ia: (va, ia)->
        mesh = new Mesh @context
        mesh.stride = 3*4
        mesh.offsets = [0, 0, va.length, ia.length]
        mesh.load_from_va_ia va, ia
        mesh.elements = []
        mesh.materials = [@material]
        mesh.color = vec4.create 1,1,1,1
        mesh.data.draw_method = render_manager.gl.LINES
        mesh.scale = vec3.create 1,1,1
        mesh._update_matrices()
        return mesh

# @nodoc
sort_by_mat_id = (a,b) ->
    id_a = (a.materials[0]?.id) + a._flip<<30 # boolean coerced into 1 or 0
    id_b = (b.materials[0]?.id) + b._flip<<30
    id_a - id_b

module.exports = {
    RenderManager,
    VECTOR_MINUS_Z
}
