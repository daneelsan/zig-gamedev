// This intro application shows how to load a texture image from file, generate mipmaps on the GPU
// and draw 3D textured objects.

const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const win32 = @import("win32");
const w = win32.base;
const d2d1 = win32.d2d1;
const d3d12 = win32.d3d12;
const dwrite = win32.dwrite;
const common = @import("common");
const gfx = common.graphics;
const lib = common.library;
const zm = common.zmath;
const c = common.c;

const hrPanic = lib.hrPanic;
const hrPanicOnFail = lib.hrPanicOnFail;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// We need to export below symbols for DirectX 12 Agility SDK.
pub export var D3D12SDKVersion: u32 = 4;
pub export var D3D12SDKPath: [*:0]const u8 = ".\\d3d12\\";

const window_name = "zig-gamedev: intro 4";
const window_width = 1920;
const window_height = 1080;

// By convention, we use 'Pso_' prefix for structures that are also defined in HLSL code
// (see 'DrawConst' and 'FrameConst' in intro4.hlsl).
const Pso_DrawConst = struct {
    object_to_world: [16]f32,
};

const Pso_FrameConst = struct {
    world_to_clip: [16]f32,
};

const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
    texcoord: [2]f32,
};

const DemoState = struct {
    gctx: gfx.GraphicsContext,
    guictx: gfx.GuiContext,
    frame_stats: lib.FrameStats,

    brush: *d2d1.ISolidColorBrush,
    normal_tfmt: *dwrite.ITextFormat,

    non_bindless_pso: gfx.PipelineHandle,
    bindless_pso: gfx.PipelineHandle,
    is_bindless_mode_active: bool,

    vertex_buffer: gfx.ResourceHandle,
    index_buffer: gfx.ResourceHandle,

    depth_texture: gfx.ResourceHandle,
    depth_texture_dsv: d3d12.CPU_DESCRIPTOR_HANDLE,

    mesh_num_vertices: u32,
    mesh_num_indices: u32,
    mesh_texture: gfx.ResourceHandle,
    mesh_texture_srv: d3d12.CPU_DESCRIPTOR_HANDLE,

    camera: struct {
        position: [3]f32,
        forward: [3]f32,
        pitch: f32,
        yaw: f32,
    },
    mouse: struct {
        cursor_prev_x: i32,
        cursor_prev_y: i32,
    },
};

