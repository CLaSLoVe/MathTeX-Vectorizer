import SwiftUI
import WebKit
import Combine
import Foundation

// MARK: - Main View
struct ContentView: View {
    @StateObject private var viewModel = LatexViewModel()
    @State private var isPinned: Bool = false
    @State private var window: NSWindow?
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        ZStack {
            WindowAccessor(window: $window)
                .frame(width: 0, height: 0)
            
            VStack(spacing: 0) {
                
                // Top Input Area
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 0) {
                        if viewModel.textInput.isEmpty {
                            HStack {
                                Text("LaTeX code here ...")
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .font(.system(size: 12))
                                    .padding(.leading, 8)
                                    .padding(.top, 12)
                                Spacer()
                            }
                        }
                        
                        TextEditor(text: $viewModel.textInput)
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(2)
                            .padding(8)
                            .padding(.top, 20)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .scrollContentBackground(.hidden)
                            .focused($isInputFocused)
                            // TextEditor often eats clicks, so we force a clipboard read here too just in case
                            .simultaneousGesture(TapGesture().onEnded {
                                viewModel.readClipboard(force: true)
                            })
                    }
                    
                    // Top-right controls
                    HStack(spacing: 6) {
                        // Fallback button if auto-paste fails
                        Button(action: {
                            viewModel.readClipboard(force: true)
                        }) {
                            Image(systemName: "clipboard")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(4)
                                .background(Color.black.opacity(0.05))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Force read clipboard")
                        
                        if viewModel.extractedCount > 0 {
                            Text("\(viewModel.extractedCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.8)))
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .frame(height: 90)
                .background(Color(nsColor: .controlBackgroundColor))
                // UX fix: clicking empty background area should also trigger read
                .onTapGesture {
                    viewModel.readClipboard(force: true)
                }
                
                Divider()
                
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    DisplayWebView(viewModel: viewModel)
                }
                // UX fix: clicking empty space in the list view also re-reads clipboard
                .onTapGesture {
                    viewModel.readClipboard(force: true)
                }
                
                Divider()
                
                // Bottom toolbar
                HStack {
                    Button(action: togglePin) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundColor(isPinned ? .blue : .secondary)
                            .rotationEffect(.degrees(isPinned ? 45 : 0))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    
                    Spacer()
                    
                    Text("LaTeX Vector")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.trailing, 10)
                }
                .frame(height: 24)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            
            // Off-screen WebView used to render the PDF vector
            WorkerWebView(viewModel: viewModel)
                .frame(width: 2000, height: 2000)
                .opacity(0)
                .allowsHitTesting(false)
                .position(x: -1000, y: -1000)
            
            if viewModel.showSuccessToast {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Copied")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Material.regular)
                    .cornerRadius(16)
                    .shadow(radius: 5)
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .frame(minWidth: 200, maxWidth: 200, minHeight: 200, maxHeight: 400)
        .onAppear { viewModel.readClipboard(force: true) }
        // Critical: Always grab clipboard when window comes to foreground
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.readClipboard(force: true)
        }
    }
    
    private func togglePin() {
        isPinned.toggle()
        window?.level = isPinned ? .floating : .normal
    }
}

// MARK: - ViewModel
class LatexViewModel: NSObject, ObservableObject {
    @Published var textInput: String = ""
    @Published var extractedFormulas: [String] = []
    @Published var extractedCount: Int = 0
    @Published var showSuccessToast: Bool = false
    
    var displayWebView: WKWebView?
    var workerWebView: WKWebView?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        super.init()
        setupPipeline()
    }
    
    private func setupPipeline() {
        $textInput
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.processInput(text)
            }
            .store(in: &cancellables)
    }
    
    func readClipboard(force: Bool = false) {
        let pasteboard = NSPasteboard.general
        if let content = pasteboard.string(forType: .string) {
            let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanContent.isEmpty {
                if force || cleanContent != self.textInput {
                    DispatchQueue.main.async {
                        // Don't vibrate if the content hasn't actually changed
                        if cleanContent != self.textInput {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        }
                        self.textInput = cleanContent
                    }
                }
            }
        }
    }
    
    func processInput(_ text: String) {
        let formulas = extractFormulas(from: text)
        self.extractedFormulas = formulas
        self.extractedCount = formulas.count
        updateDisplayWebView()
        if let first = formulas.first { copyFormula(latex: first) }
    }
    
    func copyFormula(latex: String) {
        guard let worker = workerWebView else { return }
        worker.loadHTMLString(generateWorkerHTML(latex: latex), baseURL: nil)
    }
    
    private func extractFormulas(from text: String) -> [String] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty { return [] }
        
        // Supports $$...$$, \[...\], \(...\) and inline $...$
        let pattern = #"(\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|(?<!\\)\$(?:[^$]+?)\$(?!\d))"#
        var results: [String] = []
        
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = cleanText as NSString
            let matches = regex.matches(in: cleanText, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches { results.append(sanitize(nsString.substring(with: match.range))) }
        }
        
