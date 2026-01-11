import SwiftUI

enum Tab: String, CaseIterable {
    case drill = "Drills"
    case train = "Train"
    case progress = "Progress"
    case profiles = "Profiles"
    
    var icon: String {
        switch self {
        case .drill: return "list.bullet"
        case .train: return "play.circle.fill"
        case .progress: return "chart.line.uptrend.xyaxis"
        case .profiles: return "person.circle"
        }
    }
}

struct CustomTabBar: View {
    @Binding var selectedTab: Tab
    @Namespace private var animationNamespace
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                TabButton(
                    tab: tab,
                    selectedTab: $selectedTab,
                    animationNamespace: animationNamespace
                )
            }
        }
        .frame(height: 60)
        .background(Theme.deepBlue)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.white.opacity(0.2)),
            alignment: .top
        )
    }
}

struct TabButton: View {
    let tab: Tab
    @Binding var selectedTab: Tab
    let animationNamespace: Namespace.ID
    
    private var isSelected: Bool {
        selectedTab == tab
    }
    
    var body: some View {
        Button {
            HapticFeedback.cardTap()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: isSelected ? 21 : 19, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.orange : Color.white.opacity(0.55))
                    .scaleEffect(isSelected ? 1.05 : 1.0)
                
                Text(tab.rawValue)
                    .font(.system(size: isSelected ? 11 : 10, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundColor(isSelected ? Theme.orange : Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.orange.opacity(0.15))
                            .matchedGeometryEffect(id: "selectedTab", in: animationNamespace)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
}

struct TabBarContainer<Content: View>: View {
    @Binding var selectedTab: Tab
    let content: Content
    
    init(selectedTab: Binding<Tab>, @ViewBuilder content: () -> Content) {
        self._selectedTab = selectedTab
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            CustomTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
