
fetch = window.myou_fetch ? window.fetch

fetch_promises = {}  # {file_name: promise}

## Uncomment this to find out why a politician lies
# Promise._all = Promise._all or Promise.all
# Promise.all = (list) ->
#     for l in list
#         if not l
#             debugger
#     politician = Promise._all list
#     politician.list = list
#     politician

# Load a mesh of a mesh type object, return a promise
fetch_mesh = (mesh_object, options={}) ->
    {max_mesh_lod=1} = options
    promise = new Promise (resolve, reject) ->
        if mesh_object.type != 'MESH'
            reject 'object is not a mesh'
        {context} = mesh_object
        file_name = mesh_object.packed_file or mesh_object.hash

        # Load LoD
        lod_promises = []
        lod_objects = mesh_object.lod_objects
        smallest_lod = lod_objects[0]
        if smallest_lod
            max_mesh_lod = Math.max max_mesh_lod, smallest_lod.factor
        for lod_ob in lod_objects
            if lod_ob.factor <= max_mesh_lod
                lod_promises.push fetch_mesh(lod_ob.object)

        # Not load self if only lower LoDs were loaded, or it was already loaded
        if (max_mesh_lod < 1 and lod_promises.length != 0) or mesh_object.data
            return resolve Promise.all(lod_promises)

        fetch_promise = if file_name of fetch_promises
            fetch_promises[file_name]
        else
            embed_mesh = context.embed_meshes[mesh_object.hash]
            if embed_mesh?
                buffer = (new Uint32Array(embed_mesh.int_list)).buffer
                embed_mesh.int_list = null # No longer needed, free space
                console.log 'loaded as int list'
                Promise.resolve(buffer)
            else
                base = mesh_object.scene.data_dir + '/scenes/'
                uri = base + mesh_object.source_scene_name + "/#{file_name}.mesh"
                fetch(uri).then (response)->
                    if not response.ok
                        return Promise.reject "Mesh '#{mesh_object.name}'
                            could not be loaded from URL '#{uri}' with error
                            '#{response.status} #{response.statusText}'"
                    response.arrayBuffer()


        fetch_promises[file_name] = fetch_promise

        fetch_promise.then (data) ->
            mesh_data = context.mesh_datas[mesh_object.hash]

            offset = 0
            if data.buffer? and data.byteOffset?
                # this is a node Buffer or a Uint8Array,
                # only in node or electron
                offset = data.byteOffset
                data = data.buffer
            mesh_object.load_from_arraybuffer data, offset
            if mesh_object.pending_bodies.length != 0
                context.main_loop.add_frame_callback ->
                    for body in mesh_object.pending_bodies
                        body.instance()
                    mesh_object.pending_bodies.splice 0
                    resolve(mesh_object)
            else
                resolve(mesh_object)
            return
        .catch (e) ->
            reject e
        return
    promise.mesh_object = mesh_object
    return promise

# @nodoc
# This returns a promise of all things necessary to display the object
# (meshes, textures, materials)
# See scene.load_objects etc
fetch_objects = (object_list, options={}) ->
    if not object_list.length
        return Promise.resolve()

    promises = []
    for ob in object_list
        if ob.type == 'MESH'
            if not ob.data
                promises.push fetch_mesh(ob, options)
            for mat in ob.materials
                promises.push mat.load(options)
        # TODO: Options to not instance some, or to reuse cube maps etc.
        ob.instance_probes()
    Promise.all promises

module.exports = {
    fetch_mesh, fetch_objects
}