        // Fallback: treat the whole string as latex if it's short and looks "mathy"
        if results.isEmpty && !cleanText.isEmpty && cleanText.count < 200 {
            if cleanText.contains("\\") || cleanText.contains("=") { return [sanitize(cleanText)] }
        }
        return results
    }
    
    private func sanitize(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapper symbols
        if let regex = try? NSRegularExpression(pattern: "^(\\$+|\\\\(\\[|\\())", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.count), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: "(\\$+|\\\\(\\]|\\)))$", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.count), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
    
    // HTML Templates
    private func updateDisplayWebView() {
        guard let webView = displayWebView else { return }
        let listItems = extractedFormulas.enumerated().map { (index, latex) in
            let safe = latex.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return """
            <div class="card" onclick="sendClick(\(index))">
                <div class="math-wrapper">$$ \(safe) $$</div>
            </div>
            """
        }.joined(separator: "\n")
        
        // Inject MathJax scripts
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <script src="https://polyfill.io/v3/polyfill.min.js?features=es6"></script>
            <script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
            <script>
                function sendClick(idx) { window.webkit.messageHandlers.listClicked.postMessage(idx); }
                window.MathJax = { tex: { macros: { bm: ["\\\\boldsymbol{#1}", 1] } } };
            </script>
            <style>
                body { margin: 0; padding: 8px; background-color: transparent; font-family: -apple-system, system-ui; }
                .card {
                    background: white; margin-bottom: 8px; padding: 8px;
                    border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.05);
                    cursor: pointer; border: 1px solid rgba(0,0,0,0.05);
                    transition: transform 0.1s, border-color 0.1s;
                }
                .card:hover { transform: translateY(-1px); border-color: #007AFF; }
                .math-wrapper { overflow-x: auto; overflow-y: hidden; display: flex; justify-content: center; }
                .math-wrapper::-webkit-scrollbar { display: none; }
                svg { color: #333 !important; fill: #333 !important; }
            </style>
        </head>
        <body>\(listItems)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    private func generateWorkerHTML(latex: String) -> String {
        let safe = latex.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <script src="https://polyfill.io/v3/polyfill.min.js?features=es6"></script>
            <script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
            <script>
                window.MathJax = {
                  tex: { macros: { bm: ["\\\\boldsymbol{#1}", 1] } },
                  startup: {
                    pageReady: () => {
                      return MathJax.startup.defaultPageReady().then(() => {
                        // Add a small delay to ensure rendering is actually complete before we snap the PDF
                        setTimeout(() => { window.webkit.messageHandlers.workerDone.postMessage("done"); }, 80);
                      });
                    }
                  },
                  svg: { scale: 1.5 }
                };
            </script>
            <style>
                body { margin: 0; padding: 0; }
                #content { display: inline-block; padding: 10px; }
                svg { color: black !important; fill: black !important; }
            </style>
        </head>
        <body><div id="content">$$ \(safe) $$</div></body>
        </html>
        """
    }
    
    func generatePDFFromWorker() {
        guard let webView = workerWebView else { return }
        
        // Calculate size dynamically
        let js = "var rect = document.getElementById('content').getBoundingClientRect(); [rect.width, rect.height]"
        webView.evaluateJavaScript(js) { (result, error) in
            var contentRect = CGRect(x: 0, y: 0, width: 500, height: 200)
            if let sizes = result as? [CGFloat], sizes.count == 2 {
                contentRect = CGRect(x: 0, y: 0, width: ceil(sizes[0]), height: ceil(sizes[1]))
            }
            
            let config = WKPDFConfiguration()
            config.rect = contentRect
            
            webView.createPDF(configuration: config) { [weak self] result in
                if case .success(let pdfData) = result {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(pdfData, forType: .pdf)
                    self?.triggerSuccessAnimation()
                }
            }
        }
    }
    
    private func triggerSuccessAnimation() {
        withAnimation(.spring()) { self.showSuccessToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { self.showSuccessToast = false }
        }
    }
}

// MARK: - Helpers
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DisplayHandler: NSObject, WKScriptMessageHandler {
    weak var viewModel: LatexViewModel?
    init(viewModel: LatexViewModel) { self.viewModel = viewModel }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "listClicked", let index = message.body as? Int {
            DispatchQueue.main.async {
                if let vm = self.viewModel, index < vm.extractedFormulas.count {
                    vm.copyFormula(latex: vm.extractedFormulas[index])
                }
            }
        }
    }
}

class WorkerHandler: NSObject, WKScriptMessageHandler {
    weak var viewModel: LatexViewModel?
    init(viewModel: LatexViewModel) { self.viewModel = viewModel }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "workerDone" {
            DispatchQueue.main.async { self.viewModel?.generatePDFFromWorker() }
        }
    }
}

struct DisplayWebView: NSViewRepresentable {
    @ObservedObject var viewModel: LatexViewModel
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(DisplayHandler(viewModel: viewModel), name: "listClicked")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        DispatchQueue.main.async { viewModel.displayWebView = webView; viewModel.processInput(viewModel.textInput) }
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WorkerWebView: NSViewRepresentable {
    @ObservedObject var viewModel: LatexViewModel
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WorkerHandler(viewModel: viewModel), name: "workerDone")
        let webView = WKWebView(frame: .zero, configuration: config)
        DispatchQueue.main.async { viewModel.workerWebView = webView }
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
