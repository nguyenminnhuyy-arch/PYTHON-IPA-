import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    private func bootstrap() -> String? {
        #if HAS_PYTHON
        if started { return nil }
        let home = Bundle.main.bundlePath + "/python"
        let fm = FileManager.default
        let libDir = home + "/lib"
        guard let ver = (try? fm.contentsOfDirectory(atPath: libDir))?.first(where: { $0.hasPrefix("python3") }),
              fm.fileExists(atPath: "\(libDir)/\(ver)/os.py") else {
            let found = (try? fm.contentsOfDirectory(atPath: home))?.joined(separator: ", ") ?? "thư mục không tồn tại"
            return "⚠️ Không thấy thư viện Python tại \(libDir). Có: \(found)"
        }
        func msg(_ st: PyStatus) -> String {
            st.err_msg != nil ? String(cString: st.err_msg) : "không rõ"
        }
        var config = PyConfig()
        PyConfig_InitIsolatedConfig(&config)
        defer { PyConfig_Clear(&config) }
        config.install_signal_handlers = 0
        config.write_bytecode = 0
        config.utf8_mode = 1
        var st = withUnsafeMutablePointer(to: &config) { p in
            PyConfig_SetBytesString(p, &p.pointee.home, home)
        }
        if PyStatus_Exception(st) != 0 { return "⚠️ Python config lỗi: " + msg(st) }
        st = Py_InitializeFromConfig(&config)
        if PyStatus_Exception(st) != 0 { return "⚠️ Python khởi tạo lỗi: " + msg(st) }
        started = true
        #endif
        return nil
    }

    func run(_ code: String, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            #if HAS_PYTHON
            if let err = bootstrap() { DispatchQueue.main.async { completion(err) }; return }
            let tmp = NSTemporaryDirectory() + "main.py"
            try? code.write(toFile: tmp, atomically: true, encoding: .utf8)
            let wrapper = """
            import sys, io, traceback
            _buf = io.StringIO()
            sys.stdout = sys.stderr = _buf
            try:
                exec(compile(open(r'\(tmp)', encoding='utf-8').read(), 'main.py', 'exec'), {'__name__': '__main__'})
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

// MARK: - Command (REPL) – giữ biến giữa các lệnh
extension PythonRunner {
    func runCommand(_ line: String, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            #if HAS_PYTHON
            if let err = bootstrap() { DispatchQueue.main.async { completion(err) }; return }
            let tmp = NSTemporaryDirectory() + "cmd.py"
            try? line.write(toFile: tmp, atomically: true, encoding: .utf8)
            let wrapper = """
            import sys, io, traceback
            if '_ns' not in globals():
                _ns = {'__name__': '__main__'}
            _buf = io.StringIO()
            sys.stdout = sys.stderr = _buf
            try:
                _src = open(r'\(tmp)', encoding='utf-8').read()
                try:
                    _c = compile(_src, '<console>', 'eval')
                except SyntaxError:
                    _c = None
                if _c is not None:
                    _r = eval(_c, _ns)
                    if _r is not None:
                        print(repr(_r))
                else:
                    exec(compile(_src, '<console>', 'exec'), _ns)
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
            DispatchQueue.main.async { completion(result.trimmingCharacters(in: .newlines)) }
            #else
            DispatchQueue.main.async { completion("⚠️ Chưa nhúng Python.xcframework.") }
            #endif
        }
    }
}

// MARK: - Log
struct LogEntry: Identifiable {
    enum Kind { case input, output, error, info }
    let id = UUID()
    let kind: Kind
    let text: String
    let date = Date()
}

final class ConsoleLog: ObservableObject {
    static let shared = ConsoleLog()
    @Published var entries: [LogEntry] = [LogEntry(kind: .info, text: "PyRun console – gõ lệnh Python bên dưới")]

    func add(_ kind: LogEntry.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        entries.append(LogEntry(kind: kind, text: text))
    }
    func addOutput(_ text: String) {
        add(text.contains("Traceback (most recent call last)") ? .error : .output, text)
    }
    var asText: String { entries.map(\.text).joined(separator: "\n") }
}

// MARK: - Console screen
struct ConsoleView: View {
    @ObservedObject private var log = ConsoleLog.shared
    @AppStorage("fontSize") private var fontSize = 14.0
    @State private var input = ""
    @State private var busy = false
    @State private var history: [String] = []
    @State private var histIndex = 0
    @FocusState private var focused: Bool

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 12) {
                HStack {
                    Text("Console").font(.largeTitle.bold())
                    Spacer()
                    Button { UIPasteboard.general.string = log.asText } label: {
                        Image(systemName: "doc.on.doc").padding(12)
                    }.glass(cornerRadius: 18, interactive: true)
                    Button { log.entries.removeAll() } label: {
                        Image(systemName: "trash").padding(12)
                    }.glass(cornerRadius: 18, tint: .red, interactive: true)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(log.entries) { e in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Self.fmt.string(from: e.date)).font(.caption2).foregroundStyle(.secondary)
                                    Text(e.kind == .input ? ">>> " + e.text : e.text)
                                        .font(.system(size: fontSize, design: .monospaced))
                                        .foregroundStyle(color(e.kind))
                                        .textSelection(.enabled)
                                }.id(e.id)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .glass()
                    .onChange(of: log.entries.count) { _ in
                        if let last = log.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }

                HStack(spacing: 8) {
                    Button { step(-1) } label: { Image(systemName: "arrow.up") .padding(12) }
                        .glass(cornerRadius: 18, interactive: true)
                    TextField(">>> lệnh Python", text: $input)
                        .font(.system(size: fontSize, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($focused).submitLabel(.send).onSubmit(send)
                        .padding(12).glass(cornerRadius: 20)
                    Button(action: send) {
                        Image(systemName: busy ? "hourglass" : "paperplane.fill").padding(12)
                    }.glass(cornerRadius: 18, tint: .green, interactive: true).disabled(busy)
                }
            }.padding()
        }
    }

    private func color(_ k: LogEntry.Kind) -> Color {
        switch k {
        case .input: return .cyan
        case .output: return .primary
        case .error: return .red
        case .info: return .secondary
        }
    }

    private func step(_ d: Int) {
        guard !history.isEmpty else { return }
        histIndex = max(0, min(history.count - 1, histIndex + d))
        input = history[histIndex]
    }

    private func send() {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !busy else { return }
        history.append(line); histIndex = history.count
        input = ""; busy = true
        log.add(.input, line)
        PythonRunner.shared.runCommand(line) { out in
            log.addOutput(out); busy = false; focused = true
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
            ConsoleView().tabItem { Label("Console", systemImage: "terminal.fill") }
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
    @State private var errorText: String?

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
                    ConsoleLog.shared.add(.info, "▶ Chạy \(fileName)")
                    PythonRunner.shared.run(code) {
                        output = $0; running = false
                        ConsoleLog.shared.addOutput($0)
                    }
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
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { res in
            switch res {
            case .failure(let e):
                errorText = e.localizedDescription
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                var coordErr: NSError?
                var readErr: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { u in
                    do {
                        let data = try Data(contentsOf: u)
                        let s = String(decoding: data, as: UTF8.self)
                        code = s; fileName = url.lastPathComponent
                    } catch { readErr = error }
                }
                if let e = coordErr { errorText = e.localizedDescription }
                else if let e = readErr { errorText = e.localizedDescription }
            }
        }
        .alert("Không mở được file", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
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
