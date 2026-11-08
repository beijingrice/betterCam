//
//  BetterCamWidget.swift
//  betterCam
//
//  Created by Rice on 2026/2/18.
//

import WidgetKit
import SwiftUI

struct BetterCamHomeWidget: Widget {
    let kind: String = "BetterCamHomeWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            BetterCamHomeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("betterCam widget")
        .description("betterCam widget, shutter counts & quick launch.")
        .supportedFamilies([.systemMedium])
    }
}

// 💡 1. 定义数据提供者
struct Provider: TimelineProvider {
    // 占位图（组件加载前显示）
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), totalCount: 0, todayCount: 0, sessionCount: 0, lastSS: "", lastISO: "")
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        completion(Timeline(entries: [currentEntry()], policy: .atEnd))
    }

    private func currentEntry() -> SimpleEntry {
        let prefs = UserDefaults(suiteName: ShutterManager.suiteName)
        return SimpleEntry(
            date: Date(),
            totalCount: prefs?.integer(forKey: ShutterManager.TOTAL_SHUTTER_KEY) ?? 0,
            todayCount: prefs?.integer(forKey: ShutterManager.getTodayKey()) ?? 0,
            sessionCount: prefs?.integer(forKey: "session_count") ?? 0,
            lastSS: prefs?.string(forKey: "last_SS") ?? "AUTO",
            lastISO: prefs?.string(forKey: "last_ISO") ?? "AUTO"
        )
    }
}

// 💡 2. 定义数据模型
struct SimpleEntry: TimelineEntry {
    let date: Date
    let totalCount: Int
    let todayCount: Int
    let sessionCount: Int
    let lastSS: String
    let lastISO: String
}

struct BetterCamHomeWidgetEntryView : View {
    var entry: Provider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "camera.shutter.button.fill")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(Color.yellow)
                .shadow(color: .yellow.opacity(0.5), radius: 3)
                //.foregroundColor(Color.white.opacity(0.6))
            
            // 本次 Session 张数
            HStack(alignment: .lastTextBaseline) {
                Text("\(entry.totalCount - entry.sessionCount) -> \(entry.totalCount)")
                    .foregroundColor(.white)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .lineLimit(1) // 强制单行
                    .minimumScaleFactor(0.5)
                Text("COUNTS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.6))
            }
            
            // 总快门数
            Text("TOTAL \(entry.totalCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color(white: 1.0, opacity: 0.2))
                .foregroundColor(.white)
            if entry.lastSS != "AUTO" && entry.lastISO != "AUTO" {
                Text("\(entry.lastSS)s \(entry.lastISO)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(white: 1.0, opacity: 0.2))
                    .foregroundColor(.white)
            } else {
                Text("FULL AUTO MODE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(white: 1.0, opacity: 0.2))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .containerBackground(for: .widget) {
            Color.black
            
            LinearGradient(
                colors: [
                    .white.opacity(0.15),
                    .clear,
                    .black.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            RadialGradient(
                colors: [.white.opacity(0.5), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 700
            )
        }
    }
}