fn init(gpa_allocator: std.mem.Allocator) DemoState {
    // Create application window and initialize dear imgui library.
    const window = lib.initWindow(gpa_allocator, window_name, window_width, window_height) catch unreachable;

    // Create temporary memory allocator for use during initialization. We pass this allocator to all
    // subsystems that need memory and then free everyting with a single deallocation.
    var arena_allocator_state = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena_allocator_state.deinit();
    const arena_allocator = arena_allocator_state.allocator();

    // Create DirectX 12 context.
    var gctx = gfx.GraphicsContext.init(window);

    // Create Direct2D brush which will be needed to display text.
    const brush = blk: {
        var brush: ?*d2d1.ISolidColorBrush = null;
        hrPanicOnFail(gctx.d2d.context.CreateSolidColorBrush(
            &.{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 0.5 },
            null,
            &brush,
        ));
        break :blk brush.?;
    };

    // Create Direct2D text format which will be needed to display text.
    const normal_tfmt = blk: {
        var info_txtfmt: ?*dwrite.ITextFormat = null;
        hrPanicOnFail(gctx.dwrite_factory.CreateTextFormat(
            L("Verdana"),
            null,
            .BOLD,
            .NORMAL,
            .NORMAL,
            32.0,
            L("en-us"),
            &info_txtfmt,
        ));
        break :blk info_txtfmt.?;
    };
    hrPanicOnFail(normal_tfmt.SetTextAlignment(.LEADING));
    hrPanicOnFail(normal_tfmt.SetParagraphAlignment(.NEAR));

    var non_bindless_pso: gfx.PipelineHandle = undefined;
    var bindless_pso: gfx.PipelineHandle = undefined;
    {
        const input_layout_desc = [_]d3d12.INPUT_ELEMENT_DESC{
            d3d12.INPUT_ELEMENT_DESC.init("POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0),
            d3d12.INPUT_ELEMENT_DESC.init("_Normal", 0, .R32G32B32_FLOAT, 0, 12, .PER_VERTEX_DATA, 0),
            d3d12.INPUT_ELEMENT_DESC.init("_Texcoord", 0, .R32G32B32_FLOAT, 0, 24, .PER_VERTEX_DATA, 0),
        };

        var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
        pso_desc.InputLayout = .{
            .pInputElementDescs = &input_layout_desc,
            .NumElements = input_layout_desc.len,
        };
        pso_desc.RTVFormats[0] = .R8G8B8A8_UNORM;
        pso_desc.NumRenderTargets = 1;
        pso_desc.DSVFormat = .D32_FLOAT;
        pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0xf;
        pso_desc.PrimitiveTopologyType = .TRIANGLE;

        non_bindless_pso = gctx.createGraphicsShaderPipeline(
            arena_allocator,
            &pso_desc,
            "content/shaders/intro4.vs.cso",
            "content/shaders/intro4.ps.cso",
        );
        bindless_pso = gctx.createGraphicsShaderPipeline(
            arena_allocator,
            &pso_desc,
            "content/shaders/intro4_bindless.vs.cso",
            "content/shaders/intro4_bindless.ps.cso",
        );
    }

    // Load a mesh from file and store the data in temporary arrays.
    var mesh_indices = std.ArrayList(u32).init(arena_allocator);
    var mesh_positions = std.ArrayList([3]f32).init(arena_allocator);
    var mesh_normals = std.ArrayList([3]f32).init(arena_allocator);
    var mesh_texcoords = std.ArrayList([2]f32).init(arena_allocator);
    {
        const data = lib.parseAndLoadGltfFile("content/SciFiHelmet/SciFiHelmet.gltf");
        defer c.cgltf_free(data);
        lib.appendMeshPrimitive(data, 0, 0, &mesh_indices, &mesh_positions, &mesh_normals, &mesh_texcoords, null);
    }
    const mesh_num_indices = @intCast(u32, mesh_indices.items.len);
    const mesh_num_vertices = @intCast(u32, mesh_positions.items.len);

    // Create vertex buffer and return a *handle* to the underlying Direct3D12 resource.
    const vertex_buffer = gctx.createCommittedResource(
        .DEFAULT,
        d3d12.HEAP_FLAG_NONE,
        &d3d12.RESOURCE_DESC.initBuffer(mesh_num_vertices * @sizeOf(Vertex)),
        d3d12.RESOURCE_STATE_COPY_DEST,
        null,
    ) catch |err| hrPanic(err);

    // Create index buffer and return a *handle* to the underlying Direct3D12 resource.
    const index_buffer = gctx.createCommittedResource(
        .DEFAULT,
        d3d12.HEAP_FLAG_NONE,
        &d3d12.RESOURCE_DESC.initBuffer(mesh_num_indices * @sizeOf(u32)),
        d3d12.RESOURCE_STATE_COPY_DEST,
        null,
    ) catch |err| hrPanic(err);

    // Create depth texture resource.
    const depth_texture = gctx.createCommittedResource(
        .DEFAULT,
        d3d12.HEAP_FLAG_NONE,
        &blk: {
            var desc = d3d12.RESOURCE_DESC.initTex2d(.D32_FLOAT, gctx.viewport_width, gctx.viewport_height, 1);
            desc.Flags = d3d12.RESOURCE_FLAG_ALLOW_DEPTH_STENCIL | d3d12.RESOURCE_FLAG_DENY_SHADER_RESOURCE;
            break :blk desc;
        },
        d3d12.RESOURCE_STATE_DEPTH_WRITE,
        &d3d12.CLEAR_VALUE.initDepthStencil(.D32_FLOAT, 1.0, 0),
    ) catch |err| hrPanic(err);

    // Create depth texture 'view' - a descriptor which can be send to Direct3D 12 API.
    const depth_texture_dsv = gctx.allocateCpuDescriptors(.DSV, 1);
    gctx.device.CreateDepthStencilView(
        gctx.getResource(depth_texture), // Get the D3D12 resource from a handle.
        null,
        depth_texture_dsv,
    );

    // Open D3D12 command list, setup descriptor heap, etc. After this call we can upload resources to the GPU,
    // draw 3D graphics etc.
    gctx.beginFrame();

    // Create and upload graphics resources for dear imgui renderer.
    var guictx = gfx.GuiContext.init(arena_allocator, &gctx, 1);

    // Create texture resource and submit GPU commands which copies texture data from CPU
    // to high-performance GPU memory where resource resides.
    const mesh_texture = gctx.createAndUploadTex2dFromFile(
        "content/SciFiHelmet/SciFiHelmet_AmbientOcclusion.png",
        .{}, // Default parameters mean that we want whole mipmap chain.
    ) catch |err| hrPanic(err);

    // Generate mipmaps for the mesh texture.
    {
        // Our generator uses fast compute shader to generate all texture levels.
        var mipgen = gfx.MipmapGenerator.init(arena_allocator, &gctx, .R8G8B8A8_UNORM);
        defer mipgen.deinit(&gctx);
        mipgen.generateMipmaps(&gctx, mesh_texture);
        gctx.finishGpuCommands(); // Wait for the GPU so that we can release the generator.
    }

    gctx.addTransitionBarrier(mesh_texture, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);

    // Non-bindless path init.
    // Allocate one (uninitialized) CPU descriptor handle that will be copied to the GPU descriptor heap
    // just before a drawcall.
    const mesh_texture_srv = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);

    // Initialize descriptor handle - after below call `mesh_texture_srv' will be a valid descriptor handle
    // which will be used to identify and interpret data stored in texture resource.
    gctx.device.CreateShaderResourceView(gctx.getResource(mesh_texture), null, mesh_texture_srv);

    // Bindless path init.
    {
        // Allocate one persistent, GPU descriptor handle. It will be allocated at slot 0 and automatically
        // available in the shader via 'ResourceDescriptorHeap' array ('ResourceDescriptorHeap[0]' in this case).
        const bindless_descriptor = gctx.allocatePersistentGpuDescriptors(1);
        gctx.device.CreateShaderResourceView(gctx.getResource(mesh_texture), null, bindless_descriptor.cpu_handle);
    }

    // Fill vertex buffer with vertex data.
    {
        // Allocate memory from upload heap and fill it with vertex data.
        const verts = gctx.allocateUploadBufferRegion(Vertex, mesh_num_vertices);
        for (mesh_positions.items) |_, i| {
            verts.cpu_slice[i].position = mesh_positions.items[i];
            verts.cpu_slice[i].normal = mesh_normals.items[i];
            verts.cpu_slice[i].texcoord = mesh_texcoords.items[i];
        }

        // Copy vertex data from upload heap to vertex buffer resource that resides in high-performance memory
        // on the GPU.
        gctx.cmdlist.CopyBufferRegion(
            gctx.getResource(vertex_buffer),
            0,
            verts.buffer,
            verts.buffer_offset,
            verts.cpu_slice.len * @sizeOf(@TypeOf(verts.cpu_slice[0])),
        );
    }

    // Fill index buffer with index data.
    {
        // Allocate memory from upload heap and fill it with index data.
        const indices = gctx.allocateUploadBufferRegion(u32, mesh_num_indices);
        for (mesh_indices.items) |_, i| {
            indices.cpu_slice[i] = mesh_indices.items[i];
        }

        // Copy index data from upload heap to index buffer resource that resides in high-performance memory
        // on the GPU.
        gctx.cmdlist.CopyBufferRegion(
            gctx.getResource(index_buffer),
            0,
            indices.buffer,
            indices.buffer_offset,
            indices.cpu_slice.len * @sizeOf(@TypeOf(indices.cpu_slice[0])),
        );
    }

    // Transition vertex and index buffers from 'copy dest' state to the state appropriate for rendering.
    gctx.addTransitionBarrier(vertex_buffer, d3d12.RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER);
    gctx.addTransitionBarrier(index_buffer, d3d12.RESOURCE_STATE_INDEX_BUFFER);
    gctx.flushResourceBarriers();

    // This will send command list to the GPU, call 'Present' and do some other bookkeeping.
    gctx.endFrame();

    // Wait for the GPU to finish all commands.
    gctx.finishGpuCommands();

    return .{
        .gctx = gctx,
        .guictx = guictx,
        .frame_stats = lib.FrameStats.init(),
        .brush = brush,
        .normal_tfmt = normal_tfmt,
        .bindless_pso = bindless_pso,
        .non_bindless_pso = non_bindless_pso,
        .is_bindless_mode_active = false,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .depth_texture = depth_texture,
        .depth_texture_dsv = depth_texture_dsv,
        .mesh_num_vertices = mesh_num_vertices,
        .mesh_num_indices = mesh_num_indices,
        .mesh_texture = mesh_texture,
        .mesh_texture_srv = mesh_texture_srv,
        .camera = .{
            .position = [3]f32{ 0.0, 5.0, -5.0 },
            .forward = [3]f32{ 0.0, 0.0, 1.0 },
            .pitch = 0.175 * math.pi,
            .yaw = 0.0,
        },
        .mouse = .{
            .cursor_prev_x = 0,
            .cursor_prev_y = 0,
        },
    };
}

