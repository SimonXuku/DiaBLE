import Foundation


// https://github.com/timoschlueter/nightscout-librelink-up


enum LibreLinkUpError: LocalizedError {
    case noConnection
    case notAuthenticated
    case jsonDecoding

    var errorDescription: String? {
        switch self {
        case .noConnection:     return "no connection"
        case .notAuthenticated: return "not authenticated"
        case .jsonDecoding:     return "JSON decoding"
        }
    }
}


struct AuthTicket: Codable {
    let token: String
    let expires: Int
    let duration: Int
}


enum MeasurementColor: Int, Codable {
    case green  = 1
    case yellow = 2
    case orange = 3
    case red    = 4
}


struct GlucoseMeasurement: Codable {
    let factoryTimestamp: String
    let timestamp: String
    let type: Int  //  0: graph, 1: logbook, 2: alarm, 3: hybrid
    let alarmType: Int?  // when type = 3  1: low, 2: high
    let valueInMgPerDl: Int
    let trendArrow: OOP.TrendArrow?    // in logbook but not in graph data
    let trendMessage: String?
    let measurementColor: MeasurementColor
    let glucoseUnits: Int
    let value: Int
    let isHigh: Bool
    let isLow: Bool
    enum CodingKeys: String, CodingKey { case factoryTimestamp = "FactoryTimestamp", timestamp = "Timestamp", type, alarmType, valueInMgPerDl = "ValueInMgPerDl", trendArrow = "TrendArrow", trendMessage = "TrendMessage", measurementColor = "MeasurementColor", glucoseUnits = "GlucoseUnits", value = "Value", isHigh, isLow }
}


struct LibreLinkUpGlucose: Identifiable, Codable {
    let glucose: Glucose
    let color: MeasurementColor
    let trendArrow: OOP.TrendArrow?
    var id: Int { glucose.id }
}


struct LibreLinkUpAlarm: Identifiable, Codable, CustomStringConvertible {
    let factoryTimestamp: String
    let timestamp: String
    let type: Int  // 2 (1 for measurements)
    let alarmType: Int  // 0: low, 1: high
    enum CodingKeys: String, CodingKey { case factoryTimestamp = "FactoryTimestamp", timestamp = "Timestamp", type, alarmType }
    var id: Int { Int(date.timeIntervalSince1970) }
    var date: Date = Date()
    var alarmDescription: String { alarmType == 0 ? "LOW" : "HIGH" }
    var description: String { "\(date): \(alarmDescription)" }
}


class LibreLinkUp: Logging {

    var main: MainDelegate!

    let siteURL = "https://api.libreview.io"
    let localSiteURL = "https://api-eu.libreview.io"
    let loginEndpoint = "llu/auth/login"
    let connectionsEndpoint = "llu/connections"
    let measurementsEndpoint = "lsl/api/measurements"

    let headers = [
        "User-Agent": "Mozilla/5.0",
        "Content-Type": "application/json",
        "product": "llu.ios",
        "version": "4.2.0",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Pragma": "no-cache",
        "Cache-Control": "no-cache",
    ]


    init(main: MainDelegate) {
        self.main = main
    }


    @discardableResult
    func login() async throws -> (Any, URLResponse) {
        var request = URLRequest(url: URL(string: "\(siteURL)/\(loginEndpoint)")!)
        let credentials = await [
            "email": main.settings.libreLinkUpEmail,
            "password": main.settings.libreLinkUpPassword
        ]
        request.httpMethod = "POST"
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let jsonData = try? JSONSerialization.data(withJSONObject: credentials)
        request.httpBody = jsonData
        do {
            debugLog("LibreLinkUp: posting to \(request.url!.absoluteString) \(jsonData!.string), headers: \(headers)")
            let (data, response) = try await URLSession.shared.data(for: request)
            debugLog("LibreLinkUp: response data: \(data.string)")
            if let response = response as? HTTPURLResponse {
                let status = response.statusCode
                if status == 401 {
                    log("LibreLinkUp: POST not authorized")
                } else {
                    log("LibreLinkUp: POST \((200..<300).contains(status) ? "success" : "error") (status: \(status))")
                }
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? Int {
                    if status == 2 {  // {"status":2,"error":{"message":"notAuthenticated"}}
                        throw LibreLinkUpError.notAuthenticated
                    }
                    if let data = json["data"] as? [String: Any],
                       let user = data["user"] as? [String: Any],
                       let id = user["id"] as? String,
                       let authTicketDict = data["authTicket"] as? [String: Any] {
                        let authTicket = AuthTicket(token: authTicketDict["token"] as? String ?? "",
                                                    expires: authTicketDict["expires"] as? Int ?? 0,
                                                    duration: authTicketDict["duration"] as? Int ?? 0)
                        self.log("LibreLinkUp: user id: \(id), authTicket: \(authTicket), expires on \(Date(timeIntervalSince1970: Double(authTicket.expires)))")
                        DispatchQueue.main.async {
                            self.main.settings.libreLinkUpPatientId = id
                            self.main.settings.libreLinkUpToken = authTicket.token
                            self.main.settings.libreLinkUpTokenExpirationDate = Date(timeIntervalSince1970: Double(authTicket.expires))
                        }
                    }
                }
                return (data, response)
            }
        } catch {
            log("LibreLinkUp: server error: \(error.localizedDescription)")
            throw error
        }
    }


