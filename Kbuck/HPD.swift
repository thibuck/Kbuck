import SwiftUI
import UIKit
import Foundation
import SafariServices
import WebKit
import EventKit
import CoreLocation
import MapKit
import Supabase
import StoreKit


struct SafariView: View {
    let url: URL

    var body: some View {
        SafariControllerView(url: url)
            .ignoresSafeArea()
    }
}

struct SafariControllerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct SearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MileageWebView: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    let vin: String
    let cancelToken: UUID
    let forceStartToken: UUID
    let onWaitingForCaptcha: () -> Void
    let onFetchingOdometer: () -> Void
    let onError: (String) -> Void
    let onExtract: (String, String, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            vin: vin,
            isActive: isActive,
            url: url,
            cancelToken: cancelToken,
            forceStartToken: forceStartToken,
            onWaitingForCaptcha: onWaitingForCaptcha,
            onFetchingOdometer: onFetchingOdometer,
            onError: onError,
            onExtract: onExtract
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let jScript = "var meta = document.createElement('meta'); meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1.0'; document.getElementsByTagName('head')[0].appendChild(meta);"
        let userScript = WKUserScript(source: jScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView
        config.userContentController.add(context.coordinator, name: context.coordinator.captchaMessageChannel)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.isMessageHandlerAttached = true
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.configure(
            vin: vin,
            isActive: isActive,
            url: url,
            cancelToken: cancelToken,
            forceStartToken: forceStartToken,
            onWaitingForCaptcha: onWaitingForCaptcha,
            onFetchingOdometer: onFetchingOdometer,
            onError: onError,
            onExtract: onExtract
        )
        context.coordinator.syncLoadingState(for: uiView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var vin: String
        private var isActive: Bool
        private var url: URL
        private var cancelToken: UUID
        private var forceStartToken: UUID
        private var onWaitingForCaptcha: () -> Void
        private var onFetchingOdometer: () -> Void
        private var onError: (String) -> Void
        private var onExtract: (String, String, String?) -> Void
        private var hasLoaded = false
        private var shouldForceStop = false
        private var shouldForceFreshLoad = false
        private var didReportFailure = false
        private var extractionTimeoutWorkItem: DispatchWorkItem?
        let captchaMessageChannel = "mileageCaptcha_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var isMessageHandlerAttached = false

        init(
            vin: String,
            isActive: Bool,
            url: URL,
            cancelToken: UUID,
            forceStartToken: UUID,
            onWaitingForCaptcha: @escaping () -> Void,
            onFetchingOdometer: @escaping () -> Void,
            onError: @escaping (String) -> Void,
            onExtract: @escaping (String, String, String?) -> Void
        ) {
            self.vin = vin
            self.isActive = isActive
            self.url = url
            self.cancelToken = cancelToken
            self.forceStartToken = forceStartToken
            self.onWaitingForCaptcha = onWaitingForCaptcha
            self.onFetchingOdometer = onFetchingOdometer
            self.onError = onError
            self.onExtract = onExtract
        }

        func configure(
            vin: String,
            isActive: Bool,
            url: URL,
            cancelToken: UUID,
            forceStartToken: UUID,
            onWaitingForCaptcha: @escaping () -> Void,
            onFetchingOdometer: @escaping () -> Void,
            onError: @escaping (String) -> Void,
            onExtract: @escaping (String, String, String?) -> Void
        ) {
            if self.cancelToken != cancelToken {
                self.cancelToken = cancelToken
                shouldForceStop = true
                didReportFailure = false
                cancelExtractionTimeout()
            }
            if self.forceStartToken != forceStartToken {
                self.forceStartToken = forceStartToken
                shouldForceFreshLoad = true
                didReportFailure = false
                cancelExtractionTimeout()
            }
            self.vin = vin
            self.isActive = isActive
            self.url = url
            self.onWaitingForCaptcha = onWaitingForCaptcha
            self.onFetchingOdometer = onFetchingOdometer
            self.onError = onError
            self.onExtract = onExtract
        }

        func syncLoadingState(for webView: WKWebView) {
            self.webView = webView
            if isActive && !isMessageHandlerAttached {
                webView.configuration.userContentController.add(self, name: captchaMessageChannel)
                isMessageHandlerAttached = true
            }
            if shouldForceStop {
                shouldForceStop = false
                hasLoaded = false
                didReportFailure = false
                cancelExtractionTimeout()
                webView.stopLoading()
                if let blankURL = URL(string: "about:blank") {
                    webView.load(URLRequest(url: blankURL))
                } else {
                    webView.loadHTMLString("", baseURL: nil)
                }
                if isMessageHandlerAttached {
                    webView.configuration.userContentController.removeScriptMessageHandler(forName: captchaMessageChannel)
                    isMessageHandlerAttached = false
                }
            }
            if shouldForceFreshLoad {
                shouldForceFreshLoad = false
                hasLoaded = true
                didReportFailure = false
                cancelExtractionTimeout()
                webView.stopLoading()
                if let blankURL = URL(string: "about:blank") {
                    webView.load(URLRequest(url: blankURL))
                }
                webView.load(URLRequest(url: url))
                return
            }
            if isActive && !hasLoaded {
                hasLoaded = true
                didReportFailure = false
                webView.load(URLRequest(url: url))
                return
            }
            if !isActive && hasLoaded {
                hasLoaded = false
                didReportFailure = false
                cancelExtractionTimeout()
                webView.stopLoading()
                if let blankURL = URL(string: "about:blank") {
                    webView.load(URLRequest(url: blankURL))
                } else {
                    webView.loadHTMLString("", baseURL: nil)
                }
                if isMessageHandlerAttached {
                    webView.configuration.userContentController.removeScriptMessageHandler(forName: captchaMessageChannel)
                    isMessageHandlerAttached = false
                }
            }
        }

        deinit {
            cancelExtractionTimeout()
            if isMessageHandlerAttached {
                webView?.configuration.userContentController.removeScriptMessageHandler(forName: captchaMessageChannel)
                isMessageHandlerAttached = false
            }
            webView?.navigationDelegate = nil
            webView?.stopLoading()
        }

        private func startExtractionTimeout(seconds: TimeInterval = 12) {
            cancelExtractionTimeout()
            let work = DispatchWorkItem { [weak self] in
                self?.handleFailure("Extraction Failed: Could not retrieve mileage from the report.")
            }
            extractionTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }

        private func cancelExtractionTimeout() {
            extractionTimeoutWorkItem?.cancel()
            extractionTimeoutWorkItem = nil
        }

        private func handleFailure(_ message: String) {
            guard !didReportFailure else { return }
            didReportFailure = true
            cancelExtractionTimeout()
            DispatchQueue.main.async {
                self.onError(message)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == captchaMessageChannel else { return }
            DispatchQueue.main.async {
                self.onFetchingOdometer()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive else { return }
            // Attempt to auto-fill VIN field by common heuristics
            let escapedVIN = vin.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function(){
                try {
                    var vin = '\(escapedVIN)';
                    var inputs = Array.from(document.querySelectorAll('input'));
                    var vinInput = inputs.find(function(i){
                        var n = (i.name||''); var id = (i.id||''); var ph = (i.placeholder||'');
                        return /vin/i.test(n) || /vin/i.test(id) || /vin/i.test(ph);
                    }) || inputs.find(function(i){ return (i.maxLength===17 || i.size===17); });
                    if (vinInput) {
                        // Use native setter so frameworks (e.g., React) detect the change
                        try {
                            var proto = Object.getPrototypeOf(vinInput);
                            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
                            if (desc && typeof desc.set === 'function') {
                                desc.set.call(vinInput, vin);
                            } else {
                                vinInput.value = vin;
                            }
                        } catch(e) { vinInput.value = vin; }
                        vinInput.setAttribute('value', vin);
                        // Dispatch common events many sites listen for
                        ['input','change','keyup'].forEach(function(t){
                            try { vinInput.dispatchEvent(new Event(t, { bubbles: true })); } catch(e) {}
                        });
                        try { vinInput.focus(); vinInput.select && vinInput.select(); } catch(e) {}
                        // Try to auto-submit/search if a likely button is nearby
                        setTimeout(function(){
                            try {
                                var form = vinInput.form || vinInput.closest('form');
                                var btn = (form ? form.querySelector('button[type=submit],input[type=submit]') : null)
                                    || Array.from(document.querySelectorAll('button,input[type=button],input[type=submit]')).find(function(b){
                                        var t = (b.innerText || b.value || '').toLowerCase();
                                        var id = (b.id || '').toLowerCase();
                                        var name = (b.name || '').toLowerCase();
                                        return /search|submit|find|go|lookup/.test(t) || /search|submit|find|go|lookup/.test(id) || /search|submit|find|go|lookup/.test(name);
                                    });
                                if (btn) { btn.click(); }
                                try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                            } catch(e) {}
                        }, 200);
                    }
                    try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                } catch(e) {}
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            // Zoom y centrar el captcha en SecurityCheck para facilitar el tap
            if let current = webView.url?.absoluteString, current.contains("SecurityCheck.aspx") {
                onWaitingForCaptcha()
                let zoomCaptchaJS = """
                (function(){
                    try {
                        var __hpdNotified = false;
                        var notifyDone = function() {
                            if (__hpdNotified) { return; }
                            __hpdNotified = true;
                            try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                            try { window.webkit.messageHandlers.\(captchaMessageChannel).postMessage('captchaSolved'); } catch(e) {}
                        };
                        var isSolved = function() {
                            try {
                                var recaptcha = document.querySelector('textarea[g-recaptcha-response], #g-recaptcha-response');
                                if (recaptcha && recaptcha.value && recaptcha.value.trim().length > 0) { return true; }
                                if (document.querySelector('.recaptcha-checkbox-checked, .recaptcha-success, .grecaptcha-badge')) { return true; }
                            } catch(e) {}
                            return false;
                        };
                        var wireSubmitButtons = function() {
                            try {
                                var btns = Array.from(document.querySelectorAll('button,input[type="submit"],input[type="button"],a'));
                                btns.forEach(function(btn) {
                                    if (btn.dataset && btn.dataset.hpdCaptchaWired === '1') { return; }
                                    var t = (btn.innerText || btn.value || btn.textContent || '').toLowerCase();
                                    var id = (btn.id || '').toLowerCase();
                                    var n = (btn.name || '').toLowerCase();
                                    if (/(search|submit|find|go|lookup|continue|next)/.test(t) || /(search|submit|find|go|lookup|continue|next)/.test(id) || /(search|submit|find|go|lookup|continue|next)/.test(n)) {
                                        btn.addEventListener('click', function(){ notifyDone(); }, { passive: true });
                                        if (btn.dataset) { btn.dataset.hpdCaptchaWired = '1'; }
                                    }
                                });
                            } catch(e) {}
                        };
                        // Aumentar zoom general para mejor alcance del captcha
                        document.documentElement.style.zoom = '1.6';
                        document.body.style.zoom = '1.6';
                        // Buscar el iframe de reCAPTCHA o contenedor captcha y centrar
                        var box = document.querySelector('iframe[title*="recaptcha" i]')
                                  || document.querySelector('[id*="captcha" i], [class*="captcha" i]')
                                  || document.querySelector('input[type="checkbox"][name*="captcha" i]');
                        if (box && box.scrollIntoView) {
                            box.scrollIntoView({behavior:'smooth', block:'center'});
                        }
                        wireSubmitButtons();
                        if (isSolved()) { notifyDone(); }
                        var watchdog = setInterval(function(){
                            wireSubmitButtons();
                            if (isSolved()) {
                                notifyDone();
                                clearInterval(watchdog);
                            }
                        }, 120);
                        // If captcha is already solved in this session, auto-attempt submit/search
                        var solved = false;
                        try {
                            var recaptcha = document.querySelector('textarea[g-recaptcha-response], #g-recaptcha-response');
                            solved = !!(recaptcha && recaptcha.value && recaptcha.value.trim().length > 0);
                        } catch(e) {}
                        if (solved) {
                            var btns = Array.from(document.querySelectorAll('button,input[type="submit"],input[type="button"],a'));
                            var submit = btns.find(function(b){
                                var t = (b.innerText || b.value || b.textContent || '').toLowerCase();
                                var id = (b.id || '').toLowerCase();
                                var n = (b.name || '').toLowerCase();
                                return /(search|submit|find|go|lookup|continue|next)/.test(t) || /(search|submit|find|go|lookup|continue|next)/.test(id) || /(search|submit|find|go|lookup|continue|next)/.test(n);
                            });
                            if (submit && submit.click) { notifyDone(); submit.click(); }
                            try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                        }
                    } catch(e) {}
                })();
                """
                webView.evaluateJavaScript(zoomCaptchaJS, completionHandler: nil)
            }
            // Targeted fill for SearchVehicleTestHistory.aspx (field id/name: txtVin, button: Search)
            if let current = webView.url?.absoluteString, current.contains("SearchVehicleTestHistory.aspx") {
                let targetedJS = """
                (function(){
                    try {
                        var vin = '\(escapedVIN)';
                        var el = document.getElementById('txtVin') || document.querySelector('input[name="txtVin"]');
                        if (!el) return;
                        var setValue = function(elem, value){
                            try {
                                var proto = Object.getPrototypeOf(elem);
                                var desc = Object.getOwnPropertyDescriptor(proto, 'value');
                                if (desc && typeof desc.set === 'function') {
                                    desc.set.call(elem, value);
                                } else {
                                    elem.value = value;
                                }
                            } catch(e) { elem.value = value; }
                            elem.setAttribute('value', value);
                        };
                        var fire = function(elem, type){
                            try { elem.dispatchEvent(new Event(type, { bubbles: true })); } catch(e) {}
                        };
                        var key = function(elem, key, code){
                            try { elem.dispatchEvent(new KeyboardEvent('keydown', { key: key, keyCode: code, which: code, bubbles: true })); } catch(e) {}
                            try { elem.dispatchEvent(new KeyboardEvent('keyup',   { key: key, keyCode: code, which: code, bubbles: true })); } catch(e) {}
                        };
                        var clickSearch = function(){
                            try {
                                var btn = Array.from(document.querySelectorAll('button,input[type=submit],input[type=button]')).find(function(b){
                                    var t = (b.innerText || b.value || '').trim().toLowerCase();
                                    return t === 'search' || t.includes('search');
                                });
                                if (btn) { btn.click(); return true; }
                            } catch(e) {}
                            return false;
                        };
                        var attempt = function(tries){
                            setValue(el, vin);
                            fire(el, 'input'); fire(el, 'change'); fire(el, 'keyup'); fire(el, 'keydown');
                            try { el.focus(); el.select && el.select(); el.scrollIntoView && el.scrollIntoView({behavior:'smooth', block:'center'}); } catch(e) {}
                            if (!clickSearch()) {
                                key(el, 'Enter', 13);
                                try { if (typeof DoGoItEnterKey === 'function') DoGoItEnterKey({ keyCode: 13 }); } catch(e) {}
                            }
                            try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                            // If value didn't stick (some pages override), retry a couple of times
                            if (tries > 0 && (el.value || '').length < 8) {
                                setTimeout(function(){ attempt(tries - 1); }, 250);
                            }
                        };
                        attempt(3);
                    } catch(e) {}
                })();
                """
                webView.evaluateJavaScript(targetedJS, completionHandler: nil)
            }

            // Auto-click the most recent Begin Date Time on VehicleTestHistory.aspx (after captcha & search)
            if let hist = webView.url?.absoluteString, hist.contains("VehicleTestHistory.aspx") {
                let clickLatestJS = """
                (function(){
                    function parseUSDateTime(s){
                        if(!s) return NaN;
                        s = String(s).trim();
                        var m = s.match(/^(\\d{1,2})\\/(\\d{1,2})\\/(\\d{4})(?:\\s+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?\\s*(AM|PM)?)?/i);
                        if(!m) return NaN;
                        var MM = parseInt(m[1],10), DD = parseInt(m[2],10), YYYY = parseInt(m[3],10);
                        var hh = m[4] ? parseInt(m[4],10) : 0;
                        var mm = m[5] ? parseInt(m[5],10) : 0;
                        var ss = m[6] ? parseInt(m[6],10) : 0;
                        var ap = m[7] ? m[7].toUpperCase() : '';
                        if(ap === 'PM' && hh < 12) hh += 12; if(ap === 'AM' && hh === 12) hh = 0;
                        var d = new Date(YYYY, MM-1, DD, hh, mm, ss);
                        return d.getTime();
                    }
                    function pickCandidates(){
                        var as = Array.from(document.querySelectorAll('a'));
                        var c = as.filter(function(a){
                            var t = (a.getAttribute('aria-label') || a.textContent || '').trim();
                            return /\\d{1,2}\\/\\d{1,2}\\/\\d{4}/.test(t);
                        });
                        return c;
                    }
                    var best = null, bestT = -1;
                    var cands = pickCandidates();
                    for(var i=0;i<cands.length;i++){
                        var a = cands[i];
                        var t = parseUSDateTime(a.getAttribute('aria-label') || a.textContent || '');
                        if(!isNaN(t) && t > bestT){ bestT = t; best = a; }
                    }
                    if(best){
                        try { best.scrollIntoView({behavior:'smooth', block:'center'}); } catch(e) {}
                        try { best.click(); } catch(e) {}
                        try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                        return 'CLICKED';
                    }
                    try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                    return 'NO_MATCH';
                })();
                """
                webView.evaluateJavaScript(clickLatestJS, completionHandler: nil)
            }

            if let url = webView.url?.absoluteString, url.contains("VehicleTestDetail.aspx") {
                onFetchingOdometer()
                startExtractionTimeout()
                let extractJS = """
                (function(){
                    function txt(n){
                        return (n && n.textContent ? n.textContent : '').replace(/\\s+/g,' ').trim();
                    }
                    function nextVal(lab){
                        if(!lab) return '';
                        var val = lab.nextElementSibling; return txt(val);
                    }
                    // Exact-match finder: label must match 100% (colon optional)
                    function findExact(label){
                        var tds = Array.from(document.querySelectorAll('td'));
                        var lab = tds.find(function(td){
                            var t = txt(td);
                            return t === label || t === (label + ':');
                        });
                        return nextVal(lab);
                    }
                    // Try a list of labels (each exact)
                    function findAnyExact(labels){
                        for (var i = 0; i < labels.length; i++){
                            var v = findExact(labels[i]);
                            if (v) return v;
                        }
                        return '';
                    }

                    // --- Values we want ---
                    // Odometer can appear as "Odometer" or "Odometer Reading"
                    var odo = findAnyExact(['Odometer','Odometer Reading']);
                    // Fallback to older loose match if exact labels not found
                    if (!odo){
                        try {
                            var tds = Array.from(document.querySelectorAll('td'));
                            var lab = tds.find(function(td){ return /^\\s*Odometer\\s*:??\\s*$/i.test(txt(td)); });
                            odo = nextVal(lab);
                        } catch(e) {}
                    }

                    // Date must be EXACT match (100%): new pages use "Test End Date/Time"
                    var date = findExact('Test End Date/Time');
                    // Backward compatibility: some pages still use "Test Date"
                    if (!date) { date = findExact('Test Date'); }

                    // Full model name (strictly additive). If missing, return null.
                    var realModel = findExact('Model');
                    if (!realModel) { realModel = null; }

                    return { odo: odo, date: date, realModel: realModel };
                })();
                """
                webView.evaluateJavaScript(extractJS) { result, _ in
                    if let dict = result as? [String: Any],
                       let odo = dict["odo"] as? String,
                       let date = dict["date"] as? String,
                       !odo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let realModel = (dict["realModel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.cancelExtractionTimeout()
                        self.onExtract(odo, date, (realModel?.isEmpty == false) ? realModel : nil)
                    } else {
                        self.handleFailure("Extraction Failed: Could not retrieve mileage from the report.")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            if isNavigationCancelled(error) {
                return
            }
            handleFailure("Extraction Failed: Unable to load mileage report page.")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            if isNavigationCancelled(error) {
                return
            }
            handleFailure("Extraction Failed: Unable to load mileage report page.")
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        }

        private func isNavigationCancelled(_ error: Error) -> Bool {
            let ns = error as NSError
            return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        }
    }
}

// MARK: - HPD Filter Sheet

private struct HPDFilterSheet: View {
    let addresses: [String]
    @Binding var selectedFilters: Set<String>
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Locations") {
                    ForEach(addresses, id: \.self) { addr in
                        locationRow(addr)
                    }
                }
            }
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selectedFilters = [] }
                        .foregroundStyle(.red)
                        .disabled(selectedFilters.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func locationRow(_ addr: String) -> some View {
        let isSelected = selectedFilters.contains(addr)
        Button {
            if isSelected {
                selectedFilters.remove(addr)
            } else {
                selectedFilters.insert(addr)
            }
        } label: {
            HStack {
                Text(addr)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - Welcome Onboarding

struct WelcomeOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideWelcomeScreen") private var hideWelcomeScreen: Bool = false
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @AppStorage("userRole") private var userRole: String = "user"

    private var dynamicLimitDisplay: String {
        if userRole == "super_admin" { return "Unlimited" }
        let limit = supabaseService.tierConfigs[supabaseService.serverTierKey]?.daily_fetch_limit ?? 3
        return limit >= 999999 ? "Unlimited" : "\(limit)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                Text("Welcome to HPD Auction")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)

                VStack(spacing: 20) {
                    featureRow(
                        icon: "magnifyingglass", color: .blue,
                        title: "Smart Aggregation",
                        description: "Search and filter historical HPD auction records instantly."
                    )
                    featureRow(
                        icon: "hammer.fill", color: .blue,
                        title: "Data Extraction",
                        description: "Fetch recent state inspection mileage and estimated DMV Private Party Values."
                    )
                    featureRow(
                        icon: "chart.bar.fill", color: .green,
                        title: "Fair-Use Quota",
                        description: "Get up to \(dynamicLimitDisplay) successful data extractions per day. Failed attempts do not consume your quota."
                    )
                }

                VStack(spacing: 8) {
                    Text("LEGAL DISCLAIMER\nData is retrieved from public third-party sources and provided 'AS IS' for informational purposes. We do not guarantee accuracy, completeness, or real-time validity. Always verify vehicles physically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 4)

                VStack(spacing: 12) {
                    Button(action: { hideWelcomeScreen.toggle() }) {
                        HStack(spacing: 10) {
                            Image(systemName: hideWelcomeScreen ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(hideWelcomeScreen ? .blue : .secondary)
                            Text("Do not show this again")
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)

                    Button("Get Started") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SPVWebView: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    let vin: String
    let mileage: String
    let cancelToken: UUID
    let onError: (String) -> Void
    let onPrice: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(vin: vin, mileage: mileage, isActive: isActive, url: url, cancelToken: cancelToken, onError: onError, onPrice: onPrice)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let suppressKeyboardScript = WKUserScript(
            source: "setTimeout(function() { try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {} }, 50);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(suppressKeyboardScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.configure(vin: vin, mileage: mileage, isActive: isActive, url: url, cancelToken: cancelToken, onError: onError, onPrice: onPrice)
        context.coordinator.syncLoadingState(for: uiView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var vin: String
        private var mileage: String
        private var isActive: Bool
        private var url: URL
        private var cancelToken: UUID
        private var onError: (String) -> Void
        private var onPrice: (String) -> Void
        private var didSubmit = false
        private var didExtract = false
        private var hasLoaded = false
        private var shouldForceStop = false
        private var didReportFailure = false
        private var extractionTimeoutWorkItem: DispatchWorkItem?
        // --- Sanitization helpers ---
        private func sanitizeVIN(_ s: String) -> String {
            let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789") // VIN excludes I,O,Q
            return s.uppercased().filter { allowed.contains($0) }
        }
        private func sanitizeODO(_ s: String) -> String {
            return s.filter { $0.isNumber }
        }
        init(vin: String, mileage: String, isActive: Bool, url: URL, cancelToken: UUID, onError: @escaping (String) -> Void, onPrice: @escaping (String) -> Void) {
            self.vin = vin
            self.mileage = mileage
            self.isActive = isActive
            self.url = url
            self.cancelToken = cancelToken
            self.onError = onError
            self.onPrice = onPrice
        }

        func configure(vin: String, mileage: String, isActive: Bool, url: URL, cancelToken: UUID, onError: @escaping (String) -> Void, onPrice: @escaping (String) -> Void) {
            if self.cancelToken != cancelToken {
                self.cancelToken = cancelToken
                shouldForceStop = true
                didSubmit = false
                didExtract = false
                didReportFailure = false
                cancelExtractionTimeout()
            }
            self.vin = vin
            self.mileage = mileage
            self.isActive = isActive
            self.url = url
            self.onError = onError
            self.onPrice = onPrice
        }

        func syncLoadingState(for webView: WKWebView) {
            if shouldForceStop {
                shouldForceStop = false
                hasLoaded = false
                didSubmit = false
                didExtract = false
                didReportFailure = false
                cancelExtractionTimeout()
                webView.stopLoading()
                if let blankURL = URL(string: "about:blank") {
                    webView.load(URLRequest(url: blankURL))
                } else {
                    webView.loadHTMLString("", baseURL: nil)
                }
            }
            if isActive && !hasLoaded {
                hasLoaded = true
                didSubmit = false
                didExtract = false
                didReportFailure = false
                webView.load(URLRequest(url: url))
                return
            }
            if !isActive && hasLoaded {
                hasLoaded = false
                didSubmit = false
                didExtract = false
                didReportFailure = false
                cancelExtractionTimeout()
                webView.stopLoading()
                if let blankURL = URL(string: "about:blank") {
                    webView.load(URLRequest(url: blankURL))
                } else {
                    webView.loadHTMLString("", baseURL: nil)
                }
            }
        }

        deinit {
            cancelExtractionTimeout()
        }

        private func startExtractionTimeout(seconds: TimeInterval = 15) {
            cancelExtractionTimeout()
            let work = DispatchWorkItem { [weak self] in
                self?.handleFailure("Extraction Failed: Private value not found.")
            }
            extractionTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }

        private func cancelExtractionTimeout() {
            extractionTimeoutWorkItem?.cancel()
            extractionTimeoutWorkItem = nil
        }

        private func handleFailure(_ message: String) {
            guard !didReportFailure else { return }
            didReportFailure = true
            cancelExtractionTimeout()
            DispatchQueue.main.async {
                self.onError(message)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive else { return }
            let cleanVIN = sanitizeVIN(vin)
            let cleanODO = sanitizeODO(mileage)
            let escapedVIN = cleanVIN.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let escapedODO = cleanODO.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

            // If we already extracted, do nothing
            if didExtract { return }

            // Step 1: only submit once, and only if inputs are present (avoid loops)
            if !didSubmit {
                let jsFill = """
                (function(){
                    function txt(n){ return (n && (n.innerText||n.value||'')).toString(); }

                    function setVal(el, v){
                        if(!el) return;
                        try {
                            var proto = Object.getPrototypeOf(el); var desc = Object.getOwnPropertyDescriptor(proto,'value');
                            if(desc && typeof desc.set==='function'){ desc.set.call(el, v); } else { el.value = v; }
                            el.setAttribute('value', v);
                        } catch(e){ el.value = v; }
                        try { el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); } catch(e) {}
                    }

                    function pickVIN(){
                        var qs = [
                            'input[name="vin"]',
                            'input#vin','input#VIN','input[name*="vin" i]','input[placeholder*="vehicle identification" i]',
                            'input[type="text"]'
                        ];
                        for(var i=0;i<qs.length;i++){ var el = document.querySelector(qs[i]); if(el) return el; }
                        return null;
                    }
                    function pickODO(){
                        var qs = [
                            'input[name="mileage"]','input#mileage','input#odometer','input[name*="mileage" i]','input[name*="odometer" i]',
                            'input[placeholder*="odometer" i]','input[type="number"]','input[type="text"]'
                        ];
                        for(var i=0;i<qs.length;i++){ var el = document.querySelector(qs[i]); if(el) return el; }
                        return null;
                    }
                    function pickSubmit(form){
                        if(form){
                            var b = form.querySelector('button[type="submit"],input[type="submit"]');
                            if(b) return b;
                        }
                        var all = Array.from(document.querySelectorAll('button,input[type="submit"],input[type="button"]'));
                        return all.find(function(b){
                            var t = (b.innerText||b.value||'').toLowerCase(); var id=(b.id||'').toLowerCase(); var n=(b.name||'').toLowerCase();
                            return /(submit|lookup|search|go)/.test(t)||/(submit|lookup|search|go)/.test(id)||/(submit|lookup|search|go)/.test(n);
                        });
                    }

                    var vin = '%@';
                    var odo = '%@'.replace(/[^0-9]/g,'');

                    var start = Date.now();
                    return new Promise(function(resolve){
                        (function wait(){
                            var vinEl = pickVIN();
                            var odoEl = pickODO();
                            if(vinEl){ setVal(vinEl, vin); try{vinEl.focus();}catch(e){} }
                            if(odoEl){ setVal(odoEl, odo); }
                            var form = (vinEl && vinEl.form) || (odoEl && odoEl.form) || document.querySelector('form');
                            var btn = pickSubmit(form);
                            // Submit only if VIN seems valid length; still resolve if not to avoid loops
                            if(btn && vin && vin.length===17){
                                try { if(form && form.requestSubmit) { form.requestSubmit(btn); } else { btn.click(); } } catch(e) {}
                                try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                                return resolve('SUBMITTED');
                            }
                            // Retry for up to 2 seconds for late-loading DOM
                            try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                            if(Date.now() - start < 2000){ return setTimeout(wait, 150); }
                            resolve('FILLED_NO_SUBMIT');
                        })();
                    });
                })();
              """.replacingOccurrences(of: "%@", with: escapedVIN)
                 .replacingOccurrences(of: "%@", with: escapedODO)
                webView.evaluateJavaScript(jsFill) { result, _ in
                    if let status = result as? String {
                        if status == "SUBMITTED" { self.didSubmit = true; self.startExtractionTimeout() }
                        else if status == "FILLED_NO_SUBMIT" { self.didSubmit = true; self.startExtractionTimeout() } // prevent repeated fills/loops
                    } else {
                        self.didSubmit = true
                        self.startExtractionTimeout()
                    }
                }
                return
            }

            // Step 2: extract once when the result is present
            let jsExtract = """
            (function(){
                function txt(n){return (n&&n.textContent?n.textContent:'').replace(/\\n+/g,' ').trim();}
                var tds = Array.from(document.querySelectorAll('td'));
                var label = tds.find(td => /(^|\\b)Private Value:?\\b/i.test(txt(td)));
                if(!label){ return ''; }
                var val = txt(label.nextElementSibling||'');
                var m = val.match(/\\$?\\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\\.[0-9]{2})?)/);
                if(m){ return '$' + m[1]; }
                return val;
            })();
            """
            webView.evaluateJavaScript(jsExtract) { result, _ in
                if let price = result as? String, !price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.didExtract = true
                    self.cancelExtractionTimeout()
                    self.onPrice(price)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            if isNavigationCancelled(error) {
                return
            }
            handleFailure("Extraction Failed: Unable to load private value page.")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            if isNavigationCancelled(error) {
                return
            }
            handleFailure("Extraction Failed: Unable to load private value page.")
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        }

        private func isNavigationCancelled(_ error: Error) -> Bool {
            let ns = error as NSError
            return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        }
    }
}

// MARK: - Invisible SPV background runner
final class SPVBackgroundRunner: NSObject, WKNavigationDelegate {
    private let vin: String
    private let mileage: String
    private let onPrice: (String) -> Void
    private var didSubmit = false
    private var didExtract = false
    private var webView: WKWebView?
    private var timeoutWorkItem: DispatchWorkItem?
    init(vin: String, mileage: String, onPrice: @escaping (String) -> Void) {
        self.vin = vin; self.mileage = mileage; self.onPrice = onPrice
        super.init()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let wk = WKWebView(frame: .zero, configuration: config)
        wk.navigationDelegate = self
        self.webView = wk
    }
    func start() {
        guard let url = URL(string: "https://tools.txdmv.gov/tools/SPV/spv_lookup.php") else { return }
        scheduleTimeout()
        webView?.load(URLRequest(url: url))
    }
    deinit {
        cancelTimeout()
        cleanupWebView()
    }
    // --- Sanitization helpers ---
    private func sanitizeVIN(_ s: String) -> String {
        let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        return s.uppercased().filter { allowed.contains($0) }
    }
    private func sanitizeODO(_ s: String) -> String { s.filter { $0.isNumber } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if didExtract { return }
        let cleanVIN = sanitizeVIN(vin)
        let cleanODO = sanitizeODO(mileage)
        let escapedVIN = cleanVIN.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedODO = cleanODO.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

        if !didSubmit {
            let jsFill = """
            (function(){
                function txt(n){ return (n && (n.innerText||n.value||'')).toString(); }
                function setVal(el, v){
                    if(!el) return; try {
                        var proto = Object.getPrototypeOf(el); var desc = Object.getOwnPropertyDescriptor(proto,'value');
                        if(desc && typeof desc.set==='function'){ desc.set.call(el, v); } else { el.value = v; }
                        el.setAttribute('value', v);
                    } catch(e){ el.value = v; }
                    try { el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); } catch(e) {}
                }
                function pickVIN(){
                    var qs = ['input[name="vin"]','input#vin','input#VIN','input[name*="vin" i]','input[placeholder*="vehicle identification" i]','input[type="text"]'];
                    for(var i=0;i<qs.length;i++){ var el = document.querySelector(qs[i]); if(el) return el; } return null;
                }
                function pickODO(){
                    var qs = ['input[name="mileage"]','input#mileage','input#odometer','input[name*="mileage" i]','input[name*="odometer" i]','input[placeholder*="odometer" i]','input[type="number"]','input[type="text"]'];
                    for(var i=0;i<qs.length;i++){ var el = document.querySelector(qs[i]); if(el) return el; } return null;
                }
                function pickSubmit(form){
                    if(form){ var b = form.querySelector('button[type="submit"],input[type="submit"]'); if(b) return b; }
                    var all = Array.from(document.querySelectorAll('button,input[type="submit"],input[type="button"]'));
                    return all.find(function(b){ var t=(b.innerText||b.value||'').toLowerCase(); var id=(b.id||'').toLowerCase(); var n=(b.name||'').toLowerCase(); return /(submit|lookup|search|go)/.test(t)||/(submit|lookup|search|go)/.test(id)||/(submit|lookup|search|go)/.test(n); });
                }
                var vin = '%@'; var odo = '%@'.replace(/[^0-9]/g,'');
                var start = Date.now();
                return new Promise(function(resolve){ (function wait(){
                    var vinEl = pickVIN(); var odoEl = pickODO();
                    if(vinEl){ setVal(vinEl, vin); } if(odoEl){ setVal(odoEl, odo); }
                    var form = (vinEl && vinEl.form) || (odoEl && odoEl.form) || document.querySelector('form');
                    var btn = pickSubmit(form);
                    if(btn && vin && vin.length===17){
                        try { if(form && form.requestSubmit) { form.requestSubmit(btn); } else { btn.click(); } } catch(e) {}
                        try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                        return resolve('SUBMITTED');
                    }
                    try { if (document.activeElement) { document.activeElement.blur(); } } catch(e) {}
                    if(Date.now() - start < 2000){ return setTimeout(wait, 150); }
                    resolve('FILLED_NO_SUBMIT');
                })(); });
            })();
            """.replacingOccurrences(of: "%@", with: escapedVIN).replacingOccurrences(of: "%@", with: escapedODO)
            webView.evaluateJavaScript(jsFill) { _, _ in }
            didSubmit = true
            return
        }
        let jsExtract = """
        (function(){
            function txt(n){return (n&&n.textContent?n.textContent:'').replace(/\\n+/g,' ').trim();}
            var tds = Array.from(document.querySelectorAll('td'));
            var label = tds.find(td => /(^|\\b)Private Value:?\\b/i.test(txt(td)));
            if(!label){ return ''; }
            var val = txt(label.nextElementSibling||'');
            var m = val.match(/\\$?\\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\\.[0-9]{2})?)/);
            if(m){ return '$' + m[1]; }
            return val;
        })();
        """
        webView.evaluateJavaScript(jsExtract) { result, _ in
            if let price = result as? String, !price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.didExtract = true
                self.finishWithPrice(price)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishWithoutPrice()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishWithoutPrice()
    }

    private func scheduleTimeout(seconds: TimeInterval = 15) {
        cancelTimeout()
        let work = DispatchWorkItem { [weak self] in
            self?.finishWithoutPrice()
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func cleanupWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    private func finishWithPrice(_ price: String) {
        cancelTimeout()
        cleanupWebView()
        onPrice(price)
    }

    private func finishWithoutPrice() {
        cancelTimeout()
        cleanupWebView()
    }
}

extension String {
    var dateOnly: String {
        trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first ?? self
    }

    func rounded2dec() -> String {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned) else { return cleaned }
        return String(format: "%.2f", value)
    }

    func normalizedUSDate() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }

        let inputFormats = ["MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy", "yyyy-MM-dd"]
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MM/dd/yyyy"

        for format in inputFormats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = format
            if let d = df.date(from: trimmed) {
                return out.string(from: d)
            }
        }
        return trimmed
    }

    func formatWithCommas() -> String {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned) else { return trimmedOrNA(self) }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: value)) ?? cleaned
    }

    func formatDateToUSD() -> String {
        normalizedUSDate()
    }

    func formatAsCurrency() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("$") { return trimmed }
        let cleaned = trimmed.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        guard let value = Double(cleaned) else { return trimmed }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: value)) ?? trimmed
    }

    private func trimmedOrNA(_ input: String) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "N/A" : t
    }

    private static let _auctionDateParseLock = NSLock()

    private static let _auctionDateParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MM/dd/yyyy"
        return df
    }()

    func toAuctionRelativeDay() -> String {
        let raw = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return self }

        String._auctionDateParseLock.lock()
        let parsedDate = String._auctionDateParser.date(from: raw)
        String._auctionDateParseLock.unlock()

        guard let targetDate = parsedDate else { return self }

        let calendar = Calendar.current
        if calendar.isDateInToday(targetDate) { return "\(self) (Today)" }
        if calendar.isDateInTomorrow(targetDate) { return "\(self) (Tomorrow)" }
        if calendar.isDateInYesterday(targetDate) { return "\(self) (Yesterday)" }

        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTargetDate = calendar.startOfDay(for: targetDate)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfTargetDate).day ?? 0

        if days > 0 {
            let label = days == 1 ? "day" : "days"
            return "\(self) (In \(days) \(label))"
        }
        if days < 0 {
            let absDays = abs(days)
            let label = absDays == 1 ? "day" : "days"
            return "\(self) (\(absDays) \(label) ago)"
        }
        return "\(self) (Today)"
    }

    // MARK: Relative date ("(1 yr 3 mo ago)")
    private static let _relativeDateLock = NSLock()

    private static let _odoDateFormats = [
        "M/d/yyyy",
        "MM/dd/yyyy",
        "yyyy-MM-dd",
        "M/d/yy"
    ]

    private static let _odoDateParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "M/d/yyyy"
        return df
    }()

    private static let _timeAgoShortFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    func timeAgoShort() -> String {
        let cleanString = dateOnly
        guard !cleanString.isEmpty else { return "" }

        let now = Date()
        String._relativeDateLock.lock()
        defer { String._relativeDateLock.unlock() }

        var parsedDate: Date?
        for format in String._odoDateFormats {
            String._odoDateParser.dateFormat = format
            if let date = String._odoDateParser.date(from: cleanString) {
                parsedDate = date
                break
            }
        }

        guard let date = parsedDate else { return "" }
        if Calendar.current.isDateInToday(date) { return "(Today)" }
        guard date < now else { return "" }

        guard let diffString = String._timeAgoShortFormatter.string(from: date, to: now), !diffString.isEmpty else { return "" }
        return "(\(diffString.replacingOccurrences(of: ",", with: "") ) ago)"
    }
}

extension Optional where Wrapped == String {
    func formatAsCurrency() -> String {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "N/A" }
        return value.formatAsCurrency() ?? value
    }
}

extension Double {
    func rounded2dec() -> String {
        String(format: "%.2f", self)
    }
}

extension OdoInfo {
    var gauge: Double {
        let cleaned = odometer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Double(cleaned) ?? 0
    }
}


private extension String {
    /// Extracts the first contiguous block of decimal digits as the grouping key.
    /// "11384 Harwin DR A" and "11384 Harwin DR," both yield "11384", so manual-entry
    /// variants that share the same street number are merged into one display label.
    var streetNumberKey: String {
        self.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first { !$0.isEmpty } ?? self.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

struct HPDView: View {
    var favoritesOnly: Bool
    @Binding var externalLocationFilter: String?

    init(favoritesOnly: Bool = false, externalLocationFilter: Binding<String?> = .constant(nil)) {
        self.favoritesOnly = favoritesOnly
        self._externalLocationFilter = externalLocationFilter
    }

    enum ExtractionState: Equatable {
        case idle
        case fetchingOdometer
        case waitingForCaptcha
        case fetchingPrice
    }

    enum FilterOption: String { case all, favorites, priced }

    private let defaultURLString = "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm"
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager

    @AppStorage("userRole")            private var userRole: String = "user"
    @AppStorage("hpdManualURLEnabled") private var manualURLModeEnabled: Bool = false
    @AppStorage("hpdManualURLInput")   private var hpdManualURLInput: String = ""
    @AppStorage("hpdRefreshTrigger")   private var hpdRefreshTrigger: Int = 0
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var entries: [HPDEntry] = []
    @AppStorage("hpd_sortKey") private var sortKey: SortKey = .date
    @AppStorage("hpd_sortAscending") private var sortAscending: Bool = true

    // Cache
    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()
    @AppStorage("hpdCachedURL") private var hpdCachedURL: String = ""
    @AppStorage("hpdLastFetchTS") private var hpdLastFetchTS: Double = 0
    @AppStorage("lastHPDSyncDate") private var lastHPDSyncDate: Double = 0
    @AppStorage("hpdHadLastError") private var hpdHadLastError: Bool = false
    @AppStorage("selectedLocationFiltersData") private var selectedLocationFiltersData: Data = Data()
    @State private var decodedLocationFilters: Set<String> = []
    @State private var cachedFilteredEntries: [HPDEntry] = []
    @State private var cachedFilteredCount: Int = 0
    @State private var cachedGroupedByDate: [(String, [HPDEntry])] = []
    @State private var favoriteLocationOptions: [(title: String, address: String, count: Int, entries: [HPDEntry])] = []
    @State private var showLocationFilterSheet: Bool = false
    @State private var isUserNavigatingFromHeader: Bool = false
    @State private var showFilter: Bool = false
    @State private var filterOption: FilterOption = .all
    @State private var selectedYear: Int? = nil
    @State private var selectedMake: String = "All"
    @State private var selectedModel: String = "All"
    @State private var maxPrice: String = ""

    @State private var searchText: String = ""

    // Auto-fetch control
    @State private var didAutoFetch: Bool = false

    @State private var expandedLocationIDs: Set<UUID> = []
    @State private var expandedLocations: [String: Bool] = [:]
    @State private var collapsedDates: Set<String> = []
    @State private var isFavoriteLocationFilterExpanded: Bool = false
    @State private var selectedFavoriteLocationFilters: Set<String> = []
    @State private var isFavoriteLocationSearchVisible: Bool = false
    @State private var favoriteLocationSearchText: String = ""
    @State private var favoriteLocationAutoCollapseToken = UUID()
    @State private var mileageVIN: String? = nil
    @State private var spvVIN: String? = nil
    @State private var spvOdo: String? = nil

    @AppStorage("hideWelcomeScreen") private var hideWelcomeScreen: Bool = false
    @State private var showWelcomeSheet: Bool = false
    static var hasShownWelcomeThisSession: Bool = false

    @State private var extractionState: ExtractionState = .idle
    @State private var extractionError: String? = nil
    @State private var extractionCancelToken = UUID()
    @State private var extractionErrorMessage: String? = nil
    @State private var showExtractionErrorAlert: Bool = false
    @State private var isQuotaExceededAlert: Bool = false
    @State private var mileageForceStartToken = UUID()

    // Tracking which card is running and which finished last
    @State private var lastProcessingVIN: String? = nil
    @State private var lastProcessedVIN: String? = nil

    // Added for favorite confirmation
    @State private var showFavoriteConfirm: Bool = false
    @State private var pendingFavoriteKey: String? = nil
    @State private var pendingFavoriteEntry: HPDEntry? = nil
    @State private var pendingFavoriteLabel: String = ""

    // Added for calendar confirmation
    @State private var showCalendarConfirm: Bool = false
    @State private var pendingCalendarEntry: HPDEntry? = nil
    @State private var pendingCalendarLabel: String = ""

    // Quick Inventory
    @State private var showQuickInventory: Bool = false

    // Legal disclaimer, copy-VIN feedback, web confirmation
    @State private var showLegalDisclaimer: Bool = false
    @State private var pendingExtractionEntry: HPDEntry? = nil
    @State private var copiedVIN: String? = nil
    @State private var webVIN: String? = nil
    @State private var showWebConfirm: Bool = false
    @State private var showMapConfirm: Bool = false
    @State private var showMapAlert: Bool = false
    @State private var showQuickDataInfo: Bool = false
    @State private var showCarfaxTeaser: Bool = false
    @State private var showCarfaxUpsellDialog: Bool = false
    @State private var showPaywall: Bool = false
    @State private var showQuotaSheet: Bool = false
    @State private var pendingMapAddress: String = ""
    @State private var pendingMapTime: String = ""
    @State private var selectedAddressForMap: String = ""
    @State private var statVinURL: URL? = nil
    @AppStorage("openWebInSafari") private var openWebInSafari: Bool = false

    enum SortKey: String { case date, year, make, model, priced, favorites }
    private let cardFixedHeight: CGFloat = 180

    // MARK: - Multi-select location filter (AppStorage-backed Set<String>)

    private var selectedLocationFilters: Set<String> {
        get { decodedLocationFilters }
        nonmutating set {
            decodedLocationFilters = newValue
            selectedLocationFiltersData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private var locationFilterLabel: String {
        let locs = selectedLocationFilters
        if locs.isEmpty { return "- All Locations" }
        if locs.count == 1 { return "- @ \(locs.first!)" }
        return "- \(locs.count) Locations"
    }

    private var showFilterIndicator: Bool {
        !selectedLocationFilters.isEmpty ||
        filterOption != .all ||
        sortKey != .date ||
        !sortAscending ||
        selectedYear != nil ||
        selectedMake != "All" ||
        selectedModel != "All" ||
        !maxPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortOption: SortKey {
        get { sortKey }
        nonmutating set { sortKey = newValue }
    }

    private var showPricedOnly: Bool {
        get { filterOption == .priced }
        nonmutating set { filterOption = newValue ? .priced : .all }
    }

    private func favoriteLocationLabel(for entry: HPDEntry) -> String {
        let address = sanitizedAddressForMaps(entry.lotAddress)
        if !address.isEmpty { return address }
        return entry.lotName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func favoriteLocationTitle(for entry: HPDEntry) -> String {
        let lotTitle = entry.lotName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lotTitle.isEmpty { return lotTitle }
        return favoriteLocationLabel(for: entry)
    }

    private var favoriteLocationSelectionSummary: String {
        let selected = selectedFavoriteLocationFilters
        if selected.isEmpty {
            return "All saved locations"
        }

        if selected.count == 1, let address = selected.first {
            let matchingTitle = favoriteLocationOptions.first { $0.address == address }?.title ?? address
            return matchingTitle.capitalized
        }

        return "\(selected.count) locations selected"
    }

    private var filteredFavoriteLocationOptions: [(title: String, address: String, count: Int, entries: [HPDEntry])] {
        favoriteLocationOptions
    }

    private func rebuildFavoriteLocationOptions(from favoriteEntries: [HPDEntry]) {
        let grouped = Dictionary(grouping: favoriteEntries, by: favoriteLocationLabel(for:))
        favoriteLocationOptions = grouped
            .compactMap { address, entries in
                let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanAddress.isEmpty else { return nil }
                let titleCounts = Dictionary(grouping: entries, by: favoriteLocationTitle(for:))
                    .mapValues(\.count)
                let bestTitle = titleCounts.max { lhs, rhs in
                    if lhs.value == rhs.value {
                        return lhs.key.count > rhs.key.count
                    }
                    return lhs.value < rhs.value
                }?.key ?? cleanAddress
                return (title: bestTitle, address: cleanAddress, count: entries.count, entries: entries)
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.title < $1.title
                }
                return $0.count > $1.count
            }
    }

    private func decodeCachedEntries(_ data: Data) -> [HPDEntry] {
        (try? JSONDecoder().decode([HPDEntry].self, from: data)) ?? []
    }
    private func encodeEntries(_ items: [HPDEntry]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data()
    }

    private func windows1252Encoding() -> String.Encoding {
        return .windowsCP1252
    }

    private func mapCharsetNameToEncoding(_ name: String) -> String.Encoding? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch n {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252", "windows1252":
            return windows1252Encoding()
        default:
            return nil
        }
    }

    private func encodingFromHTTPHeader(_ response: URLResponse?) -> String.Encoding? {
        guard let http = response as? HTTPURLResponse,
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else { return nil }
        // e.g. "text/html; charset=windows-1252"
        if let range = contentType.range(of: "charset=") {
            let charset = String(contentType[range.upperBound...]).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return mapCharsetNameToEncoding(charset)
        }
        return nil
    }

    private func encodingFromHTMLMeta(_ data: Data) -> String.Encoding? {
        // Look only at the first few KB for meta tags
        let prefixData = data.prefix(8192)
        // Use a lenient decode just for scanning
        let probe = String(decoding: prefixData, as: UTF8.self).lowercased()
        // Try <meta charset="..."> first
        if let metaRange = probe.range(of: "<meta"), let endRange = probe.range(of: ">", range: metaRange.lowerBound..<probe.endIndex) {
            let metaChunk = String(probe[metaRange.lowerBound..<endRange.upperBound])
            if let cr = metaChunk.range(of: "charset=") {
                let after = metaChunk[cr.upperBound...]
                // Extract token possibly quoted
                let token: String
                if after.first == "\"" || after.first == "'" {
                    let quote = after.first!
                    if let closing = after.dropFirst().firstIndex(of: quote) {
                        token = String(after.dropFirst()[..<closing])
                    } else {
                        token = String(after.dropFirst())
                    }
                } else {
                    token = String(after.split(whereSeparator: { $0 == ";" || $0 == ">" || $0.isWhitespace }).first ?? Substring(""))
                }
                if let enc = mapCharsetNameToEncoding(token) { return enc }
            }
        }
        // Try http-equiv variant anywhere in the prefix
        if let cr = probe.range(of: "charset=") {
            let after = probe[cr.upperBound...]
            let token = String(after.split(whereSeparator: { $0 == ";" || $0 == ">" || $0.isWhitespace || $0 == "\"" || $0 == "'" }).first ?? Substring(""))
            if let enc = mapCharsetNameToEncoding(token) { return enc }
        }
        return nil
    }

    private func decodeResponseData(_ data: Data, response: URLResponse?) -> (String, String) {
        if let enc = encodingFromHTTPHeader(response), let s = String(data: data, encoding: enc) {
            return (s, "header")
        }
        if let enc = encodingFromHTMLMeta(data), let s = String(data: data, encoding: enc) {
            return (s, "meta")
        }
        if let s = String(data: data, encoding: .utf8) {
            return (s, "utf8")
        }
        let win1252 = windows1252Encoding()
        if let s = String(data: data, encoding: win1252) {
            return (s, "windows-1252")
        }
        if let s = String(data: data, encoding: .isoLatin1) {
            return (s, "latin1")
        }
        let s = String(decoding: data, as: UTF8.self)
        return (s, "lenient-utf8")
    }

    private func parseYearInt(_ raw: String) -> Int? {
        return Int(normalizedYear(raw))
    }

    private func isCardEmpty(_ e: HPDEntry) -> Bool {
        func empty(_ s: String?) -> Bool { return (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return empty(e.make) && empty(e.model) && empty(e.year)
    }
    private func formatOdoK(_ raw: String) -> String {
        // Keep only digits, then round to nearest thousand and append 'k'
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter({ $0.isNumber })
        if digits.isEmpty { return "no odo" }
        guard let val = Int(digits), val > 0 else { return "no odo" }
        let k = Int(round(Double(val) / 1000.0))
        return "\(k)k"
    }

    private func formatTestDateMMYY(_ raw: String) -> String {
        // Devuelve MM/YY para formatos:
        //  - "06/30/2022", "6/30/22", "6/27/2021 1:34:38 AM"
        //  - "2024-06-30"
        //  - "Tue Jun 18 2024 00:00:00 GMT-0500 (CDT)"
        //  - "Jun 18, 2024", "June 18 2024", "18 Jun 2024"
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return raw }

        // 0) Mapa de meses (minúsculas)
        let monthMap: [String: Int] = [
            "jan": 1, "january": 1,
            "feb": 2, "february": 2,
            "mar": 3, "march": 3,
            "apr": 4, "april": 4,
            "may": 5,
            "jun": 6, "june": 6,
            "jul": 7, "july": 7,
            "aug": 8, "august": 8,
            "sep": 9, "sept": 9, "september": 9,
            "oct": 10, "october": 10,
            "nov": 11, "november": 11,
            "dec": 12, "december": 12
        ]

        // Helper: MM/YY
        func mmYY(mm: Int, yyyyOrYY: String) -> String {
            let mm2 = String(format: "%02d", mm)
            let yy2 = yyyyOrYY.count >= 2 ? String(yyyyOrYY.suffix(2)) : yyyyOrYY
            return "\(mm2)/\(yy2)"
        }

        // 1) MM/DD/YYYY (con posible “basura” después)
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b"#) {
            let ns = s as NSString
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 4 {
                let mmStr = ns.substring(with: m.range(at: 1))
                let yyFull = ns.substring(with: m.range(at: 3))
                let mm = Int(mmStr) ?? 0
                if (1...12).contains(mm) { return mmYY(mm: mm, yyyyOrYY: yyFull) }
            }
        }

        // 2) ISO: YYYY-MM-DD
        if let reISO = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) {
            let ns = s as NSString
            if let m = reISO.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 4 {
                let yyyy = ns.substring(with: m.range(at: 1))
                let mmStr = ns.substring(with: m.range(at: 2))
                let mm = Int(mmStr) ?? 0
                if (1...12).contains(mm) { return mmYY(mm: mm, yyyyOrYY: yyyy) }
            }
        }

        // 3a) Month-name first: (Tue )?Jun(e)? 18,? 2024 ...
        if let reMon = try? NSRegularExpression(
            pattern: #"(?:\bMon|\bTue|\bWed|\bThu|\bFri|\bSat|\bSun)\s+"# +
                     #"?(\bJan(?:uary)?|\bFeb(?:ruary)?|\bMar(?:ch)?|\bApr(?:il)?|\bMay|\bJun(?:e)?|\bJul(?:y)?|\bAug(?:ust)?|\bSep(?:t(?:ember)?)?|\bOct(?:ober)?|\bNov(?:ember)?|\bDec(?:ember)?)\s+(\d{1,2})\s*,?\s*(\d{4})"#,
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            if let m = reMon.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 4 {
                let monTok = ns.substring(with: m.range(at: 1)).lowercased()
                _ = ns.substring(with: m.range(at: 2)) // unused day token; only month+year needed
                let yyyy   = ns.substring(with: m.range(at: 3))
                if let mm = monthMap[monTok], (1...12).contains(mm) { return mmYY(mm: mm, yyyyOrYY: yyyy) }
            }
        }

        // 3b) Month-name first (sin día de la semana): Jun(e)? 18,? 2024 ...
        if let reMon2 = try? NSRegularExpression(
            pattern: #"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(\d{1,2})\s*,?\s*(\d{4})"#,
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            if let m = reMon2.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 4 {
                let monTok = ns.substring(with: m.range(at: 1)).lowercased()
                let yyyy   = ns.substring(with: m.range(at: 3))
                if let mm = monthMap[monTok], (1...12).contains(mm) { return mmYY(mm: mm, yyyyOrYY: yyyy) }
            }
        }

        // 3c) Day first: 18 Jun(e)? 2024
        if let reDayFirst = try? NSRegularExpression(
            pattern: #"\b(\d{1,2})\s+(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s*,?\s*(\d{4})"#,
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            if let m = reDayFirst.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 4 {
                let monTok = ns.substring(with: m.range(at: 2)).lowercased()
                let yyyy   = ns.substring(with: m.range(at: 3))
                if let mm = monthMap[monTok], (1...12).contains(mm) { return mmYY(mm: mm, yyyyOrYY: yyyy) }
            }
        }

        // 4) Nada coincidió: regresa el original
        return raw
    }
    
    // Inserted helpers for price parsing and comparison
    private func parsePrice(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
    private func priceValue(for vin: String) -> Double? {
        let key = normalizeVIN(vin)
        guard let spv = supabaseService.odoByVIN[key]?.privateValue else { return nil }
        return parsePrice(spv)
    }
    private func compareByPrice(_ a: HPDEntry, _ b: HPDEntry, ascending: Bool) -> Bool {
        let av = priceValue(for: a.vin)
        let bv = priceValue(for: b.vin)
        let aHas = av != nil
        let bHas = bv != nil
        // Always put priced items before non-priced
        if aHas != bHas { return aHas && !bHas }
        // If neither has price, fall back to make+model
        if !aHas && !bHas {
            return (a.make + a.model).localizedCompare(b.make + b.model) == .orderedAscending
        }
        // Both have price; compare numerically
        if let av = av, let bv = bv {
            if av == bv {
                return (a.make + a.model).localizedCompare(b.make + b.model) == .orderedAscending
            }
            return ascending ? (av < bv) : (av > bv)
        }
        return false
    }
    
    private func titleSuffix(for vin: String) -> String {
        let key = normalizeVIN(vin)
        guard let info = supabaseService.odoByVIN[key] else { return "" }
        let odoK = formatOdoK(info.odometer)
        let dMMYY = formatTestDateMMYY(info.testDate)
        let spvRaw = (info.privateValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spv = formatPrivateValueForDisplay(spvRaw)
        var parts: [String] = []
        if !odoK.isEmpty {
            if !dMMYY.isEmpty { parts.append("\(odoK) (\(dMMYY))") } else { parts.append(odoK) }
        } else if !dMMYY.isEmpty {
            parts.append("(\(dMMYY))")
        }
        if !spv.isEmpty { parts.append("- \(spv)") }
        if parts.isEmpty { return "" }
        return " • " + parts.joined(separator: " ")
    }
    
    private func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    
    private func hapticSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.impactOccurred()
    }

    private func parseAuctionDate(_ dateStr: String, timeStr: String?) -> Date? {
        let base = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = (timeStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        let dateCandidatesWithTime = [
            "MM/dd/yyyy h:mm:ss a", "MM/dd/yyyy h:mm a",
            "M/d/yyyy h:mm:ss a",  "M/d/yyyy h:mm a",
            "MM/dd/yy h:mm:ss a",  "MM/dd/yy h:mm a",
            "M/d/yy h:mm:ss a",    "M/d/yy h:mm a"
        ]
        if !time.isEmpty {
            for f in dateCandidatesWithTime { df.dateFormat = f; if let d = df.date(from: "\(base) \(time)") { return d } }
        }
        let dateOnlyCandidates = ["MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy"]
        for f in dateOnlyCandidates { df.dateFormat = f; if let d = df.date(from: base) { return d } }
        return nil
    }


    private func addToCalendar(entry e: HPDEntry) {
        let cachedInfo = supabaseService.odoByVIN[normalizeVIN(e.vin)]
        let store = EKEventStore()

        let requestHandler: (Bool, (any Error)?) -> Void = { granted, err in
            guard err == nil else { return }
            guard granted else {
                // If you don't see the permission prompt, ensure NSCalendarsUsageDescription is in Info.plist
                return
            }
            let event = EKEvent(eventStore: store)
            let title = "Auction: \(normalizedYear(e.year)) \(e.make) \(e.model)"
            event.title = title

            // Tu lógica de dirección + URL (sin perder nada)
            let addrForCal = sanitizedAddressForMaps(e.lotAddress)
            event.location = e.lotAddress // mantiene tu comportamiento textual
            if !addrForCal.isEmpty {
                let q = addrForCal.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? addrForCal
                event.url = URL(string: "http://maps.apple.com/?q=\(q)")
            }

            // Fechas
            let start = parseAuctionDate(e.dateScheduled, timeStr: e.time) ?? Date()
            event.startDate = start
            event.endDate = start.addingTimeInterval(60 * 60) // 1 hour
            event.calendar = store.defaultCalendarForNewEvents

            // Notas (con tu formato y fecha limpia)
            var notes: [String] = []
            if !addrForCal.isEmpty {
                notes.append("Address: \(addrForCal)")
                if let mapURL = event.url { notes.append("Maps: \(mapURL.absoluteString)") }
            }
            notes.append("Lot: \(e.lotName)")
            notes.append("VIN: \(e.vin)")
            if !e.plate.isEmpty { notes.append("Plate: \(e.plate)") }
            if let t = e.time, !t.isEmpty { notes.append("Time: \(t)") }
            if let info = cachedInfo {
                if !info.odometer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.append("Odometer: \(info.odometer)")
                }
                let calDate = formatTestDateMMYY(info.testDate) // <- quita GMT...
                if !calDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.append("Last Inspection: \(calDate)")
                }
                if let pv = info.privateValue, !pv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.append("Private Value: \(pv)")
                }
            }
            event.notes = notes.joined(separator: "\n")

            // Alarma 30 min antes
            let alarm = EKAlarm(relativeOffset: -30 * 60)
            event.addAlarm(alarm)

            // Helper: guardar y abrir Calendar
            func finalizeSave() {
                do {
                    try store.save(event, span: .thisEvent)
                    DispatchQueue.main.async {
                        hapticSuccess()
                        let ti = Int(event.startDate.timeIntervalSinceReferenceDate)
                        if let url = URL(string: "calshow:\(ti)") {
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        }
                    }
                } catch {
                    // opcional: mostrar alerta
                }
            }

            // Geocoding con MKLocalSearch + EKStructuredLocation para previsualización de mapa
            if !addrForCal.isEmpty {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = addrForCal
                let search = MKLocalSearch(request: request)
                search.start { response, _ in
                    if let item = response?.mapItems.first {
                        let location: CLLocation
                        if #available(iOS 26.0, *) {
                            location = item.location
                        } else {
                            location = CLLocation(
                                latitude: item.placemark.coordinate.latitude,
                                longitude: item.placemark.coordinate.longitude
                            )
                        }
                        let structured = EKStructuredLocation(title: addrForCal)
                        structured.geoLocation = location
                        structured.radius = 100
                        event.structuredLocation = structured
                    }
                    finalizeSave()
                }
            } else {
                // Sin dirección limpia: guarda igual
                finalizeSave()
            }
        }

        if #available(iOS 17.0, *) {
            store.requestWriteOnlyAccessToEvents(completion: requestHandler)
        } else {
            store.requestAccess(to: .event, completion: requestHandler)
        }
    }
    private func retryFetch() {
        autoFetch(force: true)
    }

    @ViewBuilder
    private func emptyOrErrorView() -> some View {
        if isLoading {
            EmptyView()
        } else if let err = errorMessage, !err.isEmpty {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(height: 140)
                    .overlay(
                        VStack(spacing: 8) {
                            Text("No se pudo cargar la información")
                                .bold()
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("Reintentar") {
                                retryFetch()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                        .padding()
                    )
                    .padding(.horizontal)
            }
        } else if entries.isEmpty {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(height: 140)
                    .overlay(
                        VStack(spacing: 8) {
                            Text("No hay información para mostrar")
                                .bold()
                            Button("Reintentar") {
                                retryFetch()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            Text("Desliza hacia abajo para actualizar")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    )
                    .padding(.horizontal)
            }
        }
    }
    
    private func sanitizedAddressForMaps(_ lotAddress: String) -> String {
        // Keep only if it looks like a real address; otherwise return empty so UI shows (No address)
        let t = lotAddress
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        let lower = t.lowercased()
        let hasAnyDigit = t.range(of: "\\d", options: .regularExpression) != nil
        let hasZip = t.range(of: #"\b\d{5}(?:-\d{4})?\b"#, options: .regularExpression) != nil
        let hasStreetSuffix = lower.range(of: #"\b(st|ave|rd|dr|blvd|ln|lane|way|pkwy|parkway|court|ct|cir|circle|trl|trail|hwy|highway|suite|ste)\b"#, options: .regularExpression) != nil
        let looksBusiness = (
            lower.contains(" inc") || lower.contains(" inc.") ||
            lower.contains(" llc") || lower.contains(" llc.") ||
            lower.contains(" co ") || lower.contains(" company") ||
            lower.contains(" towing") || lower.contains(" storage") ||
            lower.contains(" motors") || lower.contains(" auto ")
        )
        if looksBusiness && !(hasStreetSuffix || hasZip || hasAnyDigit) { return "" }
        if !(hasStreetSuffix || hasZip || hasAnyDigit) { return "" }
        return t
    }

    private func shortStreetAddress(_ address: String) -> String {
        var s = address
        let lower = s.lowercased()
        for marker in [" houston", ", tx", " tx ", " texas"] {
            if let r = lower.range(of: marker) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if let r = s.range(of: #"\s*\b\d{5}(?:-\d{4})?\b\s*$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? address : s
    }

    private var uniqueAddresses: [String] {
        // Group by street number key — keeps the first full readable address per number.
        // Passive guard blocks exact garbage artifacts (e.g. "Llc", "Inc", very short strings).
        var seen: [String: String] = [:]
        for entry in entries {
            let raw = entry.lotAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count >= 5,
                  !raw.lowercased().elementsEqual("llc"),
                  !raw.lowercased().elementsEqual("inc") else { continue }
            let key = raw.streetNumberKey
            if seen[key] == nil { seen[key] = raw }
        }
        return Array(seen.values).sorted()
    }

    private var uniqueMakes: [String] {
        let makes = entries
            .filter { !isDateInPast($0.dateScheduled) }
            .map { $0.make.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(makes)).sorted()
    }

    private var modelOptionsForSelectedMake: [String] {
        let base = entries.filter { !isDateInPast($0.dateScheduled) }
        let filtered: [HPDEntry]
        if selectedMake == "All" {
            filtered = base
        } else {
            filtered = base.filter { $0.make.localizedCaseInsensitiveCompare(selectedMake) == .orderedSame }
        }
        let models = filtered
            .map { $0.model.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(models)).sorted()
    }

    private var uniqueYears: [Int] {
        let years = entries
            .filter { !isDateInPast($0.dateScheduled) }
            .compactMap { parseYearInt($0.year) }
        return Array(Set(years)).sorted()
    }

    private var isPlatinumRateEligible: Bool {
        supabaseService.hasServerPlatinumAccess
    }

    private var currentServerDailyLimit: Int {
        supabaseService.currentServerDailyLimit
    }

    private func removeFavorite(_ entry: HPDEntry) {
        let key = normalizeVIN(entry.vin)
        supabaseService.removeFavoriteLocally(key)
        supabaseService.syncRemoveFavorite(key)
    }

    private enum FavoriteGroupSegment {
        case header
        case item
        case footer
    }

    private func favoriteGroupBackground(_ segment: FavoriteGroupSegment) -> some View {
        let radii: RectangleCornerRadii
        let strokeOpacity: Double
        switch segment {
        case .header:
            radii = .init(topLeading: 22, bottomLeading: 0, bottomTrailing: 0, topTrailing: 22)
            strokeOpacity = 0.07
        case .item:
            radii = .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0)
            strokeOpacity = 0
        case .footer:
            radii = .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0)
            strokeOpacity = 0.07
        }

        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(
                UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
                    .stroke(Color.black.opacity(strokeOpacity), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func favoriteVehicleRow(_ entry: HPDEntry, isFirstInLocation: Bool = false, isLastInLocation: Bool = false) -> some View {
        VehicleCardView(
            entry: entry,
            showAddress: false,
            showQuickInventory: false,
            showFavoriteButton: false,
            isFavoritesContext: true,
            initiallyExpanded: true
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                removeFavorite(entry)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, isFirstInLocation ? 4 : 8)
        .padding(.bottom, isLastInLocation ? 14 : 10)
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(favoriteGroupBackground(isLastInLocation ? .footer : .item))
    }

    @ViewBuilder
    private func favoriteLocationHeader(
        title: String,
        address: String,
        shortAddress: String,
        formattedTime: String?,
        totalVehicles: Int,
        sectionKey: String
    ) -> some View {
        let isExpanded = expandedLocations[sectionKey] ?? true

        HStack(spacing: 12) {
            Button {
                selectedAddressForMap = address
                showMapAlert = true
            } label: {
                Image("applemaps")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .opacity(0.9)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title.capitalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .allowsTightening(true)
                        .layoutPriority(1)

                    Text("(\(totalVehicles))")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    Text(shortAddress.capitalized)
                    if let formattedTime, !formattedTime.isEmpty {
                        Text("•")
                        Text(formattedTime)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            expandedLocations[sectionKey] = !isExpanded
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .listRowInsets(EdgeInsets(top: 18, leading: 10, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(favoriteGroupBackground(.header))
    }

    @ViewBuilder
    private func favoriteLocationSpacerRow() -> some View {
        Color.clear
            .frame(height: 6)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // Single reactive token — changes whenever any filter or sort option changes.
    private var activeFilterHash: String {
        "\(filterOption.rawValue)|\(sortKey.rawValue)|\(decodedLocationFilters.sorted().joined(separator: ","))|\(sortAscending)|\(selectedYear.map(String.init) ?? "All")|\(selectedMake)|\(selectedModel)|\(maxPrice)"
    }

    @ViewBuilder private func sectionRows(for items: [HPDEntry]) -> some View {
        ForEach(items) { e in
            card(for: e)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private var skeletonCardRow: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .frame(width: 44, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4).frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4).frame(width: 110, height: 10)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 14).frame(width: 34, height: 34)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .redacted(reason: .placeholder)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color(.secondarySystemBackground).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private var skeletonList: some View {
        List {
            ForEach(0..<6, id: \.self) { _ in
                skeletonCardRow
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.custom(0))
        .allowsHitTesting(false)
        .navigationTitle(favoritesOnly ? "FAVORITES (\(entries.count))" : "HPD AUCTION (\(entries.count))")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var vehicleList: some View {
        if isLoading && entries.isEmpty {
            skeletonList
        } else if favoritesOnly {
            favoritesWalletList
        } else {
        List {
            // Unified header row: chips + error + counter in one cell
            VStack(spacing: 4) {
                if !selectedLocationFilters.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(selectedLocationFilters).sorted(), id: \.self) { loc in
                                Button {
                                    var updated = selectedLocationFilters
                                    updated.remove(loc)
                                    selectedLocationFilters = updated
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(loc).lineLimit(1)
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                                .clipShape(Capsule())
                            }
                            Button(role: .destructive) {
                                selectedLocationFilters = []
                            } label: {
                                Label("Clear Filters", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .clipShape(Capsule())
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                }
                if let activeFilter = externalLocationFilter {
                    HStack {
                        Text("Filtering by: \(activeFilter)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            externalLocationFilter = nil
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                emptyOrErrorView()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if cachedFilteredEntries.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label(
                        favoritesOnly ? "No Favorites Yet" : "No Vehicles Found",
                        systemImage: favoritesOnly ? "star.slash" : "magnifyingglass"
                    )
                } description: {
                    Text(favoritesOnly ? "Vehicles you star will appear here." : "Try adjusting your search or filters.")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(cachedGroupedByDate, id: \.0) { dateKey, items in
                    let isCollapsed = collapsedDates.contains(dateKey)
                    Section(header: sectionHeader(for: dateKey, displayDate: dateKey.toAuctionRelativeDay(), count: items.count, collapsed: isCollapsed) {
                        if isCollapsed { collapsedDates.remove(dateKey) } else { collapsedDates.insert(dateKey) }
                    }) {
                        if !isCollapsed {
                            sectionRows(for: items)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.custom(0))
        .navigationTitle("HPD AUCTION (\(cachedFilteredCount))")
        .navigationBarTitleDisplayMode(.inline)
        } // end else (isLoading && entries.isEmpty)
    }

    // MARK: - Favorites Apple Wallet view (Location → Date → Vehicles sorted by odometer desc)

    @ViewBuilder private var favoritesWalletList: some View {
        let hasAnyFavorites = entries.contains {
            !isDateInPast($0.dateScheduled) && supabaseService.favorites.contains(normalizeVIN($0.vin))
        }

        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if cachedFilteredEntries.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label(hasAnyFavorites ? "No Results" : "No Favorites Yet",
                              systemImage: hasAnyFavorites ? "magnifyingglass" : "star.slash")
                    } description: {
                        Text(hasAnyFavorites
                             ? "No favorite vehicles match the current search or location filter."
                             : "Vehicles you star will appear here.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !favoriteLocationOptions.isEmpty {
                            favoriteLocationFilterCard
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        ForEach(groupedFavorites, id: \.date) { dateGroup in
                            Section {
                                ForEach(Array(dateGroup.locations.enumerated()), id: \.element.address) { locationIndex, locationGroup in
                                    let locationTitle = locationGroup.title
                                    let shortAddress = locationGroup.address.components(separatedBy: " Houston").first ?? locationGroup.address
                                    let totalVehicles = locationGroup.vehicles.count
                                    let headerAuctionDate: Date? = {
                                        let date = locationGroup.vehicles.compactMap { parseAuctionDate($0.dateScheduled, timeStr: $0.time) }.first
                                        return date
                                    }()
                                    let formattedTime = headerAuctionDate?.compactAuctionTime()
                                    let sectionKey = "\(dateGroup.date)|\(locationGroup.address)"

                                    favoriteLocationHeader(
                                        title: locationTitle,
                                        address: locationGroup.address,
                                        shortAddress: shortAddress,
                                        formattedTime: formattedTime,
                                        totalVehicles: totalVehicles,
                                        sectionKey: sectionKey
                                    )

                                    if expandedLocations[sectionKey] ?? true {
                                        ForEach(Array(locationGroup.vehicles.enumerated()), id: \.element.id) { index, e in
                                            favoriteVehicleRow(
                                                e,
                                                isFirstInLocation: index == 0,
                                                isLastInLocation: index == locationGroup.vehicles.count - 1
                                            )
                                        }
                                    }

                                    if locationIndex < dateGroup.locations.count - 1 {
                                        favoriteLocationSpacerRow()
                                    }
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Image(systemName: "calendar")
                                        .foregroundColor(.accentColor)
                                        .font(.caption)
                                    Text(dateGroup.date)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.9)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .listSectionSpacing(.custom(8))
                    .alert("Open Apple Maps", isPresented: $showMapAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Navigate") {
                            if let encodedAddress = selectedAddressForMap.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                               let url = URL(string: "maps://?daddr=\(encodedAddress)") {
                                UIApplication.shared.open(url)
                            }
                        }
                    } message: {
                        Text("Do you want to leave the app and navigate to \(selectedAddressForMap)?")
                    }
                }
            }
        }
        .navigationTitle("FAVORITES (\(cachedFilteredCount))")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var favoriteLocationFilterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isFavoriteLocationFilterExpanded.toggle()
                if isFavoriteLocationFilterExpanded {
                    scheduleFavoriteLocationAutoCollapse()
                } else {
                    favoriteLocationAutoCollapseToken = UUID()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.blue)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Locations")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(favoriteLocationSelectionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !selectedFavoriteLocationFilters.isEmpty {
                        Text("\(selectedFavoriteLocationFilters.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    Image(systemName: isFavoriteLocationFilterExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isFavoriteLocationFilterExpanded {
                Divider()
                    .padding(.top, 12)

                SearchBar(
                    text: $favoriteLocationSearchText,
                    placeholder: "VIN, make, model or year"
                )
                .padding(.top, 14)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(filteredFavoriteLocationOptions, id: \.address) { option in
                        favoriteLocationFilterChip(title: option.title, address: option.address, count: option.count)
                    }
                }
                .padding(.top, 14)

                if !selectedFavoriteLocationFilters.isEmpty {
                    Button("Clear All Locations") {
                        selectedFavoriteLocationFilters.removeAll()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.top, 14)
                }
            }
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.primary.opacity(0.08), radius: 10, x: 0, y: 5)
    }

    private func scheduleFavoriteLocationAutoCollapse() {
        let token = UUID()
        favoriteLocationAutoCollapseToken = token

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard favoriteLocationAutoCollapseToken == token, isFavoriteLocationFilterExpanded else { return }
            isFavoriteLocationFilterExpanded = false
        }
    }

    private func favoriteLocationFilterChip(title: String, address: String, count: Int) -> some View {
        let isSelected = selectedFavoriteLocationFilters.contains(address)

        return Button {
            if isSelected {
                selectedFavoriteLocationFilters.remove(address)
            } else {
                selectedFavoriteLocationFilters.insert(address)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                    Text(title.capitalized)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((isSelected ? Color.white : Color.blue).opacity(isSelected ? 0.18 : 0.10))
                        .clipShape(Capsule())
                }

                Text(address.capitalized)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.88) : .secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .padding(14)
            .background(isSelected ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }



    @ViewBuilder private var filterSortMenu: some View {
        Menu {
            Button { sortOption = .date } label: {
                Label("Date", systemImage: sortOption == .date ? "checkmark" : "calendar")
            }
            Button { sortOption = .year } label: {
                Label("Year", systemImage: sortOption == .year ? "checkmark" : "number")
            }
            Button { sortOption = .make } label: {
                Label("Make", systemImage: sortOption == .make ? "checkmark" : "car")
            }
            Button { sortOption = .model } label: {
                Label("Model", systemImage: sortOption == .model ? "checkmark" : "tag")
            }
            Divider()
            Button { sortAscending = true } label: {
                Label("Soonest First", systemImage: sortAscending ? "checkmark" : "arrow.up")
            }
            Button { sortAscending = false } label: {
                Label("Latest First", systemImage: !sortAscending ? "checkmark" : "arrow.down")
            }
            Divider()
            Button { showPricedOnly = false } label: {
                Label("All Vehicles", systemImage: !showPricedOnly ? "checkmark" : "list.bullet")
            }
            Button { showPricedOnly = true } label: {
                Label("Priced", systemImage: showPricedOnly ? "checkmark" : "dollarsign.circle")
            }
            Divider()
            Button {
                isUserNavigatingFromHeader = true
                showFilter = true
            } label: {
                Label("Locations", systemImage: "mappin.and.ellipse")
            }
        } label: {
            Image(systemName: showFilterIndicator ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title3)
                .foregroundStyle(showFilterIndicator ? Color.accentColor : Color.secondary)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(Circle())
        }
    }

    @ViewBuilder private var mainContent: some View {
        VStack(spacing: 0) {
            // 1. Fixed header inside mainContent
            VStack(spacing: 10) {
                if !favoritesOnly {
                    HStack(spacing: 12) {
                        SearchBar(
                            text: $searchText,
                            placeholder: "Search VIN, Year, Brand or Model"
                        )

                        filterSortMenu
                    }
                    .padding(.horizontal, 16)
                }
            }

            if isLoading {
                ProgressView()
                    .padding(.vertical, 8)
            }
            vehicleList
        }
        .onAppear {
            if decodedLocationFilters.isEmpty, !selectedLocationFiltersData.isEmpty {
                decodedLocationFilters = (try? JSONDecoder().decode(Set<String>.self, from: selectedLocationFiltersData)) ?? []
            }
            lastProcessingVIN = nil
            lastProcessedVIN = nil
            extractionState = .idle
            if entries.isEmpty && !hpdCachedEntriesData.isEmpty {
                entries = decodeCachedEntries(hpdCachedEntriesData).filter { !isDateInPast($0.dateScheduled) }
                entries = entries.map { e in
                    var copy = e
                    if let nd = HPDParser.normalizeUSDate(e.dateScheduled) { copy.dateScheduled = nd }
                    return copy
                }
            }
            if entries.isEmpty { autoFetch() }
            if !hideWelcomeScreen && !Self.hasShownWelcomeThisSession {
                Self.hasShownWelcomeThisSession = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showWelcomeSheet = true
                }
            }
            recomputeFilteredEntries()
        }
        .task {
            recomputeFilteredEntries()
        }
        .sheet(isPresented: $showFilter) {
            HPDFilterSheet(
                addresses: uniqueAddresses,
                selectedFilters: Binding(
                    get: { selectedLocationFilters },
                    set: { selectedLocationFilters = $0 }
                ),
                onDismiss: {
                    showFilter = false
                    showLocationFilterSheet = false
                }
            )
        }
        .onChange(of: searchText) { _, _ in
            collapsedDates.removeAll(); expandedLocationIDs.removeAll()
            recomputeFilteredEntries()
        }
        .onChange(of: activeFilterHash) { _, _ in
            collapsedDates.removeAll(); expandedLocationIDs.removeAll()
            recomputeFilteredEntries()
        }
        .onChange(of: hpdRefreshTrigger) { _, _ in
            autoFetch(force: true)
        }
        .onChange(of: entries) { _, _ in
            recomputeFilteredEntries()
        }
        .onChange(of: externalLocationFilter) { _, _ in
            recomputeFilteredEntries()
        }
        .onChange(of: selectedLocationFiltersData) { _, newData in
            decodedLocationFilters = (try? JSONDecoder().decode(Set<String>.self, from: newData)) ?? []
            recomputeFilteredEntries()
        }
        .onChange(of: selectedFavoriteLocationFilters) { _, _ in
            if isFavoriteLocationFilterExpanded {
                scheduleFavoriteLocationAutoCollapse()
            }
            recomputeFilteredEntries()
        }
        .onChange(of: favoriteLocationSearchText) { _, _ in
            if isFavoriteLocationFilterExpanded {
                scheduleFavoriteLocationAutoCollapse()
            }
            if favoriteLocationSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isFavoriteLocationSearchVisible = false
            }
            recomputeFilteredEntries()
        }
        .onChange(of: supabaseService.favorites) { _, _ in
            recomputeFilteredEntries()
        }
        .onChange(of: supabaseService.odoByVIN) { _, _ in
            recomputeFilteredEntries()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showQuotaSheet = true
                } label: {
                    let tierKey = supabaseService.serverTierKey
                    if UIImage(named: tierKey) != nil {
                        Image(tierKey)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "star.shield.fill")
                            .font(.title2)
                    }
                }
            }
        }
        .sheet(isPresented: $showQuotaSheet) {
            QuotaUsageView()
                .environmentObject(supabaseService)
                .environmentObject(storeManager)
                .presentationDetents([.height(300), .medium])
                .presentationDragIndicator(.visible)
        }
    }

    var body: some View {
        ZStack {
            NavigationStack {
                mainContent
            }
            .sheet(isPresented: $showWelcomeSheet) {
                WelcomeOnboardingView()
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .onChange(of: storeManager.purchasedSubscriptions) { _, _ in
                        Task { await supabaseService.fetchCurrentProfile() }
                    }
            }

            if extractionState != .idle {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()

                    if extractionState == .waitingForCaptcha {
                        VStack {
                            Text("Please check the CAPTCHA box and press the blue Submit button below!")
                                .font(.headline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(uiColor: .systemBackground).opacity(0.9))
                                )
                                .padding(.top, 18)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(1.15)
                            Text(extractionOverlayMessage)
                                .font(.headline)
                            if let vin = lastProcessingVIN {
                                Text((vin))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Cancel", role: .cancel) {
                                cancelExtraction()
                            }
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(uiColor: .systemBackground).opacity(0.85))
                        )
                        .padding(20)
                    }
                }
                .zIndex(2)
                .allowsHitTesting(extractionState != .waitingForCaptcha)
            }

            if extractionState == .fetchingPrice,
               let spvURL = URL(string: "https://tools.txdmv.gov/tools/SPV/spv_lookup.php") {
                SPVWebView(
                    url: spvURL,
                    isActive: true,
                    vin: spvVIN ?? "",
                    mileage: spvOdo ?? "",
                    cancelToken: extractionCancelToken,
                    onError: { message in
                        failExtraction(message)
                    }
                ) { price in
                    DispatchQueue.main.async {
                        if let v = spvVIN, var info = supabaseService.odoByVIN[v] {
                            info.privateValue = price
                            supabaseService.setOdoInfo(info, forVIN: v)
                            VINFailureTracker.shared.clearFailures(vin: v)
                            Task {
                                await supabaseService.saveQuickDataCacheToSupabase(forVIN: v)
                                await supabaseService.incrementQuota(vin: v)
                            }
                            lastProcessedVIN = v
                        }
                        lastProcessingVIN = nil
                        mileageVIN = nil
                        spvVIN = nil
                        spvOdo = nil
                        extractionState = .idle
                    }
                }
                .frame(width: 0, height: 0)
                .zIndex(3)
                .allowsHitTesting(false)
            }

            if (extractionState == .fetchingOdometer || extractionState == .waitingForCaptcha),
               let mileageURL = URL(string: "https://www.mytxcar.org/TXCar_Net/SecurityCheck.aspx") {
                MileageWebView(
                    url: mileageURL,
                    isActive: true,
                    vin: mileageVIN ?? "",
                    cancelToken: extractionCancelToken,
                    forceStartToken: mileageForceStartToken,
                    onWaitingForCaptcha: {
                        DispatchQueue.main.async { extractionState = .waitingForCaptcha }
                    },
                    onFetchingOdometer: {
                        DispatchQueue.main.async { extractionState = .fetchingOdometer }
                    },
                    onError: { message in
                        failExtraction(message)
                    },
                    onExtract: { odo, date, realModel in
                        DispatchQueue.main.async {
                            if let v = mileageVIN, !v.isEmpty {
                                var info = supabaseService.odoByVIN[v] ?? OdoInfo(odometer: "", testDate: "", privateValue: nil)
                                info.odometer = odo
                                info.testDate = date.dateOnly
                                info.realModel = realModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? realModel?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                                supabaseService.setOdoInfo(info, forVIN: v)
                                spvVIN = v
                                spvOdo = odo
                                extractionState = .fetchingPrice
                                startWatchdogTimer(for: .fetchingPrice, token: extractionCancelToken)
                            }
                        }
                    }
                )
                .frame(height: extractionState == .waitingForCaptcha ? 500 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
                .padding(.horizontal, 14)
                .opacity(extractionState == .waitingForCaptcha ? 1 : 0)
                .zIndex(4)
                .allowsHitTesting(extractionState == .waitingForCaptcha)
            }
        }
        .animation(.snappy, value: extractionState)
        // Alert for favorite confirmation
        .alert("Add to Favorites", isPresented: $showFavoriteConfirm) {
            Button("Cancel", role: .cancel) {
                pendingFavoriteKey = nil
            }
            Button("Add") {
                if let key = pendingFavoriteKey {
                    supabaseService.addFavoriteLocally(key)
                    if let entry = pendingFavoriteEntry { supabaseService.syncUpsertFavorite(entry: entry) } else { supabaseService.syncAddFavorite(key) }
                    pendingFavoriteKey = nil
                    pendingFavoriteEntry = nil
                    hapticSuccess()
                }
            }
        } message: {
            Text("\(pendingFavoriteLabel)\n\nThis vehicle will be moved to Favorites.")
        }
        // Alert for calendar confirmation
        .alert("Agregar al calendario", isPresented: $showCalendarConfirm) {
            Button("Cancelar", role: .cancel) {
                pendingCalendarEntry = nil
            }
            Button("Agregar") {
                if let e = pendingCalendarEntry {
                    addToCalendar(entry: e)
                    pendingCalendarEntry = nil
                    hapticSuccess()
                }
            }
        } message: {
            Text(pendingCalendarLabel)
        }
        .alert("Extraction Error", isPresented: Binding(get: {
            extractionError != nil
        }, set: { newValue in
            if !newValue { extractionError = nil }
        })) {
            Button("OK", role: .cancel) {
                extractionError = nil
            }
        } message: {
            Text(extractionError ?? "")
        }
        .alert(isQuotaExceededAlert ? "Daily Limit Reached" : "Extraction Failed", isPresented: $showExtractionErrorAlert) {
            Button("Cancel", role: .cancel) {
                extractionErrorMessage = nil
                isQuotaExceededAlert = false
            }
            if isQuotaExceededAlert {
                Button("Upgrade Now") {
                    extractionErrorMessage = nil
                    isQuotaExceededAlert = false
                    showPaywall = true
                }
            }
        } message: {
            Text(extractionErrorMessage ?? "An unknown error occurred.")
        }
        // Web VIN confirmation
        .confirmationDialog("Open stat.vin", isPresented: $showWebConfirm, titleVisibility: .visible) {
            Button("Open Report") {
                if let vin = webVIN, let url = URL(string: "https://stat.vin/cars/\(vin)") {
                    if openWebInSafari {
                        UIApplication.shared.open(url)
                    } else {
                        statVinURL = url
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to view the report for this VIN?")
        }
        .sheet(isPresented: Binding(get: { statVinURL != nil }, set: { if !$0 { statVinURL = nil } })) {
            if let url = statVinURL {
                SafariView(url: url).ignoresSafeArea()
            }
        }
        .alert("Navigate", isPresented: $showMapConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Navigate") {
                let q = pendingMapAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pendingMapAddress
                if let url = URL(string: "http://maps.apple.com/?q=\(q)") {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            if pendingMapTime.isEmpty {
                Text("Would you like to navigate to \(pendingMapAddress)?")
            } else {
                Text("Would you like to navigate to \(pendingMapAddress) @ \(pendingMapTime)?")
            }
        }
        .alert("Data Information", isPresented: $showQuickDataInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            let isUnlimited = currentServerDailyLimit == Int.max
            let limit = currentServerDailyLimit
            let limitStr = isUnlimited ? "unlimited" : "\(limit)"
            Text("• Mileage: Last recorded odometer during state inspection.\n• Value: Estimated DMV Private Party Value.\n\nUSAGE LIMITS:\nTo ensure system stability, you are limited to \(limitStr) successful data extractions per day, and a maximum of 3 successful extractions per specific vehicle. Failed attempts do not count against your limit.\n\nNOTE: This is historical data from third-party public records. We do not guarantee its accuracy.")
        }
        .alert("Carfax Report", isPresented: $showCarfaxTeaser) {
            Button("Cancel", role: .cancel) { }
            Button("View Plans") {
                showPaywall = true
            }
        } message: {
            Text("Carfax reports are available exclusively for Platinum Plans. Upgrade your account to unlock this feature.")
        }
        .alert("Carfax Report", isPresented: $showCarfaxUpsellDialog) {
            let stdProduct  = storeManager.consumables.first(where: { $0.id == "com.kbuck.carfax.standard" })
            let platProduct = storeManager.consumables.first(where: { $0.id == "com.kbuck.carfax.platinum" })
            let stdPrice    = stdProduct?.displayPrice  ?? "$15.99"
            let platPrice   = platProduct?.displayPrice ?? "$10.99"
            if isPlatinumRateEligible {
                Button("Buy 1 Report for \(platPrice)") {
                    Task {
                        if let product = platProduct {
                            _ = try? await storeManager.purchase(product)
                        }
                    }
                }
            } else {
                Button("Buy 1 Report for \(stdPrice)") {
                    Task {
                        if let product = stdProduct {
                            _ = try? await storeManager.purchase(product)
                        }
                    }
                }
                Button("Upgrade to Platinum (Reports for \(platPrice))") {
                    showPaywall = true
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(isPlatinumRateEligible
                 ? "Get an instant vehicle history report at your discounted Platinum rate."
                 : "Get an instant vehicle history report.")
        }
        .alert("Legal Disclaimer", isPresented: $showLegalDisclaimer) {
            Button("Cancel", role: .cancel) {
                pendingExtractionEntry = nil
            }
            Button("Accept & Fetch") {
                if let e = pendingExtractionEntry {
                    let sanitizedVIN = normalizeVIN(e.vin)
                    Task {
                        supabaseService.syncLogLegalAgreement(vin: sanitizedVIN)

                        if await supabaseService.loadQuickDataCacheFromSupabase(forVIN: sanitizedVIN) {
                            await supabaseService.incrementQuota(vin: sanitizedVIN)
                            await MainActor.run {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                VINFailureTracker.shared.clearFailures(vin: sanitizedVIN)
                                pendingExtractionEntry = nil
                            }
                            return
                        }

                        await MainActor.run {
                            UIPasteboard.general.string = sanitizedVIN
                            extractionError = nil
                            extractionCancelToken = UUID()
                            mileageForceStartToken = UUID()
                            mileageVIN = sanitizedVIN
                            spvVIN = nil
                            spvOdo = nil
                            lastProcessingVIN = sanitizedVIN
                            extractionState = .fetchingOdometer
                            startWatchdogTimer(for: .fetchingOdometer, token: extractionCancelToken)
                            pendingExtractionEntry = nil
                        }
                    }
                }
            }
        } message: {
            if let e = pendingExtractionEntry {
                Text("You are about to fetch the last recorded inspection date, reported mileage, and an estimated DMV Private Value for the \(normalizedYear(e.year)) \(e.make) \(e.model).\n\nDISCLAIMER:\nThis data is retrieved from public third-party sources and is provided 'AS IS' strictly for informational purposes.\n\nNO WARRANTIES:\nWe make no warranties regarding its accuracy, completeness, or current validity.\n\nLIABILITY:\nBy proceeding, you agree that we accept no liability for any decisions made based on this data.")
            }
        }
    }

    private func autoFetch(force: Bool = false) {
        guard !didAutoFetch || force else { return }
        didAutoFetch = true
        fetch()
    }

    private func iconFor(_ key: SortKey) -> String {
        if key != sortKey { return "arrow.up.arrow.down" }
        return sortAscending ? "arrow.up" : "arrow.down"
    }

    private func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    private func sortedEntries() -> [HPDEntry] {
        if sortKey == .priced {
            // Custom: handle ascending/descending inside comparator and keep unpriced last
            return entries.sorted { compareByPrice($0, $1, ascending: sortAscending) }
        }
        let sorted = entries.sorted { a, b in
            switch sortKey {
            case .date:
                return a.dateScheduled.localizedCompare(b.dateScheduled) == .orderedAscending
            case .year:
                return normalizedYear(a.year).localizedCompare(normalizedYear(b.year)) == .orderedAscending
            case .make:
                return a.make.localizedCompare(b.make) == .orderedAscending
            case .model:
                return a.model.localizedCompare(b.model) == .orderedAscending
            case .favorites:
                let aFav = supabaseService.favorites.contains(normalizeVIN(a.vin))
                let bFav = supabaseService.favorites.contains(normalizeVIN(b.vin))
                if aFav != bFav { return aFav && !bFav }
                // tie-breaker
                return (a.make + a.model).localizedCompare(b.make + b.model) == .orderedAscending
            case .priced:
                // handled above
                return false
            }
        }
        return sortAscending ? sorted : Array(sorted.reversed())
    }

    private func filteredEntries() -> [HPDEntry] {
        let selectedSortOption = sortOption
        let pricedOnly = showPricedOnly
        // Favorites-only tab: apply search then sort
        if favoritesOnly {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "MM/dd/yyyy"
            let asc = sortAscending

            // 1. Get base valid favorites
            var favs = entries.filter { !isDateInPast($0.dateScheduled) }
                .filter { supabaseService.favorites.contains(normalizeVIN($0.vin)) }
                .filter { !isCardEmpty($0) }

            if !selectedFavoriteLocationFilters.isEmpty {
                favs = favs.filter { entry in
                    selectedFavoriteLocationFilters.contains(favoriteLocationLabel(for: entry))
                }
            }

            let favoriteLocationQuery = favoriteLocationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !favoriteLocationQuery.isEmpty {
                favs = favs.filter { entry in
                    let odoInfo = supabaseService.odoByVIN[entry.vin] ?? supabaseService.odoByVIN[normalizeVIN(entry.vin)]
                    return vehicleMatchesSearch(favoriteLocationQuery, entry: entry, odoInfo: odoInfo)
                }
            }

            // 2. Apply search text
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                favs = favs.filter { e in
                    let odoInfo = supabaseService.odoByVIN[e.vin] ?? supabaseService.odoByVIN[normalizeVIN(e.vin)]
                    return vehicleMatchesSearch(q, entry: e, odoInfo: odoInfo)
                }
            }

            // 3. Sort and return
            return favs.sorted { a, b in
                    switch selectedSortOption {
                    case .date:
                        let da = df.date(from: a.dateScheduled)
                        let db = df.date(from: b.dateScheduled)
                        let naturalAsc: Bool
                        switch (da, db) {
                        case let (x?, y?): naturalAsc = x < y
                        default: naturalAsc = a.dateScheduled < b.dateScheduled
                        }
                        return asc ? naturalAsc : !naturalAsc
                    case .year:
                        let ay = parseYearInt(a.year) ?? 0
                        let by = parseYearInt(b.year) ?? 0
                        return asc ? ay < by : ay > by
                    case .make:
                        let cmp = a.make.localizedCompare(b.make)
                        return asc ? cmp == .orderedAscending : cmp == .orderedDescending
                    case .model:
                        let cmp = a.model.localizedCompare(b.model)
                        return asc ? cmp == .orderedAscending : cmp == .orderedDescending
                    case .priced:
                        return compareByPrice(a, b, ascending: asc)
                    case .favorites:
                        let cmp = (a.make + a.model).localizedCompare(b.make + b.model)
                        return cmp == .orderedAscending
                    }
                }
        }

        // Main tab excludes favorites to enforce strict separation —
        // bypassed when a deep-link filter is active so the full lot inventory is visible.
        var entriesToFilter = entries.filter { !isDateInPast($0.dateScheduled) }
        if externalLocationFilter == nil {
            entriesToFilter = entriesToFilter.filter { !supabaseService.favorites.contains(normalizeVIN($0.vin)) }
        }

        // External cross-tab filter injected from Dashboard deep-link (streetNumberKey tolerates address suffix variants)
        if let ext = externalLocationFilter {
            entriesToFilter = entriesToFilter.filter { $0.lotAddress.streetNumberKey == ext.streetNumberKey }
        }

        // a) Search bar
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterSearch: [HPDEntry]
        if q.isEmpty {
            afterSearch = entriesToFilter
        } else {
            afterSearch = entriesToFilter.filter { e in
                let odoInfo = supabaseService.odoByVIN[e.vin] ?? supabaseService.odoByVIN[normalizeVIN(e.vin)]
                return vehicleMatchesSearch(q, entry: e, odoInfo: odoInfo)
            }
        }

        // b) Make / Model / Year / Price filters
        let selectedMaxPrice = parsePrice(maxPrice)
        let afterFieldFilters = afterSearch.filter { entry in
            if selectedMake != "All",
               entry.make.localizedCaseInsensitiveCompare(selectedMake) != .orderedSame {
                return false
            }
            if selectedModel != "All",
               entry.model.localizedCaseInsensitiveCompare(selectedModel) != .orderedSame {
                return false
            }
            if let selectedYear,
               parseYearInt(entry.year) != selectedYear {
                return false
            }
            if let selectedMaxPrice {
                guard let price = priceValue(for: entry.vin) else { return false }
                if price > selectedMaxPrice { return false }
            }
            return true
        }

        // c) Location filter — empty set = all locations; match by street-number key to tolerate suffix variants
        let afterAddress: [HPDEntry]
        let locationFilters = selectedLocationFilters
        if locationFilters.isEmpty {
            afterAddress = afterFieldFilters
        } else {
            afterAddress = afterFieldFilters.filter { entry in
                locationFilters.contains(where: { $0.streetNumberKey == entry.lotAddress.streetNumberKey })
            }
        }

        // d) Toolbar mode filter
        let afterFilter: [HPDEntry]
        if pricedOnly {
            afterFilter = afterAddress.filter { supabaseService.odoByVIN[normalizeVIN($0.vin)]?.privateValue != nil }
        } else {
            afterFilter = afterAddress
        }

        // Drop visually empty cards then sort by selected sortKey, direction driven by sortAscending
        let clean = afterFilter.filter { !isCardEmpty($0) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MM/dd/yyyy"
        let asc = sortAscending
        return clean.sorted { a, b in
            // Returns the "natural ascending" result; we flip if asc == false where applicable.
            switch selectedSortOption {
            case .date:
                let da = df.date(from: a.dateScheduled)
                let db = df.date(from: b.dateScheduled)
                let naturalAsc: Bool
                switch (da, db) {
                case let (x?, y?): naturalAsc = x < y
                default: naturalAsc = a.dateScheduled < b.dateScheduled
                }
                return asc ? naturalAsc : !naturalAsc
            case .year:
                let ay = parseYearInt(a.year) ?? 0
                let by = parseYearInt(b.year) ?? 0
                return asc ? ay < by : ay > by
            case .make:
                let cmp = a.make.localizedCompare(b.make)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .model:
                let cmp = a.model.localizedCompare(b.model)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .priced:
                return compareByPrice(a, b, ascending: asc)
            case .favorites:
                let aFav = supabaseService.favorites.contains(normalizeVIN(a.vin))
                let bFav = supabaseService.favorites.contains(normalizeVIN(b.vin))
                if aFav != bFav { return asc ? !aFav : aFav }
                let cmp = (a.make + a.model).localizedCompare(b.make + b.model)
                return cmp == .orderedAscending
            }
        }
    }

    private func recomputeFilteredEntries() {
        let filtered = filteredEntries()
        cachedFilteredEntries = filtered
        cachedFilteredCount = filtered.count
        cachedGroupedByDate = groupedByDate(from: filtered)

        if favoritesOnly {
            let baseFavorites = entries.filter { !isDateInPast($0.dateScheduled) }
                .filter { supabaseService.favorites.contains(normalizeVIN($0.vin)) }
                .filter { !isCardEmpty($0) }
            rebuildFavoriteLocationOptions(from: baseFavorites)

            let validAddresses = Set(favoriteLocationOptions.map(\.address))
            let validSelection = selectedFavoriteLocationFilters.intersection(validAddresses)
            if validSelection != selectedFavoriteLocationFilters {
                selectedFavoriteLocationFilters = validSelection
            }
        } else {
            favoriteLocationOptions = []
            if !selectedFavoriteLocationFilters.isEmpty {
                selectedFavoriteLocationFilters = []
            }
        }
    }

    private func groupedByDate(from base: [HPDEntry]) -> [(String, [HPDEntry])] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MM/dd/yyyy"
        let groups = Dictionary(grouping: base, by: { $0.dateScheduled })

        // Schwartzian transform: parse each key string exactly once, then sort by the cached Date
        let parsedKeys: [(key: String, date: Date?)] = groups.keys.map { k in (k, df.date(from: k)) }
        var sortedKeys: [String]
        if sortKey == .date {
            sortedKeys = parsedKeys
                .sorted { a, b in
                    switch (a.date, b.date) {
                    case let (da?, db?): return sortAscending ? da < db : da > db
                    default:            return sortAscending ? a.key < b.key : a.key > b.key
                    }
                }
                .map(\.key)
        } else {
            // Non-date sorts: sections always ascend by date so context is clear
            sortedKeys = parsedKeys
                .sorted { a, b in
                    switch (a.date, b.date) {
                    case let (da?, db?): return da < db
                    default:            return a.key < b.key
                    }
                }
                .map(\.key)
        }
        return sortedKeys.map { key in
            let items = groups[key] ?? []
            let itemsSorted: [HPDEntry]
            switch sortKey {
            case .date:
                itemsSorted = items.sorted { $0.make + $0.model < $1.make + $1.model }
            case .year:
                itemsSorted = items.sorted { (parseYearInt($0.year) ?? 0) < (parseYearInt($1.year) ?? 0) }
            case .make:
                itemsSorted = items.sorted { $0.make.localizedCompare($1.make) == .orderedAscending }
            case .model:
                itemsSorted = items.sorted { $0.model.localizedCompare($1.model) == .orderedAscending }
            case .priced:
                // Custom: compute final order here respecting ascending/descending and keeping unpriced last
                itemsSorted = items.sorted { compareByPrice($0, $1, ascending: sortAscending) }
            case .favorites:
                itemsSorted = items.sorted {
                    let aFav = supabaseService.favorites.contains(normalizeVIN($0.vin))
                    let bFav = supabaseService.favorites.contains(normalizeVIN($1.vin))
                    if aFav != bFav { return aFav && !bFav }
                    return ($0.make + $0.model).localizedCompare($1.make + $1.model) == .orderedAscending
                }
            }
            // Only reverse for non-priced sorts; priced already applied direction
            let finalItems = (sortKey == .priced) ? itemsSorted : (sortAscending ? itemsSorted : Array(itemsSorted.reversed()))
            return (key, finalItems)
        }
    }

    // MARK: - Favorites: Date-primary grouping (chronological dates → alphabetical locations → odometer desc)

    private func compactAuctionTime(for entry: HPDEntry) -> String? {
        guard let rawTime = entry.time?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTime.isEmpty else { return nil }
        guard let auctionDate = parseAuctionDate(entry.dateScheduled, timeStr: rawTime) else { return nil }
        return auctionDate.compactAuctionTime()
    }

    private var groupedFavorites: [(date: String, locations: [(title: String, address: String, vehicles: [HPDEntry])])] {
        let byDate = Dictionary(grouping: cachedFilteredEntries, by: { $0.dateScheduled })

        return byDate
            .map { dateKey, dateVehicles in
                let byLocation = Dictionary(grouping: dateVehicles) { e -> String in
                    let addr = sanitizedAddressForMaps(e.lotAddress)
                    return addr.isEmpty ? e.lotName.trimmingCharacters(in: .whitespacesAndNewlines) : addr
                }

                let sortedLocations = byLocation
                    .map { address, vehicles in
                        let titleCounts = Dictionary(grouping: vehicles, by: favoriteLocationTitle(for:))
                            .mapValues(\.count)
                        let bestTitle = titleCounts.max { lhs, rhs in
                            if lhs.value == rhs.value {
                                return lhs.key.count > rhs.key.count
                            }
                            return lhs.value < rhs.value
                        }?.key ?? address
                        let sortedVehicles = vehicles.sorted { a, b in
                            let aInfo = supabaseService.odoByVIN[a.vin] ?? supabaseService.odoByVIN[normalizeVIN(a.vin)]
                            let bInfo = supabaseService.odoByVIN[b.vin] ?? supabaseService.odoByVIN[normalizeVIN(b.vin)]
                            let aOdo = Int(aInfo?.odometer ?? "0") ?? 0
                            let bOdo = Int(bInfo?.odometer ?? "0") ?? 0
                            return aOdo > bOdo
                        }
                        return (title: bestTitle, address: address, vehicles: sortedVehicles)
                    }
                    .sorted {
                        if $0.title == $1.title {
                            return $0.address < $1.address
                        }
                        return $0.title < $1.title
                    }

                return (date: dateKey, locations: sortedLocations)
            }
            .sorted { a, b in
                switch (Kbuck.parseAuctionDate(from: a.date), Kbuck.parseAuctionDate(from: b.date)) {
                case let (da?, db?): return da < db
                default: return a.date < b.date
                }
            }
    }

    // MARK: - Date helpers for coloring section headers
    private func compareDateToToday(_ dateStr: String) -> Int? {
        // Returns: -1 (past), 0 (today), 1 (future)
        guard let d = Kbuck.parseAuctionDate(from: dateStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dd = cal.startOfDay(for: d)
        if dd == today { return 0 }
        return dd < today ? -1 : 1
    }

    private func colorForDate(_ dateStr: String) -> Color {
        switch compareDateToToday(dateStr) {
        case .some(-1): return Color.red.opacity(0.8)   // past → red (not too bright)
        case .some(0):  return Color.blue.opacity(0.8)  // today → blue (not too bright)
        default:        return .primary                  // future/unknown → default
        }
    }

    @ViewBuilder private func sectionHeader(for date: String, displayDate: String, count: Int, collapsed: Bool, onToggle: @escaping () -> Void) -> some View {
        Button(action: { hapticImpact(.light); onToggle() }) {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .foregroundStyle(.secondary)
                Image(systemName: "calendar")
                Text(displayDate)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorForDate(date))
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func card(for e: HPDEntry, showAddress: Bool = true) -> some View {
        VehicleCardView(entry: e, showAddress: showAddress, showQuickInventory: false)
    }

    private var extractionOverlayMessage: String {
        switch extractionState {
        case .idle:
            return ""
        case .fetchingOdometer:
            return "Fetching odometer data..."
        case .waitingForCaptcha:
            return "Please solve the CAPTCHA..."
        case .fetchingPrice:
            return "Fetching private value..."
        }
    }

    // Helper: returns true if a flow (ODO→SPV) is in progress for any card
    private var flowInProgress: Bool { extractionState != .idle }

    private func cancelExtraction() {
        extractionCancelToken = UUID()
        extractionState = .idle
        lastProcessingVIN = nil
        mileageVIN = nil
        spvVIN = nil
        spvOdo = nil
    }

    private func failExtraction(_ message: String) {
        if let vin = lastProcessingVIN, !vin.isEmpty {
            VINFailureTracker.shared.recordFailure(vin: vin)
        }
        extractionError = message
        cancelExtraction()
    }

    private func startWatchdogTimer(for state: ExtractionState, token: UUID) {
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                if self.extractionCancelToken == token && self.extractionState == state {
                    if let vin = self.lastProcessingVIN, !vin.isEmpty {
                        VINFailureTracker.shared.recordFailure(vin: vin)
                    }
                    self.extractionState = .idle
                    self.pendingExtractionEntry = nil
                    if state == .fetchingOdometer {
                        self.extractionErrorMessage = "Odometer Fetch Failed: No recent mileage information was found from the last inspection, or the state server is currently unavailable."
                    } else if state == .fetchingPrice {
                        self.extractionErrorMessage = "Value Fetch Failed: The DMV valuation server timed out. The vehicle might not have a calculable private party value at this time."
                    } else {
                        self.extractionErrorMessage = "Extraction timed out after 8 seconds. Please check your connection and try again."
                    }
                    self.showExtractionErrorAlert = true
                }
            }
        }
    }

    private func fetch() {
        let trimmed: String
        if manualURLModeEnabled, !hpdManualURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trimmed = hpdManualURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            trimmed = defaultURLString
        }

        let isDefaultHPDSource = trimmed == defaultURLString
        let lastDate = Date(timeIntervalSince1970: lastHPDSyncDate)
        let hasLocalData = !entries.isEmpty || !hpdCachedEntriesData.isEmpty
        if isDefaultHPDSource && Calendar.current.isDateInToday(lastDate) && hasLocalData {
            if entries.isEmpty && !hpdCachedEntriesData.isEmpty {
                entries = decodeCachedEntries(hpdCachedEntriesData).filter { !isDateInPast($0.dateScheduled) }
            }
            print("✅ HPD: Data already synced today. Using local cache.")
            return
        }

        guard let url = URL(string: trimmed) else {
            errorMessage = "URL inválida"
            manualURLModeEnabled = true
            hpdHadLastError = true
            return
        }
        // No limpiamos la lista para que no "desaparezca" el contenido mientras carga
        errorMessage = nil
        let previousEntries = entries
        isLoading = true

        Task {
            for attempt in 1...2 { // 1 reintento
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 60 // Aumentar timeout
                    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

                    let (data, response) = try await URLSession.shared.data(for: request)
                    let (decoded, _) = decodeResponseData(data, response: response)
                    let parsed = HPDParser.parse(decoded)
                    let validEntries = parsed.filter { !isDateInPast($0.dateScheduled) }
                    let activeVINs = Set(validEntries.map { normalizeVIN($0.vin) })
                    await MainActor.run {
                        supabaseService.syncCleanUpExpiredFavorites(activeVINs: activeVINs)
                    }

                    if !parsed.isEmpty {
                        await MainActor.run {
                            self.entries = validEntries
                            self.hpdCachedEntriesData = encodeEntries(validEntries)
                            self.hpdCachedURL = trimmed
                            self.hpdLastFetchTS = Date().timeIntervalSince1970
                            self.lastHPDSyncDate = Date().timeIntervalSince1970
                            self.errorMessage = nil
                            self.hpdHadLastError = false
                            self.isLoading = false
                        }
                        // [NHTSA-LOCAL DISABLED] Vehicle names now come from global_vin_cache_kbuck
                        // via the server-side hpd-pipeline Edge Function. No client-side NHTSA calls needed.
                        // let scrapedVehicles = validEntries.map { entry in
                        //     NHTSAScrapedVehicle(vin: entry.vin)
                        // }
                        // Task(priority: .background) {
                        //     let pipeline = NHTSADecoderPipeline()
                        //     await pipeline.decodeAndCache(scrapedVehicles)
                        // }
                        return
                    } else {
                        if attempt == 1 {
                            // Esperar un momento y reintentar por si el servidor tardó
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            continue
                        } else {
                            await MainActor.run {
                                // Mantener los datos anteriores y mostrar aviso
                                self.entries = previousEntries
                                let lower = decoded.lowercased()
                                let trCount = (try? NSRegularExpression(pattern: "<tr", options: [.caseInsensitive]).numberOfMatches(in: decoded, options: [], range: NSRange(location: 0, length: (decoded as NSString).length))) ?? 0
                                let tdCount = (try? NSRegularExpression(pattern: "<t[dh]", options: [.caseInsensitive]).numberOfMatches(in: decoded, options: [], range: NSRange(location: 0, length: (decoded as NSString).length))) ?? 0
                                let hasTable = lower.contains("<table")
                                let snippet = decoded.prefix(200)
                                self.errorMessage = "No se encontraron registros en la página. Detalles: hasTable=\(hasTable) tr=\(trCount) td/th=\(tdCount). Primeros 200 chars: \(snippet)"
                                self.hpdHadLastError = true
                                self.isLoading = false
                                self.manualURLModeEnabled = true
                            }
                            return
                        }
                    }
                } catch {
                    if attempt == 1 {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        continue
                    } else {
                        await MainActor.run {
                            // Mantener los datos anteriores y mostrar error
                            self.entries = previousEntries
                            let msg = error.localizedDescription
                            self.errorMessage = msg
                            self.isLoading = false
                            self.hpdHadLastError = true
                            // Ensure overlay is cleared on failure
                            self.lastProcessingVIN = nil
                            self.extractionState = .idle
                            self.manualURLModeEnabled = true
                        }
                        return
                    }
                }
            }
        }
    }
}
