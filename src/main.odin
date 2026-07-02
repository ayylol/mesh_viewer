package main

import "base:runtime"
import log "core:log"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

g_ctx: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger()
  g_ctx=context

  initSDL()
  defer destroySDL()
  initVulkan()
  defer destroyVulkan()

  // Main Loop
  for {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				return
			}
		}
    drawFrame()
  }
  //
}

drawFrame :: proc() {
  must(vk.WaitForFences(ctx.device, 1, &ctx.inFlightFence, true, max(u64)))

  imageIndex: u32
  vk.AcquireNextImageKHR(
    ctx.device,
    ctx.swapchain,
    max(u64),
    ctx.imageAvailableSemaphore,
    0,
    &imageIndex
  )
  must(vk.ResetFences(ctx.device, 1, &ctx.inFlightFence))

  vk.ResetCommandBuffer(ctx.commandBuffer, {});
  recordCommandBuffer(ctx.commandBuffer, imageIndex)

  waitSemaphores : []vk.Semaphore = {ctx.imageAvailableSemaphore}
  waitStages : []vk.PipelineStageFlag = {.COLOR_ATTACHMENT_OUTPUT}

  signalSemaphores : []vk.Semaphore  = {ctx.renderFinishedSemaphore}

  // Submit
  submitInfo := vk.SubmitInfo {
    sType = .SUBMIT_INFO,
    waitSemaphoreCount = 1,
    pWaitSemaphores = &waitSemaphores[0],
		pWaitDstStageMask = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
    commandBufferCount = 1,
    pCommandBuffers = &ctx.commandBuffer,
    signalSemaphoreCount = 1,
    pSignalSemaphores = &signalSemaphores[0],
  }

  must(vk.QueueSubmit(ctx.graphicsQueue, 1, &submitInfo, ctx.inFlightFence))

  // Present
  swapchains:=[]vk.SwapchainKHR{ctx.swapchain};
  presentInfo := vk.PresentInfoKHR {
    sType = .PRESENT_INFO_KHR,
    waitSemaphoreCount = 1,
    pWaitSemaphores = &signalSemaphores[0],
    swapchainCount = 1,
    pSwapchains = &swapchains[0],
    pImageIndices = &imageIndex,
    pResults = nil,
  }

  must(vk.QueuePresentKHR(ctx.presentQueue, &presentInfo))
}
