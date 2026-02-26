import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("LiDAR Scanner")
                    .font(.largeTitle)
                    .bold()

                Text("Scan objects and find CAD files")
                    .foregroundColor(.gray)

                NavigationLink(destination: ScannerView()) {
                    Text("Start Scanning")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 50)
                        .background(Color.blue)
                        .cornerRadius(10)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
