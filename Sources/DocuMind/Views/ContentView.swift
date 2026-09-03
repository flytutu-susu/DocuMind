import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case ocr = "文字识别"
    case convert = "PDF 转 Word"
    case chat = "AI 对话"
    case server = "局域网服务"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ocr: return "doc.text.viewfinder"
        case .convert: return "doc.on.doc"
        case .chat: return "bubble.left.and.bubble.right"
        case .server: return "network"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SidebarItem? = .ocr

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection ?? .ocr {
            case .ocr:
                OCRView(sidebarSelection: $selection)
            case .convert:
                ConvertView()
            case .chat:
                ChatView()
            case .server:
                ServerView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
