import SwiftUI

/// Root view: the offline library inside a navigation stack.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            LibraryView()
        }
    }
}
