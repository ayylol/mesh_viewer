package main
import "core:fmt"
import "core:slice"
import "core:strings"

import log "core:log"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../build/vert.spv")
SHADER_FRAG :: #load("../build/frag.spv")

// Enables Vulkan debug logging and validation layers.
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

Context :: struct {
  window:                   ^sdl.Window,
  instance:                 vk.Instance,
  dbgMessenger:             vk.DebugUtilsMessengerEXT,
  physicalDevice:           vk.PhysicalDevice,
  surface:                  vk.SurfaceKHR,
  device:                   vk.Device,
  graphicsQueue:            vk.Queue,
  presentQueue:             vk.Queue,
  swapchain:                vk.SwapchainKHR,
  swapchainImages:          []vk.Image,
  swapchainViews:           []vk.ImageView,
  swapchainFormat:          vk.SurfaceFormatKHR,
  swapchainExtent:          vk.Extent2D,
  swapchainPresentMode:     vk.PresentModeKHR,
  swapchainFramebuffers:    []vk.Framebuffer,
  vertShaderModule:         vk.ShaderModule,
  fragShaderModule:         vk.ShaderModule,
  shaderStages:             [2]vk.PipelineShaderStageCreateInfo,
  renderPass:               vk.RenderPass,
  pipelineLayout:           vk.PipelineLayout,
  graphicsPipeline:         vk.Pipeline,
  commandPool:              vk.CommandPool,
  commandBuffer:            vk.CommandBuffer,
  imageAvailableSemaphore:  vk.Semaphore,
  renderFinishedSemaphore:  vk.Semaphore, 
  inFlightFence:            vk.Fence,
}
ctx: Context

initSDL :: proc () {
  assert(sdl.Init(sdl.INIT_VIDEO), string(sdl.GetError()))

	ctx.window = sdl.CreateWindow(
		"Object Viewer", 800, 600,
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
  createInstance()
  // TODO: Extract debug messenger setup into a function like the tutorial

  // Physical device
	must(pickPhysicalDevice())

  // Surface
  assert(sdl.Vulkan_CreateSurface(ctx.window, ctx.instance, nil, &ctx.surface))

  // TODO: !!move logical device setup to a function
  // Setup Logical Device
  indices := findQueueFamilies(ctx.physicalDevice)
  {
    // In case graphics!=present queues
    indexSet := make(map[u32]struct {}, allocator = context.temp_allocator)
    indexSet[indices.graphics.?] = {}
    indexSet[indices.present.?] = {}

    queueCI := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(indexSet), context.temp_allocator)
    for _ in indexSet {
      append(
        &queueCI,
        vk.DeviceQueueCreateInfo {
          sType = .DEVICE_QUEUE_CREATE_INFO,
          queueFamilyIndex = indices.graphics.?,
          queueCount = 1,
          pQueuePriorities = raw_data([]f32{1}),
        },// Scheduling priority between 0 and 1.
      )
    }

    // Using core features instead of extensions saves us code
    enabledVk12Features := vk.PhysicalDeviceVulkan12Features {
      sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
      descriptorIndexing = true,
      shaderSampledImageArrayNonUniformIndexing = true,
      descriptorBindingVariableDescriptorCount = true,
      runtimeDescriptorArray = true,
      bufferDeviceAddress = true
    }
    enabledVk13Features := vk.PhysicalDeviceVulkan13Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext = &enabledVk12Features,
        synchronization2 = true,
        dynamicRendering = true,
    }
    enabledVk10Features := vk.PhysicalDeviceFeatures {
        samplerAnisotropy = true
    }

    deviceExtensions:[]cstring={ vk.KHR_SWAPCHAIN_EXTENSION_NAME }
    deviceCI := vk.DeviceCreateInfo {
      sType = .DEVICE_CREATE_INFO,
      pNext = &enabledVk13Features,
      queueCreateInfoCount = u32(len(queueCI)),
      pQueueCreateInfos = raw_data(queueCI),
      enabledExtensionCount = u32(len(deviceExtensions)),
      ppEnabledExtensionNames = raw_data(deviceExtensions),
      pEnabledFeatures = &enabledVk10Features
    }
		must(vk.CreateDevice(ctx.physicalDevice, &deviceCI, nil, &ctx.device))

    vk.GetDeviceQueue(ctx.device, indices.graphics.?, 0, &ctx.graphicsQueue)
		vk.GetDeviceQueue(ctx.device, indices.present.?, 0, &ctx.presentQueue)
  }
  // TODO: HOW TO DO VULKAN MEMORY ALLOCATIONS???

  // SwapChain
  createSwapchain()

  createRenderPass()
  createGraphicsPipeline()

  createFramebuffers()

  createCommandPool()
  createCommandBuffer()

  createSyncObjects()
}