fn deinit(demo: *DemoState, gpa_allocator: std.mem.Allocator) void {
    demo.gctx.finishGpuCommands();
    _ = demo.gctx.releaseResource(demo.mesh_texture);
    _ = demo.gctx.releaseResource(demo.depth_texture);
    _ = demo.gctx.releaseResource(demo.vertex_buffer);
    _ = demo.gctx.releaseResource(demo.index_buffer);
    _ = demo.gctx.releasePipeline(demo.non_bindless_pso);
    _ = demo.gctx.releasePipeline(demo.bindless_pso);
    _ = demo.brush.Release();
    _ = demo.normal_tfmt.Release();
    demo.guictx.deinit(&demo.gctx);
    demo.gctx.deinit();
    lib.deinitWindow(gpa_allocator);
    demo.* = undefined;
}

fn update(demo: *DemoState) void {
    // Update frame counter and fps stats.
    demo.frame_stats.update();
    const dt = demo.frame_stats.delta_time;

    // Update dear imgui lib. After this call we can define our widgets.
    lib.newImGuiFrame(dt);

    c.igSetNextWindowPos(
        c.ImVec2{ .x = @intToFloat(f32, demo.gctx.viewport_width) - 600.0 - 20, .y = 20.0 },
        c.ImGuiCond_FirstUseEver,
        c.ImVec2{ .x = 0.0, .y = 0.0 },
    );
    c.igSetNextWindowSize(.{ .x = 600.0, .y = -1 }, c.ImGuiCond_Always);

    _ = c.igBegin(
        "Demo Settings",
        null,
        c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoSavedSettings,
    );
    c.igBulletText("", "");
    c.igSameLine(0, -1);
    c.igTextColored(.{ .x = 0, .y = 0.8, .z = 0, .w = 1 }, "Right Mouse Button + Drag", "");
    c.igSameLine(0, -1);
    c.igText(" :  rotate camera", "");

    c.igBulletText("", "");
    c.igSameLine(0, -1);
    c.igTextColored(.{ .x = 0, .y = 0.8, .z = 0, .w = 1 }, "W, A, S, D", "");
    c.igSameLine(0, -1);
    c.igText(" :  move camera", "");

    _ = c.igCheckbox("Use bindless texture", &demo.is_bindless_mode_active);

    c.igEnd();

    // Handle camera rotation with mouse.
    {
        var pos: w.POINT = undefined;
        _ = w.GetCursorPos(&pos);
        const delta_x = @intToFloat(f32, pos.x) - @intToFloat(f32, demo.mouse.cursor_prev_x);
        const delta_y = @intToFloat(f32, pos.y) - @intToFloat(f32, demo.mouse.cursor_prev_y);
        demo.mouse.cursor_prev_x = pos.x;
        demo.mouse.cursor_prev_y = pos.y;

        if (w.GetAsyncKeyState(w.VK_RBUTTON) < 0) {
            demo.camera.pitch += 0.0025 * delta_y;
            demo.camera.yaw += 0.0025 * delta_x;
            demo.camera.pitch = math.min(demo.camera.pitch, 0.48 * math.pi);
            demo.camera.pitch = math.max(demo.camera.pitch, -0.48 * math.pi);
            demo.camera.yaw = zm.modAngle(demo.camera.yaw);
        }
    }

    // Handle camera movement with 'WASD' keys.
    {
        const speed = zm.f32x4s(10.0);
        const delta_time = zm.f32x4s(demo.frame_stats.delta_time);
        const transform = zm.mul(zm.rotationX(demo.camera.pitch), zm.rotationY(demo.camera.yaw));
        var forward = zm.normalize3(zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), transform));

        zm.store(demo.camera.forward[0..], forward, 3);

        const right = speed * delta_time * zm.normalize3(zm.cross3(zm.f32x4(0.0, 1.0, 0.0, 0.0), forward));
        forward = speed * delta_time * forward;

        // Load camera position from memory to SIMD register ('3' means that we want to load three components).
        var cpos = zm.load(demo.camera.position[0..], zm.Vec, 3);

        if (w.GetAsyncKeyState('W') < 0) {
            cpos += forward;
        } else if (w.GetAsyncKeyState('S') < 0) {
            cpos -= forward;
        }
        if (w.GetAsyncKeyState('D') < 0) {
            cpos += right;
        } else if (w.GetAsyncKeyState('A') < 0) {
            cpos -= right;
        }

        // Copy updated position from SIMD register to memory.
        zm.store(demo.camera.position[0..], cpos, 3);
    }
}

