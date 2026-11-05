// SPDX-License-Identifier: GPL-3.0-or-later
// A floating glass canvas where the assistant builds what it explains: live diagrams
// (Mermaid, bundled) and 3D models (SceneKit), each assembling itself piece by piece.
// Drag the title to move it, drag a model to turn it, ✕ or Esc to close.

import AppKit
import SceneKit
import SwiftUI
import WebKit

final class AssistantCanvas: ObservableObject {
    static let shared = AssistantCanvas()

    enum Content: Equatable {
        case diagram(String)
        case model(AssistantModelSpec)
    }

    @Published private(set) var title = ""
    @Published private(set) var caption = ""
    @Published private(set) var content: Content?
    /// Bumped on every new piece of content so the entrance replays.
    @Published private(set) var generation = 0
    private var panel: NSPanel?

    func showDiagram(_ source: String, title: String, caption: String = "") {
        present(.diagram(source), title: title, caption: caption)
    }

    func showModel(_ spec: AssistantModelSpec) {
        present(.model(spec), title: spec.title, caption: spec.caption)
    }

    func close() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil); panel.alphaValue = 1 })
        content = nil
    }

    /// The scene and page the canvas shows, for checks and previews.
    static func scene(for spec: AssistantModelSpec) -> SCNScene { ModelView.scene(spec) }
    static func diagramPage(_ source: String) -> String { DiagramView.page(source) }

    private func present(_ content: Content, title: String, caption: String) {
        self.title = title
        self.caption = caption
        self.content = content
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
            let size = NSSize(width: 600, height: 520)
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.maxX - size.width - 36, y: frame.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 320)
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: CanvasView(canvas: self))
        return panel
    }
}

// MARK: - 3D spec

/// What the model sends for a 3D scene: simple solids, positioned and coloured.
struct AssistantModelSpec: Equatable {
    struct Part: Equatable {
        var shape: String
        var size: [Double]
        var position: [Double]
        var rotation: [Double]
        var color: String
        var metal: Double
        var glow: Bool
        var label: String
    }
    var title: String
    var caption: String
    var parts: [Part]
    var spin: Bool

    init?(_ object: [String: Any]) {
        guard let parts = object["parts"] as? [[String: Any]], !parts.isEmpty else { return nil }
        func numbers(_ value: Any?, _ fallback: [Double]) -> [Double] {
            ((value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        title = object["title"] as? String ?? "Model"
        caption = object["caption"] as? String ?? ""
        spin = object["spin"] as? Bool ?? true
        self.parts = parts.prefix(80).map { p in
            Part(shape: (p["shape"] as? String ?? "box").lowercased(),
                 size: numbers(p["size"], [1, 1, 1]),
                 position: numbers(p["position"], [0, 0, 0]),
                 rotation: numbers(p["rotation"], [0, 0, 0]),
                 color: p["color"] as? String ?? "#8f7cff",
                 metal: (p["metal"] as? NSNumber)?.doubleValue ?? 0.2,
                 glow: p["glow"] as? Bool ?? false,
                 label: p["label"] as? String ?? "")
        }
    }
}

// MARK: - Canvas view

private struct CanvasView: View {
    @ObservedObject var canvas: AssistantCanvas
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, AssistantOverlay.accent], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 1) {
                    Text(canvas.title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    if !canvas.caption.isEmpty {
                        Text(canvas.caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer()
                Button { canvas.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(WindowDragArea())

            Group {
                switch canvas.content {
                case .diagram(let source): DiagramView(source: source)
                case .model(let spec): ModelView(spec: spec)
                case nil: Color.clear
                }
            }
            .id(canvas.generation)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding([.horizontal, .bottom], 10)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.62))
                AuroraBorder(cornerRadius: 26)
            }
        )
        .environment(\.colorScheme, .dark)
        .scaleEffect(shown ? 1 : 0.92)
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : 10)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { shown = true } }
        .onChange(of: canvas.generation) { _, _ in
            shown = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { shown = true }
        }
    }

    private var icon: String {
        if case .model = canvas.content { return "cube.transparent" }
        return "point.3.connected.trianglepath.dotted"
    }
}

/// A slowly turning gradient hairline, the canvas's signature edge.
struct AuroraBorder: View {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 1.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: AssistantOverlay.reduceMotion)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 40)
            let colors: [Color] = [Color(red: 0.62, green: 0.52, blue: 1), Color(red: 0.2, green: 0.8, blue: 0.95),
                                   Color(red: 1, green: 0.6, blue: 0.75), Color(red: 1, green: 0.75, blue: 0.4),
                                   Color(red: 0.62, green: 0.52, blue: 1)]
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AngularGradient(colors: colors, center: .center, angle: angle), lineWidth: lineWidth * 4)
                    .blur(radius: 8).opacity(0.5)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AngularGradient(colors: colors, center: .center, angle: angle), lineWidth: lineWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Lets a borderless panel be dragged by its title row.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Diagram

