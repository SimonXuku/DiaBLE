import Foundation
import SwiftUI


struct Console: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var log: Log
    @EnvironmentObject var settings: Settings

    @State private var onlineCountdown: Int = 0
    @State private var readingCountdown: Int = 0

    @State private var showingFilterField = false
    @State private var filterString = ""

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {

            if showingFilterField {
                ScrollView {

                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(Color(.lightGray))
                        TextField("Filter", text: $filterString)
                            .foregroundColor(.blue)
                        if filterString.count > 0 {
                            Button {
                                filterString = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .frame(maxWidth: 24)
                            .padding(0)
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        }
                    }

                    // TODO: picker to filter labels
                    ForEach(Array(log.labels), id: \.self) { label in
                        Button {
                            filterString = label
                        } label: {
                            Text(label).font(.caption).foregroundColor(.blue)
                        }
                    }
                }
                .padding()
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if filterString.isEmpty {
                            ForEach(log.entries) { entry in
                                Text(entry.message)
                            }
                        } else {
                            let pattern = filterString.lowercased()
                            ForEach(log.entries.filter { $0.message.lowercased().contains(pattern) }) { entry in
                                Text(entry.message)
                            }
                        }
                    }
                }
                // .font(.system(.footnote, design: .monospaced)).foregroundColor(Color(.lightGray))
                .font(.footnote).foregroundColor(Color(.lightGray))
                .onChange(of: log.entries.count) { _ in
                    if !settings.reversedLog {
                        withAnimation {
                            proxy.scrollTo(log.entries.last!.id, anchor: .bottom)
                        }
                    } else {
                        withAnimation {
                            proxy.scrollTo(log.entries[0].id, anchor: .top)
                        }
                    }
                }
                .onChange(of: log.entries[0].id) { _ in
                    if !settings.reversedLog {
                        withAnimation {
                            proxy.scrollTo(log.entries.last!.id, anchor: .bottom)
                        }
                    } else {
                        withAnimation {
                            proxy.scrollTo(log.entries[0].id, anchor: .top)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showingFilterField.toggle() }
                    } label: {
                        Image(systemName: filterString.isEmpty ? "line.horizontal.3.decrease.circle" : "line.horizontal.3.decrease.circle.fill").font(.title3)
                        Text("Filter")
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.blue)


            HStack(alignment: .center, spacing: 0) {

                VStack(spacing: 0) {

                    Button {
                        app.main.rescan()
                    } label: {
                        VStack {
                            Image("Bluetooth").renderingMode(.template).resizable().frame(width: 24, height: 24)
                        }
                    }
                }.foregroundColor(.blue)

                if (app.status.hasPrefix("Scanning") || app.status.hasSuffix("retrying...")) && app.main.centralManager.state != .poweredOff {
                    Button {
                        app.main.centralManager.stopScan()
                        app.main.status("Stopped scanning")
                        app.main.log("Bluetooth: stopped scanning")
                    } label: {
                        Image(systemName: "octagon").resizable().frame(width: 24, height: 24)
                            .overlay((Image(systemName: "hand.raised.fill").resizable().frame(width: 12, height: 12).offset(x: 1)))
                    }.foregroundColor(.red)

                } else if app.deviceState == "Connected" || app.deviceState == "Reconnecting..." || app.status.hasSuffix("retrying...") {
                    Button {
                        if app.device != nil {
                            app.main.centralManager.cancelPeripheralConnection(app.device.peripheral!)
                        }
                    } label: {
                        Image(systemName: "escape").resizable().padding(3).frame(width: 24, height: 24)
                            .foregroundColor(.blue)
                    }

                } else {
                    Image(systemName: "octagon").resizable().frame(width: 24, height: 24)
                        .hidden()
                }

                if onlineCountdown <= 0 && !app.deviceState.isEmpty && app.deviceState != "Disconnected" {
                    VStack(spacing: 0) {
                        Text(readingCountdown > 0 || app.deviceState == "Reconnecting..." ?
                             "\(readingCountdown)" : " ")
                        Text(readingCountdown > 0 || app.deviceState == "Reconnecting..." ?
                             "s" : " ")
                    }
                    .font(Font.footnote.monospacedDigit()).foregroundColor(.orange)
                    .frame(width: 24, height: 24)
                    .allowsTightening(true)
                    .fixedSize()
                    .onReceive(timer) { _ in
                        // workaround: watchOS fails converting the interval to an Int32
                        if app.lastConnectionDate == Date.distantPast {
                            readingCountdown = 0
                        } else {
                            readingCountdown = settings.readingInterval * 60 - Int(Date().timeIntervalSince(app.lastConnectionDate))
                        }
                    }
                } else {
                    Text(" ").font(Font.footnote.monospacedDigit()).frame(width: 24, height: 24).fixedSize().hidden()
                }

                Text(onlineCountdown > 0 ? "\(onlineCountdown) s" : "")
                    .fixedSize()
                    .foregroundColor(.cyan).font(Font.footnote.monospacedDigit())
                    .onReceive(timer) { _ in
                        // workaround: watchOS fails converting the interval to an Int32
                        if settings.lastOnlineDate == Date.distantPast {
                            onlineCountdown = 0
                        } else {
                            onlineCountdown = settings.onlineInterval * 60 - Int(Date().timeIntervalSince(settings.lastOnlineDate))
                        }
                    }

                Spacer()

                Button {
                    settings.debugLevel = DebugLevel(rawValue:(settings.debugLevel.rawValue + 1) % DebugLevel.allCases.count)!
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(settings.debugLevel != .basic ? Color.blue : Color.clear)
                        Image(systemName: ["doc.plaintext", "ladybug", "testtube.2"][settings.debugLevel.rawValue]).resizable().frame(width: 22, height: 22).foregroundColor(settings.debugLevel != .basic ? .black : .blue)
                    }.frame(width: 24, height: 24)
                }

                //      Button {
                //          UIPasteboard.general.string = log.entries.map(\.message).joined(separator: "\n \n")
                //      } label: {
                //          VStack {
                //              Image(systemName: "doc.on.doc").resizable().frame(width: 24, height: 24)
                //              Text("Copy").offset(y: -6)
                //          }
                //      }

                Button {
                    log.entries = [LogEntry(message: "Log cleared \(Date().local)")]
                    log.labels = []
                    print("Log cleared \(Date().local)")
                } label: {
                    VStack {
                        Image(systemName: "clear").resizable().foregroundColor(.blue).frame(width: 24, height: 24)
                    }
                }

                Button {
                    settings.reversedLog.toggle()
                    log.entries.reverse()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(settings.reversedLog ? Color.blue : Color.clear)
                        RoundedRectangle(cornerRadius: 5).stroke(settings.reversedLog ? Color.clear : Color.blue, lineWidth: 2)
                        Image(systemName: "backward.fill").resizable().frame(width: 12, height: 12).foregroundColor(settings.reversedLog ? .black : .blue)
                    }.frame(width: 24, height: 24)
                }

                Button {
                    settings.logging.toggle()
                    app.main.log("\(settings.logging ? "Log started" : "Log stopped") \(Date().local)")
                } label: {
                    VStack {
                        Image(systemName: settings.logging ? "stop.circle" : "play.circle").resizable().frame(width: 24, height: 24).foregroundColor(settings.logging ? .red : .green)
                    }
                }

            }.font(.footnote)
        }
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle("Console")
    }
}


struct Console_Previews: PreviewProvider {

    static var previews: some View {
        Group {
            Console()
                .environmentObject(AppState.test(tab: .console))
                .environmentObject(Log())
                .environmentObject(Settings())
        }
    }
}
