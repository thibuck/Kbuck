import SwiftUI
import UIKit

// MARK: - Lógica y Modelos (Sin cambios funcionales, solo estructura)

// ... (Tus estructuras privadas API y SheetEvent se mantienen igual)
private struct SheetEvent: Codable {
    let action: String; let type: String; let amount: Double; let date: String
    let description: String; let person: String; let deviceName: String
    let deviceId: String; let clientTimestamp: String; let recordId: String
    let extra: [String: String]?
}

private enum SheetsAPI {
    static let endpoint = URL(string: "https://script.google.com/macros/s/AKfycbwGgSecGv9dNhmmwfvoH24oCl05Pg5ChiAAHkGEZgBquMsgZYAlqxzofUMxG5Fx8rQr/exec")!

    static func send(_ events: [SheetEvent]) async throws {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(events)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    struct SnapshotSaldoInicial: Codable { let amount: Double; let date: String; let person: String }
    struct SnapshotIngreso: Codable { let recordId: String; let amount: Double; let date: String; let person: String; let description: String?; let extra: [String: String]? }
    struct SnapshotGasto: Codable { let recordId: String; let amount: Double; let date: String; let person: String; let description: String; let extra: [String: String]? }
    struct SheetsSnapshot: Codable { let saldoInicial: SnapshotSaldoInicial?; let ingresos: [SnapshotIngreso]; let gastos: [SnapshotGasto] }

    static func fetchSnapshot() async throws -> SheetsSnapshot {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "action", value: "snapshot")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(SheetsSnapshot.self, from: data)
    }
}

// MARK: - Helpers (Fechas, Dispositivos, Queue)
private func makeDeviceInfo() -> (name: String, id: String) {
    let name = UIDevice.current.name
    let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    return (name, id)
}

private func isoDate(_ date: Date) -> String {
    let f = DateFormatter(); f.calendar = .current; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    return f.string(from: date)
}

private func isoTimestamp(_ date: Date) -> String {
    let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0)
    return f.string(from: date)
}

private func parseISODate(_ string: String) -> Date {
    let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return Date() }
    let f1 = DateFormatter(); f1.locale = Locale(identifier: "en_US_POSIX"); f1.dateFormat = "yyyy-MM-dd"
    if let d = f1.date(from: raw) { return d }
    let f2 = DateFormatter(); f2.locale = Locale(identifier: "en_US_POSIX"); f2.dateFormat = "dd/MM/yyyy"
    if let d = f2.date(from: raw) { return d }
    // Fallbacks simplificados
    return Date()
}

private struct PendingQueue {
    static func decode(_ data: Data) -> [SheetEvent] { (try? JSONDecoder().decode([SheetEvent].self, from: data)) ?? [] }
    static func encode(_ items: [SheetEvent]) -> Data { (try? JSONEncoder().encode(items)) ?? Data() }
}

// MARK: - Modelos Públicos
enum Persona: String, CaseIterable, Identifiable {
    case katerin = "Katerin"; case augusto = "Augusto"; case otro = "Otro"
    var id: String { rawValue }
}

enum Categoria: String, CaseIterable, Identifiable {
    case carExpenses = "Car Expenses"; case otros = "Otros"
    var id: String { rawValue }
}

extension Categoria {
    static func parse(_ raw: String?) -> Categoria {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("car") || s.contains("auto") { return .carExpenses }
        return .otros
    }
}

// MARK: - FastCurrencyField (Tu implementación original)
struct FastCurrencyField: UIViewRepresentable {
    @Binding var value: Double
    var currencyCode: String
    var onLiveValueChange: ((Double) -> Void)? = nil

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var value: Double
        let currencyFormatter: NumberFormatter
        let decimalFormatter: NumberFormatter
        var isEditing: Bool = false
        weak var textField: UITextField?
        let onLiveValueChange: ((Double) -> Void)?

