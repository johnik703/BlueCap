//
//  MutableCharacteristic.swift
//  BlueCap
//
//  Created by Troy Stribling on 8/9/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import Foundation
import CoreBluetooth

// MARK: - MutableCharacteristic -
public class MutableCharacteristic : NSObject {

    // MARK: Properties
    let profile: CharacteristicProfile

    fileprivate var centrals = [NSUUID : CBCentralInjectable]()

    fileprivate var queuedUpdates = [Data]()
    fileprivate var _isUpdating = false
    fileprivate var _value: Data?
    fileprivate var processWriteRequestPromise: StreamPromise<(request: CBATTRequestInjectable, central: CBCentralInjectable)>?

    let cbMutableChracteristic: CBMutableCharacteristicInjectable

    public internal(set) weak var service: MutableService?

    fileprivate var peripheralQueue: Queue {
        return service?.peripheralManager?.peripheralQueue ?? Queue("us.gnos.BlueCap.MutableCharacteristic")
    }

    public var value: Data? {
        get {
            return peripheralQueue.sync { return self._value }
        }
        set {
            peripheralQueue.sync { self._value = newValue }
        }
    }

    public var isUpdating: Bool {
        get {
            return peripheralQueue.sync { return self._isUpdating }
        }
    }

    public var UUID: CBUUID {
        return self.profile.UUID
    }

    public var name: String {
        return self.profile.name
    }
    
    public var stringValues: [String] {
        return self.profile.stringValues
    }
    
    public var permissions: CBAttributePermissions {
        return self.cbMutableChracteristic.permissions
    }
    
    public var properties: CBCharacteristicProperties {
        return self.cbMutableChracteristic.properties
    }

    public var subscribers: [CBCentralInjectable] {
        return peripheralQueue.sync {
            return Array(self.centrals.values)
        }
    }

    public var pendingUpdates : [Data] {
        return peripheralQueue.sync {
            return Array(self.queuedUpdates)
        }
    }

    public var stringValue: [String:String]? {
        if let value = self.value {
            return self.profile.stringValue(value)
        } else {
            return nil
        }
    }

    open var canNotify : Bool {
        return self.propertyEnabled(.notify)                    ||
               self.propertyEnabled(.indicate)                  ||
               self.propertyEnabled(.notifyEncryptionRequired)  ||
               self.propertyEnabled(.indicateEncryptionRequired)
    }

    // MARK: Initializers

    public convenience init(profile: CharacteristicProfile) {
        let cbMutableChracteristic = CBMutableCharacteristic(type: profile.UUID, properties: profile.properties, value: nil, permissions: profile.permissions)
        self.init(cbMutableCharacteristic: cbMutableChracteristic, profile: profile)
    }

    internal init(cbMutableCharacteristic: CBMutableCharacteristicInjectable, profile: CharacteristicProfile) {
        self.profile = profile
        self._value = profile.initialValue
        self.cbMutableChracteristic = cbMutableCharacteristic
    }

    internal init(cbMutableCharacteristic: CBMutableCharacteristicInjectable) {
        self.profile = CharacteristicProfile(UUID: cbMutableCharacteristic.UUID.uuidString)
        self._value = profile.initialValue
        self.cbMutableChracteristic = cbMutableCharacteristic
    }

    public init(UUID: String, properties: CBCharacteristicProperties, permissions: CBAttributePermissions, value: Data?) {
        self.profile = CharacteristicProfile(UUID: UUID)
        self._value = value
        self.cbMutableChracteristic = CBMutableCharacteristic(type:self.profile.UUID, properties:properties, value:nil, permissions:permissions)
    }

    public convenience init(UUID: String) {
        self.init(profile: CharacteristicProfile(UUID: UUID))
    }

    public class func withProfiles(_ profiles: [CharacteristicProfile]) -> [MutableCharacteristic] {
        return profiles.map{ MutableCharacteristic(profile: $0) }
    }

    public class func withProfiles(_ profiles: [CharacteristicProfile], cbCharacteristics: [CBMutableCharacteristic]) -> [MutableCharacteristic] {
        return profiles.map{ MutableCharacteristic(profile: $0) }
    }