destroyVulkan :: proc () {
  vk.DeviceWaitIdle(ctx.device)

  vk.DestroyFence(ctx.device, ctx.inFlightFence, nil)
  vk.DestroySemaphore(ctx.device, ctx.renderFinishedSemaphore, nil)
  vk.DestroySemaphore(ctx.device, ctx.imageAvailableSemaphore, nil)
  vk.DestroyCommandPool(ctx.device, ctx.commandPool, nil)
  vk.DestroyRenderPass(ctx.device, ctx.renderPass, nil)
  vk.DestroyPipeline(ctx.device, ctx.graphicsPipeline, nil)
  vk.DestroyPipelineLayout(ctx.device, ctx.pipelineLayout, nil)
  vk.DestroyShaderModule(ctx.device, ctx.vertShaderModule, nil)
  vk.DestroyShaderModule(ctx.device, ctx.fragShaderModule, nil)
  destroySwapchain()
  vk.DestroyDevice(ctx.device, nil)
  vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
  when ENABLE_VALIDATION_LAYERS {
    vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.dbgMessenger, nil)
	}
  vk.DestroyInstance(ctx.instance, nil)
}

// Sets up instance and validation layers
createInstance :: proc() {
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
			pfnUserCallback = vkMessengerCallback,
		}
		instanceCI.pNext = &dbgCI 
	}
	instanceCI.enabledExtensionCount = u32(len(extensions))
	instanceCI.ppEnabledExtensionNames = raw_data(extensions)

	must(vk.CreateInstance(&instanceCI, nil, &ctx.instance))
  vk.load_proc_addresses_instance(ctx.instance)

  when ENABLE_VALIDATION_LAYERS {
		must(vk.CreateDebugUtilsMessengerEXT(ctx.instance, &dbgCI, nil, &ctx.dbgMessenger))
	}
}

// TODO: actually do gpu rankings
@(require_results)
pickPhysicalDevice :: proc() -> vk.Result {
	count: u32
	vk.EnumeratePhysicalDevices(ctx.instance, &count, nil) or_return
	if count == 0 {log.panic("vulkan: no GPU found")}
	if count != 1 {log.warn("multiple gpu selection not yet implemented")}

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(ctx.instance, &count, raw_data(devices)) or_return

  ctx.physicalDevice=devices[0]

  props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(ctx.physicalDevice, &props)
  name := strings.truncate_to_byte(string(props.deviceName[:]), 0)
	log.infof("vulkan: Using physical device %q", name)

	return .SUCCESS
}

QueueFamilyIndices :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

findQueueFamilies :: proc(device: vk.PhysicalDevice) -> (ids: QueueFamilyIndices) {
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
		_, hasGraphics := ids.graphics.?
		_, hasPresent := ids.present.?
		if hasGraphics && hasPresent {
			break
		}
	}

	return
}