private struct DiagramView: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Mermaid ships inside Islet, so diagrams draw instantly and offline.
        if let mermaid = Self.mermaid {
            configuration.userContentController.addUserScript(
                WKUserScript(source: mermaid, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page(source), baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    private static let mermaid: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Vendor")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Mermaid in Islet's dark style; once drawn, each node and edge fades and rises in turn.
    static func page(_ source: String) -> String {
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        html,body{margin:0;height:100%;background:transparent;font-family:-apple-system,"SF Pro Rounded",system-ui;color:#eee;overflow:hidden}
        #wrap{height:100%;display:flex;align-items:center;justify-content:center;padding:18px;box-sizing:border-box;
          background:radial-gradient(600px 300px at 50% 0%,rgba(140,120,255,.18),transparent 70%),radial-gradient(500px 280px at 80% 100%,rgba(40,200,240,.12),transparent 70%)}
        .mermaid{width:100%;height:100%;display:flex;align-items:center;justify-content:center}
        .mermaid svg{width:100%;height:100%;filter:drop-shadow(0 0 18px rgba(150,130,255,.35))}
        .piece{opacity:0;filter:blur(6px) brightness(1.8);transition:opacity .55s cubic-bezier(.2,1,.3,1),filter .7s cubic-bezier(.2,1,.3,1)}
        .piece.in{opacity:1;filter:none}
        .flowchart-link,.messageLine0,.messageLine1,path.relation{stroke-dasharray:var(--len);stroke-dashoffset:var(--len);transition:stroke-dashoffset .8s cubic-bezier(.2,1,.3,1)}
        .drawn{stroke-dashoffset:0!important}
        #err{display:none;white-space:pre-wrap;font:12px ui-monospace,monospace;color:#ffb4b4;padding:20px}
        </style></head><body><div id="wrap"><pre class="mermaid">\(escaped)</pre><div id="err"></div></div>
        <script>
        mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'base',themeVariables:{
          darkMode:true,background:'transparent',fontFamily:'-apple-system, system-ui',fontSize:'15px',
          primaryColor:'#2a2350',primaryTextColor:'#f4f2ff',primaryBorderColor:'#9d86ff',lineColor:'#7fd8f2',
          secondaryColor:'#16303b',tertiaryColor:'#3a1f33',edgeLabelBackground:'#141322',clusterBkg:'#15142299',clusterBorder:'#5c4fb0',
          noteBkgColor:'#2b2238',noteTextColor:'#fff',actorBkg:'#2a2350',actorBorder:'#9d86ff',actorTextColor:'#fff',signalColor:'#7fd8f2',signalTextColor:'#eee'}});
        mermaid.run({querySelector:'.mermaid'}).then(()=>{
          const svg=document.querySelector('.mermaid svg'); if(!svg) return;
          // Fit the drawing to the canvas, whatever size Mermaid gave it.
          svg.removeAttribute('style'); svg.setAttribute('width','100%'); svg.setAttribute('height','100%');
          svg.setAttribute('preserveAspectRatio','xMidYMid meet');
          const pieces=[...svg.querySelectorAll('g.node,g.cluster,g.edgeLabel,g.actor,rect.actor,text.messageText,g.label,.task,.section0,.section1,.slice,g.mindmap-node,.timeline-node')];
          const links=[...svg.querySelectorAll('.flowchart-link,.messageLine0,.messageLine1,path.relation')];
          links.forEach(l=>{try{const n=l.getTotalLength();l.style.setProperty('--len',n);}catch(e){}});
          pieces.forEach(p=>p.classList.add('piece'));
          pieces.forEach((p,i)=>setTimeout(()=>p.classList.add('in'),60+i*70));
          links.forEach((l,i)=>setTimeout(()=>l.classList.add('drawn'),200+i*80));
        }).catch(e=>{const err=document.getElementById('err');err.style.display='block';err.textContent='This diagram could not be drawn:\\n'+e.message;document.querySelector('.mermaid').style.display='none';});
        </script></body></html>
        """
    }
}

// MARK: - 3D model

private struct ModelView: NSViewRepresentable {
    let spec: AssistantModelSpec

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.scene = Self.scene(spec)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    static func scene(_ spec: AssistantModelSpec) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        // A studio: soft key, cool rim and warm fill around a model floating in the glass.
        func light(_ type: SCNLight.LightType, _ color: NSColor, _ intensity: CGFloat, at position: SCNVector3) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light!.type = type
            node.light!.color = color
            node.light!.intensity = intensity
            if type == .directional { node.light!.castsShadow = true; node.light!.shadowRadius = 8; node.light!.shadowColor = NSColor.black.withAlphaComponent(0.45) }
            node.position = position
            node.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(node)
        }
        light(.directional, .white, 1100, at: SCNVector3(4, 7, 6))
        light(.omni, NSColor(calibratedRed: 0.45, green: 0.75, blue: 1, alpha: 1), 650, at: SCNVector3(-6, 3, -4))
        light(.omni, NSColor(calibratedRed: 1, green: 0.7, blue: 0.5, alpha: 1), 380, at: SCNVector3(5, -2, 4))
        light(.ambient, NSColor(white: 1, alpha: 1), 220, at: SCNVector3(0, 0, 0))

        var bounds = (min: SCNVector3(0, 0, 0), max: SCNVector3(0, 0, 0))
        for (index, part) in spec.parts.enumerated() {
            let node = SCNNode(geometry: geometry(part))
            node.position = SCNVector3(part.position[safe: 0], part.position[safe: 1], part.position[safe: 2])
            node.eulerAngles = SCNVector3(part.rotation[safe: 0] * .pi / 180, part.rotation[safe: 1] * .pi / 180, part.rotation[safe: 2] * .pi / 180)
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color(part.color)
            material.metalness.contents = part.metal
            material.roughness.contents = 0.32
            if part.glow { material.emission.contents = color(part.color); material.emission.intensity = 0.9 }
            node.geometry?.materials = [material]
            root.addChildNode(node)
            if !part.label.isEmpty {
                let tag = label(part.label)
                tag.position = SCNVector3(0, node.boundingBox.max.y + 0.28, 0)
                node.addChildNode(tag)
            }

            let (lo, hi) = node.boundingBox
            bounds.min = SCNVector3(min(bounds.min.x, node.position.x + lo.x), min(bounds.min.y, node.position.y + lo.y), min(bounds.min.z, node.position.z + lo.z))
            bounds.max = SCNVector3(max(bounds.max.x, node.position.x + hi.x), max(bounds.max.y, node.position.y + hi.y), max(bounds.max.z, node.position.z + hi.z))

            // Each part springs into place in turn.
            if !AssistantOverlay.reduceMotion {
                node.scale = SCNVector3(0.001, 0.001, 0.001)
                node.opacity = 0
                let grow = SCNAction.customAction(duration: 0.55) { node, elapsed in
                    let t = Double(elapsed / 0.55)
                    let springy = 1 - pow(2, -9 * t) * cos(t * 9)
                    node.scale = SCNVector3(springy, springy, springy)
                    node.opacity = min(1, t * 2.2)
                }
                node.runAction(.sequence([.wait(duration: 0.12 + Double(index) * 0.07), grow]))
            }
        }

        // Centre the model and frame it.
        let centre = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        root.position = SCNVector3(-centre.x, -centre.y, -centre.z)
        let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z, 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 40
        camera.camera!.wantsHDR = true
        camera.camera!.bloomIntensity = 0.35
        camera.camera!.bloomThreshold = 0.92
        camera.camera!.bloomBlurRadius = 6
        camera.position = SCNVector3(extent * 1.1, extent * 0.75, extent * 1.9)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        if spec.spin, !AssistantOverlay.reduceMotion {
            let pivot = SCNNode()
            root.removeFromParentNode()
            pivot.addChildNode(root)
            scene.rootNode.addChildNode(pivot)
            pivot.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 18)))
        }
        return scene
    }

    private static func geometry(_ part: AssistantModelSpec.Part) -> SCNGeometry {
        let s = part.size
        let a = CGFloat(s[safe: 0] == 0 ? 1 : s[safe: 0]), b = CGFloat(s.count > 1 ? s[1] : s[safe: 0]), c = CGFloat(s.count > 2 ? s[2] : s[safe: 0])
        switch part.shape {
        case "sphere": return SCNSphere(radius: a / 2)
        case "cylinder": return SCNCylinder(radius: a / 2, height: b)
        case "cone": return SCNCone(topRadius: 0, bottomRadius: a / 2, height: b)
        case "torus", "ring": return SCNTorus(ringRadius: a / 2, pipeRadius: max(0.02, (s.count > 1 ? b : a * 0.12) / 2))
        case "capsule": return SCNCapsule(capRadius: a / 2, height: max(b, a))
        case "pyramid": return SCNPyramid(width: a, height: b, length: c)
        case "tube": return SCNTube(innerRadius: a / 2 * 0.7, outerRadius: a / 2, height: b)
        case "plane": return SCNBox(width: a, height: 0.02, length: s.count > 1 ? b : a, chamferRadius: 0)
        default: return SCNBox(width: a, height: b, length: c, chamferRadius: min(a, b, c) * 0.06)
        }
    }

    private static func label(_ text: String) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = NSFont.systemFont(ofSize: 1, weight: .semibold)
        geometry.flatness = 0.05
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.emission.contents = NSColor.white
        material.lightingModel = .constant
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        let (lo, hi) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((hi.x - lo.x) / 2 + lo.x, lo.y, 0)
        node.scale = SCNVector3(0.32, 0.32, 0.32)
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 10
        return node
    }

    private static func color(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).scanHexInt64(&value)
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> CGFloat { index < count ? CGFloat(self[index]) : 0 }
}
