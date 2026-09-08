import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell")
                .font(.system(size: 48))
            Text("suzu")
                .font(.title)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
