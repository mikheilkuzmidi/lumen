import LumenCore
import SwiftUI

/// A view of a draft only: hosts own validation, billing and the approval token.
public struct PlanReview<Thumbnail: View>: View {
    public var plan: BatchPlan
    public var targets: [PhotoID]
    @Binding public var instructions: [String: String]
    @Binding public var excluded: Set<PhotoID>
    public var estimate: String
    public var operations: [String]
    public var busy: Bool
    public var canApprove: Bool
    public var style: AssistantStyle
    public var name: (PhotoID) -> String
    public var changed: () -> Void
    public var approve: () -> Void
    public var cancel: () -> Void
    @ViewBuilder public var thumbnail: (PhotoID) -> Thumbnail

    public init(plan: BatchPlan, targets: [PhotoID], instructions: Binding<[String: String]>, excluded: Binding<Set<PhotoID>>,
                estimate: String, operations: [String] = [], busy: Bool = false, canApprove: Bool = true, style: AssistantStyle = AssistantStyle(),
                name: @escaping (PhotoID) -> String = { $0.rawValue }, changed: @escaping () -> Void,
                approve: @escaping () -> Void, cancel: @escaping () -> Void,
                @ViewBuilder thumbnail: @escaping (PhotoID) -> Thumbnail) {
        self.plan = plan; self.targets = targets; _instructions = instructions; _excluded = excluded
        self.estimate = estimate; self.operations = operations; self.busy = busy; self.canApprove = canApprove; self.style = style
        self.name = name; self.changed = changed; self.approve = approve; self.cancel = cancel; self.thumbnail = thumbnail
    }

    private var changingPhotos: Set<PhotoID> { Set(plan.changingPhotoIDs) }
    private var includedCount: Int {
        let changing = changingPhotos
        return targets.filter { changing.contains($0) && !excluded.contains($0) }.count
    }

    public var body: some View {
        let changingPhotos = self.changingPhotos
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review your plan").font(.system(size: 16, weight: .semibold))
                Text(plan.summary).font(.system(size: 12)).foregroundStyle(style.secondary).textSelection(.enabled)
                Text("Changes proposed for \(includedCount) of \(targets.count) photos")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(style.secondary)
            }
            ForEach(plan.groups) { group in groupCard(group) }
            if !operations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also in this plan").font(.system(size: 11, weight: .semibold))
                    ForEach(Array(operations.enumerated()), id: \.offset) { _, operation in
                        Label(operation, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(style.secondary)
                    }
                }
            }
            DisclosureGroup("Photos · \(targets.count)") {
                VStack(spacing: 8) {
                    ForEach(targets, id: \.self) { photo in
                        HStack(spacing: 8) {
                            thumbnail(photo).frame(width: 38, height: 30).clipped().clipShape(RoundedRectangle(cornerRadius: LumenRadii.photo, style: .continuous))
                            if changingPhotos.contains(photo) {
                                Toggle(name(photo), isOn: inclusion(photo)).toggleStyle(.checkbox)
                                    .font(.system(size: 11)).lineLimit(1)
                                    .accessibilityIdentifier("planPhoto.\(photo.rawValue)")
                            } else {
                                Text(name(photo)).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("Unchanged").font(.system(size: 10)).foregroundStyle(style.secondary)
                            }
                        }
                    }
                }.padding(.top, 8)
            }.font(.system(size: 11, weight: .medium))
            Text("Excluded photos stay untouched, including Auto, straightening and flags.")
                .font(.system(size: 10)).foregroundStyle(style.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(style.line)
            Text(estimate).font(.system(size: 11).monospacedDigit()).foregroundStyle(style.secondary)
                .accessibilityIdentifier("planEstimate")
            Button(action: approve) {
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.mini).tint(.white) }
                    Text(busy ? "Checking plan…" : "Approve \(includedCount) \(includedCount == 1 ? "photo" : "photos")").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white).padding(.vertical, 10)
                .background(style.accent, in: RoundedRectangle(cornerRadius: LumenRadii.control))
            }
            .buttonStyle(.plain).disabled(busy || !canApprove || includedCount == 0)
            .accessibilityIdentifier("planApprove")
            Button("Discard plan", action: cancel).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(style.secondary)
                .accessibilityIdentifier("planDiscard")
        }
        .foregroundStyle(style.primary).disabled(busy)
        .accessibilityElement(children: .contain).accessibilityIdentifier("assistantPlanReview")
    }

    private func groupCard(_ group: BatchGroup) -> some View {
        let included = group.photos.contains { !excluded.contains($0) }
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { included }, set: { enabled in
                for photo in group.photos { if enabled { excluded.remove(photo) } else { excluded.insert(photo) } }
                changed()
            })) {
                Text(group.title).font(.system(size: 12, weight: .medium))
            }.toggleStyle(.checkbox).accessibilityIdentifier("planGroup.\(group.id)")
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(group.photos, id: \.self) { photo in
                        thumbnail(photo).frame(width: 54, height: 42).clipped().clipShape(RoundedRectangle(cornerRadius: LumenRadii.photo, style: .continuous))
                            .opacity(excluded.contains(photo) ? 0.3 : 1)
                            .accessibilityLabel(name(photo))
                    }
                }
            }.scrollIndicators(.hidden)
            if let instruction = group.instruction {
                TextField("Edit instruction", text: Binding(get: { instructions[group.id] ?? instruction }, set: { value in
                    instructions[group.id] = value; changed()
                }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...5)
                .padding(9).background(style.panel, in: RoundedRectangle(cornerRadius: LumenRadii.control, style: .continuous))
                .accessibilityIdentifier("planInstruction.\(group.id)")
                .disabled(!included)
            } else {
                Text("Base adjustments").font(.system(size: 11)).foregroundStyle(style.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(style.raised, in: RoundedRectangle(cornerRadius: style.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: style.radius, style: .continuous).strokeBorder(style.line) }
    }

    private func inclusion(_ photo: PhotoID) -> Binding<Bool> {
        Binding(get: { !excluded.contains(photo) }, set: { enabled in
            if enabled { excluded.remove(photo) } else { excluded.insert(photo) }
            changed()
        })
    }
}
