{vec2, vec3, quat} = require 'vmath'
{DebugCamera} = require './debug_camera'

# A viewport is a portion of the screen/canvas associated with a camera,
# with a specific size. Usually there's only one viewport covering the whole
# screen/canvas.
#
# Typically there's only a single viewport occupying the whole canvas.
#
# Created with `screen.add_viewport(camera)`` or automatically on first load
# of a scene with active camera.
# Available at `screen.viewports`.
class Viewport

    constructor: (@context, @screen, @camera)->
        @rect = [0,0,1,1]
        @rect_pix = [0,0,0,0]
        @left = @bottom = @width = @height = 0
        @effects = []
        @effects_by_id = {}
        @clear_bits = 0
        @eye_shift = vec3.create()
        @right_eye_factor = 0
        @custom_fov = null
        @debug_camera = null
        @units_to_pixels = 100
        @_v = vec3.create()
        @requires_float_buffers = false
        @last_filter_should_blend = false
        @set_clear true, true
        @recalc_aspect()

    # @private
    # Recalculates viewport rects and camera aspect ratio.
    # Used in `screen.resize` and `screen.resize_soft`
    recalc_aspect: (is_soft) ->
        [x,y,w,h] = @rect
        {size_x, size_y} = @screen.framebuffer
        @left = size_x * x
        @bottom = size_y * y
        @width = size_x * w
        @height = size_y * h
        # TODO: Warn if several viewports with different ratios have same camera
        @camera.aspect_ratio = @width/@height
        @camera.update_projection()
        if @debug_camera?
            @debug_camera.aspect_ratio = @width/@height
            @debug_camera.update_projection()
        @rect_pix = [@left, @bottom, @width, @height]
        v = vec3.set @_v, 1,0,-1
        vec3.transformMat4 v, v, (@debug_camera ? @camera).projection_matrix
        @units_to_pixels = v.x * @width
        @pixels_to_units = 1/@units_to_pixels
        if not is_soft
            for effect in @effects
                effect.on_viewport_update this
        return

    # Sets whether color and depth buffers will be cleared
    # before rendering.
    # @param color [Boolean]
    #       Whether to clear color with `scene.background_color`.
    # @param depth [Boolean] Whether to clear depth buffer.
    set_clear: (color, depth)->
        c = if color then 16384 else 0 # GL_COLOR_BUFFER_BIT
        c |= if depth then 256 else 0 # GL_DEPTH_BUFFER_BIT
        @clear_bits = c

    # Clones the viewport and adds it to the screen.
    # Note that it will be rendering over the same area unless rect is changed.
    # @return {Viewport}
    clone: (options={}) ->
        {
            copy_effects=true
            copy_behaviours=true
        } = options
        v = @screen.add_viewport @camera
        v.rect = @rect[...]
        if copy_effects
            v.effects = @effects[...]
            v.effects_by_id = Object.create @effects_by_id
        if copy_behaviours
            for behaviour in @context.behaviours
                if this in behaviour.viewports and
                        behaviour != @debug_camera_behaviour
                    # TODO: should we add and use behaviour.add_viewport()?
                    behaviour.viewports.push v
                    if behaviour._real_viewports != behaviour.viewports
                        behaviour._real_viewports.push v
        return v

    # Returns size of viewport in pixels.
    # @return [vec2]
    get_size_px: ->
        return vec2.new @width, @height

    destroy: ->
        @clear_effects()
        idx = @screen.viewports.indexOf @
        if idx != -1
            @screen.viewports.splice idx, 1
        for behaviour in @context.behaviours
            idx = behaviour.viewports.indexOf @
            if idx != -1
                behaviour.viewports.splice idx, 1
        return

    # Add effect at the end of the stack
    add_effect: (effect) ->
        effect.on_viewport_update this
        @effects.push effect
        @effects_by_id[effect.id] = effect
        @_check_requires_float_buffers()
        return effect

    # Insert an effect at the specified index of the stack
    insert_effect: (index, effect) ->
        effect.on_viewport_update this
        @effects.splice index, 0, effect
        @effects_by_id[effect.id] = effect
        @_check_requires_float_buffers()
        return effect

    replace_effect: (before, after) ->
        index = @remove_effect(before)
        if index != -1
            @insert_effect(index, after)
        else
            @add_effect(after)

    # Remove an effect from the stack
    remove_effect: (index_or_effect)->
        index = index_or_effect
        if typeof index != 'number'
            index = @effects.indexOf index_or_effect
        if index != -1
            @effects.splice(index, 1)[0].on_viewport_remove?()
        @_check_requires_float_buffers()
        return index

    clear_effects: ->
        for effect in @effects
            effect.on_viewport_remove?()
        @_check_requires_float_buffers()
        @effects.splice 0
        return this

    ensure_shared_effect: (effect_class, a, b, c, d) ->
        for effect in @effects
            if effect.constructor == effect_class
                return effect
        return @insert_effect 0, new effect_class @context, a, b, c, d

    # Splits the viewport into two, side by side, by converting this to
    # the left one, and returning the right one.
    split_left_right: (options) ->
        @rect[2] *= .5
        v2 = @clone(options)
        v2.rect[0] += @rect[2]
        @recalc_aspect()
        v2.recalc_aspect()
        return v2

    # Splits the viewport into two, over/under, by converting this to
    # the top one, and returning the bottom one.
    split_top_bottom: (options) ->
        @rect[3] *= .5
        v2 = @clone(options)
        v2.rect[1] += @rect[3]
        @recalc_aspect()
        v2.recalc_aspect()
        return v2

    enable_debug_camera: ->
        if not @debug_camera_behaviour?
            @debug_camera_behaviour = new DebugCamera @camera.scene,
                viewports: [this]
            return true
        return false

    disable_debug_camera: ->
        if @debug_camera_behaviour?
            @debug_camera_behaviour.disable()
            @debug_camera_behaviour = null
            return true
        return false

    store_debug_camera: (name) ->
        if not @debug_camera_behaviour?
            throw Error "There is no debug camera."
        if not name?
            throw Error "Name argument is mandatory."
        {position, rotation} = @debug_camera
        localStorage[name] = JSON.stringify {position, rotation}

    load_debug_camera: (name) ->
        @enable_debug_camera()
        {position, rotation} = JSON.parse localStorage[name]
        vec3.set @debug_camera.position, position...
        quat.set @debug_camera.rotation, rotation...

    get_viewport_coordinates: (x, y) ->
        x -= @left
        y = @screen.height - y
        y = @screen.height - (y - @bottom)
        return {x, y}

    _check_requires_float_buffers: ->
        @requires_float_buffers = false
        for effect in @effects
            if effect.requires_float_source or effect.requires_float_destination
                @requires_float_buffers = true
                return
        return


module.exports = {Viewport}
