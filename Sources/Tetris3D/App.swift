import MetaGame
import MetalKit
import SwiftUI

@main
struct Tetris3DApp: App {
    @State private var controller = GameController(profile: ProfileModel(store: Tetris3DApp.profileStore))

    init() {
        // Lets `swift run` behave like a bundled app (Dock icon, key focus).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Tetris 3D") {
            ContentView(controller: controller)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    controller.start()
                    #if DEBUG
                    DebugLaunch.apply(to: controller)
                    #endif
                    NSApplication.shared.activate()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

extension Tetris3DApp {
    static var profileStore: ProfileStore {
        #if DEBUG
        if let store = DebugLaunch.profileStore { return store }
        #endif
        return .standard
    }
}

struct ContentView: View {
    let controller: GameController

    var body: some View {
        ZStack {
            MetalView(controller: controller)
            HUDView(controller: controller)
        }
        .ignoresSafeArea()
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

struct MetalView: NSViewRepresentable {
    let controller: GameController

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        do {
            let renderer = try Renderer(view: view, controller: controller)
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            fatalError("Metal renderer failed to start: \(error)")
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