createSwapchain :: proc() {
	indices := findQueueFamilies(ctx.physicalDevice)

	// Setup swapchain.
	{
		support, result := querySwapchainSupport(ctx.physicalDevice, context.temp_allocator)
		if result != .SUCCESS {
			log.panicf("vulkan: query swapchain failed: %v", result)
		}

		surfaceFormat := chooseSwapchainSurfaceFormat(support.formats)

		ctx.swapchainFormat = surfaceFormat
		ctx.swapchainExtent = chooseSwapchainExtent(support.capabilities)
    ctx.swapchainPresentMode = chooseSwapchainPresentMode(support.presentModes)

		imageCount := support.capabilities.minImageCount + 1
		if support.capabilities.maxImageCount > 0 && imageCount > support.capabilities.maxImageCount {
			imageCount = support.capabilities.maxImageCount
		}

		swapchainCI := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = ctx.surface,
			minImageCount    = imageCount,
			imageFormat      = surfaceFormat.format,
			imageColorSpace  = surfaceFormat.colorSpace,
			imageExtent      = ctx.swapchainExtent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = support.capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = ctx.swapchainPresentMode,
			clipped          = true,
		}

    // TODO: Not sure if this case works, because I can't test it
		if indices.graphics != indices.present {
			swapchainCI.imageSharingMode = .CONCURRENT
			swapchainCI.queueFamilyIndexCount = 2
			swapchainCI.pQueueFamilyIndices = raw_data([]u32{indices.graphics.?, indices.present.?})
		}

		must(vk.CreateSwapchainKHR(ctx.device, &swapchainCI, nil, &ctx.swapchain))
	}

	// Setup swapchain images.
  // TODO: extract to its own function to more closely follow the Vulkan guide
	{
		count: u32
		must(vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &count, nil))

		ctx.swapchainImages = make([]vk.Image, count)
		ctx.swapchainViews = make([]vk.ImageView, count)
		must(vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &count, raw_data(ctx.swapchainImages)))

		for image, i in ctx.swapchainImages {
			swapchainImageViewCI := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = ctx.swapchainFormat.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			must(vk.CreateImageView(ctx.device, &swapchainImageViewCI, nil, &ctx.swapchainViews[i]))
		}
	}
}

destroySwapchain :: proc() {
	for framebuffer in ctx.swapchainFramebuffers {
		vk.DestroyFramebuffer(ctx.device, framebuffer, nil)
	}
	for view in ctx.swapchainViews {
		vk.DestroyImageView(ctx.device, view, nil)
	}
	delete(ctx.swapchainViews)
	delete(ctx.swapchainImages)
  vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)
}

SwapchainSupport :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}

querySwapchainSupport :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
) -> (
	support: SwapchainSupport,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, ctx.surface, &support.capabilities) or_return

	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, ctx.surface, &count, nil) or_return

		support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, ctx.surface, &count, raw_data(support.formats)) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, ctx.surface, &count, nil) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, ctx.surface, &count, raw_data(support.presentModes)) or_return
	}

	return
}

chooseSwapchainSurfaceFormat :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}

	// Fallback non optimal.
	return formats[0]
}

chooseSwapchainPresentMode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// We would like mailbox for the best tradeoff between tearing and latency.
	for mode in modes {
		if mode == .MAILBOX {
			return .MAILBOX
		}
	}

	// As a fallback, fifo (basically vsync) is always available.
	return .FIFO
}

chooseSwapchainExtent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height : i32
  sdl.GetWindowSize(ctx.window, &width, &height)
	return(
		vk.Extent2D {
			width = clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
			height = clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
		} 
	)
}

createRenderPass :: proc(){
  colorAttachment := vk.AttachmentDescription {
    format = ctx.swapchainFormat.format,
    samples = {._1},
    loadOp = .CLEAR,
    storeOp = .STORE,
    stencilLoadOp = .DONT_CARE,
    stencilStoreOp = .DONT_CARE,
    initialLayout = .UNDEFINED,
    finalLayout = .PRESENT_SRC_KHR,
  }
  colorAttachmentRef := vk.AttachmentReference {
    attachment = 0,
    layout = .COLOR_ATTACHMENT_OPTIMAL,
  }
  subpass := vk.SubpassDescription {
    pipelineBindPoint = .GRAPHICS,
    colorAttachmentCount = 1,
    pColorAttachments = &colorAttachmentRef,
  }

  dependency := vk.SubpassDependency {
    srcSubpass = vk.SUBPASS_EXTERNAL,
    dstSubpass = 0,
    srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
    srcAccessMask = {},
    dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
    dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }

  renderPassCI := vk.RenderPassCreateInfo {
    sType = .RENDER_PASS_CREATE_INFO,
    attachmentCount = 1,
    pAttachments = &colorAttachment,
    subpassCount = 1,
    pSubpasses = &subpass,
    dependencyCount = 1,
    pDependencies = &dependency,
  }

  must(vk.CreateRenderPass(ctx.device, &renderPassCI, nil, &ctx.renderPass))
}

