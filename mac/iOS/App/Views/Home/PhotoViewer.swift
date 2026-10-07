import MindloomDesign
import SwiftUI
import UIKit

/// The photo viewer (PHONE-SPEC §5.5): black, the photo fitted to the width, × at the top left,
/// 「分享 · 9:20」 centred, and a row of 40 pt thumbnails when there is more than one.
struct PhotoViewer: View {
  @Environment(\.dismiss) private var dismiss
  let row: HomeRow
  @State var index: Int

  init(row: HomeRow, index: Int) {
    self.row = row
    _index = State(initialValue: index)
  }

  var body: some View {
    GeometryReader { proxy in
      let top = proxy.safeAreaInsets.top
      let bottom = proxy.safeAreaInsets.bottom
      ZStack(alignment: .top) {
        Color.black
        if index < row.previews.count, let image = PreviewCache.image(row.previews[index]) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("照片")
        }
        HStack {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
              .background(
                Circle().fill(Color(red: 40 / 255, green: 38 / 255, blue: 35 / 255).opacity(0.5))
              )
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
          Spacer()
          Text(row.item.source.word + " · " + PhoneFormat.time(row.item.createdAt))
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
          Spacer()
          Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, top + 4)
        if row.previews.count > 1 {
          VStack {
            Spacer()
            HStack(spacing: 6) {
              ForEach(Array(row.previews.enumerated()), id: \.offset) { offset, url in
                Button {
                  index = offset
                } label: {
                  PhotoTile(url: url)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(offset == index ? 1 : 0.55)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.bottom, bottom + 12)
          }
        }
      }
      .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
    .statusBarHidden(false)
  }
}
