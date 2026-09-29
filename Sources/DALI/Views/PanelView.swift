// DALI — the main window. One fixed 328 × 540 panel:
//
//   wordmark ··· status
//   [ primary button ]
//   ┌ room card ──────┐   (or the error card, in exactly the same frame)
//   └─────────────────┘
//   ( source ··· delay · gear )
//
// A quiet room glow under native glass controls and a stable room surface.

import SwiftUI

struct PanelView: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        GlassGroup {
            content
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background(RoomBackdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await store.refreshSpeakers()
            await store.loadLibrary()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
                .frame(height: PanelMetrics.headerHeight)
                .padding(.bottom, Space.m)
            Button(store.primaryVerb) { store.bigButtonTapped() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.isError)
                .padding(.bottom, Space.l)
            Group {
                if let message = store.errorMessage ?? Self.previewError {
                    ErrorCard(message: message)
                } else {
                    RoomCard()
                }
            }
            .frame(maxHeight: .infinity)
            PanelFooter()
                .padding(.top, Space.m)
        }
        .padding(.horizontal, Space.l)
        .padding(.top, PanelMetrics.titlebar)
        .padding(.bottom, 14)
        // Laid out under the titlebar's safe area, so the header keeps its
        // distance from the traffic lights whatever height the system gives
        // the titlebar. The backdrop runs up behind them.
    }

    /// UI harness only: `DALI_PREVIEW_ERROR=<message>` shows the error card.
    private static var previewError: String? {
        DALIStore.isPreview ? ProcessInfo.processInfo.environment["DALI_PREVIEW_ERROR"] : nil
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("DALI")
                .font(.wordmark(22))
                .foregroundStyle(Color.paper)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(tone: store.statusTone, pulsing: store.statusPulsing)
                Text(store.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.paper62)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(store.statusText)")
        }
        // The whole wordmark row moves the window.
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

/// Static light behind the glass. It remains the same when the window loses
/// focus, so the idle room never becomes a flat grey sheet. This is room
/// ambience: nearly black at the top, a faint neutral light below.
private struct RoomBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.ink
                LinearGradient(stops: [
                    .init(color: Color.ink, location: 0),
                    .init(color: Color(white: 14/255), location: 0.48),
                    .init(color: Color(white: 18/255), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                RadialGradient(stops: [
                    .init(color: Color.white.opacity(0.025), location: 0),
                    .init(color: Color.white.opacity(0.008), location: 0.42),
                    .init(color: .clear, location: 1),
                ], center: .init(x: 0.5, y: 0.78),
                   startRadius: 0, endRadius: geo.size.width * 0.9)
            }
        }
        .allowsHitTesting(false)
    }
}
