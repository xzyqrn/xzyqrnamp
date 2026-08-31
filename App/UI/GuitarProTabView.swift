import Foundation
import SwiftUI
import WebKit

struct GuitarProTabView: NSViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator {
        Coordinator(data: data)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: Coordinator.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.loadViewer(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        context.coordinator.loadViewer(in: webView)
    }

    final class Coordinator: NSObject, WKURLSchemeHandler {
        static let scheme = "xzyqrn-tab"
        var data: Data

        init(data: Data) {
            self.data = data
        }

        func loadViewer(in webView: WKWebView) {
            guard let url = URL(string: "\(Self.scheme)://viewer/viewer.html") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }

            let resource: (data: Data, mime: String)?
            switch url.path {
            case "/viewer.html":
                resource = bundled("viewer", extension: "html", mime: "text/html")
            case "/alphaTab.min.js":
                resource = bundled("alphaTab.min", extension: "js", mime: "text/javascript")
            case "/font/Bravura.woff2":
                resource = bundled("Bravura", extension: "woff2", mime: "font/woff2")
            case "/score.gp":
                resource = (data, "application/octet-stream")
            default:
                resource = nil
            }

            guard let resource else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = URLResponse(
                url: url,
                mimeType: resource.mime,
                expectedContentLength: resource.data.count,
                textEncodingName: resource.mime.hasPrefix("text/") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        private func bundled(
            _ name: String,
            extension ext: String,
            mime: String
        ) -> (Data, String)? {
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: ext
            ), let bytes = try? Data(contentsOf: url) else { return nil }
            return (bytes, mime)
        }
    }
}