    func getPatientGraph() async throws -> (Any, URLResponse, [LibreLinkUpGlucose], Any, [LibreLinkUpGlucose], [LibreLinkUpAlarm]) {
        var request = URLRequest(url: URL(string: "\(localSiteURL)/\(connectionsEndpoint)/\(await main.settings.libreLinkUpPatientId)/graph")!)
        var authenticatedHeaders = headers
        authenticatedHeaders["Authorization"] = await "Bearer \(main.settings.libreLinkUpToken)"
        for (header, value) in authenticatedHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        debugLog("LibreLinkUp: URL request: \(request.url!.absoluteString), authenticated headers: \(request.allHTTPHeaderFields!)")

        var history: [LibreLinkUpGlucose] = []
        var logbookData: Data = Data()
        var logbookHistory: [LibreLinkUpGlucose] = []
        var alarms:  [LibreLinkUpAlarm] = []

        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"

        var activeSensorActivationDate: Date = Date.distantPast

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            debugLog("LibreLinkUp: response data: \(data.string), status: \((response as! HTTPURLResponse).statusCode)")
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let data = json["data"] as? [String: Any],
                   let connection = data["connection"] as? [String: Any] {
                    log("LibreLinkUp: connection data: \(connection)")
                    if let activeSensors = data["activeSensors"] as? [[String: Any]] {
                        log("LibreLinkUp: active sensors: \(activeSensors)")
                        for (i, activeSensor) in activeSensors.enumerated() {
                            // TODO: activeSensor["device"]
                            if let sensor = activeSensor["sensor"] as? [String: Any],
                               let deviceId = sensor["deviceId"] as? String,
                               let sn = sensor["sn"] as? String,
                               let a = sensor["a"] as? Int,
                               let pt = sensor["pt"] as? Int {
                                let activationDate = Date(timeIntervalSince1970: Double(a))
                                if await main.app.sensor == nil && pt == 4 {  // TEST create and prioritize a Libre 3
                                    DispatchQueue.main.async {
                                        self.main.app.sensor = Libre3(main: self.main)
                                        self.main.app.sensor.type = .libre3
                                        self.main.app.sensor.serial = sn
                                        self.main.app.sensor.state = .active
                                        self.main.app.sensor.lastReadingDate = Date()
                                    }
                                }
                                if let appSensor = await main.app.sensor,
                                   appSensor.serial.hasSuffix(sn) {
                                    activeSensorActivationDate = activationDate
                                    DispatchQueue.main.async {
                                        self.main.app.sensor.activationTime = UInt32(a)
                                        self.main.app.sensor.age = Int(Date().timeIntervalSince(activationDate)) / 60
                                    }
                                }
                                log("LibreLinkUp: active sensor #\(i) of \(activeSensors.count): serial: \(sn), product type: \(pt) (3: Libre 1/2, 4: Libre 3), activation date: \(activationDate) (timestamp = \(a)), device id: \(deviceId)")
                            }
                        }
                    }
                    if let sensor = connection["sensor"] as? [String: Any],
                       let sn = sensor["sn"] as? String,
                       let a = sensor["a"] as? Int,
                       let pt = sensor["pt"] as? Int {
                        let activationDate = Date(timeIntervalSince1970: Double(a))
                        log("LibreLinkUp: sensor serial: \(sn), product type: \(pt) (3: Libre 1/2, 4: Libre 3), activation date: \(activationDate) (timestamp = \(a))")
                    }
                    var i = 0
                    if let graphData = data["graphData"] as? [[String: Any]] {
                        for glucoseMeasurement in graphData {
                            if let measurementData = try? JSONSerialization.data(withJSONObject: glucoseMeasurement),
                               let measurement = try? JSONDecoder().decode(GlucoseMeasurement.self, from: measurementData) {
                                i += 1
                                let date = formatter.date(from: measurement.timestamp)!
                                var lifeCount = Int(date.timeIntervalSince(activeSensorActivationDate)) / 60
                                // FIXME: lifeCount not always multiple of 5
                                if lifeCount % 5 == 1 { lifeCount -= 1 }
                                history.append(LibreLinkUpGlucose(glucose: Glucose(measurement.valueInMgPerDl, id: lifeCount, date: date, source: "LibreLinkUp"), color: measurement.measurementColor, trendArrow: measurement.trendArrow))
                                debugLog("LibreLinkUp: graph measurement #\(i) of \(graphData.count): \(measurement) (JSON: \(glucoseMeasurement)), lifeCount = \(lifeCount)")
                            }
                        }
                    }
                    if let glucoseMeasurement = connection["glucoseMeasurement"] as? [String: Any],
                       let measurementData = try? JSONSerialization.data(withJSONObject: glucoseMeasurement),
                       let measurement = try? JSONDecoder().decode(GlucoseMeasurement.self, from: measurementData) {
                        i += 1
                        let date = formatter.date(from: measurement.timestamp)!
                        let lifeCount = Int(date.timeIntervalSince(activeSensorActivationDate)) / 60
                        history.append(LibreLinkUpGlucose(glucose: Glucose(measurement.valueInMgPerDl, id: lifeCount, date: date, source: "LibreLinkUp"), color: measurement.measurementColor, trendArrow: measurement.trendArrow))
                        debugLog("LibreLinkUp: last glucose measurement #\(i) of \(history.count): \(measurement) (JSON: \(glucoseMeasurement))")
                    }
                    log("LibreLinkUp: graph values: \(history.map { ($0.glucose.id, $0.glucose.value, $0.glucose.date.shortDateTime, $0.color) })")

                    if await main.settings.libreLinkUpScrapingLogbook,
                       let ticketDict = json["ticket"] as? [String: Any],
                       let token = ticketDict["token"] as? String {
                        self.log("LibreLinkUp: new token for logbook: \(token)")
                        request.setValue(await "Bearer \(token)", forHTTPHeaderField: "Authorization")
                        request.url =  URL(string: "\(localSiteURL)/\(connectionsEndpoint)/\(await main.settings.libreLinkUpPatientId)/logbook")!
                        debugLog("LibreLinkUp: URL request: \(request.url!.absoluteString), authenticated headers: \(request.allHTTPHeaderFields!)")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        debugLog("LibreLinkUp: response data: \(data.string), status: \((response as! HTTPURLResponse).statusCode)")
                        logbookData = data
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let data = json["data"] as? [[String: Any]] {
                            for entry in data {
                                let type = entry["type"] as! Int

                                if type == 1 || type == 3 {  // measurement  (type 3 has an alarmType 1: low, 2: high)  // TODO
                                    if let measurementData = try? JSONSerialization.data(withJSONObject: entry),
                                       let measurement = try? JSONDecoder().decode(GlucoseMeasurement.self, from: measurementData) {
                                        i += 1
                                        let date = formatter.date(from: measurement.timestamp)!
                                        logbookHistory.append(LibreLinkUpGlucose(glucose: Glucose(measurement.valueInMgPerDl, id: i, date: date, source: "LibreLinkUp"), color: measurement.measurementColor, trendArrow: measurement.trendArrow))
                                        debugLog("LibreLinkUp: logbook measurement #\(i - history.count) of \(data.count): \(measurement) (JSON: \(entry))")
                                    }

                                } else if type == 2 {  // alarm
                                    if let alarmData = try? JSONSerialization.data(withJSONObject: entry),
                                       var alarm = try? JSONDecoder().decode(LibreLinkUpAlarm.self, from: alarmData) {
                                        alarm.date = formatter.date(from: alarm.timestamp)!
                                        alarms.append(alarm)
                                        debugLog("LibreLinkUp: logbook alarm: \(alarm) (JSON: \(entry))")
                                    }
                                }

                            }

                            // TODO: merge with history and display trend arrow
                            log("LibreLinkUp: logbook values: \(logbookHistory.map { ($0.glucose.id, $0.glucose.value, $0.glucose.date.shortDateTime, $0.color, $0.trendArrow!.symbol) }), alarms: \(alarms.map(\.description))")
                        }
                    }
                }

                return (data, response, history, logbookData, logbookHistory, alarms)

            } catch {
                log("LibreLinkUp: error while decoding response: \(error.localizedDescription)")
                throw LibreLinkUpError.jsonDecoding
            }
        } catch {
            log("LibreLinkUp: server error: \(error.localizedDescription)")
            throw LibreLinkUpError.noConnection
        }
    }

}