fn draw(demo: *DemoState) void {
    var gctx = &demo.gctx;

    const cam_world_to_view = zm.lookToLh(
        zm.load(demo.camera.position[0..], zm.Vec, 3),
        zm.load(demo.camera.forward[0..], zm.Vec, 3),
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );
    const cam_view_to_clip = zm.perspectiveFovLh(
        0.25 * math.pi,
        @intToFloat(f32, gctx.viewport_width) / @intToFloat(f32, gctx.viewport_height),
        0.01,
        200.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    // Begin DirectX 12 rendering.
    gctx.beginFrame();

    // Get current back buffer resource and transition it to 'render target' state.
    const back_buffer = gctx.getBackBuffer();
    gctx.addTransitionBarrier(back_buffer.resource_handle, d3d12.RESOURCE_STATE_RENDER_TARGET);
    gctx.flushResourceBarriers();

    gctx.cmdlist.OMSetRenderTargets(
        1,
        &[_]d3d12.CPU_DESCRIPTOR_HANDLE{back_buffer.descriptor_handle},
        w.TRUE,
        &demo.depth_texture_dsv,
    );
    gctx.cmdlist.ClearRenderTargetView(
        back_buffer.descriptor_handle,
        &[4]f32{ 0.2, 0.2, 0.2, 1.0 },
        0,
        null,
    );
    gctx.cmdlist.ClearDepthStencilView(demo.depth_texture_dsv, d3d12.CLEAR_FLAG_DEPTH, 1.0, 0, 0, null);

    if (demo.is_bindless_mode_active)
        gctx.setCurrentPipeline(demo.bindless_pso)
    else
        gctx.setCurrentPipeline(demo.non_bindless_pso);

    gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);
    gctx.cmdlist.IASetVertexBuffers(0, 1, &[_]d3d12.VERTEX_BUFFER_VIEW{.{
        .BufferLocation = gctx.getResource(demo.vertex_buffer).GetGPUVirtualAddress(),
        .SizeInBytes = demo.mesh_num_vertices * @sizeOf(Vertex),
        .StrideInBytes = @sizeOf(Vertex),
    }});
    gctx.cmdlist.IASetIndexBuffer(&.{
        .BufferLocation = gctx.getResource(demo.index_buffer).GetGPUVirtualAddress(),
        .SizeInBytes = demo.mesh_num_indices * @sizeOf(u32),
        .Format = .R32_UINT,
    });

    if (!demo.is_bindless_mode_active) {
        // Bind mesh texture (copy CPU descriptor handle to GPU descriptor heap).
        gctx.cmdlist.SetGraphicsRootDescriptorTable(
            2, // Slot index 2 in Root Signature (SRV(t0), see intro4.hlsl)
            gctx.copyDescriptorsToGpuHeap(1, demo.mesh_texture_srv),
        );
    }

    // Upload per-frame constant data (camera xform).
    {
        // Allocate memory for one instance of Pso_FrameConst structure.
        const mem = gctx.allocateUploadMemory(Pso_FrameConst, 1);

        // Copy 'cam_world_to_clip' matrix to upload memory. We need to transpose it because
        // HLSL uses column-major matrices by default (zmath uses row-major matrices).
        zm.storeF32x4x4(mem.cpu_slice[0].world_to_clip[0..], zm.transpose(cam_world_to_clip));

        // Set GPU handle of our allocated memory region so that it is visible to the shader.
        gctx.cmdlist.SetGraphicsRootConstantBufferView(
            1, // Slot index 1 in Root Signature (CBV(b1), see intro4.hlsl)
            mem.gpu_base,
        );
    }

    // For each object, upload per-draw constant data (object to world xform) and draw.
    {
        var z: f32 = -9.0;
        while (z <= 9.0) : (z += 3.0) {
            var x: f32 = -9.0;
            while (x <= 9.0) : (x += 3.0) {
                // Compute translation matrix.
                const object_to_world = zm.translation(x, 0.0, z);

                // Allocate memory for one instance of Pso_DrawConst structure.
                const mem = gctx.allocateUploadMemory(Pso_DrawConst, 1);

                // Copy 'object_to_world' matrix to upload memory. We need to transpose it because
                // HLSL uses column-major matrices by default (zmath uses row-major matrices).
                zm.storeF32x4x4(mem.cpu_slice[0].object_to_world[0..], zm.transpose(object_to_world));

                // Set GPU handle of our allocated memory region so that it is visible to the shader.
                gctx.cmdlist.SetGraphicsRootConstantBufferView(
                    0, // Slot index 0 in Root Signature (CBV(b0), see intro4.hlsl)
                    mem.gpu_base,
                );

                gctx.cmdlist.DrawIndexedInstanced(demo.mesh_num_indices, 1, 0, 0, 0);
            }
        }
    }

    // Draw dear imgui widgets.
    demo.guictx.draw(gctx);

    // Begin Direct2D rendering to the back buffer.
    gctx.beginDraw2d();
    {
        // Display average fps and frame time.

        const stats = &demo.frame_stats;
        var buffer = [_]u8{0} ** 64;
        const text = std.fmt.bufPrint(
            buffer[0..],
            "FPS: {d:.1}\nCPU time: {d:.3} ms",
            .{ stats.fps, stats.average_cpu_time },
        ) catch unreachable;

        demo.brush.SetColor(&.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        lib.drawText(
            gctx.d2d.context,
            text,
            demo.normal_tfmt,
            &d2d1.RECT_F{
                .left = 10.0,
                .top = 10.0,
                .right = @intToFloat(f32, gctx.viewport_width),
                .bottom = @intToFloat(f32, gctx.viewport_height),
            },
            @ptrCast(*d2d1.IBrush, demo.brush),
        );
    }
    // End Direct2D rendering and transition back buffer to 'present' state.
    gctx.endDraw2d();

    // Call 'Present' and prepare for the next frame.
    gctx.endFrame();
}

pub fn main() !void {
    // Initialize some low-level Windows stuff (DPI awarness, COM), check Windows version and also check
    // if DirectX 12 Agility SDK is supported.
    lib.init();
    defer lib.deinit();

    // Create main memory allocator for our application.
    var gpa_allocator_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_allocator_state.deinit();
        std.debug.assert(leaked == false);
    }
    const gpa_allocator = gpa_allocator_state.allocator();

    var demo = init(gpa_allocator);
    defer deinit(&demo, gpa_allocator);

    while (true) {
        var message = std.mem.zeroes(w.user32.MSG);
        const has_message = w.user32.peekMessageA(&message, null, 0, 0, w.user32.PM_REMOVE) catch false;
        if (has_message) {
            _ = w.user32.translateMessage(&message);
            _ = w.user32.dispatchMessageA(&message);
            if (message.message == w.user32.WM_QUIT) {
                break;
            }
        } else {
            update(&demo);
            draw(&demo);
        }
    }
}
