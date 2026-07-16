import Foundation
import CLibMTP
import OSLog

private nonisolated final class ProgressBox: @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
}

private nonisolated let progressBridge: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    box.report(total > 0 ? Double(sent) / Double(total) : 0)
    return 0
}

actor MTPDeviceConnection: KindleDeviceConnection {
    private static let amazonVendorID: UInt16 = 0x1949

    private static let libmtpInitialized: Void = LIBMTP_Init()

    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var documentsFolderID: UInt32 = 0
    private var primaryStorageID: UInt32 = 0

    // MARK: - Detection

    nonisolated static func kindlePresent() -> Bool {
        _ = libmtpInitialized
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
        defer { free(rawDevices) }
        guard err == LIBMTP_ERROR_NONE, count > 0, let rawDevices else { return false }
        for i in 0 ..< Int(count) where isKindle(rawDevices[i]) {
            return true
        }
        return false
    }

    nonisolated private static func isKindle(_ raw: LIBMTP_raw_device_t) -> Bool {
        if raw.device_entry.vendor_id == amazonVendorID { return true }
        let vendor = raw.device_entry.vendor.map { String(cString: $0) } ?? ""
        let product = raw.device_entry.product.map { String(cString: $0) } ?? ""
        return vendor.localizedCaseInsensitiveContains("amazon")
            || product.localizedCaseInsensitiveContains("kindle")
    }

    // MARK: - Lifecycle

    func connect() throws {
        _ = Self.libmtpInitialized
        guard device == nil else { return }

        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
        defer { free(rawDevices) }
        guard err == LIBMTP_ERROR_NONE, count > 0, let rawDevices else {
            throw DeviceError.notConnected
        }

        for i in 0 ..< Int(count) where Self.isKindle(rawDevices[i]) {
            if let opened = LIBMTP_Open_Raw_Device(&rawDevices[i]) {
                device = opened
                LIBMTP_Clear_Errorstack(opened)
                loadStorageAndFolders()
                Log.device.info("Connected to Kindle over MTP")
                return
            }
        }
        Log.device.error("Detected a Kindle but LIBMTP_Open_Raw_Device failed")
        throw DeviceError.openFailed
    }

    func disconnect() {
        if let device {
            LIBMTP_Release_Device(device)
            Log.device.info("Released MTP device")
        }
        device = nil
        documentsFolderID = 0
        primaryStorageID = 0
    }

    func isAlive() -> Bool {
        device != nil && Self.kindlePresent()
    }

    private func loadStorageAndFolders() {
        guard let device else { return }

        _ = LIBMTP_Get_Storage(device, Int32(LIBMTP_STORAGE_SORTBY_MAXSPACE))
        guard let storage = device.pointee.storage else {
            Log.device.error("No MTP storage reported by the device")
            return
        }
        primaryStorageID = storage.pointee.id

        documentsFolderID = folderID(named: "documents", under: UInt32(LIBMTP_FILES_AND_FOLDERS_ROOT)) ?? 0
        Log.device.info("MTP ready: storage \(self.primaryStorageID), documents folder \(self.documentsFolderID)")
    }

    private func folderID(named name: String, under parent: UInt32) -> UInt32? {
        guard let device else { return nil }
        var match: UInt32?
        var node = LIBMTP_Get_Files_And_Folders(device, primaryStorageID, parent)
        while let file = node {
            if match == nil,
               file.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
               let raw = file.pointee.filename,
               String(cString: raw).localizedCaseInsensitiveCompare(name) == .orderedSame {
                match = file.pointee.item_id
            }
            let next = file.pointee.next
            LIBMTP_destroy_file_t(file)
            node = next
        }
        return match
    }

    // MARK: - Info

    func info() throws -> DeviceInfo {
        guard let device else { throw DeviceError.notConnected }

        var name = ""
        if let friendly = LIBMTP_Get_Friendlyname(device) {
            name = String(cString: friendly)
            free(friendly)
        }
        var model = ""
        if let modelName = LIBMTP_Get_Modelname(device) {
            model = String(cString: modelName)
            free(modelName)
        }
        var serial = ""
        if let serialNumber = LIBMTP_Get_Serialnumber(device) {
            serial = String(cString: serialNumber)
            free(serialNumber)
        }
        if name.isEmpty { name = model.isEmpty ? "Kindle" : model }

        var total: UInt64 = 0
        var freeBytes: UInt64 = 0
        var storage = device.pointee.storage
        while let node = storage {
            total += node.pointee.MaxCapacity
            freeBytes += node.pointee.FreeSpaceInBytes
            storage = node.pointee.next
        }

        return DeviceInfo(
            name: name,
            model: model,
            kind: .mtp,
            totalBytes: total,
            freeBytes: freeBytes,
            identifier: serial.isEmpty ? nil : "mtp:\(serial)"
        )
    }

    // MARK: - Files

    func listBooks() throws -> [DeviceBook] {
        guard let device else { throw DeviceError.notConnected }

        guard documentsFolderID != 0 else {
            Log.device.error("documents folder unknown — reporting no device books")
            return []
        }
        var books: [DeviceBook] = []
        var file = LIBMTP_Get_Files_And_Folders(device, primaryStorageID, documentsFolderID)
        while let node = file {
            let fileName = node.pointee.filename.map { String(cString: $0) } ?? ""
            let ext = (fileName as NSString).pathExtension.lowercased()
            if deviceBookExtensions.contains(ext) {
                let mtime = node.pointee.modificationdate
                books.append(DeviceBook(
                    mtpItemID: node.pointee.item_id,
                    path: nil,
                    fileName: fileName,
                    sizeBytes: node.pointee.filesize,
                    modifiedDate: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
                ))
            }
            let next = node.pointee.next
            LIBMTP_destroy_file_t(node)
            file = next
        }
        Log.device.info("Listed \(books.count) book(s) in documents")
        return books.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    func send(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let device else { throw DeviceError.notConnected }
        guard documentsFolderID != 0 else {
            Log.device.error("Refusing to send \(fileName, privacy: .public): documents folder unknown")
            throw DeviceError.transferFailed(code: -2)
        }
        let path = fileURL.path(percentEncoded: false)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else {
            throw DeviceError.fileMissing
        }
        Log.device.info("Sending \(fileName, privacy: .public) (\(size) bytes) → documents (folder \(self.documentsFolderID), storage \(self.primaryStorageID))")

        guard let meta = LIBMTP_new_file_t() else { throw DeviceError.transferFailed(code: -1) }
        meta.pointee.filename = strdup(fileName)
        meta.pointee.filesize = size
        meta.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        meta.pointee.parent_id = documentsFolderID
        meta.pointee.storage_id = primaryStorageID
        defer { LIBMTP_destroy_file_t(meta) }

        let box = ProgressBox(progress)
        let result = withExtendedLifetime(box) {
            LIBMTP_Send_File_From_File(
                device, path, meta, progressBridge,
                Unmanaged.passUnretained(box).toOpaque()
            )
        }
        guard result == 0 else {
            Log.device.error("LIBMTP_Send_File_From_File failed (code \(result)) for \(fileName, privacy: .public)")
            LIBMTP_Dump_Errorstack(device)
            LIBMTP_Clear_Errorstack(device)
            throw DeviceError.transferFailed(code: result)
        }
    }

    func copyBook(_ book: DeviceBook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let device else { throw DeviceError.notConnected }
        guard let itemID = book.mtpItemID else { throw DeviceError.fileMissing }

        let box = ProgressBox(progress)
        let result = withExtendedLifetime(box) {
            LIBMTP_Get_File_To_File(
                device, itemID, destination.path(percentEncoded: false), progressBridge,
                Unmanaged.passUnretained(box).toOpaque()
            )
        }
        guard result == 0 else {
            Log.device.error("LIBMTP_Get_File_To_File failed (code \(result)) for \(book.fileName, privacy: .public)")
            LIBMTP_Clear_Errorstack(device)
            throw DeviceError.transferFailed(code: result)
        }
    }

    func delete(_ book: DeviceBook) throws {
        guard let device else { throw DeviceError.notConnected }
        guard let itemID = book.mtpItemID else { throw DeviceError.fileMissing }
        let result = LIBMTP_Delete_Object(device, itemID)
        guard result == 0 else {
            LIBMTP_Clear_Errorstack(device)
            throw DeviceError.deleteFailed(code: result)
        }
    }

    func pushCoverThumbnail(_ fileURL: URL, named name: String) throws {
        guard let device else { throw DeviceError.notConnected }
        let parentID = thumbnailsFolderID()
        guard parentID != 0 else { throw DeviceError.transferFailed(code: -2) }

        let path = fileURL.path(percentEncoded: false)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { throw DeviceError.fileMissing }

        guard let meta = LIBMTP_new_file_t() else { throw DeviceError.transferFailed(code: -1) }
        meta.pointee.filename = strdup(name)
        meta.pointee.filesize = size
        meta.pointee.filetype = LIBMTP_FILETYPE_JPEG
        meta.pointee.parent_id = parentID
        meta.pointee.storage_id = primaryStorageID
        defer { LIBMTP_destroy_file_t(meta) }

        let result = LIBMTP_Send_File_From_File(device, path, meta, nil, nil)
        guard result == 0 else {
            LIBMTP_Clear_Errorstack(device)
            throw DeviceError.transferFailed(code: result)
        }
    }

    func removeAppleDoubleSidecars() -> Int { 0 }

    func readClippingsText() throws -> String? {
        guard let device else { throw DeviceError.notConnected }
        guard let itemID = fileID(named: "My Clippings.txt") else { return nil }
        let temp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        let result = LIBMTP_Get_File_To_File(device, itemID, temp.path(percentEncoded: false), nil, nil)
        guard result == 0 else {
            Log.device.error("Reading My Clippings.txt over MTP failed (libmtp code \(result))")
            LIBMTP_Clear_Errorstack(device)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let data = try? Data(contentsOf: temp) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func fileID(named name: String) -> UInt32? {
        guard let device, documentsFolderID != 0 else { return nil }
        var found: UInt32?
        var file = LIBMTP_Get_Files_And_Folders(device, primaryStorageID, documentsFolderID)
        while let node = file {
            if found == nil,
               node.pointee.filetype != LIBMTP_FILETYPE_FOLDER,
               let raw = node.pointee.filename,
               String(cString: raw).caseInsensitiveCompare(name) == .orderedSame {
                found = node.pointee.item_id
            }
            let next = node.pointee.next
            LIBMTP_destroy_file_t(node)
            file = next
        }
        return found
    }

    private func thumbnailsFolderID() -> UInt32 {
        let root = UInt32(LIBMTP_FILES_AND_FOLDERS_ROOT)
        guard let systemID = folderID(named: "system", under: root) else { return 0 }
        return folderID(named: "thumbnails", under: systemID) ?? 0
    }
}
