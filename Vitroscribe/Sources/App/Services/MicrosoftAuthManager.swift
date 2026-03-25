import Foundation
import AuthenticationServices
import CryptoKit
import os.log

class MicrosoftAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MicrosoftAuthManager()
    
    private let clientId = "a5529ce5-c494-4775-b5e5-3b7700e47677"
    private let clientSecret = "_IT8Q~rPTsz56i23EEup0aLdiDnV3V3Y68xLdaVd"
    private let redirectURI = "msauth.com.nikkipunjabi.Vitroscribe://auth"
    private let tenant = "common"
    
    @Published var isConnected: Bool = false
    @Published var connectedEmail: String = ""
    @Published var lastError: String = ""
    
    private var accessToken: String?
    private var lastTokenRefresh: Date?
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "MicrosoftRefreshToken") }
        set { UserDefaults.standard.set(newValue, forKey: "MicrosoftRefreshToken") }
    }
    
    override private init() {
        super.init()
        checkExistingConnection()
    }
    
    func checkExistingConnection() {
        if let token = refreshToken, !token.isEmpty {
            refreshAccessToken(token: token) { success in
                DispatchQueue.main.async {
                    self.isConnected = success
                    if success {
                        self.fetchUserInfo()
                    }
                }
            }
        }
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApplication.shared.windows.first ?? NSWindow()
    }
    
    func connect() {
        let codeVerifier = generateRandomString(length: 64)
        let codeChallenge = generateCodeChallenge(verifier: codeVerifier)
        
        let scope = "User.Read Calendars.Read offline_access"
        let encodedScope = scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedRedirect = redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        let authURLString = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize?client_id=\(clientId)&response_type=code&redirect_uri=\(encodedRedirect)&response_mode=query&scope=\(encodedScope)&code_challenge=\(codeChallenge)&code_challenge_method=S256"
        
        guard let authURL = URL(string: authURLString) else { 
            Logger.shared.log("Microsoft: Invalid Auth URL")
            return 
        }
        
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "msauth.com.nikkipunjabi.Vitroscribe") { callbackURL, error in
            if let error = error {
                Logger.shared.log("Microsoft Auth error: \(error.localizedDescription)")
                return
            }
            
            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                return
            }
            
            self.exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
        }
        
        session.presentationContextProvider = self
        session.start()
    }
    
    func disconnect() {
        refreshToken = nil
        accessToken = nil
        isConnected = false
        connectedEmail = ""
        Logger.shared.log("Microsoft Account disconnected.")
    }
    
    private func exchangeCodeForToken(code: String, codeVerifier: String) {
        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        request.httpBody = components.query?.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { self.lastError = "Exchange Network Error: \(error.localizedDescription)" }
                return
            }
            
            guard let data = data else { 
                DispatchQueue.main.async { self.lastError = "No data received from Microsoft" }
                return 
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errorMsg = json["error"] as? String {
                        let desc = json["error_description"] as? String ?? "No description"
                        DispatchQueue.main.async { self.lastError = "Microsoft Error: \(errorMsg) - \(desc)" }
                        return
                    }
                    
                    self.accessToken = json["access_token"] as? String
                    self.lastTokenRefresh = Date()
                    if let refresh = json["refresh_token"] as? String {
                        self.refreshToken = refresh
                    }
                    
                    DispatchQueue.main.async {
                        self.lastError = ""
                        self.isConnected = true
                        self.fetchUserInfo()
                    }
                }
            } catch {
                DispatchQueue.main.async { self.lastError = "JSON Parse Error: \(error.localizedDescription)" }
            }
        }.resume()
    }
    
    private func refreshAccessToken(token: String, completion: @escaping (Bool) -> Void) {
        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "refresh_token", value: token),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        request.httpBody = components.query?.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(false)
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccess = json["access_token"] as? String {
                    self.accessToken = newAccess
                    self.lastTokenRefresh = Date()
                    if let refresh = json["refresh_token"] as? String {
                        self.refreshToken = refresh
                    }
                    completion(true)
                } else {
                    completion(false)
                }
            } catch {
                completion(false)
            }
        }.resume()
    }
    
    private func fetchUserInfo() {
        guard let token = accessToken else { return }
        let url = URL(string: "https://graph.microsoft.com/v1.0/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.log("Microsoft: fetchUserInfo error: \(error.localizedDescription)")
                return
            }
            
            guard let data = data else { return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let email = (json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? (json["displayName"] as? String) ?? ""
                    
                    DispatchQueue.main.async {
                        self.connectedEmail = email
                        Logger.shared.log("Connected to Microsoft as \(email)")
                        MicrosoftCalendarService.shared.fetchEvents()
                    }
                }
            } catch {
                Logger.shared.log("Microsoft: Failed to parse user info: \(error.localizedDescription)")
            }
        }.resume()
    }
    
    func getValidAccessToken(completion: @escaping (String?) -> Void) {
        if let token = accessToken, let lastRefresh = lastTokenRefresh {
            // If token is less than 50 minutes old, use it
            if Date().timeIntervalSince(lastRefresh) < 3000 {
                completion(token)
                return
            }
        }
        
        if let refresh = refreshToken {
            Logger.shared.log("Microsoft: Refreshing access token...")
            refreshAccessToken(token: refresh) { success in
                completion(success ? self.accessToken : nil)
            }
        } else {
            completion(nil)
        }
    }
    
    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private func generateCodeChallenge(verifier: String) -> String {
        let data = verifier.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        let base64URL = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return base64URL
    }
}
