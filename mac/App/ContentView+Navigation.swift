import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Dispatch
import SwiftUI

// Navigation: moved out of ContentView.swift without change.
extension ContentView {
  var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .frame(width: 24, height: 24)
        Text("织机")
          .font(.system(size: 16, weight: .semibold))
      }
      .padding(.horizontal, 8)
      .padding(.top, 44)
      .padding(.bottom, 16)

      // Only for a capture that runs long enough to walk away from. A
      // dictation lasts seconds and is aimed at another app, so a row here
      // saying it is happening is a thing nobody is looking at.
      if let activeSection = activeCaptureSection, activeSection != .home {
        Button {
          navigate(to: activeSection)
        } label: {
          HStack(spacing: 9) {
            Circle()
              .fill(activeCaptureSidebarTint)
              .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
              Text(activeCaptureSidebarTitle)
                .font(.system(size: 12.5, weight: .semibold))
              Text(activeCaptureSidebarDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(activeCaptureSidebarTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        .padding(.bottom, 10)
        .accessibilityIdentifier("bestASR.activeCapture.return")
      }

      ForEach(BestASRSection.primaryCases) { item in
        SidebarNavigationButton(
          title: item.title, symbol: item.symbol, selected: selection == item
        ) {
          if item == .history { model.history.detailPresented = false }
          navigate(to: item)
          if item == .history { model.refreshHistoryIfStale() }
        }
        .accessibilityIdentifier("bestASR.sidebar.\(item.rawValue)")
        .modifier(SectionNavigationShortcut(shortcut: item.navigationShortcut))
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("扩展功能")
          Spacer()
          Text("完善中").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 24)
        .padding(.bottom, 6)

        ForEach(BestASRSection.secondaryCases) { item in
          SidebarNavigationButton(
            title: item.title, symbol: item.symbol, selected: selection == item
          ) {
            navigate(to: item)
            if item == .people { model.refreshPeople() }
            if item == .events { model.refreshEvents() }
          }
          .accessibilityIdentifier("bestASR.sidebar.\(item.rawValue)")
        }
      }

      Spacer(minLength: 16)

      Button {
        openWindow(id: "advanced-settings")
      } label: {
        Label("高级", systemImage: "wrench.and.screwdriver")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .frame(height: 30)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("bestASR.sidebar.advanced")

      SettingsLink {
        HStack(spacing: 10) {
          Image(systemName: "gearshape")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 20)
          Text("设置")
            .font(.system(size: 13.5, weight: .medium))
          Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary.opacity(0.72))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("设置")
      .accessibilityIdentifier("bestASR.openSettings")

      if !model.models.modelRuntimeReady {
        HStack(spacing: 6) {
          Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
          Text("需要完成首次设置")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .accessibilityIdentifier("bestASR.localReadiness")
      } else {
        Spacer().frame(height: 16)
      }
    }
    .padding(.horizontal, 10)
    .frame(width: 206)
  }

  func followRequestedNavigation(_ requested: String?) {
    guard let requested,
      let destination = BestASRSection(rawValue: requested)
    else { return }
    if destination == .history,
      !model.history.searchNavigationQuery.isEmpty
        || model.history.navigationOrigin != nil
    {
      historyWorkspaceTab = .transcript
    }
    navigate(to: destination)
    model.requestedNavigationSectionID = nil
  }

  func navigate(to destination: BestASRSection) {
    if destination != .history {
      model.clearHistoryNavigationOrigin()
    }
    selection = destination
    memoryNavigate(to: destination)
  }
}