        init(value: Binding<Double>, currencyCode: String, onLiveValueChange: ((Double) -> Void)?) {
            self._value = value
            let cf = NumberFormatter(); cf.numberStyle = .currency; cf.currencyCode = currencyCode; cf.maximumFractionDigits = 2; cf.minimumFractionDigits = 2
            self.currencyFormatter = cf
            let df = NumberFormatter(); df.numberStyle = .decimal; df.maximumFractionDigits = 2; df.minimumFractionDigits = 0; df.locale = cf.locale
            self.decimalFormatter = df
            self.onLiveValueChange = onLiveValueChange
        }
        func attach(_ tf: UITextField) { self.textField = tf }
        @objc func doneTapped() { textField?.endEditing(true) }
        @objc func editingChanged(_ textField: UITextField) {
            let text = textField.text ?? ""
            let filtered = String(text.filter { "0123456789.,".contains($0) })
            if let n = decimalFormatter.number(from: filtered) { onLiveValueChange?(n.doubleValue) } else { onLiveValueChange?(0) }
        }
        @objc func editingBegan(_ textField: UITextField) { isEditing = true; DispatchQueue.main.async { textField.selectAll(nil) } }
        @objc func editingEnded(_ textField: UITextField) {
            isEditing = false
            let text = textField.text ?? ""
            let filtered = String(text.filter { "0123456789.,".contains($0) })
            value = decimalFormatter.number(from: filtered)?.doubleValue ?? 0
            textField.text = currencyFormatter.string(from: NSNumber(value: value))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value, currencyCode: currencyCode, onLiveValueChange: onLiveValueChange) }
    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(); tf.keyboardType = .decimalPad; tf.textAlignment = .right
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingBegan(_:)), for: .editingDidBegin)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingEnded(_:)), for: .editingDidEnd)
        tf.text = context.coordinator.currencyFormatter.string(from: NSNumber(value: value))
        tf.placeholder = context.coordinator.currencyFormatter.string(from: NSNumber(value: 0)) ?? "0.00"
        context.coordinator.attach(tf)
        let tb = UIToolbar(); tb.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .prominent, target: context.coordinator, action: #selector(Coordinator.doneTapped))
        tb.items = [flex, done]
        tf.inputAccessoryView = tb
        return tf
    }
    func updateUIView(_ uiView: UITextField, context: Context) {
        if !uiView.isFirstResponder && !context.coordinator.isEditing {
            let formatted = context.coordinator.currencyFormatter.string(from: NSNumber(value: value))
            if uiView.text != formatted { uiView.text = formatted }
        }
    }
}

struct Ingreso: Identifiable {
    let id = UUID(); let recordId: String; let monto: Double; let fecha: Date; let quien: Persona; let categoria: Categoria
}

struct Gasto: Identifiable {
    let id = UUID(); let recordId: String; let monto: Double; let fecha: Date; let descripcion: String; let quien: Persona; let categoria: Categoria
}

// MARK: - VISTA PRINCIPAL REDISEÑADA
struct AccountInfoView: View {
    // --- Estados (Copiados del original) ---
    @AppStorage("saldoInicial") private var saldoInicial: Double = 0
    @State private var ingresos: [Ingreso] = []
    @State private var gastos: [Gasto] = []

    // Form inputs
    @State private var nuevoIngresoMonto: Double = 0
    @State private var nuevoIngresoFecha: Date = Date()
    @State private var nuevoIngresoPersona: Persona = .katerin
    @State private var ingresoMontoLive: Double = 0
    @State private var nuevoIngresoCategoria: Categoria = .otros
    @State private var nuevoGastoMonto: Double = 0
    @State private var nuevoGastoFecha: Date = Date()
    @State private var nuevoGastoDescripcion: String = ""
    @State private var nuevoGastoPersona: Persona = .katerin
    @State private var gastoMontoLive: Double = 0
    @State private var nuevoGastoCategoria: Categoria = .carExpenses