createGraphicsPipeline :: proc(){
  ctx.vertShaderModule=createShaderModule(SHADER_VERT)
  ctx.fragShaderModule=createShaderModule(SHADER_FRAG)

  vertShaderStageCI := vk.PipelineShaderStageCreateInfo {
    sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
    stage = {.VERTEX},
    module = ctx.vertShaderModule,
    pName = "main"
  }
  fragShaderStageCI := vk.PipelineShaderStageCreateInfo {
    sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
    stage = {.FRAGMENT},
    module = ctx.fragShaderModule,
    pName = "main"
  }
  ctx.shaderStages[0]=vertShaderStageCI
  ctx.shaderStages[1]=fragShaderStageCI
  
	dynamicStates := []vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamicStateCI := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamicStates)),
    pDynamicStates    = raw_data(dynamicStates),
  }

  vertexInputCI := vk.PipelineVertexInputStateCreateInfo {
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount = 0,
    pVertexBindingDescriptions = nil,
    vertexAttributeDescriptionCount = 0,
    pVertexAttributeDescriptions = nil
  }

  inputAssemblyCI := vk.PipelineInputAssemblyStateCreateInfo {
    sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
    primitiveRestartEnable = false
  }

  viewport:=vk.Viewport{
    x = 0.0,
    y = 0.0,
    width = f32(ctx.swapchainExtent.width),
    height = f32(ctx.swapchainExtent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }

  scissor:=vk.Rect2D {
    offset = {0, 0},
    extent = ctx.swapchainExtent
  }

  viewportStateCI := vk.PipelineViewportStateCreateInfo {
    sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount = 1,
  }

  rasterizerCI := vk.PipelineRasterizationStateCreateInfo {
    sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable = false,
    rasterizerDiscardEnable = false,
    polygonMode = .FILL,
    lineWidth = 1.0,
    cullMode = {.BACK},
    frontFace = .CLOCKWISE,
    depthBiasEnable = false,
    depthBiasConstantFactor = 0.0,
    depthBiasClamp = 0.0,
    depthBiasSlopeFactor = 0.0,
  }

  multisamplingCI := vk.PipelineMultisampleStateCreateInfo {
    sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    sampleShadingEnable = false,
    rasterizationSamples = {._1},
    minSampleShading = 1.0,
    pSampleMask = nil,
    alphaToCoverageEnable = false,
    alphaToOneEnable = false,
  }

  colorBlendAttachment:= vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R,.G,.B,.A},
    blendEnable = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp = .ADD,
  }

  colorBlendingCI := vk.PipelineColorBlendStateCreateInfo {
    sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable = false,
    logicOp = .COPY,
    attachmentCount = 1,
    pAttachments = &colorBlendAttachment,
    blendConstants = {0,0,0,0},
  }

  pipelineLayoutCI := vk.PipelineLayoutCreateInfo {
    sType = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount = 0,
    pSetLayouts = nil,
    pushConstantRangeCount = 0,
    pPushConstantRanges = nil,
  }
  must(vk.CreatePipelineLayout(ctx.device, &pipelineLayoutCI, nil, &ctx.pipelineLayout))

  pipelineCI := vk.GraphicsPipelineCreateInfo {
    sType = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount = 2,
    pStages = &ctx.shaderStages[0],
    pVertexInputState = &vertexInputCI,
    pInputAssemblyState = &inputAssemblyCI,
    pViewportState = &viewportStateCI,
    pRasterizationState = &rasterizerCI,
    pMultisampleState = &multisamplingCI,
    pDepthStencilState = nil,
    pColorBlendState = &colorBlendingCI,
    pDynamicState = &dynamicStateCI,
    layout = ctx.pipelineLayout,
    renderPass = ctx.renderPass,
    subpass = 0,
    basePipelineIndex = -1,
  }
  must(vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipelineCI, nil, &ctx.graphicsPipeline))
}

