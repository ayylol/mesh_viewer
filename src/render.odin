package main
import "core:fmt"
import "core:slice"
import "core:strings"

import log "core:log"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Enables Vulkan debug logging and validation layers.
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

Context :: struct {
  window:         ^sdl.Window,
  instance:       vk.Instance,
	dbg_messenger:  vk.DebugUtilsMessengerEXT,
	phys_dev:       vk.PhysicalDevice,
  surface:        vk.SurfaceKHR,
}
ctx: Context

initSDL :: proc () {
  assert(sdl.Init(sdl.INIT_VIDEO), string(sdl.GetError()))

	ctx.window = sdl.CreateWindow(
		"Object Viewer", 640, 480,
		sdl.WINDOW_VULKAN | sdl.WINDOW_HIDDEN,
	)
	assert(ctx.window != nil, string(sdl.GetError()))

  sdl.SetWindowPosition(ctx.window, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
  sdl.ShowWindow(ctx.window)
}

destroySDL :: proc () {
  sdl.DestroyWindow(ctx.window)
  sdl.Quit() 
}

initVulkan :: proc () {
  // Instance + validation layers
  create_instance()
  // Physical device
	must(pick_physical_device())
  // Surface
  assert(sdl.Vulkan_CreateSurface(ctx.window, ctx.instance, nil, &ctx.surface))
  // Setup Queue
  indices := find_queue_families(ctx.phys_dev)
  {
    // In case graphics!=present queues
    indices_set := make(map[u32]struct {}, allocator = context.temp_allocator)
    indices_set[indices.graphics.?] = {}
    indices_set[indices.present.?] = {}

    queueCIs := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(indices_set), context.temp_allocator)
    for _ in indices_set {
      append(
        &queueCIs,
        vk.DeviceQueueCreateInfo {
          sType = .DEVICE_QUEUE_CREATE_INFO,
          queueFamilyIndex = indices.graphics.?,
          queueCount = 1,
          pQueuePriorities = raw_data([]f32{1}),
        },// Scheduling priority between 0 and 1.
      )
    }

  }

  // Logical Device Setup
  // Setting up Vulkan Mem Allocator
  // SwapChain
  // Depth Attachment
}

destroyVulkan :: proc () {
  vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
  when ENABLE_VALIDATION_LAYERS {
    vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.dbg_messenger, nil)
	}
  vk.DestroyInstance(ctx.instance, nil)
}

// Sets up instance and validation layers
create_instance :: proc() {
  vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")
  
	instanceCI := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "Object Viewer",
			applicationVersion = vk.MAKE_VERSION(1, 0, 0),
			pEngineName = "No Engine",
			engineVersion = vk.MAKE_VERSION(0, 0, 0),
			apiVersion = vk.API_VERSION_1_3,
		},
	}

  instExtCount:u32=0;
  _=sdl.Vulkan_GetInstanceExtensions(&instExtCount) // Extra call to get count
  extensions:=slice.clone_to_dynamic(
  sdl.Vulkan_GetInstanceExtensions(&instExtCount)[:instExtCount],
  context.temp_allocator)

  when ENABLE_VALIDATION_LAYERS {
		instanceCI.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
		instanceCI.enabledLayerCount = 1

		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		dbgCI := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING}, // all
			pfnUserCallback = vk_messenger_callback,
		}
		instanceCI.pNext = &dbgCI
	}
	instanceCI.enabledExtensionCount = u32(len(extensions))
	instanceCI.ppEnabledExtensionNames = raw_data(extensions)

	must(vk.CreateInstance(&instanceCI, nil, &ctx.instance))
  vk.load_proc_addresses_instance(ctx.instance)

  when ENABLE_VALIDATION_LAYERS {
		must(vk.CreateDebugUtilsMessengerEXT(ctx.instance, &dbgCI, nil, &ctx.dbg_messenger))
	}
}

// TODO: actually do gpu rankings
@(require_results)
pick_physical_device :: proc() -> vk.Result {
	count: u32
	vk.EnumeratePhysicalDevices(ctx.instance, &count, nil) or_return
	if count == 0 {log.panic("vulkan: no GPU found")}
	if count != 1 {log.warn("multiple gpu selection not yet implemented")}

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(ctx.instance, &count, raw_data(devices)) or_return

  ctx.phys_dev=devices[0]

  props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(ctx.phys_dev, &props)
  name := strings.truncate_to_byte(string(props.deviceName[:]), 0)
	log.infof("vulkan: Using physical device %q", name)

	return .SUCCESS
}

Queue_Family_Indices :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

find_queue_families :: proc(device: vk.PhysicalDevice) -> (ids: Queue_Family_Indices) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if .GRAPHICS in family.queueFlags {
			ids.graphics = u32(i)
		}

		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), ctx.surface, &supported)
		if supported {
			ids.present = u32(i)
		}

		// Found all needed queues?
		_, has_graphics := ids.graphics.?
		_, has_present := ids.present.?
		if has_graphics && has_present {
			break
		}
	}

	return
}

vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = g_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}
	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}

must :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
    log.panicf("vulkan failure %v", result, location = loc)
	}
}
