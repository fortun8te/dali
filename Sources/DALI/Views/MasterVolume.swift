// DALI — extras list.

import SwiftUI

struct ExtrasDisclosure: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        // No extras on the network -> no row at all. The panel stays clean.
        if !store.extras.isEmpty {
            VStack(spacing: 8) {
                Button {
                    withAnimation(DS.spring) { store.extrasExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(store.extrasExpanded ? 90 : 0))
                        Text("More speakers (\(store.extras.count))")
                            .font(.bodySmall)
                        Spacer()
                    }
                    .foregroundStyle(Color.paper60)
                }
                .buttonStyle(.plain)

                if store.extrasExpanded {
                    VStack(spacing: 4) {
                        ForEach(store.extras) { extra in
                            ExtraRow(speaker: extra)
                        }
                    }
                }
            }
        }
    }
}

struct ExtraRow: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker

    var body: some View {
        HStack(spacing: 8) {
            Text(speaker.name)
                .font(.bodyBase)
                .foregroundStyle(speaker.enabled ? Color.paper : Color.paper60)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(
                get: { speaker.enabled },
                set: { _ in store.toggle(speaker) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.accentBlue)
        }
        .frame(height: 30)
    }
}