createShaderModule :: proc(code: []byte) -> (module: vk.ShaderModule) {
  as_u32 := slice.reinterpret([]u32, code)
  shaderModuleCI:= vk.ShaderModuleCreateInfo {
    sType = .SHADER_MODULE_CREATE_INFO,
    codeSize = len(code),
    pCode = raw_data(as_u32)
  }
  must(vk.CreateShaderModule(ctx.device, &shaderModuleCI, nil, &module))
  return
}

createFramebuffers :: proc() {
  ctx.swapchainFramebuffers = make([]vk.Framebuffer, len(ctx.swapchainViews))
  for view, i in ctx.swapchainViews {
		attachments := []vk.ImageView{view}
    framebufferInfo := vk.FramebufferCreateInfo {
      sType = .FRAMEBUFFER_CREATE_INFO,
      renderPass = ctx.renderPass,
      attachmentCount = 1,
      pAttachments = &attachments[0],
      width = ctx.swapchainExtent.width,
      height = ctx.swapchainExtent.height,
      layers = 1,
    }
    must(vk.CreateFramebuffer(ctx.device, &framebufferInfo, nil, &ctx.swapchainFramebuffers[i]))
  }
}

createCommandPool :: proc() {
  indices := findQueueFamilies(ctx.physicalDevice)
  poolCI := vk.CommandPoolCreateInfo {
    sType = .COMMAND_POOL_CREATE_INFO,
    flags = {.RESET_COMMAND_BUFFER},
    queueFamilyIndex = indices.graphics.?,
  }
  must(vk.CreateCommandPool(ctx.device, &poolCI, nil, &ctx.commandPool))
}

createCommandBuffer :: proc() {
  allocInfo := vk.CommandBufferAllocateInfo {
    sType = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool = ctx.commandPool,
    level = .PRIMARY,
    commandBufferCount = 1,
  }

  must(vk.AllocateCommandBuffers(ctx.device, &allocInfo, &ctx.commandBuffer))
}

recordCommandBuffer :: proc(commandBuffer: vk.CommandBuffer, imageIndex: u32) {
  beginInfo := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {},
    pInheritanceInfo = nil,
  }
  must(vk.BeginCommandBuffer(commandBuffer, &beginInfo))

	clear_color := vk.ClearValue{}
	clear_color.color.float32 = {0.0, 0.0, 0.0, 1.0}

  renderPassInfo := vk.RenderPassBeginInfo {
    sType = .RENDER_PASS_BEGIN_INFO,
    renderPass = ctx.renderPass,
    framebuffer = ctx.swapchainFramebuffers[imageIndex],
    renderArea = {extent = ctx.swapchainExtent},
		clearValueCount = 1,
		pClearValues = &clear_color,
  }

  vk.CmdBeginRenderPass(commandBuffer, &renderPassInfo, .INLINE)
  vk.CmdBindPipeline(commandBuffer, .GRAPHICS, ctx.graphicsPipeline)

  viewport := vk.Viewport {
    x = 0.0,
    y = 0.0,
    width = f32(ctx.swapchainExtent.width),
    height = f32(ctx.swapchainExtent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  vk.CmdSetViewport(ctx.commandBuffer, 0, 1, &viewport);

  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = ctx.swapchainExtent,
  }
  vk.CmdSetScissor(ctx.commandBuffer, 0, 1, &scissor);

  vk.CmdDraw(ctx.commandBuffer, 3, 1, 0, 0)
  vk.CmdEndRenderPass(ctx.commandBuffer)
  must(vk.EndCommandBuffer(ctx.commandBuffer))
}

createSyncObjects :: proc () {
  semaphoreCI := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
  fenceCI := vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = {.SIGNALED} }
  must(vk.CreateSemaphore(ctx.device, &semaphoreCI, nil, &ctx.imageAvailableSemaphore))
  must(vk.CreateSemaphore(ctx.device, &semaphoreCI, nil, &ctx.renderFinishedSemaphore))
  must(vk.CreateFence(ctx.device, &fenceCI, nil, &ctx.inFlightFence))
}

vkMessengerCallback :: proc "system" (
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
