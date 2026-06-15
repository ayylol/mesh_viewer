package main

import "base:runtime"
import log "core:log"
import sdl "vendor:sdl3"

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
  }
  //
}
