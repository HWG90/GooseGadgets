-- Build-specific native camera contract. RVAs are relative to game.dll.
-- tools/trace_native.py verifies these bytes against a supplied offline dump.
return {
    timestamp = 0x6AB3B43F,
    image_size = 0x4744000,
    globals = {
        camera = 0x346D560,
        controller = 0x347CE70,
        world = 0x346BF98,
        player = 0x3326468,
        avatar = 0x3326D20,
        wield = 0x3326420,
        weapons = 0x3326CE0,
    },
    functions = {
        -- Wrapper replaces RCX, but forwards EDX/R8D: pass (nil, avatar, weapon).
        enter = 0x127DDB0,
        exit = 0x127E9D0,
        allowed = 0x12B2D20,
    },
    alignment = {
        abi = 1,
        library = 'native/native_ads_alignment_0_1_5.dll',
        duration_ms = 10500,
        executable = {
            name = 'helldivers2.exe', timestamp = 0x6AB382E4, image_size = 0x39E8000,
            unit_registry = 0x1A100F0,
        },
        -- These call instructions stay intact: the native helper filters only
        -- the leased unit and these two callers, forwarding every other call.
        position_return = 0x12887CD,
        rotation_return = 0x12887ED,
    },
    pose = {
        -- Native validation owns this captured rig contract: branch5/9B115563
        -- contains l_hand(13), r_hand(34), weapon attachment8; camera50 is a
        -- sibling under root4. Its copied local vector cannot move that camera.
        abi = 2,
        library = 'native/native_ads_editor_0_1_43.dll',
        duration_ms = 30500,
        blend_ms = 150,
        -- Arms/weapon branch parent coordinates; screen-right/down remains live QA.
        offset_x = 0.15,
        offset_y = 0,
        offset_z = -0.12,
        executable = {
            name = 'helldivers2.exe', timestamp = 0x6AB382E4, image_size = 0x39E8000,
            unit_registry = 0x1A100F0,
        },
    },
    fov = {
        abi = 1,
        library = 'native/native_ads_fov_0_1_23.dll',
        executable = { name = 'helldivers2.exe', timestamp = 0x6AB382E4, image_size = 0x39E8000 },
    },
    blur = {abi=1,library='native/native_ads_blur_0_1_16.dll'},
    motion = {
        world_pose = {rva=0x1FD220,hex='40534883ec204863dae89206eaff488bc84c8b0041ff90e8000000488bcb48c1e10648034828488bc14883c4205bc3cc'},
    },
    camera = {
        abi=1,library='native/native_ads_camera_0_1_48.dll',
        forward=.18,up=.04,smoothing_ms=100,blend_ms=120,max_gap_ms=250,
        executable={name='helldivers2.exe',timestamp=0x6AB382E4,image_size=0x39E8000},
    },
    -- Optional manual diagnostic only: the paired native exit body event.
    -- Event semantics and its effect on the held weapon pose remain unproven.
    body_pose = {
        event = 0x372071D0,
        unit_api_global = 0x3326308,
        api_offset = 0x18,
        exists_offset = 0x350,
        trigger_offset = 0x370,
        executable = {
            name = 'helldivers2.exe', timestamp = 0x6AB382E4, image_size = 0x39E8000,
            exists = { rva = 0x201710, hex = '48895c2408574883ec208bfae89fc1e9ff488bc8488bd84c8b0041ff90b00100' },
            trigger = { rva = 0x201900, hex = '48895c2408574883ec208bda8bf9e8adbfe9ff448bc38bd7488b4818488b5c24' },
        },
    },
    checks = {
        {name = "enter_wrapper", rva = 0x127DDB0, hex = "40534883ec20488b1da3f71e02488bcbe85b0000008b83fc0100003983f80100007509488d93001f"},
        {name = "constructor", rva = 0x127DE20, hex = "4055535657488dac2478ffffff4881ec88010000488b05d5e13b014833c4488945500f57c033c041"},
        {name = "exit", rva = 0x127E9D0, hex = "405541544156488dac24d0feffff4881ec30020000488b0524d63b014833c4488945708b81fc0100"},
        {name = "evaluator", rva = 0x1286330, hex = "48895c24205556574154415541564157488dac24f0fcffff4881ec10040000440f299c24b0030000"},
        {name = "controller_enter", rva = 0x12B29B0, hex = "48895c2410574883ec20807904008bda488bf90f85010100008339000f85f8000000807905000f85"},
        {name = "controller_exit", rva = 0x12B2AE0, hex = "4883ec28807904007446c6410400488b0d6baa1b02e8d6befcff488b053f3807"},
        {name = "controller_update", rva = 0x12B26A0, hex = "f30f114c24105341574883ec38488b05b43d07024c8bf983b8880000000074128b90a8030000488d"},
        {name = "controller_aim_gate", rva = 0x12B28A3, hex = "48b800000000000001004985842480e853004c8b64243074083b3dc61e1d027508498bcfe814020000"},
        {name = "input_desired_gate", rva = 0xA41C0B, hex = "488b0d5eb2a3024c8bb424b80000003a4104741984c074098bd3e8860d8700eb0c488b0d3db2a302e8a80e8700"},
        {name = "allowed", rva = 0x12B2D20, hex = "48895c240848896c2410488974241857415641574883ec203b15e20e1d027452488b1d993f070245"},
        {name = "allow_fpv_field", rva = 0x12B2DFB, hex = "418bc9488b0ccee8396c25ff80b880010000007482b001eb80"},
        {name = "root_position_call", rva = 0x12887C9, hex = "41ff5138"},
        {name = "root_rotation_call", rva = 0x12887E9, hex = "41ff5148"},
        {name = "pose_branch_position_call", rva = 0x1288420, hex = "41ff5138"},
    },
}