    // MARK: Properties & Permissions

    public func propertyEnabled(_ property:CBCharacteristicProperties) -> Bool {
        return (self.properties.rawValue & property.rawValue) > 0
    }
    
    public func permissionEnabled(_ permission:CBAttributePermissions) -> Bool {
        return (self.permissions.rawValue & permission.rawValue) > 0
    }

    // MARK: Data

    public func data(fromString data: [String:String]) -> Data? {
        return self.profile.data(fromString: data)
    }

    // MARK: Manage Writes

    public func startRespondingToWriteRequests(capacity: Int = Int.max) -> FutureStream<(request: CBATTRequestInjectable, central: CBCentralInjectable)> {
        return peripheralQueue.sync {
            if let processWriteRequestPromise = self.processWriteRequestPromise {
                return processWriteRequestPromise.stream
            }
            self.processWriteRequestPromise = StreamPromise<(request: CBATTRequestInjectable, central: CBCentralInjectable)>(capacity: capacity)
            return self.processWriteRequestPromise!.stream
        }
    }
    
    public func stopRespondingToWriteRequests() {
        peripheralQueue.sync {
            self.processWriteRequestPromise = nil
        }
    }
    
    public func respondToRequest(_ request: CBATTRequestInjectable, withResult result: CBATTError.Code) {
        self.service?.peripheralManager?.respondToRequest(request, withResult: result)
    }

    internal func didRespondToWriteRequest(_ request: CBATTRequestInjectable, central: CBCentralInjectable) -> Bool  {
        guard let processWriteRequestPromise = self.processWriteRequestPromise else {
            return false
        }
        processWriteRequestPromise.success((request, central))
        return true
    }

    // MARK: Manage Notification Updates

    public func updateValue(withString value: [String:String]) -> Bool {
        guard let data = self.profile.data(fromString: value) else {
            return false
        }
        return self.update(withData: data)
    }

    public func update(withData value: Data) -> Bool  {
        return self.updateValues([value])
    }

    public func update<T: Deserializable>(_ value: T) -> Bool {
        return self.update(withData: SerDe.serialize(value))
    }

    public func update<T: RawDeserializable>(_ value: T) -> Bool  {
        return self.update(withData: SerDe.serialize(value))
    }

    public func update<T: RawArrayDeserializable>(_ value: T) -> Bool  {
        return self.update(withData: SerDe.serialize(value))
    }

    public func update<T: RawPairDeserializable>(_ value: T) -> Bool  {
        return self.update(withData: SerDe.serialize(value))
    }

    public func update<T: RawArrayPairDeserializable>(_ value: T) -> Bool  {
        return self.update(withData: SerDe.serialize(value))
    }

    // MARK: CBPeripheralManagerDelegate Shims

    internal func peripheralManagerIsReadyToUpdateSubscribers() {
        self._isUpdating = true
        let _ = self.updateValues(self.queuedUpdates)
        self.queuedUpdates.removeAll()
    }

    internal func didSubscribeToCharacteristic(_ central: CBCentralInjectable) {
        self._isUpdating = true
        self.centrals[central.identifier as NSUUID] = central
        let _ = self.updateValues(self.queuedUpdates)
        self.queuedUpdates.removeAll()
    }

    internal func didUnsubscribeFromCharacteristic(_ central: CBCentralInjectable) {
        self.centrals.removeValue(forKey: central.identifier as NSUUID)
        if self.centrals.keys.count == 0 {
            self._isUpdating = false
        }
    }

    // MARK: Utils

    fileprivate func updateValues(_ values: [Data]) -> Bool  {
        return peripheralQueue.sync {
            guard let value = values.last else {
                return self._isUpdating
            }
            self._value = value
            if let peripheralManager = self.service?.peripheralManager , self._isUpdating && self.canNotify {
                for value in values {
                    self._isUpdating = peripheralManager.updateValue(value, forCharacteristic:self)
                    if !self._isUpdating {
                        self.queuedUpdates.append(value)
                    }
                }
            } else {
                self._isUpdating = false
                self.queuedUpdates.append(value)
            }
            return self._isUpdating
        }
    }

}
