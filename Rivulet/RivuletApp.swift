//
//  RivuletApp.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Sentry

// MARK: - App Delegate

class RivuletAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Task {
            await DeepLinkHandler.shared.handle(url: url)
        }
        return true
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void) -> Bool {
        guard let ratingKey = userActivity.userInfo?["ratingKey"] as? String,
              !ratingKey.isEmpty else { return false }

        switch userActivity.activityType {
        case "com.rivulet.viewMedia":
            Task {
                await DeepLinkHandler.shared.handle(
                    url: URL(string: "rivulet://detail?ratingKey=\(ratingKey)")!
                )
            }
            return true
        case "com.rivulet.playMedia":
            Task {
                await DeepLinkHandler.shared.handle(
                    url: URL(string: "rivulet://play?ratingKey=\(ratingKey)")!
                )
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - App

@main
struct RivuletApp: App {
    @UIApplicationDelegateAdaptor(RivuletAppDelegate.self) var appDelegate

    init() {
        StartupTimer.arm()
        StartupTimer.mark("RivuletApp.init")
        #if !DEBUG
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.debug = false
            options.tracesSampleRate = 1.0
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = true
            options.enableSwizzling = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2

            options.beforeSend = { event in
                // Drop cancelled URL request errors — these are normal when navigating away
                if let exceptions = event.exceptions,
                   exceptions.contains(where: { $0.value?.contains("Code=-999") == true || $0.value?.contains("cancelled") == true }) {
                    return nil
                }
                if let message = event.message?.formatted,
                   message.contains("Code=-999") || (message.contains("NSURLErrorDomain") && message.contains("cancelled")) {
                    return nil
                }
                return event
            }
        }
        #endif

        // NowPlayingService disabled — AVPlayerViewController handles Now Playing natively.
        // NowPlayingService.shared.initialize()

        // PERF SPIKE: emit AppLaunch event + start RSS sampler + frame
        // hitch sampler so the perf-compare driver script can correlate
        // launch time, memory, and scroll smoothness across SwiftUI vs
        // UIKit home runs. Removable after the comparison is concluded.
        Task { @MainActor in
            // Honor a launch-arg override for the home impl preference so
            // the perf-compare driver can run trials without flipping the
            // Settings toggle interactively. Format:
            //   xcrun devicectl device process launch ... -- --home-impl=uikit
            let args = CommandLine.arguments
            if let arg = args.first(where: { $0.hasPrefix("--home-impl=") }) {
                let value = String(arg.dropFirst("--home-impl=".count))
                if HomeImpl(rawValue: value) != nil {
                    UserDefaults.standard.set(value, forKey: HomeImplPreference.storageKey)
                }
            }

            PerfLog.resetFileLog()
            Perf.event(.appLaunch, message: "init")
            PerfLog.startRSSSampler(interval: 1.0)
            FrameHitchSampler.shared.start()
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(MediaProviderRegistry.shared)
                .environment(MusicProviderRegistry.shared)
                .environment(MetadataSourceRegistry.shared)
        }
        .modelContainer(sharedModelContainer)
    }
}
