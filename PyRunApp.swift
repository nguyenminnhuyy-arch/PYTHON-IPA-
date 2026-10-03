import SwiftUI
import UniformTypeIdentifiers
#if canImport(Python)
import Python
#endif

// MARK: - App
@main
struct PyRunApp: App {
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}

// MARK: - Python runner
final class PythonRunner: ObservableObject {
    static let shared = PythonRunner()
    private var started = false
    private let queue = DispatchQueue(label: "py.runner")

    private func start() {
        #if canImport(Python)
        guard !started else { return }
        let home = Bundle.main.resourcePath! + "/python"
        setenv("PYTHONHOME", home, 1)
        setenv("PYTHONPATH", home + "/lib/python3.13:" + home + "/lib/python3.13/lib-dynload", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        Py_Initialize()
        started = true
        #endif
    }

    func run(_ code: String, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            #if canImport(Python)
            start()
            let tmp = NSTemporaryDirectory() + "main.py"
            try? code.write(toFile: tmp, atomically: true, encoding: .utf8)
            let wrapper = """
            import sys, io, traceback
            _buf = io.StringIO()
            sys.stdout = sys.stderr = _buf
            try:
                exec(compile(open(r'\(tmp)').read(), 'main.py', 'exec'), {'__name__': '__main__'})
            except BaseException:
                traceback.print_exc()
            sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__
            _out = _buf.getvalue()
            """
            PyRun_SimpleString(wrapper)
            var result = ""
            if let main = PyImport_AddModule("__main__"),
               let dict = PyModule_GetDict(main),
               let obj = PyDict_GetItemString(dict, "_out"),
               let c = PyUnicode_AsUTF8(obj) {
                result = String(cString: c)
            }
            DispatchQueue.main.async { completion(result.isEmpty ? "(không có output)" : result) }
            #else
            DispatchQueue.main.async {
                completion("⚠️ Chưa nhúng Python.xcframework. Xem README.md để thêm.")
            }
            #endif
        }
    }
}

// MARK: - Liquid Glass helper (iOS 26, fallback material cho bản cũ)
extension View {
    @ViewBuilder
    func glass(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let g: Glass = {
                var g = Glass.regular
                if let tint { g = g.tint(tint.opacity(0.35)) }
                return interactive ? g.interactive() : g
            }()
            self.glassEffect(g, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(.white.opacity(0.15)))
        }
    }
}

struct AuroraBackground: View {
    @State private var move = false
    var body: some View {
        ZStack {
            Color.black
            Circle().fill(.indigo).frame(width: 320).blur(radius: 90)
                .offset(x: move ? -90 : 90, y: move ? -240 : -120)
            Circle().fill(.cyan.opacity(0.8)).frame(width: 280).blur(radius: 90)
                .offset(x: move ? 110 : -80, y: move ? 160 : 260)
            Circle().fill(.pink.opacity(0.7)).frame(width: 240).blur(radius: 90)
                .offset(x: move ? -60 : 100, y: move ? 280 : 60)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { move = true } }
    }
}

// MARK: - Root
struct RootView: View {
    var body: some View {
        TabView {
            RunView().tabItem { Label("Chạy", systemImage: "play.fill") }
            SettingsView().tabItem { Label("Cài đặt", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Run screen
struct RunView: View {
    @AppStorage("fontSize") private var fontSize = 14.0
    @State private var code = "print('Xin chào từ Python 🐍')\nfor i in range(3):\n    print(i * i)"
    @State private var output = ""
    @State private var running = false
    @State private var picking = false
    @State private var fileName = "main.py"

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 14) {
                HStack {
                    Text("PyRun").font(.largeTitle.bold())
                    Spacer()
                    Button { picking = true } label: {
                        Label("Mở .py", systemImage: "doc.badge.plus").padding(.horizontal, 14).padding(.vertical, 10)
                    }.glass(cornerRadius: 20, interactive: true)
                }
                Text(fileName).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $code)
                    .font(.system(size: fontSize, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .padding(12).glass()

                Button {
                    running = true
                    PythonRunner.shared.run(code) { output = $0; running = false }
                } label: {
                    HStack {
                        if running { ProgressView() } else { Image(systemName: "play.fill") }
                        Text(running ? "Đang chạy…" : "Chạy").bold()
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .glass(cornerRadius: 26, tint: .green, interactive: true)
                .disabled(running)

                ScrollView {
                    Text(output.isEmpty ? "Output sẽ hiện ở đây" : output)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(output.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(14)
                }.glass().frame(maxHeight: 220)
            }
            .padding()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "py") ?? .plainText, .plainText]) { res in
            guard case .success(let url) = res else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let s = try? String(contentsOf: url, encoding: .utf8) { code = s; fileName = url.lastPathComponent }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @AppStorage("fontSize") private var fontSize = 14.0
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 16) {
                    Text("Cài đặt").font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Cỡ chữ code: \(Int(fontSize))", systemImage: "textformat.size")
                        Slider(value: $fontSize, in: 10...24, step: 1)
                    }.padding(18).glass()

                    VStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 36))
                        Text("PyRun").font(.title2.bold())
                        Text("Chạy file Python trên iOS").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(22).glass()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Credit", systemImage: "heart.fill").font(.headline)
                        Text("Nguyen Minh Huy")
                        Button {
                            openURL(URL(string: "https://t.me/mh_nguyen")!)
                        } label: {
                            Label("Telegram: @mh_nguyen", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.glass(cornerRadius: 20, tint: .blue, interactive: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
                }.padding()
            }
        }
    }
}
