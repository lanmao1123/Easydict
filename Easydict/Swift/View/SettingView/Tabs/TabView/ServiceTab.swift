//
//  ServiceTab.swift
//  Easydict
//
//  Created by phlpsong on 2024/1/6.
//  Copyright © 2024 izual. All rights reserved.
//

import Combine
import Foundation
import SwiftUI

// MARK: - ServiceTab

struct ServiceTab: View {
    // MARK: Internal

    var body: some View {
        HSplitView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    List(
                        selection: Binding(
                            get: { viewModel.selectedItems },
                            set: { viewModel.selectItems($0) }
                        )
                    ) {
                        ServiceItems()
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.never)
                    .borderedCard()
                    .onReceive(serviceHasUpdatedNotification) { _ in
                        viewModel.updateServices()
                    }

                    ServiceListControls()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(minWidth: 270, maxWidth: 320, maxHeight: .infinity)

            ServiceDetailView()
                .layoutPriority(1)
        }
        .environmentObject(viewModel)
    }

    // MARK: Private

    @StateObject private var viewModel: ServiceTabViewModel = .init()

    private let serviceHasUpdatedNotification = NotificationCenter.default
        .publisher(for: .serviceHasUpdated)
}

// MARK: - ServiceTabSelection

enum ServiceTabSelection: Hashable {
    case service(String)
}

// MARK: - ServiceTabViewModel

@MainActor
class ServiceTabViewModel: ObservableObject {
    // MARK: Lifecycle

    init() {
        Self.sanitizeServiceTypes()
        self.serviceItems = Self.loadServiceItems()
        self.availableServiceItems = Self.loadAvailableServiceItems()
    }

    // MARK: Internal

    @Published private(set) var serviceItems: [ServiceListItem]

    @Published private(set) var availableServiceItems: [ServiceListItem]

    @Published private(set) var selectedService: QueryService?

    @Published private(set) var selectedItems: Set<ServiceTabSelection> = []

    var canRemoveSelectedServices: Bool {
        let selectedCount = selectedServiceItems.count
        return selectedCount > 0 && selectedCount < serviceItems.count
    }

    func updateServices() {
        serviceItems = Self.loadServiceItems()
        availableServiceItems = Self.loadAvailableServiceItems()

        let availableSelections = Set(
            serviceItems.map { ServiceTabSelection.service($0.id) }
        )
        let validSelections = selectedItems.filter { availableSelections.contains($0) }
        setSelection(Set(validSelections), preferred: selectedItem)
    }

    func moveServices(fromOffsets: IndexSet, toOffset: Int) {
        var serviceItems = serviceItems
        serviceItems.move(fromOffsets: fromOffsets, toOffset: Int(toOffset))

        let serviceTypes = serviceItems.map(\.id)
        LocalStorage.shared().setAllServiceTypes(serviceTypes, windowType: .main)

        postUpdateServiceNotification()
        updateServices()
    }

    func addServices(_ items: [ServiceListItem]) {
        var addedTypeIds: [String] = []
        var addedItems: [ServiceListItem] = []

        for item in items {
            let serviceTypeId = item.createsNewInstance
                ? "\(item.type.rawValue)#\(UUID().uuidString)"
                : item.id
            guard LocalStorage.shared().addServiceType(
                serviceTypeId,
                windowType: .main
            ) else {
                continue
            }
            addedTypeIds.append(serviceTypeId)
            addedItems.append(item)
        }

        guard let selectedTypeId = addedTypeIds.last else { return }
        setSelection([.service(selectedTypeId)])
        postUpdateServiceNotification()
        reloadLLMSubscribersIfNeeded(for: addedItems)
        updateServices()
    }

    func removeSelectedServices() {
        let selectedItems = selectedServiceItems
        guard !selectedItems.isEmpty, selectedItems.count < serviceItems.count else { return }

        let selectedTypeIds = Set(selectedItems.map(\.id))
        let remainingTypeIds = serviceItems
            .map(\.id)
            .filter { !selectedTypeIds.contains($0) }
        LocalStorage.shared().setAllServiceTypes(
            remainingTypeIds,
            windowType: .main
        )

        setSelection([])
        postUpdateServiceNotification()
        reloadLLMSubscribersIfNeeded(for: selectedItems)
        updateServices()
    }

    func selectItems(_ items: Set<ServiceTabSelection>) {
        let preferredItem = items.first
        setSelection(items, preferred: preferredItem)
    }

    func setServiceEnabled(_ enabled: Bool, for item: ServiceListItem) {
        if selectedService?.serviceTypeWithUniqueIdentifier() == item.id {
            selectedService?.enabled = enabled
            if let selectedService {
                LocalStorage.shared().setService(selectedService, windowType: .main)
            }
        } else {
            LocalStorage.shared().setServiceEnabled(
                enabled,
                serviceTypeId: item.id,
                windowType: .main
            )
        }

        postUpdateServiceNotification()
        reloadLLMSubscribersIfNeeded(for: [item])
        updateServices()
    }