    @AppStorage("initialBalanceRecorded") private var initialBalanceRecorded: Bool = false
    @State private var saldoInicialFecha: Date = Date()
    @State private var saldoInicialPersona: Persona = .katerin
    @AppStorage("pendingEventsData") private var pendingEventsData: Data = Data()
    @State private var isSyncing: Bool = false
    @State private var lastSyncError: String? = nil
    @State private var isFetching: Bool = false
    @State private var showInitialBalanceSheet: Bool = false
    @State private var didInitialLoad: Bool = false
    @AppStorage("ingCarExpanded") private var ingCarExpanded: Bool = true
    @AppStorage("ingOtrosExpanded") private var ingOtrosExpanded: Bool = true
    @AppStorage("gasCarExpanded") private var gasCarExpanded: Bool = true
    @AppStorage("gasOtrosExpanded") private var gasOtrosExpanded: Bool = true
    @State private var showAddIngresoSheet: Bool = false
    @State private var showAddGastoSheet: Bool = false

    // --- Lógica de UI ---
    private func imageName(for persona: Persona) -> String {
        switch persona { case .katerin: return "katerin"; case .augusto: return "augusto"; case .otro: return "otro" }
    }
    private func iconName(for category: Categoria) -> String {
        switch category { case .carExpenses: return "car.fill"; case .otros: return "fork.knife" }
    }
    private func color(for category: Categoria) -> Color {
        switch category { case .carExpenses: return .blue; case .otros: return .orange }
    }
    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }
    
    // Bindings helpers
    private func ingresosExpandedBinding(for category: Categoria) -> Binding<Bool> {
        category == .carExpenses ? $ingCarExpanded : $ingOtrosExpanded
    }
    private func gastosExpandedBinding(for category: Categoria) -> Binding<Bool> {
        category == .carExpenses ? $gasCarExpanded : $gasOtrosExpanded
    }
    
    // Data sources
    private var ingresosByCategory: [(Categoria, [Ingreso])] {
        [.carExpenses, .otros].map { cat in (cat, ingresos.filter { $0.categoria == cat }.sorted { $0.fecha > $1.fecha }) }
    }
    private var gastosByCategory: [(Categoria, [Gasto])] {
        [.carExpenses, .otros].map { cat in (cat, gastos.filter { $0.categoria == cat }.sorted { $0.fecha > $1.fecha }) }
    }

    // Cálculos
    private var totalIngresos: Double { ingresos.reduce(0) { $0 + $1.monto } }
    private var totalGastos: Double { gastos.reduce(0) { $0 + $1.monto } }
    private var saldoActual: Double { saldoInicial + totalIngresos - totalGastos }
    private func asignado(_ cat: Categoria) -> Double {
        let base = ingresos.filter { $0.categoria == cat }.reduce(0) { $0 + $1.monto }
        return cat == .carExpenses ? base + saldoInicial : base
    }
    private func gastado(_ cat: Categoria) -> Double { gastos.filter { $0.categoria == cat }.reduce(0) { $0 + $1.monto } }
    private func disponible(_ cat: Categoria) -> Double { asignado(cat) - gastado(cat) }
    
    // Validaciones UI
    private var canAddIngreso: Bool { max(nuevoIngresoMonto, ingresoMontoLive) > 0 }
    private var canAddGasto: Bool { max(nuevoGastoMonto, gastoMontoLive) > 0 && !nuevoGastoDescripcion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // --- Cuerpo de la Vista ---
    var body: some View {
        NavigationStack {
            List {
                // 1. Sección de Balance (Tarjeta Moderna)
                Section {
                    BalanceCardView(
                        balance: saldoActual,
                        income: totalIngresos,
                        expense: totalGastos,
                        initial: saldoInicial
                    )
                    .listRowInsets(EdgeInsets()) // Elimina padding por defecto
                    .listRowBackground(Color.clear) // Fondo transparente para que la tarjeta flote
                }

                // 2. Alerta de Configuración Inicial
                if !initialBalanceRecorded {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configuración requerida")
                                .font(.headline)
                            Text("Registra el saldo inicial para comenzar.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Configurar ahora") { showInitialBalanceSheet = true }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // 3. Sección de Presupuestos (Progress Bars)
                Section("Presupuestos") {
                    BudgetProgressRow(category: .carExpenses, icon: "car.fill", color: .blue, asignado: asignado(.carExpenses), gastado: gastado(.carExpenses))
                    BudgetProgressRow(category: .otros, icon: "fork.knife", color: .orange, asignado: asignado(.otros), gastado: gastado(.otros))
                }
                
                // 4. Lista de Ingresos
                if !ingresos.isEmpty {
                    Section("Ingresos") {
                        ForEach(ingresosByCategory, id: \.0) { (cat, items) in
                            if !items.isEmpty {
                                DisclosureGroup(isExpanded: ingresosExpandedBinding(for: cat)) {
                                    ForEach(items) { item in
                                        TransactionRowView(
                                            imageName: imageName(for: item.quien),
                                            title: item.quien.rawValue,
                                            date: item.fecha,
                                            amount: item.amountDisplay,
                                            isIncome: true
                                        )
                                    }
                                    .onDelete { deleteIngresos(at: $0, in: items) }
                                } label: {
                                    Label(cat.rawValue, systemImage: iconName(for: cat))
                                        .foregroundStyle(color(for: cat))
                                }
                            }
                        }
                    }
                }
                
                // 5. Lista de Gastos
                if !gastos.isEmpty {
                    Section("Gastos") {
                        ForEach(gastosByCategory, id: \.0) { (cat, items) in
                            if !items.isEmpty {
                                DisclosureGroup(isExpanded: gastosExpandedBinding(for: cat)) {
                                    ForEach(items) { item in
                                        TransactionRowView(
                                            imageName: imageName(for: item.quien),
                                            title: item.descripcion.isEmpty ? "Gasto" : item.descripcion,
                                            date: item.fecha,
                                            amount: item.amountDisplay,
                                            isIncome: false
                                        )
                                    }
                                    .onDelete { deleteGastos(at: $0, in: items) }
                                } label: {
                                    Label(cat.rawValue, systemImage: iconName(for: cat))
                                        .foregroundStyle(color(for: cat))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped) // Estilo "Settings" moderno de iOS
            .refreshable { await loadFromServer() }
            .navigationTitle("Cuenta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showInitialBalanceSheet = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image("chase") // Asegúrate de tener este asset
                            .resizable().scaledToFit().frame(width: 24, height: 24).clipShape(Circle())
                        Text("Chase Kbuck").font(.headline)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: { showAddIngresoSheet = true }) { Label("Ingreso", systemImage: "plus.circle") }
                        Button(action: { showAddGastoSheet = true }) { Label("Gasto", systemImage: "minus.circle") }
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
            }
            // Modales
            .sheet(isPresented: $showInitialBalanceSheet) { initialBalanceView }
            .sheet(isPresented: $showAddIngresoSheet) { addIngresoView }
            .sheet(isPresented: $showAddGastoSheet) { addGastoView }
            .overlay {
                if isFetching {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
            }
        }
        .task {
            if !didInitialLoad {
                didInitialLoad = true
                if !pendingEvents.isEmpty { await flushQueue() } else { await loadFromServer() }
            } else if !pendingEvents.isEmpty {
                await flushQueue()
            }
        }
    }
    
    // --- Subvistas de Modales (Extractadas para limpieza) ---
    
    var initialBalanceView: some View {
        NavigationStack {
            Form {
                Section("Detalles") {
                    DatePicker("Fecha", selection: $saldoInicialFecha, displayedComponents: .date)
                    HStack {
                        Text("Monto")
                        Spacer()
                        FastCurrencyField(value: $saldoInicial, currencyCode: currencyCode).frame(width: 120)
                    }
                }
                Section("Persona") {
                    PersonSelector(selected: $saldoInicialPersona)
                }
                Section {
                    Button(initialBalanceRecorded ? "Actualizar" : "Registrar Saldo") {
                        submitInitialBalance()
                    }
                    .disabled(saldoInicial <= 0)
                }
                
                if isSyncing || (lastSyncError != nil) {
                    Section("Estado") {
                        if isSyncing { ProgressView("Sincronizando...") }
                        if let err = lastSyncError { Text(err).foregroundStyle(.red).font(.caption) }
                    }
                }
            }
            .navigationTitle("Saldo Inicial")
            .toolbar { Button("Cerrar") { showInitialBalanceSheet = false } }
        }
    }
    
    var addIngresoView: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Monto").fontWeight(.medium)
                        Spacer()
                        FastCurrencyField(value: $nuevoIngresoMonto, currencyCode: currencyCode, onLiveValueChange: { ingresoMontoLive = $0 })
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .frame(height: 50)
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Detalles") {
                    DatePicker("Fecha", selection: $nuevoIngresoFecha, displayedComponents: .date)
                    Picker("Categoría", selection: $nuevoIngresoCategoria) {
                        ForEach(Categoria.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("¿Quién ingresa?") {
                    PersonSelector(selected: $nuevoIngresoPersona)
                }
            }
            .navigationTitle("Nuevo Ingreso")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { showAddIngresoSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { submitIngreso() }.disabled(!canAddIngreso).fontWeight(.bold)
                }
            }
        }
    }
    
    var addGastoView: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Monto").fontWeight(.medium)
                        Spacer()
                        FastCurrencyField(value: $nuevoGastoMonto, currencyCode: currencyCode, onLiveValueChange: { gastoMontoLive = $0 })
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.red)
                            .frame(height: 50)
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Detalles") {
                    TextField("Descripción", text: $nuevoGastoDescripcion)
                    DatePicker("Fecha", selection: $nuevoGastoFecha, displayedComponents: .date)
                    Picker("Categoría", selection: $nuevoGastoCategoria) {
                        ForEach(Categoria.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("¿Quién gasta?") {
                    PersonSelector(selected: $nuevoGastoPersona)
                }
            }
            .navigationTitle("Nuevo Gasto")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { showAddGastoSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { submitGasto() }.disabled(!canAddGasto).fontWeight(.bold)
                }
            }
        }
    }

    // --- Lógica de envío (Integrada de tu código anterior) ---
    
    private var pendingEvents: [SheetEvent] { PendingQueue.decode(pendingEventsData) }
    private func setPendingEvents(_ items: [SheetEvent]) { pendingEventsData = PendingQueue.encode(items) }
    
    @MainActor private func enqueue(_ events: [SheetEvent]) {
        var all = pendingEvents; all.append(contentsOf: events); setPendingEvents(all)
    }
    
    private func sendOrEnqueue(_ events: [SheetEvent]) {
        enqueue(events)
        Task { await flushQueue() }
    }

    @MainActor private func flushQueue() async {
        guard !isSyncing else { return }
        isSyncing = true; defer { isSyncing = false }
        while true {
            let toSend = pendingEvents; if toSend.isEmpty { break }
            do {
                try await SheetsAPI.send(toSend)
                let current = pendingEvents
                let sentIds = Set(toSend.map { $0.recordId })
                let remaining = current.filter { !sentIds.contains($0.recordId) }
                setPendingEvents(remaining)
                lastSyncError = nil
                await loadFromServer(silent: true)
            } catch {
                lastSyncError = String(describing: error)
                break
            }
        }
    }

    @MainActor private func loadFromServer(silent: Bool = false) async {
        if !silent { isFetching = true }
        defer { if !silent { isFetching = false } }
        do {
            let snap = try await SheetsAPI.fetchSnapshot()
            if let si = snap.saldoInicial {
                saldoInicial = si.amount
                saldoInicialFecha = parseISODate(si.date)
                saldoInicialPersona = Persona(rawValue: si.person) ?? .otro
                initialBalanceRecorded = si.amount > 0
            }
            let filteredIngresos = snap.ingresos.filter { s in
                let desc = (s.description ?? "").lowercased(); let source = s.extra?["source"]?.lowercased()
                return !(desc == "saldo inicial" || source == "initialbalance")
            }
            ingresos = filteredIngresos.map {
                Ingreso(recordId: $0.recordId, monto: $0.amount, fecha: parseISODate($0.date), quien: Persona(rawValue: $0.person) ?? .otro, categoria: Categoria.parse($0.extra?["category"]))
            }
            gastos = snap.gastos.map {
                Gasto(recordId: $0.recordId, monto: $0.amount, fecha: parseISODate($0.date), descripcion: $0.description, quien: Persona(rawValue: $0.person) ?? .otro, categoria: Categoria.parse($0.extra?["category"]))
            }
            lastSyncError = nil
        } catch { lastSyncError = error.localizedDescription }
    }
    
    // --- Helpers Actions ---
    
    private func submitInitialBalance() {
        let evt = SheetEvent(action: "add", type: "ingreso", amount: saldoInicial, date: isoDate(saldoInicialFecha), description: "Saldo inicial", person: saldoInicialPersona.rawValue, deviceName: makeDeviceInfo().name, deviceId: makeDeviceInfo().id, clientTimestamp: isoTimestamp(Date()), recordId: UUID().uuidString, extra: ["source":"initialBalance"])
        sendOrEnqueue([evt])
        dismissKeyboard(); showInitialBalanceSheet = false
    }
    
    private func submitIngreso() {
        let recId = UUID().uuidString
        let item = Ingreso(recordId: recId, monto: nuevoIngresoMonto, fecha: nuevoIngresoFecha, quien: nuevoIngresoPersona, categoria: nuevoIngresoCategoria)
        ingresos.append(item)
        let evt = SheetEvent(action: "add", type: "ingreso", amount: item.monto, date: isoDate(item.fecha), description: "", person: item.quien.rawValue, deviceName: makeDeviceInfo().name, deviceId: makeDeviceInfo().id, clientTimestamp: isoTimestamp(Date()), recordId: recId, extra: ["category": item.categoria.rawValue])
        sendOrEnqueue([evt])
        resetIngresoForm(); showAddIngresoSheet = false
    }
    
    private func submitGasto() {
        let recId = UUID().uuidString
        let item = Gasto(recordId: recId, monto: nuevoGastoMonto, fecha: nuevoGastoFecha, descripcion: nuevoGastoDescripcion.trimmingCharacters(in: .whitespacesAndNewlines), quien: nuevoGastoPersona, categoria: nuevoGastoCategoria)
        gastos.append(item)
        let evt = SheetEvent(action: "add", type: "gasto", amount: item.monto, date: isoDate(item.fecha), description: item.descripcion, person: item.quien.rawValue, deviceName: makeDeviceInfo().name, deviceId: makeDeviceInfo().id, clientTimestamp: isoTimestamp(Date()), recordId: recId, extra: ["category": item.categoria.rawValue])
        sendOrEnqueue([evt])
        resetGastoForm(); showAddGastoSheet = false
    }
    
    private func deleteIngresos(at offsets: IndexSet, in items: [Ingreso]) {
        let toDelete = offsets.map { items[$0] }
        let ids = Set(toDelete.map { $0.recordId })
        ingresos.removeAll { ids.contains($0.recordId) }
        let events: [SheetEvent] = toDelete.map { i in
            SheetEvent(action: "delete", type: "ingreso", amount: i.monto, date: isoDate(i.fecha), description: "", person: i.quien.rawValue, deviceName: makeDeviceInfo().name, deviceId: makeDeviceInfo().id, clientTimestamp: isoTimestamp(Date()), recordId: i.recordId, extra: nil)
        }
        sendOrEnqueue(events)
    }
    
    private func deleteGastos(at offsets: IndexSet, in items: [Gasto]) {
        let toDelete = offsets.map { items[$0] }
        let ids = Set(toDelete.map { $0.recordId })
        gastos.removeAll { ids.contains($0.recordId) }
        let events: [SheetEvent] = toDelete.map { g in
            SheetEvent(action: "delete", type: "gasto", amount: g.monto, date: isoDate(g.fecha), description: g.descripcion, person: g.quien.rawValue, deviceName: makeDeviceInfo().name, deviceId: makeDeviceInfo().id, clientTimestamp: isoTimestamp(Date()), recordId: g.recordId, extra: nil)
        }
        sendOrEnqueue(events)
    }
    
    private func resetIngresoForm() { nuevoIngresoMonto = 0; ingresoMontoLive = 0; nuevoIngresoFecha = Date(); nuevoIngresoPersona = .katerin }
    private func resetGastoForm() { nuevoGastoMonto = 0; gastoMontoLive = 0; nuevoGastoFecha = Date(); nuevoGastoDescripcion = ""; nuevoGastoPersona = .katerin }
    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

// MARK: - COMPONENTES DE DISEÑO REUTILIZABLES

struct BalanceCardView: View {
    let balance: Double
    let income: Double
    let expense: Double
    let initial: Double
    
    var body: some View {
        ZStack {
            // Fondo con degradado moderno
            LinearGradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            
            VStack(spacing: 20) {
                // Balance Principal
                VStack(spacing: 5) {
                    Text("Balance Disponible")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(balance as NSNumber, formatter: NumberFormatter.currencyFormatter)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                
                Divider().background(.white.opacity(0.3))
                
                // Detalles Horizontales
                HStack(alignment: .top) {
                    statColumn(title: "Inicial", value: initial, color: .white)
                    Spacer()
                    statColumn(title: "Ingresos", value: income, color: .green.opacity(0.9))
                    Spacer()
                    statColumn(title: "Gastos", value: expense, color: .red.opacity(0.9))
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        .padding(.horizontal)
        .padding(.top, 10)
    }
    
    private func statColumn(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.7))
            Text(value as NSNumber, formatter: NumberFormatter.currencyAbbreviated)
                .font(.system(.callout, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
    }
}

struct TransactionRowView: View {
    let imageName: String
    let title: String
    let date: Date
    let amount: Double
    let isIncome: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar con anillo
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(amount as NSNumber, formatter: NumberFormatter.currencyFormatter)
                .font(.system(.callout, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(isIncome ? Color.green : Color.primary)
        }
        .padding(.vertical, 4)
    }
}

struct BudgetProgressRow: View {
    let category: Categoria
    let icon: String
    let color: Color
    let asignado: Double
    let gastado: Double
    
    private var progress: Double {
        guard asignado > 0 else { return 0 }
        return min(gastado / asignado, 1.0)
    }
    
    private var disponible: Double { asignado - gastado }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(category.rawValue, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                Text(disponible as NSNumber, formatter: NumberFormatter.currencyFormatter)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(disponible >= 0 ? Color.primary : Color.red)
            }
            
            // Barra de progreso visual
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                        .frame(height: 8)
                    Capsule().fill(progress > 0.9 ? Color.red : color)
                        .frame(width: geo.size.width * progress, height: 8)
                }
            }
            .frame(height: 8)
            
            HStack {
                Text("Gastado: \(NumberFormatter.currencyAbbreviated.string(from: NSNumber(value: gastado)) ?? "")")
                Spacer()
                Text("Meta: \(NumberFormatter.currencyAbbreviated.string(from: NSNumber(value: asignado)) ?? "")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct PersonSelector: View {
    @Binding var selected: Persona
    
    var body: some View {
        HStack(spacing: 20) {
            ForEach(Persona.allCases) { persona in
                Button {
                    withAnimation(.snappy) { selected = persona }
                } label: {
                    VStack(spacing: 8) {
                        Image(imageName(for: persona))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 50, height: 50)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(selected == persona ? Color.blue : Color.clear, lineWidth: 3)
                            )
                            .shadow(radius: selected == persona ? 4 : 0)
                            .scaleEffect(selected == persona ? 1.1 : 1.0)
                        
                        Text(persona.rawValue)
                            .font(.caption)
                            .fontWeight(selected == persona ? .bold : .regular)
                            .foregroundStyle(selected == persona ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    private func imageName(for p: Persona) -> String {
        switch p { case .katerin: return "katerin"; case .augusto: return "augusto"; case .otro: return "otro" }
    }
}

// MARK: - Extensiones de Formato
extension NumberFormatter {
    static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = .current
        return f
    }()
    static let currencyAbbreviated: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = .current
        f.maximumFractionDigits = 0 // Para vistas compactas
        return f
    }()
}

// Helpers para Display en Row
extension Ingreso { var amountDisplay: Double { monto } }
extension Gasto { var amountDisplay: Double { monto } }

#Preview {
    AccountInfoView()
}
