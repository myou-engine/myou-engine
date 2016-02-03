{vec2} = require 'gl-matrix'
tmpv1 = vec2.create()
tmpv2 = vec2.create()
class Events
    # All are just 1 or 0
    keys_pressed: new Uint8Array 256
    keys_just_pressed: new Uint8Array 256
    keys_just_released: new Uint8Array 256
    keys_pressed_count: 0
    NO_MOVE_TICKS: 3

    mouse:
        # mouse x and y are relative to the app root element
        # and they can be negative or out of the element when
        # there's a button pressed
        x: 0
        y: 0
        # rel_x and rel_y is the difference from the last frame
        # both when the pointer is unlocked and locked
        rel_x: 0
        rel_y: 0
        page_x: 0
        page_y: 0
        movement_since_mousedown: 0
        move_events_since_mousedown: 0
        left: false
        middle: false
        right: false
        any_button: false
        wheel: 0
        # You can assign cancel_wheel = true to prevent the
        # mouse wheel from scrolling
        cancel_wheel: false
        target: null
        # Target element on mousedown
        down_target: null
        lock_element: false

    touch: {
        #touch events is a list of the captured touch events
        touch_events:[]
        #number of current touches
        touches:0
        # 2 finger gestures
        pos1: vec2.create()
        pos2: vec2.create()

        #pinch (zoom) gesture
        pinch:null
        rel_pinch:0

        #rotation gesture
        rot:null
        rel_rot:0
    }

    #This function returns only the non undefined touch events
    get_touch_events: ->
        touch_events = []
        for t in @touch.touch_events
            if t? and t.touching
                touch_events.push(t)

        return touch_events

    # This function sets a set of generic event handlers
    # for keyboard, mouse, touch... to be used by game logic
    # without having to add one listener per key or button
    constructor: (root_element)->
        # The root_element is used on mousedown
        # and mousemove when no button is pressed
        # while the window is used on mouseup
        # and mousemove when a button is pressed
        # This way you can drag the mouse out of the window and
        # it keeps working until you release.

        keydown = (event)=>
            ae = document.activeElement
            code = event.keyCode
            # F12 is kept pressed after opening the debug console
            if ae.value? or ae.isContentEditable or code==123
                return
            jp = @keys_just_pressed[code] = @keys_pressed[code] ^ 1
            @keys_pressed[code] = 1
            @keys_pressed_count += jp
            if code == 116 # F5
                # workaround for chrome, reload ends up eating a lot of memory
                location.href = location.href
                event.preventDefault()
        document.body.addEventListener 'keydown', keydown, false

        keyup = (event)=>
            ae = document.activeElement
            code = event.keyCode
            if ae.value? or ae.isContentEditable or code==123
                return
            @keys_pressed[code] = 0
            @keys_just_released[code] = 1
            @keys_pressed_count -= 1
        document.body.addEventListener 'keyup', keyup, false

        touch_start = (event)=>
            event.preventDefault()
            for t in event.touches
                touch = {}
                touch.touching = true
                touch.id = t.identifier
                touch.page_x = t.pageX
                touch.page_y = t.pageY
                touch.force = t.force
                touch.radius_x = t.radiusX
                touch.radius_y = t.radiusY
                touch.rotation_angle = t.rotationAngle
                touch.x = t.pageX - root_element.rect.left
                touch.y = t.pageY - root_element.rect.top
                touch.rel_x = 0
                touch.rel_y = 0
                touch.movement_since_touch = 0
                touch.touch_target = touch.target = t.target
                @touch.touch_events[touch.id] = touch
            @touch.touches = event.touches.length

            #Reseting 2 finger gestures
            if @touch.touches < 2
                @touch.pos1[0] = 0
                @touch.pos1[1] = 0
                @touch.pos2[0] = 0
                @touch.pos2[1] = 0

                @touch.pinch = null
                @touch.rel_pinch = 0
                @touch.rot = null
                @touch.rel_rot = 0

        root_element.addEventListener 'touchstart', touch_start, false

        touch_end = (event)=>
            event.preventDefault()
            for t in event.touches
                touch = @touch.touch_events[t.identifier]
                touch.touching = 0
                touch.force = 0
                touch.radius_x = 0
                touch.radius_y = 0
                touch.rel_x = 0
                touch.rel_y = 0
            @touch.touches = event.touches.length

            #Reseting 2 finger gestures
            if @touch.touches < 2
                @touch.pos1[0] = 0
                @touch.pos1[1] = 0
                @touch.pos2[0] = 0
                @touch.pos2[1] = 0

                @touch.pinch = null
                @touch.rel_pinch = 0
                @touch.rotation = null
                @touch.rel_rotation = 0

        root_element.addEventListener 'touchend', touch_end, false

        touch_move = (event)=>
            event.preventDefault()

            for t in event.touches
                touch = {}
                touch.id = t.identifier
                touch.touching = true
                touch.page_x = t.pageX
                touch.page_y = t.pageY
                touch.force = t.force
                touch.radius_x = t.radiusX
                touch.radius_y = t.radiusY
                touch.rotation_angle = t.rotationAngle
                touch.x = t.pageX - root_element.rect.left
                touch.y = t.pageY - root_element.rect.top
                x = t.pageX
                y = t.pageY
                if @touch.touch_events[touch.id]?
                    touch.rel_x = x - @touch.touch_events[touch.id].page_x
                    touch.rel_y = y - @touch.touch_events[touch.id].page_y
                else
                    touch.rel_x = 0
                    touch.rel_y = 0
                touch.movement_since_touch = Math.abs(touch.rel_x) + Math.abs(touch.rel_y)
                @touch.touch_events[touch.id] = touch
            @touch.touches = event.touches.length


            #2 finger gestures
            if @touch.touches > 1
                touch_events = @get_touch_events()[...2]
                pos1 = @touch.pos1
                pos2 = @touch.pos2
                pos1[0] = touch_events[0].x
                pos1[1] = touch_events[0].y
                pos2[0] = touch_events[1].x
                pos2[1] = touch_events[1].y

                #pinch
                pinch = vec2.dist(pos1,pos2)

                #If last_pinch is null the rel_pinch must be 0
                last_pinch = if @touch.pinch? then @touch.pinch else pinch
                @touch.rel_pinch = pinch - last_pinch
                @touch.pinch = pinch

                #rot
                r = tmpv1
                vec2.sub(r, pos2, pos1)

                if r[0] > 0
                    if r[1] > 0 # +X+Y
                        rot = Math.atan(r[1]/ r[0])
                    else # +X-Y
                        rot = Math.atan(r[1]/ r[0]) + PI_2
                else if r[0] < 0 # -X
                    rot = Math.atan(r[1]/ r[0]) + Math.PI

                #If last_rot is null the rel_rot must be 0
                last_rot = if @touch.rot? then @touch.rot else rot

                @touch.rel_rot = rot - last_rot

                #Avoid rotation jump when the rotation completes a circle.
                if @touch.rel_rot > 0.9 * PI_2
                    @touch.rel_rot = @touch.rel_rot - PI_2

                @touch.rot = rot

            else
                #Reseting 2 finger gestures
                @touch.pos1[0] = 0
                @touch.pos1[1] = 0
                @touch.pos2[0] = 0
                @touch.pos2[1] = 0

                @touch.pinch = null
                @touch.rel_pinch = 0
                @touch.rot = null
                @touch.rel_rot = 0



        root_element.addEventListener 'touchmove', touch_move, false


        mouse = @mouse
        mousedown = (event)->
            event.preventDefault()
            mouse[['left', 'middle', 'right'][event.button]] = true
            mouse.any_button = true
            mouse.page_x = event.pageX
            mouse.page_y = event.pageY
            x = event.layerX
            y = event.layerY
            p = event.target
            while p != root_element
                x += p.offsetLeft
                y += p.offsetTop
                p = p.offsetParent
            mouse.x = x
            mouse.y = y
            mouse.rel_x = 0
            mouse.rel_y = 0
            mouse.movement_since_mousedown = 0
            mouse.move_events_since_mousedown = 0
            mouse.down_target = mouse.target = event.target
        root_element.addEventListener 'mousedown', mousedown, false

        contextmenu = (event)->
            event.preventDefault()
        root_element.addEventListener 'contextmenu', contextmenu, false

        # This mousemove is only used when no button is pressed
        mousemove = (event)->
            if mouse.any_button
                return
            event.preventDefault()
            x = event.pageX
            y = event.pageY
            rel_x = x - mouse.page_x
            rel_y = y - mouse.page_y
            mouse.page_x = x
            mouse.page_y = y
            mouse.rel_x += rel_x
            mouse.rel_y += rel_y
            mouse.x += rel_x
            mouse.y += rel_y
            mouse.target = event.target
        root_element.addEventListener 'mousemove', mousemove, false

    # But this mousemove is only used when a button is pressed
        mousemove_pressed = (event)->
            if not mouse.any_button or mouse.lock_element
                return
            event.preventDefault()
            x = event.pageX
            y = event.pageY
            rel_x = x - mouse.page_x
            rel_y = y - mouse.page_y
            mouse.move_events_since_mousedown += 1
            if mouse.move_events_since_mousedown < @NO_MOVE_TICKS
                return
            mouse.page_x = x
            mouse.page_y = y
            mouse.rel_x += rel_x
            mouse.rel_y += rel_y
            mouse.x += rel_x
            mouse.y += rel_y
            mouse.target = event.target
            mouse.movement_since_mousedown += Math.abs(rel_x) + Math.abs(rel_y)
        window.addEventListener 'mousemove', mousemove_pressed, false

        mouseup = (event)->
            if not mouse.any_button
                return
            event.preventDefault()
            mouse[['left', 'middle', 'right'][event.button]] = false
            mouse.any_button = mouse.left or mouse.middle or mouse.right
            x = event.pageX
            y = event.pageY
            rel_x = x - mouse.page_x
            rel_y = y - mouse.page_y
            mouse.page_x = x
            mouse.page_y = y
            mouse.rel_x += rel_x
            mouse.rel_y += rel_y
            mouse.x += rel_x
            mouse.y += rel_y
            mouse.target = event.target
        window.addEventListener 'mouseup', mouseup, false

        wheel = (event)->
            # this value will eventually be normalized to be pixels or heights
            # until then, we'll have 1 or -1
            mouse.wheel += Math.max(-1, Math.min(1, event.deltaY))
            if mouse.cancel_wheel
                event.preventDefault()
        root_element.addEventListener 'wheel', wheel, false

        locked_mousemove = (event)->
            rel_x = event.mozMovementX or event.webkitMovementX or event.movementX or 0
            rel_y = event.mozMovementY or event.webkitMovementY or event.movementY or 0
            mouse.move_events_since_mousedown += 1
            if mouse.move_events_since_mousedown < NO_MOVE_TICKS
                return
            mouse.rel_x += rel_x
            mouse.rel_y += rel_y
            mouse.movement_since_mousedown += Math.abs(rel_x) + Math.abs(rel_y)

        pointerlockchange = (event)->
            if mouse.lock_element
                mouse.lock_element.removeEventListener 'mousemove', locked_mousemove
            e = (document.mozPointerLockElement or
                document.webkitPointerLockElement or
                document.pointerLockElement)
            if e
                mouse.lock_element = e
                e.addEventListener 'mousemove', locked_mousemove
            mouse.rel_x = mouse.rel_y = 0

        document.addEventListener 'pointerlockchange', pointerlockchange
        document.addEventListener 'mozpointerlockchange', pointerlockchange
        document.addEventListener 'webkitpointerlockchange', pointerlockchange


    _empty_key_array = new Uint8Array 256

    reset_frame_events: ->
        @keys_just_pressed.set _empty_key_array
        @keys_just_released.set _empty_key_array
        @mouse.rel_x = 0
        @mouse.rel_y = 0
        @mouse.wheel = 0

module.exports = {Events}
