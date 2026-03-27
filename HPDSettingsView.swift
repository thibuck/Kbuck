import SwiftUI
import Supabase

struct LegalTermsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Terms & Conditions")
                        .font(.title2.bold())

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Data Source Disclaimer")
                            .font(.headline)
                        Text("Vehicle-related data, including inspection date, reported mileage, and estimated DMV Private Value, may be retrieved from public third-party sources. This information is provided strictly for informational purposes and may not reflect current conditions.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Warranties")
                            .font(.headline)
                        Text("All information is provided 'AS IS' and 'AS AVAILABLE' without warranties of any kind, express or implied, including but not limited to accuracy, completeness, reliability, fitness for a particular purpose, merchantability, or non-infringement.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Limitation of Liability")
                            .font(.headline)
                        Text("By using this app and proceeding with data retrieval, you acknowledge and agree that the app provider is not responsible for any losses, damages, claims, or decisions arising from reliance on third-party data. You assume full responsibility for independently verifying all information before taking any action.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Legal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct HPDSettingsView: View {
    @EnvironmentObject private var supabaseService: SupabaseService

    // Role written by ContentView after fetching from the profiles table.
    @AppStorage("userRole") private var userRole: String = "user"

    // Shared AppStorage keys read/written by HPDView as well
    @AppStorage("hpdManualURLEnabled") private var manualURLModeEnabled: Bool = false
    @AppStorage("hpdManualURLInput")   private var hpdManualURLInput: String = ""
    @AppStorage("hpdHadLastError")     private var hpdHadLastError: Bool = false
    @AppStorage("hpdRefreshTrigger")   private var refreshTrigger: Int = 0
    @AppStorage("hpdCachedURL")        private var hpdCachedURL: String = ""
    @AppStorage("openWebInSafari")     private var openWebInSafari: Bool = false

    // Local state
    @State private var showClearOdoAlert = false
    @State private var showSignOutAlert  = false
    @State private var showHPDWeb: Bool  = false
    @State private var showTerms: Bool   = false

    private let defaultURLString = "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm"

    private var userEmail: String? { supabase.auth.currentUser?.email }

    var body: some View {
        NavigationStack {
            Form {
                if let email = userEmail, !email.isEmpty {
                    Section {
                        Text("Welcome, \(email)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Restricted to Super Admin
                if userRole == "super_admin" {
                    Section(header: Text("Data Source")) {
                        LabeledContent("Default URL", value: defaultURLString)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Button { refreshTrigger += 1 } label: {
                            Label("Refresh Now", systemImage: "arrow.clockwise")
                        }

                        Toggle("Edit URL Manually", isOn: $manualURLModeEnabled)
                            .tint(.blue)

                        Button { showHPDWeb = true } label: {
                            Label("Open HPD Web", systemImage: "safari")
                        }
                    }

                    if manualURLModeEnabled || hpdHadLastError {
                        Section(
                            header: Text("Manual URL"),
                            footer: Text("Use only if the target page changed. You can revert to the default URL anytime.")
                        ) {
                            TextField("https://…", text: $hpdManualURLInput)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .autocorrectionDisabled(true)

                            HStack {
                                Button {
                                    refreshTrigger += 1
                                } label: {
                                    Label("Fetch", systemImage: "arrow.down.circle")
                                }
                                .disabled(hpdManualURLInput.trimmingCharacters(in: .whitespaces).isEmpty)

                                Spacer()

                                Button {
                                    hpdManualURLInput = defaultURLString
                                    manualURLModeEnabled = false
                                    hpdHadLastError = false
                                } label: {
                                    Label("Use Default URL", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Browser Preferences")) {
                    Toggle("Force External Safari for Reports", isOn: $openWebInSafari)
                }

                Section(header: Text("Legal")) {
                    Button("Terms & Conditions") {
                        showTerms = true
                    }
                }

                Section(
                    header: Text("ODO / Date / SPV Cache"),
                    footer: Text("This only clears the locally saved odometer, date, and Private Value data.")
                ) {
                    Button(role: .destructive) {
                        showClearOdoAlert = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                }
                .alert("Clear Cache", isPresented: $showClearOdoAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        supabaseService.clearOdoCache()
                    }
                } message: {
                    Text("This will permanently delete saved odometers, dates, and SPV values. This action cannot be undone.")
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
                .alert("Sign Out", isPresented: $showSignOutAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Sign Out", role: .destructive) {
                        supabaseService.clearAllLocalState()
                        Task { try? await supabase.auth.signOut() }
                    }
                } message: {
                    Text("Are you sure you want to sign out?")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showHPDWeb) {
                NavigationStack {
                    if let url = URL(string: hpdCachedURL.isEmpty ? defaultURLString : hpdCachedURL) {
                        SafariView(url: url).ignoresSafeArea()
                    } else {
                        Text("Invalid URL")
                    }
                }
            }
            .sheet(isPresented: $showTerms) {
                LegalTermsView()
            }
            .onAppear {
                // Pre-fill manual URL field with the default so the text field isn't blank
                if hpdManualURLInput.isEmpty {
                    hpdManualURLInput = defaultURLString
                }
            }
        }
    }
}