    func postUpdateServiceNotification() {
        NotificationCenter.default.postServiceUpdateNotification(windowType: .main)
    }

    // MARK: Private

    private var selectedItem: ServiceTabSelection?

    private var selectedServiceItems: [ServiceListItem] {
        serviceItems.filter {
            selectedItems.contains(.service($0.id))
        }
    }

    /// The dock translate panel takes its translation from the first enabled
    /// service of the main-window list, so that list stays the single source
    /// of truth. Everything except the key-free built-in AI service is
    /// stripped — dropped services must never survive a settings visit.
    private static func sanitizeServiceTypes() {
        let current = LocalStorage.shared().allServiceTypes(.main)
        let kept = current.filter { typeId in
            guard let metadata = QueryServiceFactory.shared.metadata(withTypeId: typeId) else {
                return false
            }
            return metadata.serviceType == .builtInAI
        }
        if kept.isEmpty {
            LocalStorage.shared().setAllServiceTypes(
                [ServiceType.builtInAI.rawValue], windowType: .main
            )
        } else if kept.count != current.count {
            LocalStorage.shared().setAllServiceTypes(kept, windowType: .main)
        }
        if kept.contains(ServiceType.builtInAI.rawValue) || kept.isEmpty {
            // The dock translate panel reads the first enabled service; make
            // sure the survivor is actually on.
            LocalStorage.shared().setServiceEnabled(
                true, serviceTypeId: ServiceType.builtInAI.rawValue, windowType: .main
            )
        }
    }

    private static func loadServiceItems() -> [ServiceListItem] {
        serviceItems(from: LocalStorage.shared().allServiceTypes(.main))
    }

    private static func loadAvailableServiceItems() -> [ServiceListItem] {
        serviceItems(
            from: LocalStorage.shared().availableServiceTypeIDs(windowType: .main),
            forAddition: true
        )
    }

    private static func serviceItems(
        from serviceTypeIds: [String],
        forAddition: Bool = false
    )
        -> [ServiceListItem] {
        serviceTypeIds.compactMap { typeId in
            guard let metadata = QueryServiceFactory.shared.metadata(withTypeId: typeId),
                  metadata.serviceType == .builtInAI
            else {
                return nil
            }
            let createsNewInstance = forAddition
                && metadata.allowsMultipleInstances
                && metadata.uuid.isEmpty
            let info = LocalStorage.shared().serviceInfo(
                withType: metadata.serviceType,
                serviceId: metadata.uuid,
                windowType: .main
            )
            return ServiceListItem(
                id: typeId,
                type: metadata.serviceType,
                name: createsNewInstance
                    ? NSLocalizedString("custom_openai", comment: "")
                    : metadata.title,
                enabled: info?.enabled == true,
                requirement: metadata.apiKeyRequirement,
                isStream: metadata.isStream,
                createsNewInstance: createsNewInstance
            )
        }
    }

    private func updateSelectedService() {
        guard case let .service(serviceID) = selectedItem else {
            selectedService = nil
            return
        }
        guard serviceItems.contains(where: { $0.id == serviceID }) else {
            selectedService = nil
            return
        }
        selectedService = LocalStorage.shared().service(serviceID, windowType: .main)
    }

    private func setSelection(
        _ selection: Set<ServiceTabSelection>,
        preferred: ServiceTabSelection? = nil
    ) {
        selectedItem = preferred.flatMap {
            selection.contains($0) ? $0 : nil
        } ?? selection.first
        selectedItems = selection
        updateSelectedService()
    }

    private func reloadLLMSubscribersIfNeeded(for items: [ServiceListItem]) {
        // Stream configuration observers cover all window memberships, so any
        // window can add or remove a service that changes the observed union.
        guard items.contains(where: { $0.isStream }) else { return }
        GlobalContext.shared.reloadLLMServicesSubscribers()
    }
}

// MARK: - ServiceListItem

struct ServiceListItem: Identifiable {
    let id: String
    let type: ServiceType
    let name: String
    let enabled: Bool
    let requirement: ServiceAPIKeyRequirement
    let isStream: Bool
    let createsNewInstance: Bool
}

// MARK: - ServiceDetailView

private struct ServiceDetailView: View {
    // MARK: Internal

    var body: some View {
        Group {
            if let service = viewModel.selectedService {
                if let view = service.configurationListItems() as? (any View) {
                    Form {
                        AnyView(view)
                    }
                    .formStyle(.grouped)
                } else {
                    VStack {
                        Spacer()

                        Text("setting.service.detail.no_configuration \(service.name())")

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack {
                    Spacer()
                    Text("setting.service.detail.no_configuration \"\"")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Private

    @EnvironmentObject private var viewModel: ServiceTabViewModel
}
